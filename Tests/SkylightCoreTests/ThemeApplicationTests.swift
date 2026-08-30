import XCTest
import SkylightCore

final class ThemeApplicationTests: XCTestCase {
    private var mocha: SkylightTheme {
        var t = SkylightTheme(name: "Catppuccin Mocha", source: .ghostty,
                              background: Color8("#1e1e2e")!,
                              foreground: Color8("#cdd6f4")!)
        t.palette = [0: Color8("#45475a")!, 1: Color8("#f38ba8")!,
                     15: Color8("#a6adc8")!]
        t.cursor = Color8("#f5e0dc")
        t.backgroundOpacity = 0.98
        t.fontSize = 14
        t.fontFamily = "JetBrains Mono"
        return t
    }

    private func keys(_ commands: [ThemeApplication.ConfigCommand]) -> [String] {
        commands.map(\.key)
    }

    private func value(_ commands: [ThemeApplication.ConfigCommand],
                       _ key: String) -> String? {
        commands.first { $0.key == key }?.value
    }

    func testEmitsColoursAndPaletteInStableOrder() {
        let commands = ThemeApplication.configCommands(for: mocha,
                                                       reduceTransparency: false)
        XCTAssertEqual(value(commands, "background"), "#1e1e2e")
        XCTAssertEqual(value(commands, "foreground"), "#cdd6f4")
        XCTAssertEqual(value(commands, "cursor-color"), "#f5e0dc")
        // Palette entries ride one key with an index=colour value, ascending —
        // ghostty's own spelling, and a stable order keeps the rendered config
        // diffable instead of reshuffling on every apply.
        let palette = commands.filter { $0.key == "palette" }.map(\.value)
        XCTAssertEqual(palette, ["0=#45475a", "1=#f38ba8", "15=#a6adc8"])
        // Determinism, twice over.
        XCTAssertEqual(commands,
                       ThemeApplication.configCommands(for: mocha,
                                                       reduceTransparency: false))
    }

    func testNilFieldsEmitNoKeys() {
        let bare = SkylightTheme(name: "B", source: .bundled,
                                 background: Color8("#000000")!,
                                 foreground: Color8("#ffffff")!)
        let commands = ThemeApplication.configCommands(for: bare,
                                                       reduceTransparency: false)
        // We never write a key we do not have — the engine default keeps
        // ruling instead of being frozen to whatever we would have guessed.
        for absent in ["cursor-color", "cursor-text", "selection-background",
                       "bold-color", "palette", "font-family", "font-size",
                       "background-blur", "cursor-style", "minimum-contrast"] {
            XCTAssertFalse(keys(commands).contains(absent), absent)
        }
        XCTAssertEqual(keys(commands).sorted(),
                       ["background", "background-opacity", "foreground"])
    }

    func testOpacityIsClampedToReadabilityFloor() {
        var glassy = mocha
        glassy.backgroundOpacity = 0.2
        XCTAssertEqual(
            value(ThemeApplication.configCommands(for: glassy,
                                                  reduceTransparency: false),
                  "background-opacity"), "0.5")
        var solid = mocha
        solid.backgroundOpacity = 3
        XCTAssertEqual(
            value(ThemeApplication.configCommands(for: solid,
                                                  reduceTransparency: false),
                  "background-opacity"), "1.0")
    }

    func testAThemeWithNoOpacityGetsTheAppDefault() {
        var noOpacity = mocha
        noOpacity.backgroundOpacity = nil
        XCTAssertEqual(
            value(ThemeApplication.configCommands(for: noOpacity,
                                                  reduceTransparency: false),
                  "background-opacity"), "0.92")
    }

    /// The accessibility setting outranks everything, an import included.
    func testReduceTransparencyForcesSolidRegardlessOfTheme() {
        let commands = ThemeApplication.configCommands(for: mocha,
                                                       reduceTransparency: true)
        XCTAssertEqual(value(commands, "background-opacity"), "1.0")
        XCTAssertFalse(keys(commands).contains("background-blur"))
    }

