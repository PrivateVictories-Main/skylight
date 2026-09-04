import XCTest
import SkylightCore

/// The subprocess side, which shipped with zero tests — and both live bugs in
/// this feature lived here. These run real `/bin/sh` scripts rather than a
/// mock, because what was wrong was never the logic: it was what an actual
/// process does with pipes, streams and a timeout.
///
/// No agent CLI is ever invoked, and nothing here touches a credential.
final class ProbeRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-runner-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an executable shell script and returns its path.
    private func script(_ body: String) throws -> String {
        let url = directory.appendingPathComponent("s\(UUID().uuidString.prefix(6)).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url.path
    }

    func testCapturesStdout() throws {
        let result = ProbeRunner.run(try script("echo hello-out"), [], timeout: 5)
        XCTAssertEqual(result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "hello-out")
        XCTAssertEqual(result.exitCode, 0)
    }

    /// The bug that shipped: codex answers entirely on stderr.
    func testCapturesStderrWhenStdoutIsSilent() throws {
        let result = ProbeRunner.run(try script("echo on-err >&2"), [], timeout: 5)
        XCTAssertEqual(result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "on-err")
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCapturesBothStreamsSeparately() throws {
        let result = ProbeRunner.run(
            try script("echo out; echo err >&2"), [], timeout: 5)
        XCTAssertTrue(result.stdout?.contains("out") ?? false)
        XCTAssertTrue(result.stderr?.contains("err") ?? false)
        // Separate, not merged — merging lets a warning corrupt JSON.
        XCTAssertFalse(result.stdout?.contains("err") ?? true)
    }

    func testReportsNonZeroExit() throws {
        XCTAssertEqual(ProbeRunner.run(try script("exit 7"), [], timeout: 5).exitCode, 7)
    }

    /// The other bug that shipped: a "status" command that never returns.
    /// A nil exit code is how a timeout reports itself, which AuthProbe reads
    /// as "no answer" rather than as bad news.
    func testAHangingProcessIsKilledAndReportedAsNoAnswer() throws {
        let start = Date()
        let result = ProbeRunner.run(try script("sleep 60"), [], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result.exitCode)
        XCTAssertNil(result.stdout)
        XCTAssertLessThan(elapsed, 10, "the timeout did not fire")
    }

    /// A hang must not merely be abandoned — the process must actually die,
    /// or every probe leaks a stuck CLI into the user's process table.
    func testAHungProcessIsActuallyReapedNotJustAbandoned() throws {
        let marker = directory.appendingPathComponent("alive").path
        _ = ProbeRunner.run(
            try script("trap '' TERM; touch \(marker); sleep 30"), [], timeout: 1)
        // Give the kill a moment to land, then confirm nothing is still there.
        Thread.sleep(forTimeInterval: 0.5)
        let output = Pipe()
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "sleep 30"]
        pgrep.standardOutput = output
        try pgrep.run()
        pgrep.waitUntilExit()
        let running = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        XCTAssertTrue(running.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "a timed-out probe left a process behind: \(running)")
    }

    /// A child that outruns the 64 KB pipe buffer deadlocks anything that
    /// waits for exit before draining. Both pipes must be drained concurrently.
    func testALargeStdoutDoesNotDeadlock() throws {
        let result = ProbeRunner.run(
            try script("for i in $(seq 1 4000); do echo line-$i-padding-padding; done"),
            [], timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue((result.stdout?.count ?? 0) > 64 * 1024,
                      "expected more than one pipe buffer of output")
    }

    /// The same hazard on the stream nobody thinks about: draining only stdout
    /// wedges on a CLI that is chatty on stderr.
    func testALargeStderrDoesNotDeadlock() throws {
        let result = ProbeRunner.run(
            try script("for i in $(seq 1 4000); do echo err-$i-padding-padding >&2; done"),
            [], timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue((result.stderr?.count ?? 0) > 64 * 1024)
    }

    /// stdin is /dev/null, so a CLI that decides to prompt gets EOF instead of
    /// waiting for a human who is not there. This is what bounded the damage
    /// from cursor-agent's interactive "status".
    func testAProcessReadingStdinGetsEOFRatherThanHanging() throws {
        let start = Date()
        let result = ProbeRunner.run(
            try script("read line; echo \"got:$line\""), [], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "it waited for input")
        XCTAssertNotNil(result.exitCode)
    }

    func testAMissingBinaryIsNoAnswerRatherThanACrash() {
        let result = ProbeRunner.run("/nonexistent/nope", [], timeout: 5)
        XCTAssertNil(result.exitCode)
        XCTAssertNil(result.stdout)
    }

    func testDiscoveredCLIAlsoFindsItsShebangRuntime() throws {
        let bin = directory.appendingPathComponent(".volta/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let runtime = bin.appendingPathComponent("skylight-test-runtime")
        try "#!/bin/sh\necho RUNTIME_FOUND\n".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let cli = bin.appendingPathComponent("test-agent")
        try "#!/usr/bin/env skylight-test-runtime\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let finder = ["PATH": "/usr/bin:/bin"]
        let binary = try XCTUnwrap(Catalog.resolve("test-agent", pathVariable: finder["PATH"],
            home: directory.path, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }))
        let withoutRuntime = ProbeRunner.run(binary, [], timeout: 2, environment: finder)
        XCTAssertNotEqual(withoutRuntime.exitCode, 0)
        let environment = finder.merging(Launch.agentEnvironment(base: finder, home: directory.path)) { _, new in new }
        let result = ProbeRunner.run(binary, [], timeout: 2, environment: environment)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout?.contains("RUNTIME_FOUND") == true)
    }

    /// End to end through the real decision, on the exact shapes the two live
    /// CLIs produce.
    func testEndToEndAgainstTheShapesTheRealCLIsProduce() throws {
        let codexLike = try script("echo 'Logged in using ChatGPT' >&2")
        let codex = ProbeRunner.run(codexLike, [], timeout: 5)
        XCTAssertEqual(
            AuthProbe.state(stdout: codex.stdout, stderr: codex.stderr,
                            exitCode: codex.exitCode,
                            probe: Catalog.harness("codex")!.authProbe!),
            .signedIn(account: nil, plan: nil))

        let claudeLike = try script(
            #"echo '{"loggedIn":true,"email":"a@b.c","subscriptionType":"max"}'"#)
        let claude = ProbeRunner.run(claudeLike, [], timeout: 5)
        XCTAssertEqual(
            AuthProbe.state(stdout: claude.stdout, stderr: claude.stderr,
                            exitCode: claude.exitCode,
                            probe: Catalog.harness("claude")!.authProbe!),
            .signedIn(account: "a@b.c", plan: "max"))
    }
}
