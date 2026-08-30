import XCTest
import SkylightCore

final class WindowsTerminalParserTests: XCTestCase {
    private let settings = """
    {
      // Windows Terminal settings, brought over from a PC
      "defaultProfile": "{guid}",
      "profiles": {
        "defaults": { "opacity": 80, "useAcrylic": true,
                      "font": { "face": "Cascadia Code", "size": 12 } },
        "list": [ { "name": "PowerShell", "colorScheme": "Campbell" } ]
      },
      "schemes": [
        {
          "name": "Campbell",
          "background": "#0C0C0C", "foreground": "#CCCCCC",
          "cursorColor": "#FFFFFF", "selectionBackground": "#FFFFFF",
          "black": "#0C0C0C", "red": "#C50F1F", "green": "#13A10E",
          "yellow": "#C19C00", "blue": "#0037DA", "purple": "#881798",
          "cyan": "#3A96DD", "white": "#CCCCCC",
          "brightBlack": "#767676", "brightRed": "#E74856",
          "brightGreen": "#16C60C", "brightYellow": "#F9F1A5",
          "brightBlue": "#3B78FF", "brightPurple": "#B4009E",
          "brightCyan": "#61D6D6", "brightWhite": "#F2F2F2"
        },
        {
          "name": "Solarized Light",
          "background": "#FDF6E3", "foreground": "#657B83"
        }
      ]
    }
    """

    func testSchemesArrayYieldsOneThemePerScheme() throws {
        let themes = WindowsTerminalParser.parse(Data(settings.utf8), name: "settings")
        XCTAssertEqual(themes.map(\.name), ["Campbell", "Solarized Light"])
        XCTAssertEqual(themes.first?.source, .windowsTerminal)
        // One file, two looks — the import UI has to offer a choice.
        XCTAssertEqual(themes.count, 2)
    }

    /// Windows Terminal names its colours AND calls magenta "purple". Getting
    /// this map wrong recolours every program the user runs.
    func testColorNamesMapToIndices() throws {
        let campbell = try XCTUnwrap(
            WindowsTerminalParser.parse(Data(settings.utf8), name: "s").first)
        XCTAssertEqual(campbell.palette[0], Color8("#0C0C0C"))   // black
        XCTAssertEqual(campbell.palette[1], Color8("#C50F1F"))   // red
        XCTAssertEqual(campbell.palette[5], Color8("#881798"))   // purple → magenta
        XCTAssertEqual(campbell.palette[7], Color8("#CCCCCC"))   // white
        XCTAssertEqual(campbell.palette[8], Color8("#767676"))   // brightBlack
        XCTAssertEqual(campbell.palette[13], Color8("#B4009E"))  // brightPurple
        XCTAssertEqual(campbell.palette[15], Color8("#F2F2F2"))  // brightWhite
        XCTAssertEqual(campbell.palette.count, 16)
        XCTAssertEqual(campbell.cursor, Color8("#FFFFFF"))
        XCTAssertEqual(campbell.selectionBackground, Color8("#FFFFFF"))
    }

    /// Opacity lives on the PROFILE, not the scheme — a different object
    /// entirely. Joining them is a judgement call, so it is stated.
    func testProfileOpacityJoinsOntoEverySchemeAndSaysSo() throws {
        let campbell = try XCTUnwrap(
            WindowsTerminalParser.parse(Data(settings.utf8), name: "s").first)
        XCTAssertEqual(campbell.backgroundOpacity ?? -1, 0.8, accuracy: 0.001)
        XCTAssertTrue(campbell.skipped.contains { $0.contains("opacity") },
                      "a joined-in profile value must be named, got \(campbell.skipped)")
        XCTAssertEqual(campbell.fontFamily, "Cascadia Code")
        XCTAssertEqual(campbell.fontSize, 12)
    }

    func testFractionalOpacityIsAlsoAccepted() throws {
        // Older settings write 0.8; newer ones write 80.
        let json = """
        { "profiles": { "defaults": { "opacity": 0.5 } },
          "schemes": [ { "name": "X", "background": "#000000", "foreground": "#ffffff" } ] }
        """
        let theme = try XCTUnwrap(
            WindowsTerminalParser.parse(Data(json.utf8), name: "s").first)
        XCTAssertEqual(theme.backgroundOpacity ?? -1, 0.5, accuracy: 0.001)
    }

    /// The reachable-today vector: font.face is a JSON string, and JSON is
    /// perfectly happy to carry a newline inside one. Refused at parse time
    /// AND named, per the honest-refusal rule — a silently dropped font looks
    /// identical to a font we never read.
    func testFontFaceCarryingADirectiveIsRefusedAndNamed() throws {
        let json = """
        { "profiles": { "defaults": {
            "font": { "face": "Consolas\\nkeybind = ctrl+shift+x=text:whatever" } } },
          "schemes": [ { "name": "X", "background": "#000000", "foreground": "#ffffff" } ] }
        """
        let theme = try XCTUnwrap(
            WindowsTerminalParser.parse(Data(json.utf8), name: "s").first)
        XCTAssertNil(theme.fontFamily)
        XCTAssertTrue(theme.skipped.contains { $0.contains("font") },
                      "a refused font must be named, got \(theme.skipped)")
    }

    func testSchemeWithoutBackgroundOrForegroundIsDropped() {
        let json = """
        { "schemes": [ { "name": "Broken", "red": "#ff0000" },
                       { "name": "Fine", "background": "#000000", "foreground": "#ffffff" } ] }
        """
        let themes = WindowsTerminalParser.parse(Data(json.utf8), name: "s")
        XCTAssertEqual(themes.map(\.name), ["Fine"])
    }

    func testEmptyOrMissingSchemesIsEmpty() {
        XCTAssertTrue(WindowsTerminalParser.parse(Data(#"{"schemes": []}"#.utf8), name: "s").isEmpty)
        XCTAssertTrue(WindowsTerminalParser.parse(Data(#"{"a": 1}"#.utf8), name: "s").isEmpty)
        XCTAssertTrue(WindowsTerminalParser.parse(Data("nope".utf8), name: "s").isEmpty)
    }
}
