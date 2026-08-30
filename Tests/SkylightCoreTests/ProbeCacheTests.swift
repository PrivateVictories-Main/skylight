import XCTest
import SkylightCore

final class ProbeCacheTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    func testCacheHitWithinTTL() {
        var cache = ProbeCache()
        cache.record("codex", .signedIn(account: nil, plan: nil), at: epoch)
        XCTAssertEqual(cache.state(for: "codex", now: epoch.addingTimeInterval(60)),
                       .signedIn(account: nil, plan: nil))
    }

    func testCacheMissAfterTTL() {
        var cache = ProbeCache()
        cache.record("codex", .signedIn(account: nil, plan: nil), at: epoch)
        XCTAssertNil(cache.state(for: "codex",
                                 now: epoch.addingTimeInterval(ProbeCache.ttl + 1)))
    }

    /// `.unknown` means "we could not find out". Storing it as an answer would
    /// make one failed probe suppress every retry for the whole TTL — the
    /// state most worth retrying becomes the one we stop asking about.
    func testUnknownIsNeverCachedAsAnAnswer() {
        var cache = ProbeCache()
        cache.record("codex", .unknown, at: epoch)
        XCTAssertNil(cache.state(for: "codex", now: epoch))
        XCTAssertTrue(cache.needsProbe("codex", now: epoch))
    }

    func testSignedOutIsCachedBecauseItIsARealAnswer() {
        var cache = ProbeCache()
        cache.record("codex", .signedOut, at: epoch)
        XCTAssertEqual(cache.state(for: "codex", now: epoch), .signedOut)
        XCTAssertFalse(cache.needsProbe("codex", now: epoch))
    }

    func testUnknownHarnessAlwaysNeedsAProbe() {
        let cache = ProbeCache()
        XCTAssertTrue(cache.needsProbe("claude", now: epoch))
        XCTAssertNil(cache.state(for: "claude", now: epoch))
    }

    /// Signing in inside a Skylight terminal is exactly when the cached answer
    /// stops being true, so the login lane must be able to drop it.
    func testInvalidateForcesTheNextProbe() {
        var cache = ProbeCache()
        cache.record("codex", .signedOut, at: epoch)
        cache.invalidate("codex")
        XCTAssertTrue(cache.needsProbe("codex", now: epoch))
        XCTAssertNil(cache.state(for: "codex", now: epoch))
    }

    func testEntriesAreIndependentPerHarness() {
        var cache = ProbeCache()
        cache.record("codex", .signedOut, at: epoch)
        cache.record("claude", .signedIn(account: "a@b.c", plan: "max"), at: epoch)
        cache.invalidate("codex")
        XCTAssertEqual(cache.state(for: "claude", now: epoch),
                       .signedIn(account: "a@b.c", plan: "max"))
    }

    /// A clock that jumps backwards (sleep, DST, NTP) must not make an entry
    /// immortal or resurrect an expired one.
    func testAClockGoingBackwardsExpiresRatherThanPersists() {
        var cache = ProbeCache()
        cache.record("codex", .signedOut, at: epoch)
        XCTAssertNil(cache.state(for: "codex", now: epoch.addingTimeInterval(-3600)))
    }

    func testCodableRoundTripSurvivesRelaunch() throws {
        var cache = ProbeCache()
        cache.record("claude", .signedIn(account: "a@b.c", plan: "max"), at: epoch)
        cache.record("codex", .signedOut, at: epoch)
        let back = try JSONDecoder().decode(ProbeCache.self,
                                            from: JSONEncoder().encode(cache))
        XCTAssertEqual(back.state(for: "claude", now: epoch),
                       .signedIn(account: "a@b.c", plan: "max"))
        XCTAssertEqual(back.state(for: "codex", now: epoch), .signedOut)
    }

    /// The sidecar is written to disk, so it must never carry anything from a
    /// credential — only the state, and only what the CLI printed itself.
    func testPersistedFormHoldsNoSecrets() throws {
        var cache = ProbeCache()
        cache.record("claude", .signedIn(account: "a@b.c", plan: "max"), at: epoch)
        let json = try String(data: JSONEncoder().encode(cache), encoding: .utf8)!
        for forbidden in ["token", "secret", "key", "Bearer", "sk-", "oauth"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()), forbidden)
        }
    }
}
