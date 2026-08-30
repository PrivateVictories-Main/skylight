import XCTest
import SkylightCore

final class GhosttyConfigParserTests: XCTestCase {
    /// Ryan's real ~/.config/ghostty/config, verbatim. If the highest-fidelity
    /// importer cannot read the machine it is being built on, nothing below it
    /// is worth trusting.
    private let ryansConfig = """
    font-family = JetBrains Mono Nerd Font
    font-family = JetBrainsMonoClaude NFM
    font-size = 14
    theme = Catppuccin Mocha
    background-opacity = 0.98
    window-padding-x = 24
    window-padding-y = 24
    scrollbar = never
    macos-titlebar-style = tabs

    # Thin blinking I-beam cursor (like a text editor) instead of the block
    cursor-style = bar
    cursor-style-blink = true

    # Close tabs/splits instantly, no "are you sure?" prompt
    confirm-close-surface = false
    copy-on-select = false
    keybind = shift+enter=text:\\n

    # Default window size
    window-width = 140
    window-height = 42

    # Auto-launch tmux on every new window
    command = /opt/homebrew/bin/tmux new-session

    font-codepoint-map = U+2591-U+2593=Statusline Dots Fine
    """

    func testParsesRyansConfig() throws {
        let parsed = try XCTUnwrap(GhosttyConfigParser.parse(ryansConfig, name: "config"))
        XCTAssertEqual(parsed.themeReference, "Catppuccin Mocha")
        XCTAssertEqual(parsed.theme.backgroundOpacity, 0.98)
        XCTAssertEqual(parsed.theme.fontSize, 14)
        XCTAssertEqual(parsed.theme.paddingX, 24)
        XCTAssertEqual(parsed.theme.paddingY, 24)
        XCTAssertEqual(parsed.theme.cursorStyle, "bar")
        XCTAssertEqual(parsed.theme.cursorBlink, true)
        // The FIRST font-family wins: ghostty treats repeats as a fallback
        // chain, and the head of that chain is the face the user chose.
        XCTAssertEqual(parsed.theme.fontFamily, "JetBrains Mono Nerd Font")
    }

    /// The security line, exercised against the real file that contains a
    /// `command` launching tmux.
    func testCommandAndKeybindAreRefusedAndNamed() throws {
        let parsed = try XCTUnwrap(GhosttyConfigParser.parse(ryansConfig, name: "config"))
        XCTAssertTrue(parsed.theme.skipped.contains("command"))
        XCTAssertTrue(parsed.theme.skipped.contains("keybind"))
        // Nothing executable may survive anywhere in the parsed theme.
        let encoded = try String(data: JSONEncoder().encode(parsed.theme), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("tmux"), "a command leaked into the theme")
        XCTAssertFalse(encoded.contains("shift+enter"))
        // Keys we have no opinion about are ignored, not paraded as refusals.
        XCTAssertFalse(parsed.theme.skipped.contains("window-width"))
        XCTAssertFalse(parsed.theme.skipped.contains("scrollbar"))
    }

    func testPaletteEntriesParse() throws {
        let config = """
        background = #1e1e2e
        foreground = #cdd6f4
        palette = 0=#45475a
        palette = 1=#f38ba8
        palette = 15=#a6adc8
        cursor-color = #f5e0dc
        selection-background = #585b70
        """
        let parsed = try XCTUnwrap(GhosttyConfigParser.parse(config, name: "c"))
        XCTAssertEqual(parsed.theme.background, Color8("#1e1e2e"))
        XCTAssertEqual(parsed.theme.foreground, Color8("#cdd6f4"))
        XCTAssertEqual(parsed.theme.palette[0], Color8("#45475a"))
        XCTAssertEqual(parsed.theme.palette[1], Color8("#f38ba8"))
        XCTAssertEqual(parsed.theme.palette[15], Color8("#a6adc8"))
        XCTAssertEqual(parsed.theme.cursor, Color8("#f5e0dc"))
        XCTAssertEqual(parsed.theme.selectionBackground, Color8("#585b70"))
    }

    func testDualThemeSplitsLightAndDark() throws {
        let parsed = try XCTUnwrap(
            GhosttyConfigParser.parse("theme = light:Alabaster,dark:Afterglow", name: "c"))
        XCTAssertEqual(parsed.lightThemeReference, "Alabaster")
        XCTAssertEqual(parsed.darkThemeReference, "Afterglow")
        XCTAssertNil(parsed.themeReference)
    }

    func testCommentsBlanksAndInlineWhitespaceIgnored() throws {
        let parsed = try XCTUnwrap(GhosttyConfigParser.parse("""
        # a comment

          background   =   #112233
        # trailing comment line
        """, name: "c"))
        XCTAssertEqual(parsed.theme.background, Color8("#112233"))
    }

    func testLastColourKeyWins() throws {
        let parsed = try XCTUnwrap(GhosttyConfigParser.parse("""
        background = #000000
        background = #1e1e2e
        """, name: "c"))
        XCTAssertEqual(parsed.theme.background, Color8("#1e1e2e"))
    }

    func testAlphaInAColourBecomesOpacityNotALostChannel() throws {
        let parsed = try XCTUnwrap(
            GhosttyConfigParser.parse("background = #1e1e2ecc", name: "c"))
        XCTAssertEqual(parsed.theme.background, Color8("#1e1e2e"))
        XCTAssertEqual(parsed.theme.backgroundOpacity ?? -1,
                       Double(0xcc) / 255, accuracy: 0.001)
    }

    func testExplicitOpacityOutranksAnAlphaChannel() throws {
        let parsed = try XCTUnwrap(GhosttyConfigParser.parse("""
        background = #1e1e2ecc
        background-opacity = 0.5
        """, name: "c"))
        XCTAssertEqual(parsed.theme.backgroundOpacity, 0.5)
    }

    /// The secondary vector: this parser splits on \n only, so a bare
    /// carriage return rides INSIDE a value — and lands in a rendered config
    /// where the engine may well treat it as a line break.
    func testACarriageReturnInsideAValueIsRefusedAndNamed() throws {
        let parsed = try XCTUnwrap(GhosttyConfigParser.parse(
            "background = #1e1e2e\nfont-family = Menlo\rcommand = /bin/sh",
            name: "c"))
        XCTAssertNil(parsed.theme.fontFamily)
        XCTAssertTrue(parsed.theme.skipped.contains { $0.contains("font-family") },
                      "got \(parsed.theme.skipped)")
    }

    func testAConfigWithNoLookKeysIsNotATheme() {
        // A file that says nothing about appearance must not produce a black
        // theme out of thin air.
        XCTAssertNil(GhosttyConfigParser.parse("window-width = 140", name: "c"))
        XCTAssertNil(GhosttyConfigParser.parse("", name: "c"))
    }
}
