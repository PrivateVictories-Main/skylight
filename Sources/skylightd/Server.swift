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
        var masterFD: Int32
        var readSource: DispatchSourceRead?
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
        var readSource: DispatchSourceRead?
        var buffer = Data()
        var attached: Set<UUID> = []

        init(fd: Int32) { self.fd = fd }
    }

    private let queue = DispatchQueue(label: "skylightd.server")
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sigchld: DispatchSourceSignal?
    private var sigterm: DispatchSourceSignal?
    private var sessions: [UUID: Session] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    /// A daemon that never gets a client is an orphan from a crashed launch —
    /// it exits rather than lingering; one that served a client exits when
    /// the last session AND last client are gone.
    private var everServed = false

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        queue.async { self.bootstrap() }
    }

    private func bootstrap() {
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { fatalError("socket() failed: \(errno)") }
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
            // A socket file exists. A LIVE daemon answers a connect; ours
            // then has no job. A stale file refuses — unlink and claim it.
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, size)
                }
            }
            close(probe)
            if connected == 0 {
                log("another daemon is live; exiting")
                exit(0)
            }
            unlink(socketPath)
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, size)
                }
            }
        }
        guard bound == 0 else { fatalError("bind() failed: \(errno)") }
        chmod(socketPath, 0o600)
        guard listen(listenFD, 4) == 0 else { fatalError("listen() failed: \(errno)") }

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
        unlink(socketPath)
        exit(0)
    }

    // MARK: - Clients

    private func acceptClient() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        everServed = true
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
        guard n > 0 else { return drop(client) }
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
        client.readSource?.cancel()
        client.readSource = nil
        clients.removeValue(forKey: ObjectIdentifier(client))
        log("client gone (\(clients.count))")
        exitIfIdle()
    }

    private func send(_ frame: WireFrame, to client: Client) {
        let data = Wire.encode(frame)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            let base = raw.baseAddress!
            while offset < raw.count {
                let n = write(client.fd, base + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        if !ok { drop(client) }
    }

    // MARK: - Frames

    private func handle(_ frame: WireFrame, from client: Client) {
        switch frame.type {
        case .hello, .list:
            let reply = HelloReply(
                protocolVersion: Wire.protocolVersion,
                daemonPID: getpid(),
                sessions: sessions.values.map {
                    SessionInfo(id: $0.id, argv: $0.argv,
                                alive: !$0.exited, exitCode: $0.exitCode)
                })
            let payload = (try? JSONEncoder().encode(reply)) ?? Data()
            send(WireFrame(type: frame.type == .hello ? .helloReply : .listReply,
                           payload: payload), to: client)
        case .spawn:
            guard let request = try? JSONDecoder().decode(SpawnRequest.self,
                                                          from: frame.payload) else { return }
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
            guard let (id, bytes) = WirePayload.parseIDPrefixed(frame.payload),
                  let session = sessions[id], !session.exited else { return }
            _ = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(session.masterFD, base, raw.count)
            }
        case .resize:
            guard let resize = WirePayload.parseResize(frame.payload),
                  let session = sessions[resize.id], !session.exited else { return }
            PTY.resize(masterFD: session.masterFD,
                       columns: resize.columns, rows: resize.rows,
                       widthPixels: resize.widthPixels, heightPixels: resize.heightPixels)
        case .kill:
            guard let id = WirePayload.uuid(from: frame.payload),
                  let session = sessions[id] else { return }
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
        do {
            let child = try PTY.spawn(argv: request.argv, cwd: request.cwd,
                                      extraEnv: request.env)
            let session = Session(id: request.id, argv: request.argv,
                                  pid: child.pid, masterFD: child.masterFD)
            sessions[request.id] = session
            client.attached.insert(request.id)
            let source = DispatchSource.makeReadSource(fileDescriptor: child.masterFD,
                                                       queue: queue)
            source.setEventHandler { [weak self, weak session] in
                guard let self, let session else { return }
                self.readFromPTY(session)
            }
            source.setCancelHandler { [masterFD = child.masterFD] in close(masterFD) }
            source.resume()
            session.readSource = source
            log("spawned \(request.argv[0]) pid=\(child.pid) id=\(request.id)")
        } catch {
            log("spawn failed for \(request.argv): \(error)")
            // The child never existed: report it as an instant exit so the
            // client's surface shows an honest end instead of hanging empty.
            send(WireFrame(type: .exited,
                           payload: WirePayload.encodeExited(request.id, code: 127)),
                 to: client)
        }
    }

    private func readFromPTY(_ session: Session) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(session.masterFD, &chunk, chunk.count)
        if n > 0 {
            let data = Data(chunk[0..<n])
            session.ring.append(data)
            let payload = WirePayload.idPrefixed(session.id, data)
            for client in clients.values where client.attached.contains(session.id) {
                send(WireFrame(type: .output, payload: payload), to: client)
            }
        } else {
            // EOF/EIO: the child side is gone. Drain complete.
            session.readSource?.cancel()
            session.readSource = nil
            session.drained = true
            announceExitIfComplete(session)
        }
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
            session.killEscalation?.cancel()
            session.killEscalation = nil
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
        session.readSource?.cancel()
        session.readSource = nil
        session.killEscalation?.cancel()
        session.killEscalation = nil
        sessions.removeValue(forKey: session.id)
        for client in clients.values { client.attached.remove(session.id) }
    }

    private func exitIfIdle() {
        guard everServed, clients.isEmpty else { return }
        if sessions.isEmpty {
            log("idle; exiting")
            unlink(socketPath)
            exit(0)
        }
        // Only dead sessions left and nobody connected: hold the replay for a
        // returning app, but not forever — a daemon carrying nothing but
        // corpses exits after ten unclaimed minutes.
        if sessions.values.allSatisfy(\.exited) {
            queue.asyncAfter(deadline: .now() + 600) { [weak self] in
                guard let self, self.clients.isEmpty,
                      self.sessions.values.allSatisfy(\.exited) else { return }
                self.log("unclaimed dead sessions; exiting")
                unlink(self.socketPath)
                exit(0)
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[skylightd] \(message)\n".utf8))
    }
}
