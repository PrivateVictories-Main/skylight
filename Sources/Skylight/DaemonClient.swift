import Darwin
import Foundation
import GhosttyTerminal
import SkylightDaemonCore

/// The app's side of the session keeper. One socket to skylightd, frames
/// multiplexed by session id: terminal keystrokes and resizes go out, output
/// and exits come back. Output lands directly in each session's
/// `InMemoryTerminalSession` from the read queue — thread-safe by the
/// library's contract — and exits hop to the main actor for the honesty
/// bookkeeping.
final class DaemonClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ryan.skylight.daemon-client")
    private var fd: Int32
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    /// Session routes, written on main at surface creation and read on the
    /// socket queue per frame — the one shared table, lock-guarded.
    private let lock = NSLock()
    private var routes: [UUID: InMemoryTerminalSession] = [:]
    /// Sessions whose attach — and therefore the daemon's ring replay —
    /// waits for the surface's SETTLED size. A rebuilding window reports a
    /// run of transitional grids (44×14 → 96×38 → …); replaying into any of
    /// them wraps every long line, and the reflow once the real size lands
    /// WAS the reattach-debris artifact (stray %, right-shifted prompts).
    /// Each reported size restarts a short quiet timer — the same contract
    /// as the daemon's own birth debounce — and only a grid that holds
    /// still receives the replay; a fallback covers surfaces that never lay
    /// out. (This supersedes the old winch-jiggle: a replay landing on the
    /// grid it was drawn for needs no child repaint.)
    private var deferredAttach: Set<UUID> = []
    private var attachSettleGeneration: [UUID: Int] = [:]
    /// The last link of end-to-end flow control: the read queue admits
    /// output to the parser through a token bucket, and when the bucket is
    /// dry it BLOCKS — the socket fills, the daemon's high-water pauses the
    /// pty, and the CHILD blocks on its tty. Renderer speed governs the
    /// producer, exactly like a real terminal; without this, a flood grew
    /// the parse queue without bound (the library's own drain barrier is
    /// internal, so the brake is a stated rate: the parser clocks ~2× this
    /// on one core, so the queue can never grow — and no human reads 32
    /// MB/s of terminal).
    private var floodTokens = Double(DaemonClient.floodBurst)
    private var floodRefillAt = DispatchTime.now()
    private static let floodRate = Double(32 << 20)   // bytes/second
    private static let floodBurst = 16 << 20

    /// What the daemon already held when we connected, by session id.
    /// Mutated (main actor only, like every store-facing call here) when a
    /// session is killed: a restarted dead-inherited id must SPAWN next
    /// time, not re-attach to a corpse the kill just removed — that path
    /// used to produce a permanently blank terminal.
    private(set) var inheritedSessions: [UUID: SessionInfo]

    /// A session's process ended (delivered on the main actor).
    var onExited: (@MainActor (UUID, Int32) -> Void)?
    /// The daemon is gone (crash, protocol error). Carries every id this
    /// client was routing, so the store can stop lying about them.
    var onConnectionLost: (@MainActor ([UUID]) -> Void)?
    // Deliberately ABSENT: `session.finish(exitCode:)` is never called. The
    // library's in-surface ending renders ghostty's app-model UI ("failed to
    // launch…", "Press any key to close the window") — two lies in this
    // app's model. The honesty layer is the sidebar's "Session ended" +
    // Restart; the surface simply holds its last output, which is the
    // bare-bones truth.

    private init(fd: Int32, inherited: [SessionInfo], leftover: Data) {
        self.fd = fd
        buffer = leftover   // before resume: the queue owns it afterwards
        inheritedSessions = Dictionary(uniqueKeysWithValues: inherited.map { ($0.id, $0) })
        // The handshake's receive timeout must not survive onto the
        // streaming fd: a spurious source wake would block a read for the
        // timeout and then read as a false connection loss.
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Sends, however, get a bound: a wedged daemon behind a full socket
        // buffer once parked the client queue in write() forever — and quit's
        // flush() then hung the app at the exact moment the survival promise
        // was being exercised. Two seconds, then the loss is handled honestly.
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO,
                   &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(fd) }
        source.resume()
        readSource = source
    }

    /// Drain queued outbound work (used at quit so a just-sent kill frame
    /// is not lost to process exit).
    func flush() { queue.sync {} }

    // MARK: - Bootstrap

    /// Connect to a live daemon or start one, then handshake. Runs on the
    /// caller's thread (once, at first terminal creation) and gives up fast:
    /// a nil return means the exec lane carries this app run.
    static func bootstrap() -> DaemonClient? {
        guard ProcessInfo.processInfo.environment["SKYLIGHT_NO_DAEMON"] == nil else {
            return nil
        }
        let socketPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight/daemon.sock").path
        for attempt in 0..<2 {
            if let fd = connectSocket(path: socketPath, retries: attempt == 0 ? 1 : 20) {
                switch handshake(fd: fd) {
                case let .compatible(sessions, leftover):
                    return DaemonClient(fd: fd, inherited: sessions, leftover: leftover)
                case let .stale(pid):
                    // A daemon from an older build: it dies (HUPping its
                    // children — they were that build's sessions), and a
                    // fresh one takes the socket.
                    close(fd)
                    Darwin.kill(pid, SIGTERM)
                    usleep(300_000)
                case .failed:
                    close(fd)
                    return nil
                }
            }
            guard spawnDaemon() else { return nil }
        }
        return nil
    }

    private static func spawnDaemon() -> Bool {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("skylightd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return false }
        let process = Process()
        process.executableURL = binary
        return (try? process.run()) != nil
    }

    private static func connectSocket(path: String, retries: Int) -> Int32? {
        let attempts = max(1, retries)
        for attempt in 0..<attempts {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            // The daemon can die between our write and its read; without
            // this, that write raises SIGPIPE and kills the whole app.
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                       &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            path.withCString { cPath in
                withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                    _ = strlcpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self),
                                cPath, dest.count)
                }
            }
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return fd }
            close(fd)
            if attempt < attempts - 1 { usleep(100_000) }
        }
        return nil
    }

    private enum HandshakeResult {
        case compatible([SessionInfo], leftover: Data)
        case stale(pid_t)
        case failed
    }

    private static func handshake(fd: Int32) -> HandshakeResult {
        // Bounded tightly: this runs before the first terminal can render,
        // and every worst case here is main-thread stall.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, socklen_t(MemoryLayout<timeval>.size))
        let hello = Wire.encode(WireFrame(type: .hello))
        let sent = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == hello.count else { return .failed }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return .failed }               // EOF: daemon died on us
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { continue }        // recv timeout; deadline decides
                return .failed
            }
            buffer.append(contentsOf: chunk[0..<n])
            guard let frames = try? Wire.decodeAvailable(&buffer),
                  let reply = frames.first(where: { $0.type == .helloReply })
            else { continue }
            guard let decoded = try? JSONDecoder().decode(HelloReply.self,
                                                          from: reply.payload)
            else { return .failed }
            guard decoded.busy != true else { return .failed }   // one app at a time
            guard decoded.protocolVersion == Wire.protocolVersion else {
                return .stale(decoded.daemonPID)
            }
            return .compatible(decoded.sessions, leftover: buffer)
        }
        return .failed
    }

    // MARK: - Outbound (any thread)

    func spawn(_ request: SpawnRequest, session: InMemoryTerminalSession) {
        register(session, for: request.id)
        let payload = (try? JSONEncoder().encode(request)) ?? Data()
        enqueue(WireFrame(type: .spawn, payload: payload))
    }

    /// Reattach to a session the daemon already holds. The attach frame —
    /// and with it the daemon's ring replay — is DEFERRED until the surface
    /// reports its first real size, so the replay always lands on the grid
    /// it was drawn for.
    func attach(_ id: UUID, session: InMemoryTerminalSession) {
        register(session, for: id)
        lock.lock()
        deferredAttach.insert(id)
        lock.unlock()
        // A surface that never lays out (created hidden) still gets its
        // replay — the same fallback contract as the daemon's birth timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.completeAttach(id)
        }
    }

    /// Restart the quiet timer for a deferred attach: 200ms without a new
    /// size report means the grid has settled and the replay can land.
    private func scheduleAttachSettle(_ id: UUID) {
        lock.lock()
        guard deferredAttach.contains(id) else { lock.unlock(); return }
        let generation = (attachSettleGeneration[id] ?? 0) + 1
        attachSettleGeneration[id] = generation
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.attachSettleGeneration[id]
            self.lock.unlock()
            if current == generation { self.completeAttach(id) }
        }
    }

    /// Send the clear + attach once the surface's grid has held still — or
    /// on the fallback timer. Idempotent: whichever fires second finds
    /// nothing to do.
    private func completeAttach(_ id: UUID) {
        lock.lock()
        let session = deferredAttach.remove(id) != nil ? routes[id] : nil
        attachSettleGeneration.removeValue(forKey: id)
        lock.unlock()
        guard let session else { return }
        // A clean slate before the replay: without it, replayed absolute
        // cursor moves land on whatever the fresh grid holds and the first
        // frame reads as debris. Queued on the session before the attach
        // frame goes out, so FIFO guarantees it renders first.
        session.receive("\u{1b}[H\u{1b}[2J")
        enqueue(WireFrame(type: .attach, payload: WirePayload.uuidData(id)))
    }

    func input(_ id: UUID, _ data: Data) {
        enqueue(WireFrame(type: .input, payload: WirePayload.idPrefixed(id, data)))
    }

    func resize(_ payload: ResizePayload) {
        // A surface reports a zeroed grid while detaching or hidden. Forwarded,
        // that reshaped the pty to 0×0 — and every shell falls back to 80×24,
        // drawing prompts for a width the renderer doesn't have. A zero-size
        // terminal is never a real request; it dies here.
        guard payload.columns > 0, payload.rows > 0 else { return }
        enqueue(WireFrame(type: .resize, payload: WirePayload.encodeResize(payload)))
        // Every size report restarts the deferred attach's quiet timer —
        // the replay goes out only once the grid holds still, and the
        // resize frames are already ahead of the attach in the pipe, so
        // the daemon applies the final grid before it replays.
        scheduleAttachSettle(payload.id)
    }

    func kill(_ id: UUID) {
        lock.lock()
        routes.removeValue(forKey: id)
        deferredAttach.remove(id)
        lock.unlock()
        // Killed means gone from the daemon too: a later terminal(for:) under
        // this id must SPAWN, never re-attach to the corpse this removed.
        inheritedSessions.removeValue(forKey: id)
        enqueue(WireFrame(type: .kill, payload: WirePayload.uuidData(id)))
    }

    private func register(_ session: InMemoryTerminalSession, for id: UUID) {
        lock.lock()
        routes[id] = session
        lock.unlock()
    }

    private func enqueue(_ frame: WireFrame) {
        let data = Wire.encode(frame)
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            let complete = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                let base = raw.baseAddress!
                while offset < raw.count {
                    let n = write(self.fd, base + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EINTR { continue }
                    return false   // SNDTIMEO expiry or a dead socket
                }
                return true
            }
            // A short write mid-frame has already corrupted the framing;
            // the only honest continuation is no continuation.
            if !complete { self.connectionLost("write stalled") }
        }
    }

    // MARK: - Inbound (socket queue)

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return connectionLost("read error \(errno)")
        }
        guard n > 0 else { return connectionLost("EOF") }
        buffer.append(contentsOf: chunk[0..<n])
        guard let frames = try? Wire.decodeAvailable(&buffer) else {
            return connectionLost("protocol error")
        }
        for frame in frames {
            switch frame.type {
            case .output:
                guard let (id, bytes) = WirePayload.parseIDPrefixed(frame.payload) else { continue }
                lock.lock()
                let session = routes[id]
                lock.unlock()
                guard let session else { continue }
                // Refill, spend, and — dry — deliberately block this
                // (background) read queue: the brake IS the point.
                let now = DispatchTime.now()
                let elapsed = Double(now.uptimeNanoseconds - floodRefillAt.uptimeNanoseconds) / 1e9
                floodRefillAt = now
                floodTokens = min(Double(Self.floodBurst), floodTokens + elapsed * Self.floodRate)
                floodTokens -= Double(bytes.count)
                session.receive(bytes)
                if floodTokens < 0 {
                    usleep(UInt32(min(0.25, -floodTokens / Self.floodRate) * 1e6))
                }
            case .exited:
                guard let (id, code) = WirePayload.parseExited(frame.payload) else { continue }
                lock.lock()
                let session = routes.removeValue(forKey: id)
                lock.unlock()
                guard session != nil else { continue }   // ghost echo for a deleted id
                if let onExited {
                    Task { @MainActor in onExited(id, code) }
                }
            default:
                break
            }
        }
    }

    /// The keeper is gone. The surfaces cannot be silently swapped to the
    /// exec lane (a running terminal must never be secretly replaced), so
    /// the store is told exactly which ids just became dead lanes — it marks
    /// them ended, restores the truthful quit dialog, and routes future
    /// terminals to the exec lane.
    private func connectionLost(_ reason: String) {
        NSLog("Skylight: daemon connection lost (\(reason))")
        readSource?.cancel()
        readSource = nil
        fd = -1
        lock.lock()
        let ids = Array(routes.keys)
        routes.removeAll()
        deferredAttach.removeAll()
        lock.unlock()
        if let onConnectionLost {
            Task { @MainActor in onConnectionLost(ids) }
        }
    }
}
