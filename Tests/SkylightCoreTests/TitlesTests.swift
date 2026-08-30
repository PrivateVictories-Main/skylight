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

    // MARK: - sanitizedPaste

    func testSanitizedPasteLeavesPlainTextAlone() {
        XCTAssertEqual(Titles.sanitizedPaste("fix the login bug"), "fix the login bug")
        // Newlines and tabs are legitimate in a multi-line prompt.
        XCTAssertEqual(Titles.sanitizedPaste("fix the\nlogin\tbug"), "fix the\nlogin\tbug")
    }

    /// The whole point of the upgrade: dropping the lone ESC scalar used to
    /// leave the human-readable tail of the sequence behind, so a pasted line
    /// of colored build output named the terminal "[1;31mBuild failed[0m".
    func testSanitizedPasteStripsWholeCSISequences() {
        XCTAssertEqual(Titles.sanitizedPaste("\u{1B}[1;31mBuild failed\u{1B}[0m"),
                       "Build failed")
        // Cursor moves and erases are CSI too, params or not.
        XCTAssertEqual(Titles.sanitizedPaste("a\u{1B}[2Kb\u{1B}[Hc"), "abc")
    }

    func testSanitizedPasteStripsOSCSequences() {
        // BEL-terminated (what shells actually emit for a window title).
        XCTAssertEqual(Titles.sanitizedPaste("\u{1B}]0;my title\u{07}done"), "done")
        // ST-terminated (ESC \) is the other legal ending.
        XCTAssertEqual(Titles.sanitizedPaste("\u{1B}]0;my title\u{1B}\\done"), "done")
    }

    func testSanitizedPasteStripsFunctionKeyScalars() {
        // 0xF700…0xF8FF: arrows and F-keys arrive as characters.
        XCTAssertEqual(Titles.sanitizedPaste("a\u{F700}b\u{F8FF}c"), "abc")
    }

    func testSanitizedPasteOfPureControlNoiseIsEmpty() {
        XCTAssertEqual(Titles.sanitizedPaste("\u{1B}[0m\u{07}\u{01}"), "")
        XCTAssertEqual(Titles.sanitizedPaste(""), "")
    }

    /// An unterminated sequence is not evidence enough to eat the text after
    /// it — only the ESC itself goes, exactly as before the upgrade.
    func testSanitizedPasteKeepsTextAfterAnIncompleteSequence() {
        XCTAssertEqual(Titles.sanitizedPaste("\u{1B}[1;31"), "[1;31")
        XCTAssertEqual(Titles.sanitizedPaste("\u{1B}]0;no terminator"), "]0;no terminator")
    }
}

final class AbbreviatedPathTests: XCTestCase {
    private let home = "/Users/ryan_s"

    func testTildeAbbreviation() {
        XCTAssertEqual(Titles.abbreviatedPath("/Users/ryan_s/code/skylight",
                                              home: home, maxLength: 40),
                       "~/code/skylight")
        XCTAssertEqual(Titles.abbreviatedPath(home, home: home, maxLength: 40), "~")
    }

    /// A path that is NOT under home keeps its root — silently showing
    /// "~/…" for /opt/homebrew would be a lie about where you are.
    func testAPathOutsideHomeIsNotTilded() {
        XCTAssertEqual(Titles.abbreviatedPath("/opt/homebrew/bin",
                                              home: home, maxLength: 40),
                       "/opt/homebrew/bin")
    }

    /// A near-miss must not be mistaken for a match: /Users/ryan_smith is a
    /// different person's home.
    func testAHomePrefixThatIsNotAPathBoundaryIsNotTilded() {
        XCTAssertEqual(Titles.abbreviatedPath("/Users/ryan_smith/x",
                                              home: home, maxLength: 40),
                       "/Users/ryan_smith/x")
    }

    /// The last component is what tells you where you are; it survives.
    func testMiddleTruncationKeepsTheLastComponent() throws {
        let long = "/Users/ryan_s/code/active/skylight/Sources/SkylightCore/Subscriptions"
        let result = try XCTUnwrap(
            Titles.abbreviatedPath(long, home: home, maxLength: 28))
        XCTAssertTrue(result.hasSuffix("Subscriptions"), result)
        XCTAssertTrue(result.count <= 28, "\(result.count): \(result)")
        XCTAssertTrue(result.contains("…"), result)
    }

    /// A single component longer than the budget cannot be split without
    /// lying about the name, so it is returned whole.
    func testAnOverlongSingleComponentIsNotMangled() {
        let name = "/" + String(repeating: "x", count: 40)
        XCTAssertEqual(Titles.abbreviatedPath(name, home: home, maxLength: 10),
                       String(repeating: "x", count: 40))
    }

    func testRootAndEmptyEdgeCases() {
        XCTAssertEqual(Titles.abbreviatedPath("/", home: home, maxLength: 20), "/")
        XCTAssertNil(Titles.abbreviatedPath("", home: home, maxLength: 20))
        XCTAssertNil(Titles.abbreviatedPath("   ", home: home, maxLength: 20))
    }

    func testTrailingSlashDoesNotProduceAnEmptyTail() {
        XCTAssertEqual(Titles.abbreviatedPath("/Users/ryan_s/code/",
                                              home: home, maxLength: 40),
                       "~/code")
    }
}
