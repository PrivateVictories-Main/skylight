import XCTest
import SkylightCore

final class RecommendationTests: XCTestCase {
    private let claude = TerminalSpec(harness: "claude")
    private let plain = TerminalSpec()

    func testRecordCountsAndStoresSpec() {
        var log = UsageLog()
        log.record(claude)
        log.record(claude)
        XCTAssertEqual(log.counts[claude.comboKey], 2)
        XCTAssertEqual(log.specs[claude.comboKey], claude)
    }

    func testTopComboRequiresMinimumUses() {
        var log = UsageLog()
        log.record(claude)
        log.record(claude)
        XCTAssertNil(log.topCombo(minimumUses: 3))
        log.record(claude)
        XCTAssertEqual(log.topCombo(minimumUses: 3), claude)
    }

    func testTopComboPicksMostUsedAndBreaksTiesDeterministically() {
        var log = UsageLog()
        for _ in 0..<3 { log.record(claude) }
        for _ in 0..<5 { log.record(plain) }
        XCTAssertEqual(log.topCombo(), plain)

        var tied = UsageLog()
        for _ in 0..<3 { tied.record(claude) }
        for _ in 0..<3 { tied.record(plain) }
        // Equal counts: the lexicographically smaller combo key wins, always.
        let expected = [claude, plain].min { $0.comboKey < $1.comboKey }
        XCTAssertEqual(tied.topCombo(), expected)
    }

    func testEmptyLogHasNoRecommendation() {
        XCTAssertNil(UsageLog().topCombo())
    }

    /// The usage log is written to disk on every launch and read back on every
    /// start, so a field that stops surviving JSON silently costs the user
    /// their "Your usual" row. Full equality, both dictionaries populated.
    func testUsageLogRoundTripsThroughJSON() throws {
        var log = UsageLog()
        log.record(TerminalSpec(harness: "claude", arguments: ["--model", "opus"]))
        log.record(TerminalSpec())
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(UsageLog.self, from: data), log)
    }
}
