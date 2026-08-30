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

    enum CodingKeys: String, CodingKey { case entries }

    private struct Entry: Codable, Equatable {
        var state: StoredState
        var checked: Date
    }

    /// `SubscriptionState` in a Codable spelling — and deliberately a LOSSY
    /// one: **the account never reaches disk.**
    ///
    /// An email address is personal data, this sidecar is a plain file that
    /// nothing prunes on a schedule, and nothing in the Settings copy told
    /// anyone it was there. The only thing keeping it bought was skipping a
    /// 737ms re-probe once per launch, which is not a trade worth making. The
    /// account lives in memory for the session; after a relaunch the row says
    /// "Signed in" until the next probe fills the name back in.
    ///
    /// The plan stays: "max" is not personal, and losing it would blank a row
    /// that was perfectly informative a moment ago.
    private struct StoredState: Codable, Equatable {
        var signedIn: Bool
        var plan: String?

        init(_ state: SubscriptionState) {
            switch state {
            case let .signedIn(_, plan):
                signedIn = true; self.plan = plan
            case .signedOut, .expired, .unknown:
                // .unknown is never stored at all — see `record`.
                signedIn = false; plan = nil
            }
        }

        var state: SubscriptionState {
            signedIn ? .signedIn(account: nil, plan: plan) : .signedOut
        }
    }

    private var entries: [String: Entry] = [:]
    /// Accounts, held for THIS SESSION ONLY and never encoded. Keeping the
    /// name on screen after the probe that fetched it, without keeping it on
    /// disk after the app closes.
    private var sessionAccounts: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Drop everything past its TTL. Called on a read miss, so an entry for a
    /// harness that is never probed again cannot sit in the file forever.
    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { _, entry in
            let age = now.timeIntervalSince(entry.checked)
            return age >= 0 && age <= Self.ttl
        }
        sessionAccounts = sessionAccounts.filter { entries[$0.key] != nil }
    }

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
            sessionAccounts.removeValue(forKey: harnessID)
            return
        }
        entries[harnessID] = Entry(state: StoredState(state), checked: now)
        if let account = state.account {
            sessionAccounts[harnessID] = account
        } else {
            sessionAccounts.removeValue(forKey: harnessID)
        }
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
        let stored = entry.state.state
        // Re-attach the account from memory if this session is the one that
        // learned it. After a relaunch there is nothing to re-attach, and the
        // row reads "Signed in" until the next probe.
        if case let .signedIn(_, plan) = stored {
            return .signedIn(account: sessionAccounts[harnessID], plan: plan)
        }
        return stored
    }

    public func needsProbe(_ harnessID: String, now: Date = Date()) -> Bool {
        state(for: harnessID, now: now) == nil
    }

    /// Signing in inside a Skylight terminal is precisely when the cached
    /// answer stops being true.
    public mutating func invalidate(_ harnessID: String) {
        entries.removeValue(forKey: harnessID)
        sessionAccounts.removeValue(forKey: harnessID)
    }

    public mutating func invalidateAll() {
        entries.removeAll()
        sessionAccounts.removeAll()
    }

    /// When this harness was last successfully asked — shown as "checked N
    /// minutes ago" so a stale answer looks stale.
    public func lastChecked(_ harnessID: String) -> Date? {
        entries[harnessID]?.checked
    }
}
