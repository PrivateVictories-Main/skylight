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
/// 2. `credentialMarkers` — paths whose EXISTENCE and mtime we stat. The
///    contents are credentials and are never opened. A marker being present
///    is not proof of a working subscription and is never treated as one.
/// 3. `loginCommand` — what a real Skylight terminal runs so the user can sign
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
    /// `~`-relative paths. Stat only — never read, never parsed.
    public let credentialMarkers: [String]
    /// Arguments for a terminal that signs the user in, or nil when the CLI
    /// signs in by simply being run.
    public let loginCommand: [String]?

    public init(statusCommand: [String]? = nil,
                format: ProbeOutputFormat = .text(signedIn: [], signedOut: []),
                credentialMarkers: [String] = [],
                loginCommand: [String]? = nil) {
        self.statusCommand = statusCommand
        self.format = format
        self.credentialMarkers = credentialMarkers
        self.loginCommand = loginCommand
    }
}

public extension AuthProbe {
    /// Turn a completed probe into a state. **Pure** — it runs nothing, opens
    /// nothing, and knows only what it is handed. Every subprocess and every
    /// `stat` happens above this line, which is what makes the whole decision
    /// testable from captured output.
    ///
    /// `markersPresent` is deliberately weak evidence. A credential file on
    /// disk may be expired, revoked, or for an account the user has since
    /// changed — so it can move an answerless probe from "signed out" to
    /// "unknown", and it can never on its own produce `.signedIn`. Claiming a
    /// working subscription because a file exists is exactly the guess this
    /// module refuses everywhere else.
    static func state(stdout: String?, exitCode: Int32?,
                      markersPresent: Bool, probe: AuthProbe) -> SubscriptionState {
        /// No usable answer. A marker keeps it honest at "unknown"; without
        /// one, signed out is the only reading left.
        func undecided() -> SubscriptionState {
            markersPresent ? .unknown : .signedOut
        }

        // No probe was declared, or none was run: markers are all there is.
        guard probe.statusCommand != nil else { return undecided() }
        // A CLI that failed has not told us anything, whatever it printed on
        // the way down.
        guard exitCode == 0 else { return .unknown }
        guard let stdout, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unknown }

        switch probe.format {
        case let .text(signedIn, signedOut):
            // Signed-out literals are checked FIRST: "Not logged in" contains
            // no signed-in literal today, but a future pair where one is a
            // substring of the other must not silently resolve the wrong way.
            if signedOut.contains(where: stdout.contains) { return .signedOut }
            if signedIn.contains(where: stdout.contains) {
                return .signedIn(account: nil, plan: nil)
            }
            return undecided()

        case let .json(loggedInKey, accountKey, planKey):
            guard let data = stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any]
            else {
                // It claimed to print JSON and did not. That is a broken
                // answer, not a "signed out" one.
                return .unknown
            }
            guard let loggedIn = root[loggedInKey] as? Bool else { return .unknown }
            guard loggedIn else { return .signedOut }
            // Account and plan appear ONLY because the CLI printed them.
            return .signedIn(account: accountKey.flatMap { root[$0] as? String },
                             plan: planKey.flatMap { root[$0] as? String })
        }
    }
}
