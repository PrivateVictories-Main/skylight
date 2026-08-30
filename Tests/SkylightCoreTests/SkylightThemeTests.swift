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

    func testNilOverlayFieldsNeverErasePresentOnes() {
        var base = theme("#000000")
        base.backgroundOpacity = 0.9
        base.fontFamily = "Menlo"
        let merged = base.merging(theme("#000000"))
        XCTAssertEqual(merged.backgroundOpacity, 0.9)
        XCTAssertEqual(merged.fontFamily, "Menlo")
    }
}
