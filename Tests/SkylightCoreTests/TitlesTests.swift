import XCTest
import SkylightCore

final class TitlesTests: XCTestCase {
    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(Titles.derived(fromPrompt: "  fix   the\nlogin  bug  "),
                       "fix the login bug")
    }

    func testShortAndSlashPromptsProduceNothing() {
        XCTAssertNil(Titles.derived(fromPrompt: "ls"))
        XCTAssertNil(Titles.derived(fromPrompt: "y"))
        XCTAssertNil(Titles.derived(fromPrompt: "/init the project setup"))
        XCTAssertNil(Titles.derived(fromPrompt: "       "))
    }

    func testLongPromptCutsAtWordBoundary() {
        let prompt = "refactor the persistence layer to support versioned migrations cleanly"
        let title = Titles.derived(fromPrompt: prompt)!
        XCTAssertLessThanOrEqual(title.count, 40)
        XCTAssertFalse(title.hasSuffix(" "))
        // Never ends mid-word: the next char in the source after the cut is a space.
        XCTAssertTrue(prompt.hasPrefix(title))
        let next = prompt.index(prompt.startIndex, offsetBy: title.count)
        XCTAssertEqual(prompt[next], " ")
    }

    func testExactFitPassesThrough() {
        XCTAssertEqual(Titles.derived(fromPrompt: "ship the canvas zoom round"),
                       "ship the canvas zoom round")
    }

    func testBoundaryRetreatRespectsMinimumFloor() {
        // A cut whose only space is before the 8-char floor must NOT retreat —
        // it keeps the mid-word cut instead of collapsing to a stub.
        let prompt = "reconfigure" + String(repeating: "x", count: 60)   // no space after idx 0
        let long = "a " + prompt
        let title = Titles.derived(fromPrompt: long)!
        XCTAssertEqual(title.count, 40)   // no retreat below the floor
    }

    func testCleanCutAtExactSpaceDoesNotRetreat() {
        // 40 chars land exactly before a space: pass through with no retreat.
        let head = String(repeating: "ab ", count: 13) + "c"   // 40 chars exactly
        XCTAssertEqual(head.count, 40)
        let title = Titles.derived(fromPrompt: head + " tail words")!
        XCTAssertEqual(title, head)
    }

    func testMinimumLengthBoundary() {
        XCTAssertNil(Titles.derived(fromPrompt: "1234567"))       // 7 = too thin
        XCTAssertNotNil(Titles.derived(fromPrompt: "12345678"))   // 8 = named
    }
}
