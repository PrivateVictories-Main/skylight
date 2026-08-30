import XCTest
import SkylightCore

final class VSCodeThemeParserTests: XCTestCase {
    func testMapsTerminalAnsiKeys() throws {
        let json = """
        {
          "name": "Catppuccin Mocha",
          "colors": {
            "terminal.background": "#1e1e2e",
            "terminal.foreground": "#cdd6f4",
            "terminal.ansiBlack": "#45475a",
            "terminal.ansiRed": "#f38ba8",
            "terminal.ansiBrightBlack": "#585b70",
            "terminal.ansiBrightWhite": "#a6adc8",
            "terminalCursor.foreground": "#f5e0dc",
            "terminal.selectionBackground": "#585b70"
          }
        }
        """
        let theme = try XCTUnwrap(VSCodeThemeParser.parse(Data(json.utf8), name: "x"))
        XCTAssertEqual(theme.name, "Catppuccin Mocha")   // the file's own name wins
        XCTAssertEqual(theme.source, .vscode)
        XCTAssertEqual(theme.background, Color8("#1e1e2e"))
        XCTAssertEqual(theme.foreground, Color8("#cdd6f4"))
        XCTAssertEqual(theme.palette[0], Color8("#45475a"))
        XCTAssertEqual(theme.palette[1], Color8("#f38ba8"))
        XCTAssertEqual(theme.palette[8], Color8("#585b70"))
        XCTAssertEqual(theme.palette[15], Color8("#a6adc8"))
        XCTAssertEqual(theme.cursor, Color8("#f5e0dc"))
        XCTAssertEqual(theme.selectionBackground, Color8("#585b70"))
    }

    /// VS Code files are JSONC: comments and trailing commas are legal, and
    /// JSONSerialization rejects both. Most real theme files use them.
    func testJSONCCommentsAndTrailingCommasTolerated() throws {
        let json = """
        {
          // the terminal bit
          "colors": {
            "terminal.background": "#000000", /* inline */
            "terminal.foreground": "#ffffff",
          },
        }
        """
        let theme = try XCTUnwrap(VSCodeThemeParser.parse(Data(json.utf8), name: "x"))
        XCTAssertEqual(theme.background, Color8("#000000"))
        XCTAssertEqual(theme.foreground, Color8("#ffffff"))
    }

    func testAHashInsideAStringIsNotAComment() throws {
        // A naive comment stripper eats the colour literals themselves.
        let json = """
        { "colors": { "terminal.background": "#1e1e2e", "terminal.foreground": "#cdd6f4" } }
        """
        let theme = try XCTUnwrap(VSCodeThemeParser.parse(Data(json.utf8), name: "x"))
        XCTAssertEqual(theme.background, Color8("#1e1e2e"))
    }

    func testASlashInsideAStringIsNotAComment() throws {
        let json = """
        { "name": "http://not/a/comment",
          "colors": { "terminal.background": "#111111", "terminal.foreground": "#eeeeee" } }
        """
        let theme = try XCTUnwrap(VSCodeThemeParser.parse(Data(json.utf8), name: "x"))
        XCTAssertEqual(theme.name, "http://not/a/comment")
        XCTAssertEqual(theme.background, Color8("#111111"))
    }

    /// Most themes never set terminal.background — the terminal inherits the
    /// editor. Falling back is right; doing it silently is not.
    func testFallsBackToEditorBackgroundAndFlagsInferred() throws {
        let json = """
        { "colors": { "editor.background": "#1e1e2e", "editor.foreground": "#cdd6f4" } }
        """
        let theme = try XCTUnwrap(VSCodeThemeParser.parse(Data(json.utf8), name: "x"))
        XCTAssertEqual(theme.background, Color8("#1e1e2e"))
        XCTAssertEqual(theme.foreground, Color8("#cdd6f4"))
        XCTAssertTrue(theme.skipped.contains { $0.contains("editor.background") },
                      "an inferred background must say so, got \(theme.skipped)")
    }

    func testWorkbenchColorCustomizationsFromSettingsJSON() throws {
        let json = """
        {
          "editor.fontSize": 13,
          "workbench.colorCustomizations": {
            "terminal.background": "#002b36",
            "terminal.foreground": "#839496"
          }
        }
        """
        let theme = try XCTUnwrap(VSCodeThemeParser.parse(Data(json.utf8), name: "settings"))
        XCTAssertEqual(theme.background, Color8("#002b36"))
    }

    func testAlphaInAColourBecomesOpacity() throws {
        let json = """
        { "colors": { "terminal.background": "#1e1e2ecc", "terminal.foreground": "#ffffff" } }
        """
        let theme = try XCTUnwrap(VSCodeThemeParser.parse(Data(json.utf8), name: "x"))
        XCTAssertEqual(theme.background, Color8("#1e1e2e"))
        XCTAssertEqual(theme.backgroundOpacity ?? -1, Double(0xcc) / 255, accuracy: 0.001)
    }

    func testNoColoursIsNil() {
        XCTAssertNil(VSCodeThemeParser.parse(Data(#"{"editor.fontSize": 13}"#.utf8), name: "x"))
        XCTAssertNil(VSCodeThemeParser.parse(Data("not json".utf8), name: "x"))
        XCTAssertNil(VSCodeThemeParser.parse(Data(), name: "x"))
    }
}
