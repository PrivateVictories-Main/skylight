import Foundation

/// What a harness row in the New sheet should actually offer.
///
/// It used to be a boolean: installed, or dimmed with an install command.
/// There is a third state, and it is the one that wastes people's time —
/// installed but signed out, where Create happily launches a terminal that
/// immediately fails with the CLI's own auth error.
public enum HarnessRowState: Equatable, Sendable {
    case notInstalled
    /// Installed, and we KNOW it is signed out. Offers Sign in.
    case signedOut
    /// Installed and either signed in or not something we can ask about.
    case ready

    public var canLaunch: Bool { self == .ready }

    public static func of(installed: Bool,
                          subscription: SubscriptionState) -> HarnessRowState {
        // Not being there outranks everything we might believe about auth:
        // the install command is the only useful thing to say.
        guard installed else { return .notInstalled }
        // `.unknown` is READY on purpose. Most harnesses have no verified
        // probe, and blocking a launch because we could not ask would break
        // every CLI this feature does not cover — while the CLI itself is
        // perfectly able to say "please log in" for us.
        return subscription.isUsable ? .ready : .signedOut
    }
}

/// The words shown for a subscription state, in one place so the sheet, the
/// Settings pane and the surface banner cannot drift apart.
public enum SubscriptionCopy {
    /// The small grey line under a harness name. nil = say nothing, which is
    /// the right answer for the harnesses we cannot ask about: a row reading
    /// "unknown" is noise, not information.
    public static func rowDetail(for harness: Harness,
                                 state: SubscriptionState) -> String? {
        switch state {
        case .unknown:
            return nil
        case .signedOut:
            return "Not signed in"
        case let .signedIn(account, plan):
            // Only what the CLI printed itself — never inferred, never
            // prettified into a claim the vendor did not make.
            let parts = [account, plan].compactMap { $0 }
            return parts.isEmpty ? "Signed in" : parts.joined(separator: " · ")
        }
    }

    /// The surface banner for a running terminal whose harness is signed out.
    /// nil when there is nothing honest to say.
    public static func bannerMessage(for harness: Harness,
                                     state: SubscriptionState) -> String? {
        guard state == .signedOut else { return nil }
        guard let login = harness.authProbe?.loginCommand, !login.isEmpty else {
            // No verified login command: say the true half rather than
            // printing "run  to connect it" with a hole in it.
            return "\(harness.displayName) isn't signed in."
        }
        let command = ([harness.id] + login).joined(separator: " ")
        return "\(harness.displayName) isn't signed in — run \(command) to connect it."
    }

    /// What the Sign in button runs, as a spec the launcher can use directly.
    /// nil when we never verified one, in which case no button is offered.
    public static func signInSpec(for harness: Harness) -> TerminalSpec? {
        guard let login = harness.authProbe?.loginCommand, !login.isEmpty else {
            return nil
        }
        return TerminalSpec(harness: harness.id, arguments: login)
    }
}
