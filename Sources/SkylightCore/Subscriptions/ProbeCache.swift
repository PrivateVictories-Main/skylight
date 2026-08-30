import Foundation

/// Remembered probe answers, so opening the New sheet does not re-run a
/// subprocess per harness every time.
///
/// The idle-CPU promise is load-bearing here: probes never run on a timer and
/// never run at render. They run when the sheet re-samples (it already does
/// that on `didBecomeActive`), when someone asks explicitly, and after a login
/// terminal exits — and between those, this is the answer.
public struct ProbeCache: Codable, Equatable, Sendable {
    /// Long enough that flipping between apps is free, short enough that
    /// signing out elsewhere is noticed within a coffee break.
    public static let ttl: TimeInterval = 30 * 60

    private struct Entry: Codable, Equatable {
        var state: StoredState
        var checked: Date
    }

    /// `SubscriptionState` with a Codable spelling. Written to disk, so it
    /// deliberately has nowhere to put a token even if someone tried: the
    /// only strings it can hold are the account and plan the CLI printed.
    private struct StoredState: Codable, Equatable {
        var signedIn: Bool
        var account: String?
        var plan: String?
        var expired: Bool

        init(_ state: SubscriptionState) {
            switch state {
            case let .signedIn(account, plan):
                signedIn = true; self.account = account; self.plan = plan; expired = false
            case .signedOut:
                signedIn = false; account = nil; plan = nil; expired = false
            case .expired:
                signedIn = false; account = nil; plan = nil; expired = true
            case .unknown:
                // Never stored — see `record`.
                signedIn = false; account = nil; plan = nil; expired = false
            }
        }

        var state: SubscriptionState {
            if expired { return .expired }
            return signedIn ? .signedIn(account: account, plan: plan) : .signedOut
        }
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Store a real answer.
    ///
    /// `.unknown` is deliberately NOT stored. It means "we could not find
    /// out", and caching it would let one failed probe suppress every retry
    /// for the whole TTL — turning the state most worth re-asking into the one
    /// we stop asking about.
    public mutating func record(_ harnessID: String, _ state: SubscriptionState,
                                at now: Date = Date()) {
        guard state != .unknown else {
            entries.removeValue(forKey: harnessID)
            return
        }
        entries[harnessID] = Entry(state: StoredState(state), checked: now)
    }

    /// The remembered answer, or nil when there is none worth trusting.
    ///
    /// An entry from the FUTURE is treated as expired rather than valid: a
    /// clock that jumped backwards (sleep, DST, an NTP correction) must not
    /// be able to make an answer immortal.
    public func state(for harnessID: String, now: Date = Date()) -> SubscriptionState? {
        guard let entry = entries[harnessID] else { return nil }
        let age = now.timeIntervalSince(entry.checked)
        guard age >= 0, age <= Self.ttl else { return nil }
        return entry.state.state
    }

    public func needsProbe(_ harnessID: String, now: Date = Date()) -> Bool {
        state(for: harnessID, now: now) == nil
    }

    /// Signing in inside a Skylight terminal is precisely when the cached
    /// answer stops being true.
    public mutating func invalidate(_ harnessID: String) {
        entries.removeValue(forKey: harnessID)
    }

    public mutating func invalidateAll() {
        entries.removeAll()
    }

    /// When this harness was last successfully asked — shown as "checked N
    /// minutes ago" so a stale answer looks stale.
    public func lastChecked(_ harnessID: String) -> Date? {
        entries[harnessID]?.checked
    }
}
