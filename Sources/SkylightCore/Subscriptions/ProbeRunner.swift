import Darwin
import Foundation

/// Runs a vendor's own read-only status command and reports what it said.
///
/// Everything about this type is shaped by two things learned from running
/// the real CLIs on 2026-08-30, neither of which any fixture would have shown:
///
/// - `cursor-agent status` looks exactly like a read-only probe and instead
///   printed "Starting login process… Authenticating with Cursor…", hanging
///   until killed when it had a terminal attached.
/// - `codex login status` prints its entire answer on **stderr** and nothing
///   at all on stdout.
///
/// Any CLI can do either, including one whose probe is verified today and
/// changes next release. So the runner assumes the worst:
///
/// - **A hard timeout**, always, with the process killed when it expires.
/// - **No tty.** stdin is `/dev/null`, so a CLI that decides to prompt gets an
///   immediate EOF instead of waiting forever for a human.
/// - **Killed by process GROUP on timeout**, guarded against a non-positive
///   pid — `kill(-0, …)` would signal Skylight's own group. These CLIs are
///   node wrappers whose children outlive a plain terminate().
/// - **Never on the main thread**, never on a timer, never at render.
///
/// It reads stdout AND stderr and nothing else. It does not open, stat, or
/// even name a credential file anywhere.
public enum ProbeRunner {
    /// Generous enough for a cold node start, short enough that a hung CLI is
    /// a two-second annoyance rather than a wedged Settings pane.
    public static let defaultTimeout: TimeInterval = 8

    public struct Outcome: Equatable, Sendable {
        public var state: SubscriptionState
        public var checkedAt: Date
    }

    /// Probe one harness. Blocking — callers run it off the main actor.
    public static func probe(harness: Harness, binaryPath: String) -> Outcome {
        guard let probe = harness.authProbe else {
            return Outcome(state: .unknown, checkedAt: Date())
        }

        // Nothing to ask, so nothing is claimed. Skylight no longer stats the
        // user's credential paths at all: once markers were forbidden from
        // deciding anything — which they could never honestly do — carrying
        // and touching those paths was surface with no purpose behind it.
        guard let arguments = probe.statusCommand else {
            return Outcome(state: .unknown, checkedAt: Date())
        }

        let base = ProcessInfo.processInfo.environment
        let environment = base.merging(Launch.agentEnvironment(
            base: base, home: FileManager.default.homeDirectoryForCurrentUser.path)) { _, new in new }
        let (stdout, stderr, exitCode) = run(binaryPath, arguments,
                                             timeout: defaultTimeout, environment: environment)
        return Outcome(state: AuthProbe.state(stdout: stdout, stderr: stderr,
                                              exitCode: exitCode, probe: probe),
                       checkedAt: Date())
    }

    /// Returns (stdout, stderr, exitCode). A timeout returns a nil exit code,
    /// which `AuthProbe.state` reads as "no answer" rather than as bad news.
    ///
    /// stderr is captured because CLIs put status there: `codex login status`
    /// prints its whole answer on stderr and nothing on stdout.
    /// Exposed so the subprocess behaviour itself can be tested. Both bugs
    /// this feature shipped with — an interactive "status" command and an
    /// answer arriving on stderr — lived in here, the one part that had no
    /// tests at all.
    public static func run(_ binary: String, _ arguments: [String],
                           timeout: TimeInterval,
                           environment: [String: String]? = nil) -> (stdout: String?,
                                                      stderr: String?,
                                                      exitCode: Int32?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        process.qualityOfService = .utility
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // No tty: a CLI that decides to prompt gets EOF instead of a wait.
        // This alone defuses most interactive surprises — cursor-agent's
        // status, which hung for minutes attached to a terminal, exits
        // immediately here. It still starts a login, which is why it has no
        // probe at all; this only means the damage is bounded.
        process.standardInput = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return (nil, nil, nil) }
        let pid = process.processIdentifier

        // Both streams drained on background queues: a child that outruns the
        // 64 KB pipe buffer would otherwise block forever while we wait for
        // exit, and waiting for exit before reading is the classic deadlock.
        // Draining only ONE pipe has the same failure — a CLI that is chatty
        // on stderr would wedge on a full buffer nobody is emptying.
        let outBox = OutputBox()
        let errBox = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
        }

        // Wait on the exit itself rather than polling `isRunning`. The old
        // 20ms usleep loop burned a whole thread for the life of the probe,
        // and callers reach this from a task — where blocking a cooperative
        // pool thread starves unrelated work for up to the full timeout.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut

        if timedOut {
            // SIGKILL the child's process GROUP, then the process itself.
            //
            // The group kill is load-bearing, and measured: with it removed,
            // this exact path leaves a `sleep` alive after the probe returns
            // (ProbeRunnerTests proves it both ways). Foundation puts the
            // child in its own group, which is why the negative pid resolves —
            // these CLIs are node wrappers whose children would otherwise
            // outlive the probe and keep the pipe open.
            //
            // Guarded because `kill(-0, …)` signals OUR OWN process group:
            // Skylight and every terminal it is hosting. A pid of 0 should be
            // impossible after a successful run(), and this is far too
            // expensive a mistake to leave resting on "should".
            if pid > 1 {
                Darwin.kill(-pid, SIGKILL)
            }
            process.terminate()
            _ = outBox.wait(seconds: 1)
            _ = errBox.wait(seconds: 1)
            return (nil, nil, nil)
        }

        let out = outBox.wait(seconds: 2) ?? Data()
        let err = errBox.wait(seconds: 2) ?? Data()
        return (String(data: out, encoding: .utf8),
                String(data: err, encoding: .utf8),
                process.terminationStatus)
    }

    /// Lock-guarded handoff from the reader queue, same pattern as
    /// `LiveSessionStore.PrewarmBox`.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var data: Data?

        func set(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
            done.signal()
        }

        func wait(seconds: Double) -> Data? {
            _ = done.wait(timeout: .now() + seconds)
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
