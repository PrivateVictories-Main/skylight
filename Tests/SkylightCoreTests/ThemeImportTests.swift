import XCTest
import SkylightCore

final class ThemeImportTests: XCTestCase {
    private let ghosttyConfig = "background = #1e1e2e\nforeground = #cdd6f4\n"
    private let warpYAML = "background: '#1e1e2e'\nforeground: '#cdd6f4'\n"
    private let vscodeJSON = """
    { "colors": { "terminal.background": "#1e1e2e", "terminal.foreground": "#cdd6f4" } }
    """
    private let windowsJSON = """
    { "schemes": [ { "name": "Campbell", "background": "#0C0C0C", "foreground": "#CCCCCC" } ] }
    """
    private let itermPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Background Color</key><dict>
      <key>Red Component</key><real>0</real>
      <key>Green Component</key><real>0</real>
      <key>Blue Component</key><real>0</real></dict>
    <key>Foreground Color</key><dict>
      <key>Red Component</key><real>1</real>
      <key>Green Component</key><real>1</real>
      <key>Blue Component</key><real>1</real></dict>
    </dict></plist>
    """

    private func themes(_ text: String, _ filename: String) throws -> [SkylightTheme] {
        try ThemeImport.parse(data: Data(text.utf8), filename: filename).get()
    }

    func testDispatchesByExtension() throws {
        XCTAssertEqual(try themes(ghosttyConfig, "config").first?.source, .ghostty)
        XCTAssertEqual(try themes(warpYAML, "catppuccin_mocha.yml").first?.source, .warp)
        XCTAssertEqual(try themes(warpYAML, "x.yaml").first?.source, .warp)
        XCTAssertEqual(try themes(itermPlist, "Solarized.itermcolors").first?.source, .iterm2)
    }

    /// Both are `.json`. The only honest way to tell them apart is to look
    /// inside for the `schemes` array — the extension cannot say.
    func testSniffsWindowsTerminalVsVSCodeJSON() throws {
        XCTAssertEqual(try themes(windowsJSON, "settings.json").first?.source,
                       .windowsTerminal)
        XCTAssertEqual(try themes(vscodeJSON, "settings.json").first?.source, .vscode)
        // Even named misleadingly, the CONTENT decides.
        XCTAssertEqual(try themes(windowsJSON, "theme.json").first?.source,
                       .windowsTerminal)
    }

    func testUnknownExtensionWithKnownContentStillParses() throws {
        // A config someone saved as "mytheme.txt" is still a ghostty config.
        XCTAssertEqual(try themes(ghosttyConfig, "mytheme.txt").first?.source, .ghostty)
        XCTAssertEqual(try themes(itermPlist, "noext").first?.source, .iterm2)
    }

    func testNameComesFromTheFileWhenTheFormatHasNone() throws {
        XCTAssertEqual(try themes(ghosttyConfig, "Catppuccin Mocha.conf").first?.name,
                       "Catppuccin Mocha")
        XCTAssertEqual(try themes(itermPlist, "Solarized Dark.itermcolors").first?.name,
                       "Solarized Dark")
    }

    func testUnrecognizedReturnsErrorNotEmptyTheme() {
        switch ThemeImport.parse(data: Data("¯\\_(ツ)_/¯".utf8), filename: "x.bin") {
        case .success(let themes):
            XCTFail("expected a refusal, got \(themes.count) themes")
        case .failure(let error):
            XCTAssertEqual(error, .unrecognizedFormat)
        }
    }

    func testEmptyInputIsAnError() {
        switch ThemeImport.parse(data: Data(), filename: "config") {
        case .success: XCTFail("empty data must not produce a theme")
        case .failure(let error): XCTAssertEqual(error, .empty)
        }
    }

    /// A format we recognise that yields nothing usable is a DIFFERENT failure
    /// from one we could not read at all — the user gets told which.
    func testRecognizedButEmptyIsMalformed() {
        switch ThemeImport.parse(data: Data(#"{"schemes": []}"#.utf8),
                                 filename: "settings.json") {
        case .success: XCTFail("an empty schemes array is not a theme")
        case .failure(let error): XCTAssertEqual(error, .malformed("no themes in file"))
        }
    }

    func testWindowsTerminalYieldsEveryScheme() throws {
        let many = """
        { "schemes": [
          { "name": "A", "background": "#000000", "foreground": "#ffffff" },
          { "name": "B", "background": "#ffffff", "foreground": "#000000" } ] }
        """
        XCTAssertEqual(try themes(many, "settings.json").map(\.name), ["A", "B"])
    }

    func testStandaloneWindowsSchemeKeepsItsPaletteAndSource() throws {
        let single = """
        { // A scheme copied from a theme gallery
          "name": "Personal Windows theme", "background": "#123", "foreground": "#def",
          "purple": "#a0b1c2", "brightPurple": "#d3e4f5", "cursorColor": "#f00",
        }
        """
        let theme = try XCTUnwrap(try themes(single, "theme.json").first)
        XCTAssertEqual(theme.source, .windowsTerminal)
        XCTAssertEqual(theme.name, "Personal Windows theme")
        XCTAssertEqual(theme.background, Color8("#112233"))
        XCTAssertEqual(theme.palette[5], Color8("#a0b1c2"))
        XCTAssertEqual(theme.palette[13], Color8("#d3e4f5"))
        XCTAssertEqual(theme.cursor, Color8("#ff0000"))
        XCTAssertEqual(try themes(single, "theme.txt"), [theme])
    }

    func testVSCodeWrapperWinsOverUnrelatedTopLevelColorMetadata() throws {
        let json = """
        { "background": "#fff", "foreground": "#000",
          "colors": { "terminal.background": "#123456", "terminal.foreground": "#abcdef" } }
        """
        let theme = try XCTUnwrap(try themes(json, "theme.json").first)
        XCTAssertEqual(theme.source, .vscode)
        XCTAssertEqual(theme.background, Color8("#123456"))
    }

    func testSharedPortableFixturesKeepTheSameCorePaletteOnMacOS() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for filename in ["theme-ghostty.conf", "theme-windows.jsonc", "theme-vscode.jsonc"] {
            let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/\(filename)"))
            let theme = try XCTUnwrap(try ThemeImport.parse(data: data, filename: filename).get().first)
            XCTAssertEqual(theme.background, Color8("#102030"), filename)
            XCTAssertEqual(theme.foreground, Color8("#e0e1e2"), filename)
            XCTAssertEqual(theme.cursor, Color8("#abcdef"), filename)
            XCTAssertEqual(theme.selectionBackground, Color8("#304050"), filename)
            XCTAssertEqual(theme.palette[1], Color8("#cc3322"), filename)
            XCTAssertEqual(theme.palette[5], Color8("#aa44bb"), filename)
            XCTAssertEqual(theme.palette[13], Color8("#ff88ee"), filename)
            XCTAssertEqual(theme.backgroundOpacity ?? -1, filename == "theme-vscode.jsonc" ? 0.8 : 0.9,
                           accuracy: 0.001, filename)
        }
    }
}
