import Darwin
import Foundation
import SkylightDaemonCore

/// The sessions: birth, pty IO, flow control, exit, removal.
extension Server {
    // MARK: - Sessions

    func spawn(_ request: SpawnRequest, for client: Client) {
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

    func performSpawn(_ request: SpawnRequest,
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

    func readFromPTY(_ session: Session) {
        // Drain the master to EAGAIN in one wake, coalescing into ONE frame:
        // events, not bytes, are the flood cost. The cap yields the queue so
        // one loud session cannot starve its siblings' IO. Reads land
        // straight in the shared scratch; exactly one copy makes the frame.
        var filled = 0
        var reachedEnd = false
        let fd = session.masterFD
        readScratch.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            while filled < raw.count {
                let n = read(fd, base + filled, raw.count - filled)
                if n > 0 { filled += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN { break }
                reachedEnd = true   // 0 or EIO: the child side is gone
                break
            }
        }
        if filled > 0 {
            // Output proves the child owns the tty: our winsize-preserving
            // slave can go, and child-exit EOF detection takes over.
            if session.slaveFD >= 0 {
                close(session.slaveFD)
                session.slaveFD = -1
            }
            var anyAttached = false
            var anyDrowning = false
            readScratch.withUnsafeBytes { raw in
                let window = UnsafeRawBufferPointer(rebasing: raw[0..<filled])
                session.ring.append(window)
                for client in clients.values where client.attached.contains(session.id) {
                    anyAttached = true
                    sendOutput(session.id, window, to: client)
                    if client.outboundPending > Self.clientHighWater { anyDrowning = true }
                }
            }
            // Flow control, both directions of absence:
            // — an attached client that can't keep up gets BACKPRESSURE (the
            //   child blocks on its tty, like under any real terminal),
            //   released at the low-water mark by flushOutbound;
            // — nobody attached means full-rate reading only overwrites the
            //   ring, so a flood is sampled in pulses instead of pegging a
            //   core for as long as it runs.
            if anyDrowning {
                pauseReading(session)
            } else if !anyAttached {
                session.detachedBurst += filled
                if session.detachedBurst >= Self.detachedBurstLimit {
                    session.detachedBurst = 0
                    pauseReading(session)
                    queue.asyncAfter(deadline: .now() + 0.25) { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.resumeReading(session)
                    }
                }
            } else {
                session.detachedBurst = 0
            }
        }
        if reachedEnd {
            // Drain complete — after the final bytes above went out. The fd
            // is closed by the cancel handler; -1 keeps INPUT/RESIZE frames
            // off whatever recycles the number.
            session.inputSource?.cancel()
            session.inputSource = nil
            session.readSource?.cancel()
            session.readSource = nil
            session.masterFD = -1
            session.drained = true
            announceExitIfComplete(session)
        }
    }

    func pauseReading(_ session: Session) {
        guard !session.readPaused, session.readSource != nil else { return }
        session.readPaused = true
        session.readSource?.suspend()
    }

    func resumeReading(_ session: Session) {
        guard session.readPaused else { return }
        session.readPaused = false
        session.readSource?.resume()
    }

    /// The tty-input twin of flushOutbound: drain what the tty will take,
    /// arm a write source for the rest.
    func flushInput(_ session: Session) {
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

    func armInput(_ session: Session) {
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

    func reapChildren() {
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
            // A paused reader must wake to see its EOF — and a suspended
            // source could never be cancelled at removal anyway.
            resumeReading(session)
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
    func announceExitIfComplete(_ session: Session) {
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

    func requestKill(_ session: Session) {
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

    func remove(_ session: Session) {
        // The read source's cancel handler owns the master fd close, on
        // every path — drained sources already ran it, live ones run it now.
        // The input source goes first: it shares that fd. A suspended source
        // must be resumed before cancel — dispatch's rule, not a preference.
        resumeReading(session)
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

    func exitIfIdle() {
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

    func log(_ message: String) {
        let stamp = logStamp.string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) [skylightd] \(message)\n".utf8))
    }

    /// Environmental failures end the daemon with a logged reason and a
    /// nonzero exit — never an abort trap; a crash report for a missing
    /// directory helps no one.
    func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }

}
