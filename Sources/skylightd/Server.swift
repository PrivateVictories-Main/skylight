import Darwin
import Foundation
import SkylightDaemonCore

/// The whole daemon lives on one serial queue: session table, pty reads,
/// client sockets, signals. No locks, no races — confinement is the design,
/// and the @unchecked Sendable marks below are that design stated to the
/// compiler: every closure that captures these types runs on `queue`.
final class Server: @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        let id: UUID
        let argv: [String]
        var pid: pid_t
        /// The child's kernel start time — with the pid, its identity proof
        /// in the orphan ledger (a recycled pid can never match).
        var startSeconds: Int64 = 0
        /// -1 once the master has drained and closed — INPUT/RESIZE frames
        /// arriving after that must never touch a recycled fd number.
        var masterFD: Int32
        /// Our held slave (see SpawnedChild.slaveFD): released on the first
        /// proof the child owns the tty — first output, or its reap.
        var slaveFD: Int32 = -1
        var readSource: DispatchSourceRead?
        /// Pending keystrokes for a tty whose input queue is full (child
        /// stopped, or just slow). Bounded: past the cap the NEWEST bytes are
        /// dropped with a log line — input to a wedged child is already lost
        /// semantically; unbounded memory would lose the daemon.
        var inputBacklog = Data()
        var inputSource: DispatchSourceWrite?
        var ring = OutputRing()
        var exitCode: Int32?
        /// Output fully drained from the master after child exit.
        var drained = false
        var exited: Bool { exitCode != nil }
        var exitAnnounced = false
        /// A client asked for this session's end: remove it the moment its
        /// exit completes instead of keeping the corpse for replay.
        var killRequested = false
        var killEscalation: DispatchSourceTimer?

        init(id: UUID, argv: [String], pid: pid_t, masterFD: Int32) {
            self.id = id
            self.argv = argv
            self.pid = pid
            self.masterFD = masterFD
        }
    }

    private final class Client: @unchecked Sendable {
        let fd: Int32
        /// True once this connection claimed the APP role via hello. A
        /// status probe never hellos (it lists), so it can neither trip the
        /// one-app gate nor bounce a launching app into the exec lane.
        var isApp = false
        var readSource: DispatchSourceRead?
        var buffer = Data()
        /// Frames waiting for a socket that can't take them right now. A
        /// blocking write here once meant one SIGSTOP'd app froze EVERY
        /// session's IO — the daemon's single queue must never block.
        var outbound = Data()
        var writeSource: DispatchSourceWrite?
        var attached: Set<UUID> = []

        init(fd: Int32) { self.fd = fd }
    }

    /// A client this far behind is not coming back for its bytes.
    private static let maxClientBacklog = 4 << 20
    /// Keystrokes queued for one tty; far beyond any legitimate typing.
    private static let maxInputBacklog = 1 << 20

    private let queue = DispatchQueue(label: "skylightd.server")
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sigchld: DispatchSourceSignal?
    private var sigterm: DispatchSourceSignal?
    private var sessions: [UUID: Session] = [:]
    /// Spawns waiting for their surface's size: a pty born at a guessed
    /// 80×24 lets the shell draw its first prompt for the wrong width — a
    /// wrapped right-prompt before the real size ever arrives. The surface
    /// reports a grid within a frame of mounting, but the FIRST report can
    /// still be one layout pass early (padding-balance settles a column
    /// later), so the birth is debounced briefly and takes the latest size:
    /// the child is born into the settled grid, never resized into it.
    private final class PendingSpawn: @unchecked Sendable {
        let request: SpawnRequest
        var latest: ResizePayload?
        /// Bumped per resize; a birth timer only fires for its own
        /// generation, so every fresh size restarts the quiet period.
        var generation = 0
        init(request: SpawnRequest) { self.request = request }
    }
    private var pendingSpawns: [UUID: PendingSpawn] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    /// A daemon that never gets a client is an orphan from a crashed launch —
    /// it exits rather than lingering; one that served a client exits when
    /// the last session AND last client are gone.
    private var everServed = false
    /// Bumped on every accept so a stale corpse-expiry timer from an earlier
    /// quiet period can never fire against a newer one's clock.
    private var clientGeneration = 0
    /// Orphans HUPped at boot whose SIGKILL escalation hasn't run yet. The
    /// daemon must not exit inside that window — the ledger is already gone,
    /// and a HUP-immune straggler would leak with no record anywhere.
    private var pendingOrphanKills: [LedgerEntry] = []
    private var lockFD: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        queue.async { self.bootstrap() }
    }

    private func bootstrap() {
        // One daemon per socket path, settled by flock — not by racy
        // probe-connect-unlink dances. The lock outlives everything (the fd
        // is held for the process lifetime), and ONLY the lock holder ever
        // unlinks the socket, so no interleaving of two starting daemons can
        // destroy a live one's socket.
        lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            log("another daemon holds the lock; exiting")
            exit(0)
        }
        // Under the lock (so no live daemon owns these), hang up whatever a
        // crashed predecessor left running: those children's pty masters
        // died with it, making them unreachable forever — leaked shells and
        // agents this machine would otherwise carry until reboot.
        sweepOrphans()
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { fail("socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { path in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                _ = strlcpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self),
                            path, dest.count)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        var bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, size)
            }
        }
        if bound != 0, errno == EADDRINUSE {
            // We hold the lock, so a socket file here is stale — except
            // during the one transition where a pre-lock-era daemon is still
            // live: a probe connect spares its socket.
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, size)
                }
            }
            close(probe)
            if connected == 0 {
                log("another (pre-lock) daemon is live; exiting")
                exit(0)
            }
            unlink(socketPath)
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, size)
                }
            }
        }
        guard bound == 0 else { fail("bind() failed: \(errno)") }
        chmod(socketPath, 0o600)
        guard listen(listenFD, 4) == 0 else { fail("listen() failed: \(errno)") }

        let accept = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        accept.setEventHandler { [weak self] in self?.acceptClient() }
        accept.resume()
        acceptSource = accept

        let chld = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        chld.setEventHandler { [weak self] in self?.reapChildren() }
        chld.resume()
        sigchld = chld

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { [weak self] in self?.shutdown() }
        term.resume()
        sigterm = term
        signal(SIGTERM, SIG_IGN)

        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.everServed else { return }
            self.log("no client within 60s; exiting")
            self.shutdown()
        }
        log("listening at \(socketPath)")
    }

    /// SIGTERM (or a stale-version replacement): sessions get a HUP — this
    /// path only runs when the user is losing the daemon anyway, and a
    /// half-orphaned shell is worse than a closed one.
    private func shutdown() {
        for session in sessions.values where !session.exited {
            kill(session.pid, SIGHUP)
        }
        // A SIGTERM mid-sweep cannot wait 3s (our replacement is waiting on
        // the flock) — settle the escalation right now instead of leaking it.
        for entry in pendingOrphanKills
        where processStartSeconds(entry.pid) == entry.startSeconds {
            log("escalating orphan sweep for pid=\(entry.pid) at shutdown")
            kill(entry.pid, SIGKILL)
        }
        unlink(socketPath)
        exit(0)
    }

    // MARK: - Clients

    private func acceptClient() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.readFromClient(client)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        client.readSource = source
        clients[ObjectIdentifier(client)] = client
        log("client connected (\(clients.count))")
    }

    private func readFromClient(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(client.fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return drop(client)
        }
        guard n > 0 else { return drop(client) }   // EOF
        client.buffer.append(contentsOf: chunk[0..<n])
        do {
            for frame in try Wire.decodeAvailable(&client.buffer) {
                handle(frame, from: client)
            }
        } catch {
            log("protocol error from client: \(error)")
            drop(client)
        }
    }

    private func drop(_ client: Client) {
        // Write source first: its fd is closed by the READ source's cancel
        // handler, and a source must never outlive its descriptor.
        client.writeSource?.cancel()
        client.writeSource = nil
        client.readSource?.cancel()
        client.readSource = nil
        clients.removeValue(forKey: ObjectIdentifier(client))
        // Unborn spawns leave with their requester: a session that never
        // started is not one the quit promise covers, and a fallback-spawned
        // ghost would pin the daemon open for nobody.
        for id in client.attached where pendingSpawns[id] != nil {
            pendingSpawns.removeValue(forKey: id)
        }
        log("client gone (\(clients.count))")
        exitIfIdle()
    }

    /// Never blocks: what the socket won't take now is buffered and drained
    /// by a write source. The daemon's one queue is every session's lifeline
    /// — a wedged client loses its connection, not everyone's IO.
    private func send(_ frame: WireFrame, to client: Client) {
        client.outbound.append(Wire.encode(frame))
        guard client.outbound.count <= Self.maxClientBacklog else {
            log("client backlog exceeded; dropping")
            return drop(client)
        }
        flushOutbound(client)
    }

    private func flushOutbound(_ client: Client) {
        while !client.outbound.isEmpty {
            let n = client.outbound.withUnsafeBytes { raw in
                write(client.fd, raw.baseAddress, min(raw.count, 128 * 1024))
            }
            if n > 0 {
                client.outbound.removeFirst(n)
            } else if n < 0, errno == EAGAIN {
                armWrite(client)
                return
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return drop(client)
            }
        }
        client.writeSource?.cancel()
        client.writeSource = nil
    }

    private func armWrite(_ client: Client) {
        guard client.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.flushOutbound(client)
        }
        source.resume()
        client.writeSource = source
    }

    // MARK: - Frames

    private func handle(_ frame: WireFrame, from client: Client) {
        switch frame.type {
        case .hello, .list:
            if frame.type == .hello {
                // Serving is an APP thing: a status probe connecting and
                // leaving must neither arm the idle-exit (it once killed the
                // daemon it had just reported on) nor restart the corpse
                // clock. The 60s no-client timer covers a never-helloed run.
                everServed = true
                clientGeneration += 1
            }
            // One app at a time — the spec's single-client rule, enforced
            // where it can be. Two app instances would otherwise fight over
            // the same session ids (SPAWN-replace SIGKILLs the first one's
            // children silently); the loser gets busy=true, falls back to
            // the exec lane, and hurts nothing.
            if frame.type == .hello,
               clients.values.contains(where: { $0 !== client && $0.isApp }) {
                let reply = HelloReply(protocolVersion: Wire.protocolVersion,
                                       daemonPID: getpid(), sessions: [], busy: true)
                send(WireFrame(type: .helloReply,
                               payload: (try? JSONEncoder().encode(reply)) ?? Data()),
                     to: client)
                log("busy: refused a second concurrent client")
                queue.asyncAfter(deadline: .now() + 1) { [weak self, weak client] in
                    guard let self, let client,
                          self.clients[ObjectIdentifier(client)] != nil else { return }
                    self.drop(client)
                }
                return
            }
            if frame.type == .hello { client.isApp = true }
            let appConnected = clients.values.contains { $0.isApp }
            let reply = HelloReply(
                protocolVersion: Wire.protocolVersion,
                daemonPID: getpid(),
                sessions: sessions.values.map {
                    SessionInfo(id: $0.id, argv: $0.argv,
                                alive: !$0.exited, exitCode: $0.exitCode,
                                startSeconds: $0.startSeconds,
                                ringBytes: $0.ring.count)
                },
                busy: frame.type == .list && appConnected ? true : nil,
                daemonStartSeconds: processStartSeconds(getpid()))
            let payload = (try? JSONEncoder().encode(reply)) ?? Data()
            send(WireFrame(type: frame.type == .hello ? .helloReply : .listReply,
                           payload: payload), to: client)
        case .spawn:
            guard let request = try? JSONDecoder().decode(SpawnRequest.self,
                                                          from: frame.payload) else {
                // Malformed spawn is a protocol error — a silent return would
                // leave the client waiting forever for a session that will
                // never exist.
                log("undecodable spawn payload; dropping client")
                return drop(client)
            }
            spawn(request, for: client)
        case .attach:
            guard let id = WirePayload.uuid(from: frame.payload),
                  let session = sessions[id] else { return }
            client.attached.insert(id)
            if session.ring.count > 0 {
                send(WireFrame(type: .output,
                               payload: WirePayload.idPrefixed(id, session.ring.contents)),
                     to: client)
            }
            if session.exited, let code = session.exitCode {
                send(WireFrame(type: .exited,
                               payload: WirePayload.encodeExited(id, code: code)), to: client)
            }
        case .input:
            // masterFD guard as well as exited: drain and reap are
            // independent, and a drained-but-unreaped session's fd number
            // may already belong to someone else.
            guard let (id, bytes) = WirePayload.parseIDPrefixed(frame.payload),
                  let session = sessions[id], !session.exited,
                  session.masterFD >= 0 else { return }
            session.inputBacklog.append(bytes)
            if session.inputBacklog.count > Self.maxInputBacklog {
                log("input backlog exceeded for \(id); dropping newest")
                session.inputBacklog.removeLast(
                    session.inputBacklog.count - Self.maxInputBacklog)
            }
            flushInput(session)
        case .resize:
            guard let resize = WirePayload.parseResize(frame.payload),
                  resize.columns > 0, resize.rows > 0 else { return }
            if let pending = pendingSpawns[resize.id] {
                // Quiet-period birth: the surface's grid moves through
                // transitional sizes while layout settles, and a shell born
                // into one draws its first prompt for a width that is about
                // to be wrong — worse, zsh can miss the corrective SIGWINCH
                // during its own startup. Every DIFFERING size restarts the
                // clock; the child is born only once the grid holds still.
                let changed = pending.latest.map {
                    $0.columns != resize.columns || $0.rows != resize.rows
                } ?? true
                pending.latest = resize
                guard changed else { return }
                pending.generation += 1
                let generation = pending.generation
                // Identity- and generation-guarded: a kill-then-respawn
                // replaces the pending object, and a newer size obsoletes
                // this timer.
                queue.asyncAfter(deadline: .now() + 0.2) { [weak self, weak pending] in
                    guard let self, let pending,
                          self.pendingSpawns[resize.id] === pending,
                          pending.generation == generation,
                          let size = pending.latest else { return }
                    self.pendingSpawns.removeValue(forKey: resize.id)
                    self.performSpawn(pending.request,
                                      columns: size.columns, rows: size.rows,
                                      widthPixels: size.widthPixels,
                                      heightPixels: size.heightPixels)
                }
                return
            }
            guard let session = sessions[resize.id], !session.exited,
                  session.masterFD >= 0 else { return }
            PTY.resize(masterFD: session.masterFD,
                       columns: resize.columns, rows: resize.rows,
                       widthPixels: resize.widthPixels, heightPixels: resize.heightPixels)
        case .kill:
            guard let id = WirePayload.uuid(from: frame.payload) else { return }
            if pendingSpawns.removeValue(forKey: id) != nil {
                for client in clients.values { client.attached.remove(id) }
                return
            }
            guard let session = sessions[id] else { return }
            requestKill(session)
        case .helloReply, .output, .exited, .listReply:
            break   // daemon→client types arriving here are a client bug; ignore
        }
    }

    // MARK: - Sessions

    private func spawn(_ request: SpawnRequest, for client: Client) {
        if let existing = sessions[request.id] {
            // A respawn under a known id replaces the old session outright —
            // the restart flow kills first, so a live leftover is defensive.
            if !existing.exited { kill(existing.pid, SIGKILL) }
            remove(existing)
        }
        pendingSpawns.removeValue(forKey: request.id)
        // Client-controlled data crashes nothing: an unrunnable request is an
        // instant honest exit, exactly like a binary that fails to exec.
        guard !request.argv.isEmpty else {
            send(WireFrame(type: .exited,
                           payload: WirePayload.encodeExited(request.id, code: 127)),
                 to: client)
            return
        }
        // Enqueue, don't exec: the child waits for its surface's settled
        // size (see pendingSpawns). A fallback covers a client that never
        // resizes at all.
        let pending = PendingSpawn(request: request)
        pendingSpawns[request.id] = pending
        client.attached.insert(request.id)
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak pending] in
            guard let self, let pending,
                  self.pendingSpawns[request.id] === pending else { return }
            self.pendingSpawns.removeValue(forKey: request.id)
            let size = pending.latest
            self.log("grid never settled for \(request.id); spawning at "
                + "\(size?.columns ?? 80)x\(size?.rows ?? 24)")
            self.performSpawn(pending.request,
                              columns: size?.columns ?? 80, rows: size?.rows ?? 24,
                              widthPixels: size?.widthPixels ?? 0,
                              heightPixels: size?.heightPixels ?? 0)
        }
    }

    private func performSpawn(_ request: SpawnRequest,
                              columns: UInt16, rows: UInt16,
                              widthPixels: UInt16, heightPixels: UInt16) {
        // A working directory deleted while the app was closed is the common
        // spawn killer — the shell still deserves to exist. Home instead.
        var cwd = request.cwd
        if let dir = cwd, !FileManager.default.fileExists(atPath: dir) {
            log("cwd \(dir) is gone; spawning in home")
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
        }
        do {
            let child = try PTY.spawn(argv: request.argv, cwd: cwd,
                                      extraEnv: request.env,
                                      columns: max(2, columns), rows: max(2, rows),
                                      widthPixels: widthPixels,
                                      heightPixels: heightPixels)
            // Non-blocking master, both directions: a full tty input queue
            // (stopped child) or a torrent of output must never block the
            // one queue every session lives on.
            _ = fcntl(child.masterFD, F_SETFL,
                      fcntl(child.masterFD, F_GETFL) | O_NONBLOCK)
            let session = Session(id: request.id, argv: request.argv,
                                  pid: child.pid, masterFD: child.masterFD)
            session.slaveFD = child.slaveFD
            session.startSeconds = processStartSeconds(child.pid) ?? 0
            sessions[request.id] = session
            persistLedger()
            let source = DispatchSource.makeReadSource(fileDescriptor: child.masterFD,
                                                       queue: queue)
            source.setEventHandler { [weak self, weak session] in
                guard let self, let session else { return }
                self.readFromPTY(session)
            }
            source.setCancelHandler { [masterFD = child.masterFD] in close(masterFD) }
            source.resume()
            session.readSource = source
            log("spawned \(request.argv[0]) pid=\(child.pid) id=\(request.id) grid=\(columns)x\(rows)")
        } catch {
            log("spawn failed for \(request.argv): \(error)")
            // The child never existed: report an instant exit so the
            // surface shows an honest end instead of hanging empty. To every
            // attached client — the requester attached at enqueue time.
            let payload = WirePayload.encodeExited(request.id, code: 127)
            for client in clients.values where client.attached.contains(request.id) {
                send(WireFrame(type: .exited, payload: payload), to: client)
            }
        }
    }

    private func readFromPTY(_ session: Session) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(session.masterFD, &chunk, chunk.count)
        if n > 0 {
            // Output proves the child owns the tty: our winsize-preserving
            // slave can go, and child-exit EOF detection takes over.
            if session.slaveFD >= 0 {
                close(session.slaveFD)
                session.slaveFD = -1
            }
            let data = Data(chunk[0..<n])
            session.ring.append(data)
            let payload = WirePayload.idPrefixed(session.id, data)
            for client in clients.values where client.attached.contains(session.id) {
                send(WireFrame(type: .output, payload: payload), to: client)
            }
        } else if n < 0, errno == EAGAIN || errno == EINTR {
            // A non-blocking master can wake spuriously — this is NOT the
            // drain signal, and treating it as one would announce an exit
            // that never happened.
            return
        } else {
            // EOF/EIO: the child side is gone. Drain complete. The fd is
            // closed by the cancel handler; -1 keeps INPUT/RESIZE frames off
            // whatever recycles the number.
            session.inputSource?.cancel()
            session.inputSource = nil
            session.readSource?.cancel()
            session.readSource = nil
            session.masterFD = -1
            session.drained = true
            announceExitIfComplete(session)
        }
    }

    /// The tty-input twin of flushOutbound: drain what the tty will take,
    /// arm a write source for the rest.
    private func flushInput(_ session: Session) {
        guard session.masterFD >= 0 else { return }
        while !session.inputBacklog.isEmpty {
            let n = session.inputBacklog.withUnsafeBytes { raw in
                write(session.masterFD, raw.baseAddress, raw.count)
            }
            if n > 0 {
                session.inputBacklog.removeFirst(n)
            } else if n < 0, errno == EAGAIN {
                armInput(session)
                return
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return   // dying tty; the drain path owns the cleanup
            }
        }
        session.inputSource?.cancel()
        session.inputSource = nil
    }

    private func armInput(_ session: Session) {
        guard session.inputSource == nil, session.masterFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: session.masterFD,
                                                    queue: queue)
        source.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.flushInput(session)
        }
        source.resume()
        session.inputSource = source
    }

    private func reapChildren() {
        while true {
            var status: Int32 = 0
            let pid = waitpid(-1, &status, WNOHANG)
            guard pid > 0 else { break }
            guard let session = sessions.values.first(where: { $0.pid == pid }) else { continue }
            let code: Int32
            if status & 0x7F == 0 {           // WIFEXITED
                code = (status >> 8) & 0xFF   // WEXITSTATUS
            } else {
                code = 128 + (status & 0x7F)  // signal deaths, shell-style
            }
            session.exitCode = code
            // A child that never spoke still holds our slave hostage — its
            // reap is the other proof, and the master needs the close to EOF.
            if session.slaveFD >= 0 {
                close(session.slaveFD)
                session.slaveFD = -1
            }
            session.killEscalation?.cancel()
            session.killEscalation = nil
            if session.killRequested, !session.drained {
                // A grandchild holding the slave open can stall the drain
                // forever; under an explicit kill the leader's death is
                // enough. Marking drained closes the master via the removal
                // below — a real hangup for whatever still holds the tty.
                session.drained = true
            }
            persistLedger()
            announceExitIfComplete(session)
        }
    }

    /// EXITED goes out only when the child is reaped AND its last output has
    /// been drained — an exit racing ahead of its own final bytes would make
    /// the client finish the surface early and drop them.
    private func announceExitIfComplete(_ session: Session) {
        guard session.exited, session.drained, !session.exitAnnounced,
              let code = session.exitCode else { return }
        session.exitAnnounced = true
        let payload = WirePayload.encodeExited(session.id, code: code)
        for client in clients.values where client.attached.contains(session.id) {
            send(WireFrame(type: .exited, payload: payload), to: client)
        }
        log("session \(session.id) exited code=\(code)")
        if session.killRequested {
            remove(session)
            exitIfIdle()
        }
        // Otherwise the dead session is KEPT (ring + code) until a client
        // kills it — a relaunching app deserves the replay and the ending.
    }

    private func requestKill(_ session: Session) {
        if session.exited {
            remove(session)
            exitIfIdle()
            return
        }
        // Removal is deterministic: announceExitIfComplete sees the flag the
        // moment reap-and-drain completes. The timer only escalates a child
        // that shrugs off the HUP.
        session.killRequested = true
        kill(session.pid, SIGHUP)
        session.killEscalation?.cancel()   // a second kill must not leak the first timer
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session, !session.exited else { return }
            self.log("escalating kill for pid=\(session.pid)")
            kill(session.pid, SIGKILL)
        }
        timer.resume()
        session.killEscalation = timer
    }

    private func remove(_ session: Session) {
        // The read source's cancel handler owns the master fd close, on
        // every path — drained sources already ran it, live ones run it now.
        // The input source goes first: it shares that fd.
        session.inputSource?.cancel()
        session.inputSource = nil
        session.readSource?.cancel()
        session.readSource = nil
        session.masterFD = -1
        if session.slaveFD >= 0 {
            close(session.slaveFD)
            session.slaveFD = -1
        }
        session.killEscalation?.cancel()
        session.killEscalation = nil
        sessions.removeValue(forKey: session.id)
        for client in clients.values { client.attached.remove(session.id) }
        persistLedger()
    }

    private func exitIfIdle() {
        // The sweep's escalation must complete first: exiting mid-window
        // leaks a HUP-immune orphan whose ledger record is already gone.
        guard pendingOrphanKills.isEmpty else { return }
        guard everServed, clients.isEmpty else { return }
        if sessions.isEmpty {
            log("idle; exiting")
            unlink(socketPath)
            exit(0)
        }
        // Only dead sessions left and nobody connected: hold the replay for a
        // returning app, but not forever — a daemon carrying nothing but
        // corpses exits after ten unclaimed minutes. Generation-stamped so a
        // reconnect-and-leave restarts the clock instead of inheriting an
        // older timer's earlier deadline.
        if sessions.values.allSatisfy(\.exited) {
            let generation = clientGeneration
            queue.asyncAfter(deadline: .now() + 600) { [weak self] in
                guard let self, self.clientGeneration == generation,
                      self.clients.isEmpty,
                      self.sessions.values.allSatisfy(\.exited) else { return }
                self.log("unclaimed dead sessions; exiting")
                unlink(self.socketPath)
                exit(0)
            }
        }
    }

    private let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func log(_ message: String) {
        let stamp = logStamp.string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) [skylightd] \(message)\n".utf8))
    }

    /// Environmental failures end the daemon with a logged reason and a
    /// nonzero exit — never an abort trap; a crash report for a missing
    /// directory helps no one.
    private func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }

    // MARK: - Orphan ledger

    private var ledgerPath: String { socketPath + ".ledger" }

    private func processStartSeconds(_ pid: pid_t) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return Int64(info.pbi_start_tvsec)
    }

    /// Every live child, persisted so a successor can find what a crash of
    /// ours would orphan. Written on spawn, exit, and removal — tiny and
    /// rare; removed outright when nothing is running.
    private func persistLedger() {
        let entries = sessions.values.compactMap { session -> LedgerEntry? in
            guard !session.exited else { return nil }
            return LedgerEntry(pid: session.pid, startSeconds: session.startSeconds)
        }
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(atPath: ledgerPath)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: URL(fileURLWithPath: ledgerPath), options: .atomic)
        }
    }

    private func sweepOrphans() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ledgerPath)) else { return }
        try? FileManager.default.removeItem(atPath: ledgerPath)
        guard let previous = try? JSONDecoder().decode([LedgerEntry].self, from: data)
        else { return }
        let orphans = OrphanSweep.orphans(in: previous) { processStartSeconds($0) }
        guard !orphans.isEmpty else { return }
        for entry in orphans {
            log("sweeping orphan pid=\(entry.pid) left by a crashed predecessor")
            kill(entry.pid, SIGHUP)
        }
        pendingOrphanKills = orphans
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            for entry in self.pendingOrphanKills
            where self.processStartSeconds(entry.pid) == entry.startSeconds {
                self.log("escalating orphan sweep for pid=\(entry.pid)")
                kill(entry.pid, SIGKILL)
            }
            self.pendingOrphanKills = []
            self.exitIfIdle()
        }
    }
}
