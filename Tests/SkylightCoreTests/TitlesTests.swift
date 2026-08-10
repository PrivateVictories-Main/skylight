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
}
