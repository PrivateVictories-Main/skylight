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

    /// The env carried by SpawnRequest must actually reach the child. The
    /// plumbing was always there and unused, so nothing had ever proved it —
    /// and shell integration, which is what makes the regular terminal
    /// first-class, is delivered entirely through this one field.
    func testSpawnEnvironmentReachesTheChild() throws {
        let id = UUID()
        var conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .hello))
        _ = try conn.expect(.helloReply)

        let spawn = SpawnRequest(
            id: id,
            argv: ["/bin/sh", "-c", "echo ENV_IS:$SKYLIGHT_E2E_VAR; exec cat"],
            env: ["SKYLIGHT_E2E_VAR": "carried"])
        try conn.send(WireFrame(type: .spawn,
                                payload: JSONEncoder().encode(spawn)))
        try conn.sendResize(id)
        let output = try conn.collectOutput(for: id, until: "ENV_IS:")
        XCTAssertTrue(output.contains("ENV_IS:carried"),
                      "environment did not reach the child: \(output)")

        try conn.send(WireFrame(type: .kill, payload: WirePayload.uuidData(id)))
        conn.close()
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
        try conn.sendResize(id)
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

    func testSixSessionsAllSurviveAClientDeath() throws {
        // The flagship at breadth: a whole workspace of sessions rides out
        // the app dying, and every one is listed, alive, and replayable.
        var conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .hello))
        _ = try conn.expect(.helloReply)
        let ids = (1...6).map { _ in UUID() }
        // Spawn→confirm per session: the collector discards other ids'
        // frames, so interleaved batch collection would drop them.
        for (index, id) in ids.enumerated() {
            let spawn = SpawnRequest(id: id,
                                     argv: ["/bin/sh", "-c", "echo READY-\(index); exec cat"])
            try conn.send(WireFrame(type: .spawn, payload: JSONEncoder().encode(spawn)))
            try conn.sendResize(id)
            _ = try conn.collectOutput(for: id, until: "READY-\(index)", timeout: 10)
        }

        conn.close()
        usleep(300_000)
        XCTAssertTrue(daemonProcess?.isRunning ?? false)

        conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .hello))
        let back = try JSONDecoder().decode(HelloReply.self,
                                            from: try conn.expect(.helloReply).payload)
        XCTAssertEqual(Set(back.sessions.map(\.id)), Set(ids))
        XCTAssertTrue(back.sessions.allSatisfy(\.alive), "a session died with the client")
        // Spot-check replay on the last one.
        try conn.send(WireFrame(type: .attach, payload: WirePayload.uuidData(ids[5])))
        let replay = try conn.collectOutput(for: ids[5], until: "READY-5")
        XCTAssertTrue(replay.contains("READY-5"))

        for id in ids {
            try conn.send(WireFrame(type: .kill, payload: WirePayload.uuidData(id)))
        }
        conn.close()
        for _ in 0..<50 where daemonProcess?.isRunning == true { usleep(100_000) }
        XCTAssertFalse(daemonProcess?.isRunning ?? true)
        daemonProcess = nil
    }

    func testMegabyteReplayKeepsTheTailNotTheHead() throws {
        let id = UUID()
        var conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .hello))
        _ = try conn.expect(.helloReply)
        // ~1.7 MB of numbered lines through the pty: the 1 MiB ring must
        // keep the END of the stream — and the buffered non-blocking client
        // lane must survive the flood without dropping a frame mid-stream.
        let spawn = SpawnRequest(id: id,
                                 argv: ["/bin/sh", "-c", "seq 1 200000; echo RING_DONE; exec cat"])
        try conn.send(WireFrame(type: .spawn, payload: JSONEncoder().encode(spawn)))
        try conn.sendResize(id)
        _ = try conn.collectOutput(for: id, until: "RING_DONE", timeout: 30)

        conn.close()
        usleep(200_000)
        conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .attach, payload: WirePayload.uuidData(id)))
        let replay = try conn.collectOutput(for: id, until: "RING_DONE", timeout: 10)
        // Byte-level checks: pty output is CRLF, and "\r\n" is a SINGLE
        // grapheme to Swift's String.contains — a character-level search for
        // "\n199999" can never match it. utf8 has no such opinions.
        let bytes = Array(replay.utf8)
        XCTAssertNotNil(bytes.firstRange(of: Array("\n199999".utf8)),
                        "tail lines missing from replay")
        XCTAssertNil(bytes.prefix(8).firstRange(of: Array("1\r\n2\r\n".utf8)),
                     "ring kept the head, not the tail")
        XCTAssertLessThanOrEqual(replay.utf8.count, (1 << 20) + 64 * 1024,
                                 "replay exceeded the ring bound")

        try conn.send(WireFrame(type: .kill, payload: WirePayload.uuidData(id)))
        _ = try? conn.expect(.exited)
        conn.close()
        daemonProcess?.terminate()
        daemonProcess = nil
    }

    func testCrashedDaemonsOrphansAreSweptByTheSuccessor() throws {
        let id = UUID()
        var conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .hello))
        _ = try conn.expect(.helloReply)
        // The exact (and only) process class that leaks without the sweep:
        // ignores the kernel's hangup (trap "" HUP → SIG_IGN survives exec)
        // AND never reads the dead tty (cat would exit on EOF; sleep won't).
        // Everything else dies naturally with its pty when a daemon crashes.
        let spawn = SpawnRequest(id: id,
                                 argv: ["/bin/sh", "-c", #"trap "" HUP; echo up; exec sleep 1000"#])
        try conn.send(WireFrame(type: .spawn, payload: JSONEncoder().encode(spawn)))
        try conn.sendResize(id)
        _ = try conn.collectOutput(for: id, until: "up")
        // Find the child via the ledger the daemon just wrote.
        let ledgerData = try Data(contentsOf: URL(fileURLWithPath: socketPath + ".ledger"))
        let ledger = try JSONDecoder().decode([LedgerEntry].self, from: ledgerData)
        let childPID = try XCTUnwrap(ledger.first?.pid)

        // The daemon CRASHES (SIGKILL — no HUP, no cleanup). The child is
        // now a leaked, unreachable process...
        kill(try XCTUnwrap(daemonProcess).processIdentifier, SIGKILL)
        conn.close()
        usleep(300_000)
        XCTAssertEqual(kill(childPID, 0), 0, "child should have survived the crash")

        // ...until the next daemon boots on the same socket and sweeps it.
        let successor = Process()
        successor.executableURL = daemonBinary
        successor.environment = daemonProcess?.environment
        try successor.run()
        daemonProcess = successor
        var swept = false
        for _ in 0..<60 {                                  // HUP, then the 3s SIGKILL escalation
            if kill(childPID, 0) != 0 { swept = true; break }
            usleep(100_000)
        }
        XCTAssertTrue(swept, "orphan pid \(childPID) was never swept")
        successor.terminate()
        daemonProcess = nil
    }

    func testHostileSpawnPayloadsGetHonestExitsNotCrashes() throws {
        var conn = try Conn(path: socketPath)
        try conn.send(WireFrame(type: .hello))
        _ = try conn.expect(.helloReply)

        // Empty argv: valid JSON, unrunnable request — once a crash primitive.
        let empty = SpawnRequest(id: UUID(), argv: [])
        try conn.send(WireFrame(type: .spawn, payload: JSONEncoder().encode(empty)))
        let exited = try conn.expect(.exited)
        XCTAssertEqual(WirePayload.parseExited(exited.payload)?.code, 127)

        // Nonexistent binary: same honest ending.
        let missing = SpawnRequest(id: UUID(), argv: ["/no/such/binary"])
        try conn.send(WireFrame(type: .spawn, payload: JSONEncoder().encode(missing)))
        try conn.sendResize(missing.id)
        XCTAssertEqual(WirePayload.parseExited(try conn.expect(.exited).payload)?.code, 127)

        // A deleted cwd falls back to home instead of failing the spawn.
        let homeless = SpawnRequest(id: UUID(),
                                    argv: ["/bin/sh", "-c", "pwd; exec cat"],
                                    cwd: "/no/such/dir/anywhere")
        try conn.send(WireFrame(type: .spawn, payload: JSONEncoder().encode(homeless)))
        try conn.sendResize(homeless.id)
        let output = try conn.collectOutput(for: homeless.id,
                                            until: NSHomeDirectory())
        XCTAssertTrue(output.contains(NSHomeDirectory()))

        try conn.send(WireFrame(type: .kill, payload: WirePayload.uuidData(homeless.id)))
        _ = try? conn.expect(.exited)
        conn.close()
        daemonProcess?.terminate()
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

        /// The daemon defers exec until the surface's first resize — the
        /// birth certificate. Tests play the client's part.
        func sendResize(_ id: UUID, columns: UInt16 = 80, rows: UInt16 = 24) throws {
            try send(WireFrame(type: .resize, payload: WirePayload.encodeResize(
                ResizePayload(id: id, columns: columns, rows: rows))))
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
        /// Byte-level, tail-window search: a naive contains() over a growing
        /// megabyte String per frame is O(n²) grapheme work — it once made
        /// this harness time out on a stream the daemon delivered in 0.4s.
        mutating func collectOutput(for id: UUID, until marker: String,
                                    timeout: TimeInterval = 5) throws -> String {
            let markerBytes = Data(marker.utf8)
            var collected = Data()
            var found = false
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, !found {
                let frame = try next(timeout: deadline.timeIntervalSinceNow)
                guard frame.type == .output,
                      let (frameID, bytes) = WirePayload.parseIDPrefixed(frame.payload),
                      frameID == id else { continue }
                collected.append(bytes)
                let window = collected.suffix(bytes.count + markerBytes.count)
                found = window.range(of: markerBytes) != nil
            }
            return String(decoding: collected, as: UTF8.self)
        }

        func close() { Darwin.close(fd) }
    }
}
