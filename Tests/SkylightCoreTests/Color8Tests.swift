import XCTest
import SkylightCore

final class Color8Tests: XCTestCase {
    func testParsesEveryLiteralForm() {
        let expected = Color8(r: 0x1e, g: 0x1e, b: 0x2e)
        for literal in ["#1e1e2e", "1e1e2e", "0x1e1e2e", "#1E1E2E",
                        "rgb(30,30,46)", "rgb(30, 30, 46)", " #1e1e2e "] {
            XCTAssertEqual(Color8(literal), expected, literal)
        }
    }

    func testShortHexExpands() {
        // #f0a → ff00aa: each nibble doubles, the CSS rule.
        XCTAssertEqual(Color8("#f0a"), Color8(r: 0xff, g: 0x00, b: 0xaa))
        XCTAssertEqual(Color8("#000"), Color8(r: 0, g: 0, b: 0))
        XCTAssertEqual(Color8("#fff"), Color8(r: 255, g: 255, b: 255))
    }

    func testRejectsGarbage() {
        for literal in ["", "#", "#GG0011", "#12345", "nonsense", "rgb(1,2)",
                        "rgb(300,0,0)", "#1e1e2e2e2e", "0x", "rgba(1,2,3)"] {
            XCTAssertNil(Color8(literal), literal)
        }
    }

    /// Character.isHexDigit says YES to fullwidth and other non-ASCII digit
    /// forms; UInt8(_:radix:) says nil. The gate and the conversion disagreed,
    /// and a force-unwrap sat in the gap — so one poisoned file crashed the
    /// app, and ThemeDiscovery auto-parses on opening the Theme tab, which
    /// made ⌘, the trigger.
    func testFullwidthAndNonASCIIHexDigitsAreRefusedNotCrashed() {
        for hostile in ["#ＦＦ００ＡＡ", "#ＦＦＡ", "ＦＦ００ＡＡ", "0xＦＦ００ＡＡ",
                       "#１２３４５６", "#٠١٢٣٤٥"] {
            XCTAssertNil(Color8(hostile), hostile)
        }
    }

    func testAlphaIsPreservedNotDropped() {
        // Alpha carries a terminal's transparency. Dropping it silently is how
        // an imported theme loses the look it was imported for — it is folded
        // out into backgroundOpacity at apply time instead.
        let c = Color8("#1e1e2eCC")
        XCTAssertEqual(c?.rgb, Color8(r: 0x1e, g: 0x1e, b: 0x2e))
        XCTAssertEqual(c?.a, 0xCC)
        XCTAssertEqual(c?.opacity ?? -1, Double(0xCC) / 255, accuracy: 0.0001)
        XCTAssertNil(Color8("#1e1e2e")?.a)
        XCTAssertEqual(Color8("rgba(30,30,46,0.5)")?.a, 128)
    }

    func testHexRendersWithoutAlphaForGhostty() {
        // Ghostty's `background`/`palette` keys take #RRGGBB. The alpha rides
        // in background-opacity, never in the colour literal.
        XCTAssertEqual(Color8("#1e1e2eCC")?.hex, "#1e1e2e")
        XCTAssertEqual(Color8(r: 255, g: 0, b: 170).hex, "#ff00aa")
    }

    func testNamedColorsFromRealConfigs() {
        XCTAssertEqual(Color8("black"), Color8(r: 0, g: 0, b: 0))
        XCTAssertEqual(Color8("white"), Color8(r: 255, g: 255, b: 255))
        XCTAssertEqual(Color8("red"), Color8(r: 255, g: 0, b: 0))
        XCTAssertEqual(Color8("NONE"), nil)          // kitty's "no colour"
        XCTAssertEqual(Color8("Blue"), Color8(r: 0, g: 0, b: 255))   // case-insensitive
    }

    func testFloatComponentsClampAndRound() {
        // iTerm2 stores 0–1 floats. 0.5 → 128 (round-half-up), and values
        // outside the range are clamped rather than wrapping to nonsense.
        XCTAssertEqual(Color8(floatComponents: (1, 0, 0.5)), Color8(r: 255, g: 0, b: 128))
        XCTAssertEqual(Color8(floatComponents: (-1, 2, 0)), Color8(r: 0, g: 255, b: 0))
        XCTAssertEqual(Color8(floatComponents: (.nan, 0, 0)), Color8(r: 0, g: 0, b: 0))
    }

    func testLuminanceSeparatesLightFromDarkBackgrounds() {
        XCTAssertLessThan(Color8("#1e1e2e")!.luminance, 128)      // Catppuccin Mocha
        XCTAssertGreaterThan(Color8("#F7F7F7")!.luminance, 128)   // Alabaster
    }

    /// Every parser in the theme module funnels through this type, so the
    /// round trip has to hold for the whole space, not a handful of samples.
    func testHexRoundTripForEveryChannelLevel() {
        for level in stride(from: 0, through: 255, by: 1) {
            let c = Color8(r: UInt8(level), g: UInt8(255 - level), b: UInt8(level / 2))
            XCTAssertEqual(Color8(c.hex), c, "level \(level)")
        }
    }

    func testCodableRoundTrip() throws {
        let c = Color8(r: 1, g: 2, b: 3, a: 4)
        let back = try JSONDecoder().decode(Color8.self,
                                            from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}