    func testAppearanceReportsDarknessOpacityAndFont() {
        let applied = ThemeApplication.appearance(for: mocha, reduceTransparency: false)
        XCTAssertTrue(applied.isDark)
        XCTAssertEqual(applied.opacity, 0.98)
        XCTAssertEqual(applied.fontFamily, "JetBrains Mono")
        XCTAssertEqual(applied.fontSize, 14)

        var light = mocha
        light.background = Color8("#F7F7F7")!
        XCTAssertFalse(ThemeApplication.appearance(for: light,
                                                   reduceTransparency: false).isDark)
    }

    func testAppearanceOpacityObeysReduceTransparency() {
        XCTAssertEqual(
            ThemeApplication.appearance(for: mocha, reduceTransparency: true).opacity, 1.0)
    }

    func testCursorAndPaddingRideAlongWhenPresent() {
        var t = mocha
        t.cursorStyle = "bar"
        t.cursorBlink = true
        t.paddingX = 24
        t.paddingY = 24
        t.minimumContrast = 1.1
        let commands = ThemeApplication.configCommands(for: t, reduceTransparency: false)
        XCTAssertEqual(value(commands, "cursor-style"), "bar")
        XCTAssertEqual(value(commands, "cursor-style-blink"), "true")
        XCTAssertEqual(value(commands, "window-padding-x"), "24")
        XCTAssertEqual(value(commands, "window-padding-y"), "24")
        XCTAssertEqual(value(commands, "minimum-contrast"), "1.1")
    }

    /// The value-side twin of the key test below.
    ///
    /// A theme's free-text fields reach a LINE-BASED config verbatim. This is
    /// reachable from a sidecar in Application Support too, which no parser
    /// ever sees — so the emit boundary is the only complete defence.
    func testAValueCarryingADirectiveIsNeverEmitted() {
        var hostile = mocha
        hostile.fontFamily = "Consolas\nkeybind = ctrl+shift+x=text:whatever"
        hostile.cursorStyle = "bar\ncommand = /bin/sh"
        let commands = ThemeApplication.configCommands(for: hostile,
                                                       reduceTransparency: false)
        XCTAssertFalse(keys(commands).contains("font-family"))
        XCTAssertFalse(keys(commands).contains("cursor-style"))
        for command in commands {
            XCTAssertFalse(command.value.contains("\n"), command.key)
            XCTAssertFalse(command.value.contains("\r"), command.key)
        }
    }

    /// Rendered exactly as the engine will see it: one directive per line,
    /// and every line's key must still pass the allowlist. A value that
    /// smuggled a second directive shows up here as an extra line.
    func testRenderedConfigCannotGainALineFromAValue() {
        var hostile = mocha
        hostile.fontFamily = "Menlo\ncommand = /bin/sh"
        hostile.cursorStyle = "bar\rcustom-shader = /tmp/x.glsl"
        let commands = ThemeApplication.configCommands(for: hostile,
                                                       reduceTransparency: false)
        let rendered = commands.map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")
        let lines = rendered.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, commands.count,
                       "a value opened a directive of its own")
        for line in lines {
            let key = line.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(ThemeKeyPolicy.decide(key), .importable, String(line))
        }
        XCTAssertFalse(rendered.contains("command ="))
        XCTAssertFalse(rendered.contains("custom-shader"))
    }

    /// Nothing this function emits may be a behaviour key — the security line
    /// held at the far end of the pipeline as well as the near one.
    func testEmittedKeysAreAllImportableLookKeys() {
        var t = mocha
        t.cursorStyle = "bar"
        t.paddingX = 10
        for command in ThemeApplication.configCommands(for: t, reduceTransparency: false) {
            XCTAssertEqual(ThemeKeyPolicy.decide(command.key), .importable,
                           "emitted \(command.key)")
        }
    }
}

