import Darwin
import XCTest
import SkylightDaemonCore

/// End-to-end against the REAL daemon binary: spawn it on a private socket,
/// run a live pty session through it, drop the connection, come back, and
/// expect the replay. This is the session-survival contract, executed.
final class DaemonE2ETests: XCTestCase {
    private var daemonProcess: Process?
    private var tempDir: URL!
    private var socketPath: String { tempDir.appendingPathComponent("d.sock").path }

    /// Test binaries and skylightd land in the same build directory.
    private var daemonBinary: URL {
        Bundle(for: DaemonE2ETests.self).bundleURL           // …/debug/SkylightPackageTests.xctest
            .deletingLastPathComponent()                     // …/debug
            .appendingPathComponent("skylightd")
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skylightd-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: daemonBinary.path),
                          "skylightd not built beside the test bundle")
        let process = Process()
        process.executableURL = daemonBinary
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["SKYLIGHTD_SOCKET": socketPath,
             "SKYLIGHTD_LOG": tempDir.appendingPathComponent("d.log").path]
        ) { _, new in new }
        try process.run()
        daemonProcess = process
    }

    override func tearDown() {
        if let process = daemonProcess, process.isRunning { process.terminate() }
        daemonProcess = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSpawnSurviveDisconnectReplayKill() throws {
        let id = UUID()
        var conn = try Conn(path: socketPath)

        // Hello: right protocol, no sessions yet.
        try conn.send(WireFrame(type: .hello))
        let hello = try conn.expect(.helloReply)
        let reply = try JSONDecoder().decode(HelloReply.self, from: hello.payload)
        XCTAssertEqual(reply.protocolVersion, Wire.protocolVersion)
        XCTAssertTrue(reply.sessions.isEmpty)

        // Spawn a session that speaks once, then stays alive.
        let spawn = SpawnRequest(id: id,
                                 argv: ["/bin/sh", "-c", "echo SKYLIGHT_E2E_MARKER; exec cat"])
        try conn.send(WireFrame(type: .spawn,
                                payload: JSONEncoder().encode(spawn)))
        let banner = try conn.collectOutput(for: id, until: "SKYLIGHT_E2E_MARKER")
        XCTAssertTrue(banner.contains("SKYLIGHT_E2E_MARKER"))

        // The app "quits": the session must not.
        conn.close()
        usleep(200_000)
        XCTAssertTrue(daemonProcess?.isRunning ?? false, "daemon died with the client")

        // The app "relaunches": the session is listed, and attach replays.
        conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .hello))
        let back = try JSONDecoder().decode(HelloReply.self,
                                            from: try conn.expect(.helloReply).payload)
        XCTAssertEqual(back.sessions.map(\.id), [id])
        XCTAssertEqual(back.sessions.first?.alive, true)
        try conn.send(WireFrame(type: .attach, payload: WirePayload.uuidData(id)))
        let replay = try conn.collectOutput(for: id, until: "SKYLIGHT_E2E_MARKER")
        XCTAssertTrue(replay.contains("SKYLIGHT_E2E_MARKER"), "replay lost the scrollback")

        // Live after reattach: input flows, cat echoes it back.
        try conn.send(WireFrame(type: .input,
                                payload: WirePayload.idPrefixed(id, Data("ping\n".utf8))))
        let echoed = try conn.collectOutput(for: id, until: "ping")
        XCTAssertTrue(echoed.contains("ping"))

        // Kill ends the child and, once we hang up, the daemon itself.
        try conn.send(WireFrame(type: .kill, payload: WirePayload.uuidData(id)))
        _ = try? conn.expect(.exited, timeout: 5)
        conn.close()
        for _ in 0..<50 where daemonProcess?.isRunning == true { usleep(100_000) }
        XCTAssertFalse(daemonProcess?.isRunning ?? true, "daemon lingered past its last session")
        daemonProcess = nil
    }

    // MARK: - Minimal blocking client

    private struct Conn {
        private var fd: Int32
        private var buffer = Data()
        /// decodeAvailable consumes every complete frame — the ones not yet
        /// asked for wait here instead of being dropped.
        private var pending: [WireFrame] = []

        init(path: String) throws {
            var lastError: Int32 = 0
            // The daemon needs a moment to bind after launch.
            for _ in 0..<50 {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
                if result == 0 {
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                               &timeout, socklen_t(MemoryLayout<timeval>.size))
                    self.fd = fd
                    return
                }
                lastError = errno
                Darwin.close(fd)
                usleep(100_000)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(lastError))
        }

        func send(_ frame: WireFrame) throws {
            let data = Wire.encode(frame)
            let written = data.withUnsafeBytes {
                write(fd, $0.baseAddress, $0.count)
            }
            guard written == data.count else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        mutating func next(timeout: TimeInterval = 5) throws -> WireFrame {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if !pending.isEmpty { return pending.removeFirst() }
                guard Date() < deadline else {
                    throw NSError(domain: "e2e", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "timed out"])
                }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { continue }
                buffer.append(contentsOf: chunk[0..<n])
                pending += try Wire.decodeAvailable(&buffer)
            }
        }

        mutating func expect(_ type: WireType,
                             timeout: TimeInterval = 5) throws -> WireFrame {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let frame = try next(timeout: deadline.timeIntervalSinceNow)
                if frame.type == type { return frame }
            }
            throw NSError(domain: "e2e", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no \(type) frame"])
        }

        /// Accumulate OUTPUT payloads for `id` until the text shows up.
        mutating func collectOutput(for id: UUID, until marker: String,
                                    timeout: TimeInterval = 5) throws -> String {
            var text = ""
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, !text.contains(marker) {
                let frame = try next(timeout: deadline.timeIntervalSinceNow)
                guard frame.type == .output,
                      let (frameID, bytes) = WirePayload.parseIDPrefixed(frame.payload),
                      frameID == id else { continue }
                text += String(decoding: bytes, as: UTF8.self)
            }
            return text
        }

        func close() { Darwin.close(fd) }
    }
}
