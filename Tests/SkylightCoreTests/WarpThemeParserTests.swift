import XCTest
import SkylightCore

final class WarpThemeParserTests: XCTestCase {
    /// Ryan's real ~/.warp/themes/catppuccin/themes/catppuccin_mocha.yml,
    /// verbatim. He runs Catppuccin Mocha in Ghostty AND Warp, so this and the
    /// ghostty fixture should land on the same look from two directions.
    private let catppuccinMocha = """
    background: '#1e1e2e'
    accent: '#f5e0dc'
    foreground: '#cdd6f4'
    details: darker
    terminal_colors:
      normal:
        black: '#45475a'
        red: '#f38ba8'
        green: '#a6e3a1'
        yellow: '#f9e2af'
        blue: '#89b4fa'
        magenta: '#f5c2e7'
        cyan: '#94e2d5'
        white: '#bac2de'
      bright:
        black: '#585b70'
        red: '#f38ba8'
        green: '#a6e3a1'
        yellow: '#f9e2af'
        blue: '#89b4fa'
        magenta: '#f5c2e7'
        cyan: '#94e2d5'
        white: '#a6adc8'
    """

    func testParsesCatppuccinMocha() throws {
        let theme = try XCTUnwrap(
            WarpThemeParser.parse(catppuccinMocha, name: "catppuccin_mocha"))
        XCTAssertEqual(theme.background, Color8("#1e1e2e"))
        XCTAssertEqual(theme.foreground, Color8("#cdd6f4"))
        XCTAssertEqual(theme.source, .warp)
        XCTAssertTrue(theme.isDarkDerived)
    }

    /// Warp names its colours; ANSI numbers them. The mapping is explicit
    /// because getting it wrong swaps red and blue in every program the user
    /// runs, and nothing about the file would look wrong.
    func testNamedColoursMapToAnsiIndices() throws {
        let theme = try XCTUnwrap(
            WarpThemeParser.parse(catppuccinMocha, name: "t"))
        XCTAssertEqual(theme.palette[0], Color8("#45475a"))    // normal black
        XCTAssertEqual(theme.palette[1], Color8("#f38ba8"))    // normal red
        XCTAssertEqual(theme.palette[2], Color8("#a6e3a1"))    // normal green
        XCTAssertEqual(theme.palette[3], Color8("#f9e2af"))    // normal yellow
        XCTAssertEqual(theme.palette[4], Color8("#89b4fa"))    // normal blue
        XCTAssertEqual(theme.palette[5], Color8("#f5c2e7"))    // normal magenta
        XCTAssertEqual(theme.palette[6], Color8("#94e2d5"))    // normal cyan
        XCTAssertEqual(theme.palette[7], Color8("#bac2de"))    // normal white
        XCTAssertEqual(theme.palette[8], Color8("#585b70"))    // bright black
        XCTAssertEqual(theme.palette[15], Color8("#a6adc8"))   // bright white
        XCTAssertEqual(theme.palette.count, 16)
    }

    func testQuotedAndUnquotedScalars() throws {
        let theme = try XCTUnwrap(WarpThemeParser.parse("""
        background: "#000000"
        foreground: #ffffff
        accent: '#ff0000'
        """, name: "t"))
        XCTAssertEqual(theme.background, Color8("#000000"))
        XCTAssertEqual(theme.foreground, Color8("#ffffff"))
    }

    func testMissingBrightBlockLeavesUpperPaletteNil() throws {
        let theme = try XCTUnwrap(WarpThemeParser.parse("""
        background: '#000000'
        foreground: '#ffffff'
        terminal_colors:
          normal:
            black: '#111111'
            red: '#222222'
        """, name: "t"))
        XCTAssertEqual(theme.palette[0], Color8("#111111"))
        XCTAssertEqual(theme.palette[1], Color8("#222222"))
        XCTAssertNil(theme.palette[8])
        XCTAssertNil(theme.palette[2])
    }

    func testCommentsAndBlankLinesIgnored() throws {
        let theme = try XCTUnwrap(WarpThemeParser.parse("""
        # Catppuccin
        background: '#1e1e2e'

        foreground: '#cdd6f4'   # trailing
        """, name: "t"))
        XCTAssertEqual(theme.background, Color8("#1e1e2e"))
        XCTAssertEqual(theme.foreground, Color8("#cdd6f4"))
    }

    /// YAML written with tabs (or a mix) is still YAML people have on disk.
    /// Counting only spaces read every nested key as top-level, which put the
    /// colour names outside the terminal_colors block entirely.
    func testTabIndentedFileParses() throws {
        let theme = try XCTUnwrap(WarpThemeParser.parse(
            "background: '#000000'\nforeground: '#ffffff'\n"
            + "terminal_colors:\n\tnormal:\n\t\tblack: '#111111'\n\t\tred: '#222222'\n",
            name: "t"))
        XCTAssertEqual(theme.palette[0], Color8("#111111"))
        XCTAssertEqual(theme.palette[1], Color8("#222222"))
    }

    func testFileWithoutBackgroundOrForegroundIsNil() {
        XCTAssertNil(WarpThemeParser.parse("details: darker", name: "t"))
        XCTAssertNil(WarpThemeParser.parse("", name: "t"))
    }
}