final class ChromeTonesTests: XCTestCase {
    private func theme(_ background: String, _ foreground: String) -> SkylightTheme {
        SkylightTheme(name: "T", source: .ghostty,
                      background: Color8(background)!, foreground: Color8(foreground)!)
    }

    private var mocha: SkylightTheme { theme("#1e1e2e", "#cdd6f4") }
    private var alabaster: SkylightTheme { theme("#F7F7F7", "#000000") }

    func testTonesAreDeterministic() {
        XCTAssertEqual(ThemeApplication.chromeTones(for: mocha),
                       ThemeApplication.chromeTones(for: mocha))
    }

    /// The panel backing sits UNDER a translucent terminal surface. If it
    /// drifts far from the terminal's own background the glass reads as a
    /// dirty smear rather than depth.
    func testPanelBackingTracksTheTerminalBackground() {
        let tones = ThemeApplication.chromeTones(for: mocha)
        XCTAssertEqual(tones.panelBacking, mocha.background)
    }

    /// Chrome must stay legible against the surface it decorates, in BOTH
    /// directions: a near-black theme needs lighter chrome, a near-white one
    /// needs darker. A fixed offset works for one and vanishes for the other.
    func testChromeContrastFloorIsRespectedOnLightAndDarkThemes() {
        for theme in [mocha, alabaster, self.theme("#000000", "#ffffff"),
                      self.theme("#ffffff", "#000000")] {
            let tones = ThemeApplication.chromeTones(for: theme)
            let gap = abs(tones.hairline.luminance - theme.background.luminance)
            XCTAssertGreaterThan(gap, 12,
                                 "hairline vanished on \(theme.background.hex)")
            let headerGap = abs(tones.header.luminance - theme.background.luminance)
            XCTAssertGreaterThan(headerGap, 4,
                                 "header vanished on \(theme.background.hex)")
        }
    }

    func testDarkThemesGetLighterChromeAndLightThemesDarker() {
        let dark = ThemeApplication.chromeTones(for: mocha)
        XCTAssertGreaterThan(dark.hairline.luminance, mocha.background.luminance)
        let light = ThemeApplication.chromeTones(for: alabaster)
        XCTAssertLessThan(light.hairline.luminance, alabaster.background.luminance)
    }

    /// The dot grid is background texture: present, never competing with the
    /// text sitting on top of it.
    func testDotGridSitsBetweenBackgroundAndForeground() {
        let tones = ThemeApplication.chromeTones(for: mocha)
        let low = min(mocha.background.luminance, mocha.foreground.luminance)
        let high = max(mocha.background.luminance, mocha.foreground.luminance)
        XCTAssertGreaterThan(tones.dotGrid.luminance, low)
        XCTAssertLessThan(tones.dotGrid.luminance, high)
    }

    func testEveryToneStaysInRangeOnExtremes() {
        // Clamping, not wrapping: pure black must not roll over to white.
        // (Asserting Color8(tone.hex) != nil proved nothing — hex always
        // round-trips, so that assertion could not fail for any input.)
        for background in ["#000000", "#ffffff", "#010101", "#fefefe"] {
            let base = Color8(background)!
            let tones = ThemeApplication.chromeTones(for: theme(background, "#808080"))
            for (label, tone) in [("backdrop", tones.canvasBackdrop),
                                  ("header", tones.header),
                                  ("hairline", tones.hairline),
                                  ("dotGrid", tones.dotGrid)] {
                XCTAssertTrue((0...255).contains(tone.luminance),
                              "\(label) out of range on \(background)")
                // A step away from black must be LIGHTER and a step away from
                // white DARKER — wrapping would show up as the opposite.
                if base.luminance < 128 {
                    XCTAssertGreaterThanOrEqual(tone.luminance, base.luminance - 0.5,
                                                "\(label) wrapped on \(background)")
                } else {
                    XCTAssertLessThanOrEqual(tone.luminance, base.luminance + 0.5,
                                             "\(label) wrapped on \(background)")
                }
            }
        }
    }
}
