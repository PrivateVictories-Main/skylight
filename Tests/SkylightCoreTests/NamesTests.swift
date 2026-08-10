import XCTest
import SkylightCore

final class NamesTests: XCTestCase {
    func testBareBaseWhenNothingExists() {
        XCTAssertEqual(Names.numbered(base: "Terminal", among: []), "Terminal")
        XCTAssertEqual(Names.numbered(base: "Canvas", among: ["Terminal", "Terminal 2"]),
                       "Canvas")
    }

    func testBaseOnlyExistingTakesTwo() {
        XCTAssertEqual(Names.numbered(base: "Terminal", among: ["Terminal"]), "Terminal 2")
    }

    /// The reason this counts the highest suffix and not the count: "Terminal
    /// 2" was deleted out of the middle, and "Terminal 3" is still on screen.
    /// Reusing 2 would be fine; handing out 2 while 3 exists reads as a bug the
    /// next time the list is sorted, and reusing 3 would collide outright.
    func testHighestSuffixWinsAcrossADeletedMiddle() {
        XCTAssertEqual(Names.numbered(base: "Terminal", among: ["Terminal", "Terminal 3"]),
                       "Terminal 4")
    }

    func testNonNumericSuffixesAreNotMembersOfTheSeries() {
        // A rename that merely starts with the base is somebody's own name.
        XCTAssertEqual(Names.numbered(base: "Terminal", among: ["Terminal beta"]),
                       "Terminal")
        XCTAssertEqual(Names.numbered(base: "Terminal",
                                      among: ["Terminal", "Terminal beta"]),
                       "Terminal 2")
        // No space, so not a member either.
        XCTAssertEqual(Names.numbered(base: "Terminal", among: ["Terminal2"]), "Terminal")
    }
}
