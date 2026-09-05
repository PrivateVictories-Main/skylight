import Foundation

/// How a CLI reports its own auth state.
public enum ProbeOutputFormat: Equatable, Sendable {
    /// Literal substrings on stdout. Declared, never heuristic: matching
    /// "logged" or "error" against arbitrary agent output is how a probe
    /// starts inventing answers.
    case text(signedIn: [String], signedOut: [String])
    /// The CLI prints JSON, so we read declared KEYS instead of pattern
    /// matching a serialization whose spacing may change between releases.
    case json(loggedInKey: String, accountKey: String?, planKey: String?)
}

/// How to learn whether a subscription is signed in — **without ever touching
/// a credential.**
///
/// Three things, all of them things the vendor already offers:
///
/// 1. `statusCommand` — the vendor's OWN read-only status subcommand, run
///    detached with a hard timeout and no tty.
/// 2. `loginCommand` — what a real Skylight terminal runs so the user can sign
///    in with the vendor's own flow. That terminal IS the interconnect;
///    Skylight holds nothing.
///
/// Every field is nil-able and **nil means "we have not verified this"**, the
/// same contract `Harness.autonomyFlag` has carried since the New sheet
/// shipped. That rule earned itself on 2026-08-30: `cursor-agent status`
/// looks exactly like a status command and instead prints "Starting login
/// process… Authenticating with Cursor…" and hangs until killed. A guessed
/// probe does not merely fail — it hijacks the app into an interactive login
/// nobody asked for.
public struct AuthProbe: Equatable, Sendable {
    /// ARGUMENTS ONLY. The binary comes from the same PATH resolution every
    /// launch uses; a declaration that could name its own executable would be
    /// a second, unreviewed launch path.
    public let statusCommand: [String]?
    public let format: ProbeOutputFormat
    /// Nonzero exits the vendor documents as an expected signed-out result.
    /// A matching negative reply is still required; these codes never permit
    /// a signed-in result. Undeclared failures stay unknown.
    public let signedOutExitCodes: Set<Int32>
    /// Arguments for a terminal that signs the user in, or nil when the CLI
    /// signs in by simply being run.
    public let loginCommand: [String]?

    public init(statusCommand: [String]? = nil,
                format: ProbeOutputFormat = .text(signedIn: [], signedOut: []),
                signedOutExitCodes: Set<Int32> = [],
                loginCommand: [String]? = nil) {
        self.statusCommand = statusCommand
        self.format = format
        self.signedOutExitCodes = signedOutExitCodes
        self.loginCommand = loginCommand
    }
}

public extension AuthProbe {
    /// Turn a completed probe into a state. **Pure** — it runs nothing, opens
    /// nothing, and knows only what it is handed. Every subprocess and every
    /// `stat` happens above this line, which is what makes the whole decision
    /// testable from captured output.
    ///
    /// **Only the CLI's own words can produce an answer.** Not the presence of
    /// a credential file, not its absence, not anything we inferred.
    ///
    /// This function used to fall back to `.signedOut` whenever a probe could
    /// not decide and no credential file was found, and that broke the rule
    /// this module is built on in the place it hurt most: `.signedOut` dims
    /// the row, ignores clicks, disables Create, and banners running surfaces.
    /// So a guessed path being wrong did not degrade gracefully — it made a
    /// working CLI unusable.
    ///
    /// It was wrong on this very machine. opencode is installed and signed in;
    /// its declared marker path did not exist, so it was reported "Not signed
    /// in" and could not be launched at all.
    ///
    /// Now: a CLI that says nothing we recognise leaves us `.unknown`, which
    /// is usable, and the CLI gets to speak for itself when it runs.
    /// stdout and stderr BOTH, because a CLI's idea of where a status line
    /// belongs is its own. Verified on 2026-08-30: `codex login status` prints
    /// "Logged in using ChatGPT" on **stderr** and leaves stdout empty, so a
    /// reader that took stdout alone resolved codex to .unknown forever and
    /// its row silently never worked. No fixture would have caught that —
    /// only running the real thing did.
    ///
    /// stdout is preferred where both speak: a CLI that answers on stdout and
    /// warns on stderr must not be read off the warning.
    static func state(stdout: String?, stderr: String?, exitCode: Int32?,
                      probe: AuthProbe) -> SubscriptionState {
        // No status command means no evidence of any kind. Not "signed out" —
        // unknown, and launchable.
        guard probe.statusCommand != nil else { return .unknown }
        // Claude and Codex report a normal signed-out state with exit 1.
        // Accept that only when declared AND accompanied by their negative
        // evidence. Crashes, missing statuses and other failures stay unknown.
        guard let exitCode,
              exitCode == 0 || probe.signedOutExitCodes.contains(exitCode)
        else { return .unknown }

        func meaningful(_ text: String?) -> String? {
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return text
        }
        // stdout first, then stderr — ordered, not merged. Concatenating them
        // would let a stderr warning corrupt a JSON document on stdout.
        let streams = [meaningful(stdout), meaningful(stderr)].compactMap { $0 }
        guard !streams.isEmpty else { return .unknown }

        switch probe.format {
        case let .text(signedIn, signedOut):
            for stream in streams {
                // Signed-out literals are checked FIRST: "Not logged in"
                // contains no signed-in literal today, but a future pair where
                // one is a substring of the other must not silently resolve
                // the wrong way.
                if signedOut.contains(where: stream.contains) { return .signedOut }
                if signedIn.contains(where: stream.contains) {
                    guard exitCode == 0 else { return .unknown }
                    return .signedIn(account: nil, plan: nil)
                }
            }
            // Words we do not recognise are a question we failed to answer,
            // exactly like unparseable JSON below — never a negative answer.
            // A codex release that rewords its status line must not silently
            // block a CLI that works.
            return .unknown

        case let .json(loggedInKey, accountKey, planKey):
            for stream in streams {
                guard let data = stream.data(using: .utf8),
                      let root = (try? JSONSerialization.jsonObject(with: data))
                        as? [String: Any],
                      let loggedIn = root[loggedInKey] as? Bool
                else { continue }
                guard loggedIn else { return .signedOut }
                guard exitCode == 0 else { return .unknown }
                // Account and plan appear ONLY because the CLI printed them.
                return .signedIn(account: accountKey.flatMap { root[$0] as? String },
                                 plan: planKey.flatMap { root[$0] as? String })
            }
            // It claimed to print JSON and did not, on either stream. A broken
            // answer, not a "signed out" one.
            return .unknown
        }
    }
}
