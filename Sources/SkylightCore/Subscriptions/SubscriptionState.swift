import Foundation

/// Whether the user's subscription is actually reachable through a given
/// agent CLI.
///
/// Skylight's entire relationship to a subscription is that it launches the
/// vendor's own CLI, in the user's own shell, under the user's own login. It
/// holds no token, implements no OAuth flow, opens no webview, and reads no
/// credential file's CONTENTS. This type is the whole of what it claims to
/// know, and `.unknown` is the honest default rather than a failure.
public enum SubscriptionState: Equatable, Sendable {
    /// We have not verified a way to ask, the ask failed, or the answer was
    /// not one we declared. Never a guess dressed as an answer.
    case unknown
    case signedOut
    /// Account and plan appear ONLY when the CLI printed them itself.
    case signedIn(account: String?, plan: String?)
    /// The CLI says the credential exists but is no longer good.
    case expired

    /// Whether a terminal launched with this harness will actually work. Used
    /// to decide between "Create" and "Sign in" — and `.unknown` reads as
    /// usable on purpose, because refusing to launch something we merely
    /// could not ask about would be worse than letting the CLI speak for
    /// itself.
    public var isUsable: Bool {
        switch self {
        case .signedIn, .unknown: true
        case .signedOut, .expired: false
        }
    }

    public var account: String? {
        if case let .signedIn(account, _) = self { return account }
        return nil
    }

    public var plan: String? {
        if case let .signedIn(_, plan) = self { return plan }
        return nil
    }
}
