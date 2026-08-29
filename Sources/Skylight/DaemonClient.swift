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
    /// Reattaching surfaces whose next resize should jiggle (rows−1, rows) so
    /// a replayed full-screen TUI repaints — dtach's winch trick.
    private var jigglePending: Set<UUID> = []

    /// What the daemon already held when we connected, by session id.
    let inheritedSessions: [UUID: SessionInfo]

    /// A session's process ended (delivered on the main actor).
    var onExited: (@MainActor (UUID, Int32) -> Void)?

    private init(fd: Int32, inherited: [SessionInfo]) {
        self.fd = fd
        inheritedSessions = Dictionary(uniqueKeysWithValues: inherited.map { ($0.id, $0) })
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(fd) }
        source.resume()
        readSource = source
    }

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
                    let client = DaemonClient(fd: fd, inherited: sessions)
                    client.buffer = leftover
                    return client
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
        for _ in 0..<max(1, retries) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
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
            usleep(100_000)
        }
        return nil
    }

    private enum HandshakeResult {
        case compatible([SessionInfo], leftover: Data)
        case stale(pid_t)
        case failed
    }

    private static func handshake(fd: Int32) -> HandshakeResult {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, socklen_t(MemoryLayout<timeval>.size))
        let hello = Wire.encode(WireFrame(type: .hello))
        let sent = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == hello.count else { return .failed }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { continue }
            buffer.append(contentsOf: chunk[0..<n])
            guard let frames = try? Wire.decodeAvailable(&buffer),
                  let reply = frames.first(where: { $0.type == .helloReply })
            else { continue }
            guard let decoded = try? JSONDecoder().decode(HelloReply.self,
                                                          from: reply.payload)
            else { return .failed }
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

    /// Reattach to a session the daemon already holds. Replay arrives as
    /// ordinary output; a live one gets the repaint jiggle on its first
    /// resize.
    func attach(_ id: UUID, session: InMemoryTerminalSession, live: Bool) {
        register(session, for: id)
        if live {
            lock.lock()
            jigglePending.insert(id)
            lock.unlock()
        }
        enqueue(WireFrame(type: .attach, payload: WirePayload.uuidData(id)))
    }

    func input(_ id: UUID, _ data: Data) {
        enqueue(WireFrame(type: .input, payload: WirePayload.idPrefixed(id, data)))
    }

    func resize(_ payload: ResizePayload) {
        lock.lock()
        let jiggle = jigglePending.remove(payload.id) != nil
        lock.unlock()
        if jiggle, payload.rows > 1 {
            var smaller = payload
            smaller.rows -= 1
            enqueue(WireFrame(type: .resize, payload: WirePayload.encodeResize(smaller)))
        }
        enqueue(WireFrame(type: .resize, payload: WirePayload.encodeResize(payload)))
    }

    func kill(_ id: UUID) {
        lock.lock()
        routes.removeValue(forKey: id)
        jigglePending.remove(id)
        lock.unlock()
        enqueue(WireFrame(type: .kill, payload: WirePayload.uuidData(id)))
    }

    /// ⌘Q "Quit and End Sessions": everything this client routes, ended.
    func killAll() {
        lock.lock()
        let ids = Array(routes.keys)
        routes.removeAll()
        lock.unlock()
        for id in ids {
            enqueue(WireFrame(type: .kill, payload: WirePayload.uuidData(id)))
        }
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
            _ = data.withUnsafeBytes { raw -> Int in
                var offset = 0
                let base = raw.baseAddress!
                while offset < raw.count {
                    let n = write(self.fd, base + offset, raw.count - offset)
                    if n <= 0 { return offset }
                    offset += n
                }
                return offset
            }
        }
    }

    // MARK: - Inbound (socket queue)

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else {
            // The keeper is gone. Surfaces freeze where they are; the exec
            // fallback would need new surfaces, and silently swapping a
            // running terminal is worse than an honest stall. Rare enough
            // to log and live with.
            NSLog("Skylight: daemon connection lost")
            readSource?.cancel()
            readSource = nil
            fd = -1
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        guard let frames = try? Wire.decodeAvailable(&buffer) else {
            NSLog("Skylight: daemon protocol error")
            readSource?.cancel()
            readSource = nil
            fd = -1
            return
        }
        for frame in frames {
            switch frame.type {
            case .output:
                guard let (id, bytes) = WirePayload.parseIDPrefixed(frame.payload) else { continue }
                lock.lock()
                let session = routes[id]
                lock.unlock()
                session?.receive(bytes)
            case .exited:
                guard let (id, code) = WirePayload.parseExited(frame.payload) else { continue }
                lock.lock()
                let session = routes.removeValue(forKey: id)
                lock.unlock()
                session?.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: 0)
                if let onExited {
                    Task { @MainActor in onExited(id, code) }
                }
            default:
                break
            }
        }
    }
}
