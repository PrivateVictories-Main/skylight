import XCTest
import SkylightCore

final class ArgumentsTests: XCTestCase {
    func testPlainWordsSplitOnWhitespace() {
        XCTAssertEqual(Arguments.split("--model opus"), ["--model", "opus"])
        XCTAssertEqual(Arguments.split("  a \t b  "), ["a", "b"])
    }

    func testDoubleQuotesGroupSpaces() {
        XCTAssertEqual(Arguments.split(#"--dir "/Applications/My Tool""#),
                       ["--dir", "/Applications/My Tool"])
        XCTAssertEqual(Arguments.split(#"a "b c" d"#), ["a", "b c", "d"])
    }

    func testSingleQuotesAreLiteral() {
        XCTAssertEqual(Arguments.split(#"'a "b" \n c'"#), [#"a "b" \n c"#])
    }

    func testBackslashEscapes() {
        XCTAssertEqual(Arguments.split(#"a\ b"#), ["a b"])
        XCTAssertEqual(Arguments.split(#""a \" b""#), [#"a " b"#])
        // Inside double quotes only " and \ are escapable — POSIX keeps the
        // backslash otherwise.
        XCTAssertEqual(Arguments.split(#""a\nb""#), [#"a\nb"#])
    }

    func testUnterminatedQuoteKeepsRemainder() {
        XCTAssertEqual(Arguments.split(#"a "b c"#), ["a", "b c"])
        XCTAssertEqual(Arguments.split(#"tail\"#), ["tail\\"])
    }

    func testEmptyAndBlankInput() {
        XCTAssertEqual(Arguments.split(""), [])
        XCTAssertEqual(Arguments.split("   "), [])
    }

    func testEmptyQuotesMakeAnEmptyArgument() {
        XCTAssertEqual(Arguments.split(#"a "" b"#), ["a", "", "b"])
    }
}
