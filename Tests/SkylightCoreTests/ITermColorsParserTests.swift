import XCTest
import SkylightCore

final class ITermColorsParserTests: XCTestCase {
    /// A minimal but real-shaped .itermcolors: Apple XML plist, one dict per
    /// colour, components as 0-1 reals.
    private func plist(_ entries: [String: (Double, Double, Double, String?)],
                       alpha: Double? = nil) -> Data {
        var body = ""
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            body += """
                <key>\(key)</key>
                <dict>
                    <key>Red Component</key><real>\(value.0)</real>
                    <key>Green Component</key><real>\(value.1)</real>
                    <key>Blue Component</key><real>\(value.2)</real>
            """
            if let alpha { body += "<key>Alpha Component</key><real>\(alpha)</real>" }
            if let space = value.3 {
                body += "<key>Color Space</key><string>\(space)</string>"
            }
            body += "</dict>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        \(body)
        </dict></plist>
        """.data(using: .utf8)!
    }

    private var fullScheme: Data {
        var entries: [String: (Double, Double, Double, String?)] = [
            "Background Color": (0, 0, 0, nil),
            "Foreground Color": (1, 1, 1, nil),
            "Cursor Color": (1, 0, 0, nil),
            "Cursor Text Color": (0, 1, 0, nil),
            "Selection Color": (0, 0, 1, nil),
            "Selected Text Color": (1, 1, 0, nil),
            "Bold Color": (0, 1, 1, nil),
        ]
        for index in 0...15 {
            entries["Ansi \(index) Color"] = (Double(index) / 15, 0, 0, nil)
        }
        return plist(entries)
    }

    func testParsesAnsi0Through15() throws {
        let theme = try XCTUnwrap(ITermColorsParser.parse(fullScheme, name: "Test"))
        XCTAssertEqual(theme.palette.count, 16)
        XCTAssertEqual(theme.palette[0], Color8(r: 0, g: 0, b: 0))
        XCTAssertEqual(theme.palette[15], Color8(r: 255, g: 0, b: 0))
        XCTAssertEqual(theme.source, .iterm2)
        XCTAssertEqual(theme.name, "Test")
    }

    func testFloatComponentsBecomeBytes() throws {
        let theme = try XCTUnwrap(
            ITermColorsParser.parse(plist(["Background Color": (0.5, 1, 0, nil),
                                           "Foreground Color": (1, 1, 1, nil)]),
                                    name: "T"))
        XCTAssertEqual(theme.background, Color8(r: 128, g: 255, b: 0))
    }

    func testBackgroundForegroundCursorSelectionMapped() throws {
        let theme = try XCTUnwrap(ITermColorsParser.parse(fullScheme, name: "T"))
        XCTAssertEqual(theme.background, Color8(r: 0, g: 0, b: 0))
        XCTAssertEqual(theme.foreground, Color8(r: 255, g: 255, b: 255))
        XCTAssertEqual(theme.cursor, Color8(r: 255, g: 0, b: 0))
        XCTAssertEqual(theme.cursorText, Color8(r: 0, g: 255, b: 0))
        XCTAssertEqual(theme.selectionBackground, Color8(r: 0, g: 0, b: 255))
        XCTAssertEqual(theme.selectionForeground, Color8(r: 255, g: 255, b: 0))
        XCTAssertEqual(theme.bold, Color8(r: 0, g: 255, b: 255))
    }

    /// A P3 file read as sRGB is visibly wrong — saturated colours shift. We
    /// do not silently mis-import it: the theme still lands (the numbers are
    /// real) but the colour space is NAMED so the user knows what they got.
    func testDisplayP3IsFlaggedNotSilentlyWrong() throws {
        let theme = try XCTUnwrap(
            ITermColorsParser.parse(plist(["Background Color": (0.1, 0.1, 0.2, "P3"),
                                           "Foreground Color": (1, 1, 1, "P3")]),
                                    name: "T"))
        XCTAssertTrue(theme.skipped.contains { $0.contains("P3") },
                      "a P3 colour space must be reported, got \(theme.skipped)")
    }

    func testSRGBIsNotFlagged() throws {
        let theme = try XCTUnwrap(
            ITermColorsParser.parse(plist(["Background Color": (0, 0, 0, "sRGB"),
                                           "Foreground Color": (1, 1, 1, "sRGB")]),
                                    name: "T"))
        XCTAssertTrue(theme.skipped.isEmpty)
    }

    /// The never-invent-a-colour rule: absent optional keys stay nil rather
    /// than defaulting to black, which would look deliberate and be wrong.
    func testMissingKeysLeaveNilNotBlack() throws {
        let theme = try XCTUnwrap(
            ITermColorsParser.parse(plist(["Background Color": (0, 0, 0, nil),
                                           "Foreground Color": (1, 1, 1, nil)]),
                                    name: "T"))
        XCTAssertNil(theme.cursor)
        XCTAssertNil(theme.selectionBackground)
        XCTAssertNil(theme.bold)
        XCTAssertTrue(theme.palette.isEmpty)
    }

    func testAlphaComponentBecomesBackgroundOpacity() throws {
        let theme = try XCTUnwrap(
            ITermColorsParser.parse(plist(["Background Color": (0, 0, 0, nil),
                                           "Foreground Color": (1, 1, 1, nil)],
                                          alpha: 0.8),
                                    name: "T"))
        XCTAssertEqual(theme.backgroundOpacity ?? -1, 0.8, accuracy: 0.01)
    }

    func testMalformedPlistIsNil() {
        XCTAssertNil(ITermColorsParser.parse(Data("not a plist".utf8), name: "T"))
        XCTAssertNil(ITermColorsParser.parse(Data(), name: "T"))
        // A valid plist with no colours in it is not a theme.
        XCTAssertNil(ITermColorsParser.parse(plist([:]), name: "T"))
    }

    /// Without a background OR foreground there is nothing to build a theme
    /// around, and half a scheme is worse than an honest refusal.
    func testSchemeWithoutBackgroundOrForegroundIsNil() {
        XCTAssertNil(ITermColorsParser.parse(plist(["Cursor Color": (1, 0, 0, nil)]),
                                             name: "T"))
    }
}
