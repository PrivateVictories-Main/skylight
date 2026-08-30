import Foundation
import SkylightCore

/// Runs a vendor's own read-only status command and reports what it said.
///
/// Everything about this type is shaped by one real observation: on
/// 2026-08-30 `cursor-agent status` — which looks exactly like a read-only
/// probe — printed "Starting login process… Authenticating with Cursor…" and
/// hung until it was killed. Any CLI can do that, including one whose probe is
/// verified today and changes next release. So the runner assumes the worst:
///
/// - **A hard timeout**, always, with the process killed when it expires.
/// - **No tty.** stdin is `/dev/null`, so a CLI that decides to prompt gets an
///   immediate EOF instead of waiting forever for a human.
/// - **Killed by process GROUP.** These CLIs are node wrappers that spawn
///   children; terminating only the parent leaves the child holding the pipe
///   and the read never finishes.
/// - **Never on the main thread**, never on a timer, never at render.
///
/// It reads stdout only. It never reads a credential file — the marker check
/// below is `fileExists`, and there is deliberately no code path here that
/// could open one.
enum SubscriptionProbeRunner {
    /// Generous enough for a cold node start, short enough that a hung CLI is
    /// a two-second annoyance rather than a wedged Settings pane.
    private static let timeout: TimeInterval = 8

    struct Outcome: Sendable {
        var state: SubscriptionState
        var checkedAt: Date
    }

    /// Probe one harness. Blocking — callers run it off the main actor.
    nonisolated static func probe(harness: Harness, binaryPath: String) -> Outcome {
        guard let probe = harness.authProbe else {
            return Outcome(state: .unknown, checkedAt: Date())
        }

        let markersPresent = probe.credentialMarkers.contains { marker in
            // EXISTENCE ONLY. There is no read anywhere in this function, and
            // that is the point — the contents are the user's credentials and
            // Skylight has no business with them.
            FileManager.default.fileExists(atPath: expand(marker))
        }

        guard let arguments = probe.statusCommand else {
            return Outcome(state: AuthProbe.state(stdout: nil, exitCode: nil,
                                                  markersPresent: markersPresent,
                                                  probe: probe),
                           checkedAt: Date())
        }

        let (stdout, exitCode) = run(binaryPath, arguments)
        return Outcome(state: AuthProbe.state(stdout: stdout, exitCode: exitCode,
                                              markersPresent: markersPresent,
                                              probe: probe),
                       checkedAt: Date())
    }

    private static func expand(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path
            + String(path.dropFirst(1))
    }

    /// Returns (stdout, exitCode). A timeout returns a nil exit code, which
    /// `AuthProbe.state` reads as "no answer" rather than as bad news.
    private static func run(_ binary: String,
                            _ arguments: [String]) -> (String?, Int32?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        // Its own process group, so the kill below reaches the node children
        // these CLIs spawn — terminating the parent alone leaves a child
        // holding the pipe open and the read never returns.
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        // No tty: a CLI that decides to prompt gets EOF instead of a wait.
        process.standardInput = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return (nil, nil) }
        let group = process.processIdentifier

        // Read on a background queue: a child that outruns the 64 KB pipe
        // buffer would otherwise block forever while we wait for exit, and
        // waiting for exit before reading is the classic deadlock here.
        let box = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            box.set(data)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }

        if process.isRunning {
            // The cursor-agent case. Group first (negative pid), then the
            // process itself as a fallback.
            Darwin.kill(-group, SIGKILL)
            process.terminate()
            _ = box.wait(seconds: 1)
            return (nil, nil)
        }

        process.waitUntilExit()
        let data = box.wait(seconds: 2) ?? Data()
        return (String(data: data, encoding: .utf8), process.terminationStatus)
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
