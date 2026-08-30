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
