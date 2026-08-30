import XCTest
import SkylightCore

final class SkylightThemeTests: XCTestCase {
    private func theme(_ background: String, name: String = "T") -> SkylightTheme {
        SkylightTheme(name: name, source: .ghostty,
                      background: Color8(background)!,
                      foreground: Color8("#ffffff")!)
    }

    func testCodableRoundTrip() throws {
        var t = theme("#1e1e2e", name: "Catppuccin Mocha")
        t.palette = [0: Color8("#45475a")!, 15: Color8("#a6adc8")!]
        t.backgroundOpacity = 0.98
        t.fontFamily = "JetBrains Mono"
        t.fontSize = 14
        t.skipped = ["command", "keybind"]
        let back = try JSONDecoder().decode(SkylightTheme.self,
                                            from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }

    func testDarkLuminanceThreshold() {
        XCTAssertTrue(theme("#1e1e2e").isDarkDerived)     // Catppuccin Mocha
        XCTAssertTrue(theme("#000000").isDarkDerived)
        XCTAssertFalse(theme("#F7F7F7").isDarkDerived)    // Alabaster
        XCTAssertFalse(theme("#ffffff").isDarkDerived)
    }

    func testMergingLetsLaterKeysWin() {
        var base = theme("#000000")
        base.fontSize = 12
        base.cursor = Color8("#111111")
        var overlay = theme("#1e1e2e")
        overlay.fontSize = 14
        let merged = base.merging(overlay)
        XCTAssertEqual(merged.background, Color8("#1e1e2e"))   // later wins
        XCTAssertEqual(merged.fontSize, 14)
        // A key the overlay never mentions survives from the base — this is
        // ghostty's own composition rule, and it is what lets a `theme = NAME`
        // line be overridden by the explicit colours below it.
        XCTAssertEqual(merged.cursor, Color8("#111111"))
    }

    func testMergingPaletteIsPerIndexNotWholesale() {
        var base = theme("#000000")
        base.palette = [0: Color8("#aaaaaa")!, 1: Color8("#bbbbbb")!]
        var overlay = theme("#000000")
        overlay.palette = [1: Color8("#cccccc")!]
        let merged = base.merging(overlay)
        XCTAssertEqual(merged.palette[0], Color8("#aaaaaa"))   // untouched
        XCTAssertEqual(merged.palette[1], Color8("#cccccc"))   // overridden
    }

    func testSkippedKeysAccumulateOnMerge() {
        var base = theme("#000000")
        base.skipped = ["command"]
        var overlay = theme("#000000")
        overlay.skipped = ["keybind", "command"]
        // Deduped and ordered: the import sheet lists these to a human.
        XCTAssertEqual(base.merging(overlay).skipped, ["command", "keybind"])
    }

    /// The shape ghostty's own 485-theme catalogue stores: bare hex strings,
    /// no leading hash, palette values likewise. The bridge in the app target
    /// is a thin adapter over THIS, so the mapping is tested here where no
    /// engine import is needed.
    func testDefinitionShapedInitMapsEveryField() throws {
        let theme = try XCTUnwrap(SkylightTheme(
            catalogName: "Aardvark Blue",
            background: "102040", foreground: "dddddd",
            cursorColor: "007acc", cursorText: "bfdbfe",
            selectionBackground: "bfdbfe", selectionForeground: "000000",
            palette: [0: "191919", 1: "aa342e", 15: "f7f7f7"]))
        XCTAssertEqual(theme.name, "Aardvark Blue")
        XCTAssertEqual(theme.source, .bundled)
        XCTAssertEqual(theme.background, Color8("#102040"))
        XCTAssertEqual(theme.foreground, Color8("#dddddd"))
        XCTAssertEqual(theme.cursor, Color8("#007acc"))
        XCTAssertEqual(theme.cursorText, Color8("#bfdbfe"))
        XCTAssertEqual(theme.selectionBackground, Color8("#bfdbfe"))
        XCTAssertEqual(theme.selectionForeground, Color8("#000000"))
        XCTAssertEqual(theme.palette[0], Color8("#191919"))
        XCTAssertEqual(theme.palette[15], Color8("#f7f7f7"))
        XCTAssertTrue(theme.isDarkDerived)
    }

    func testDefinitionShapedInitAcceptsHashPrefixedPaletteToo() throws {
        // The catalogue writes bare hex; a hand-built definition may not.
        let theme = try XCTUnwrap(SkylightTheme(
            catalogName: "X", background: "#000000", foreground: "#ffffff",
            palette: [0: "#112233"]))
        XCTAssertEqual(theme.palette[0], Color8("#112233"))
    }

    func testDefinitionShapedInitRefusesAnUnreadableAnchorColour() {
        XCTAssertNil(SkylightTheme(catalogName: "X", background: "zzz",
                                   foreground: "#ffffff"))
        XCTAssertNil(SkylightTheme(catalogName: "X", background: "#000000",
                                   foreground: ""))
    }

    /// C3, the shape of Ryan's OWN config: `theme = Catppuccin Mocha` plus
    /// font/opacity/padding lines and NO background or foreground.
    ///
    /// The overlay's anchors are placeholders — the file never stated them —
    /// so merging must keep the catalogue's. Before this, the seeded
    /// #000000/#ffffff were assigned unconditionally and the applied theme was
    /// Mocha's palette on pure black, named "config".
    func testMergingKeepsCatalogueAnchorsWhenTheOverlayIsSilent() {
        var catalogue = theme("#1e1e2e", name: "Catppuccin Mocha")
        catalogue.foreground = Color8("#cdd6f4")!
        catalogue.palette = [0: Color8("#45475a")!]

        var config = theme("#000000", name: "config")   // placeholder anchors
        config.foreground = Color8("#ffffff")!
        config.stated = SkylightTheme.StatedFields(name: false, background: false,
                                                   foreground: false)
        config.fontSize = 14
        config.backgroundOpacity = 0.98

        let merged = catalogue.merging(config)
        XCTAssertEqual(merged.background, Color8("#1e1e2e"))
        XCTAssertEqual(merged.foreground, Color8("#cdd6f4"))
        XCTAssertEqual(merged.palette[0], Color8("#45475a"))
        XCTAssertEqual(merged.name, "Catppuccin Mocha")
        // The config's own explicit look keys still win — ghostty's rule.
        XCTAssertEqual(merged.fontSize, 14)
        XCTAssertEqual(merged.backgroundOpacity, 0.98)
    }

    func testMergingTakesOverlayAnchorsWhenTheOverlayDidStateThem() {
        let catalogue = theme("#1e1e2e", name: "Catppuccin Mocha")
        var config = theme("#ff0000", name: "config")
        config.stated = SkylightTheme.StatedFields(name: false, background: true,
                                                   foreground: false)
        let merged = catalogue.merging(config)
        XCTAssertEqual(merged.background, Color8("#ff0000"))   // stated: wins
        XCTAssertEqual(merged.foreground, catalogue.foreground) // unstated: kept
        XCTAssertEqual(merged.name, "Catppuccin Mocha")
    }

    func testMergedThemeRemembersWhatEitherSideStated() {
        var catalogue = theme("#1e1e2e", name: "Mocha")
        catalogue.stated = SkylightTheme.StatedFields(name: true, background: true,
                                                      foreground: true)
        var config = theme("#000000", name: "config")
        config.stated = SkylightTheme.StatedFields(name: false, background: false,
                                                   foreground: false)
        XCTAssertEqual(catalogue.merging(config).stated,
                       SkylightTheme.StatedFields(name: true, background: true,
                                                  foreground: true))
    }

    func testEverythingStatesItsFieldsByDefault() {
        // Only a parser that KNOWS the file was silent may say otherwise.
        XCTAssertEqual(theme("#000000").stated,
                       SkylightTheme.StatedFields(name: true, background: true,
                                                  foreground: true))
    }

    func testNilOverlayFieldsNeverErasePresentOnes() {
        var base = theme("#000000")
        base.backgroundOpacity = 0.9
        base.fontFamily = "Menlo"
        let merged = base.merging(theme("#000000"))
        XCTAssertEqual(merged.backgroundOpacity, 0.9)
        XCTAssertEqual(merged.fontFamily, "Menlo")
    }
}
