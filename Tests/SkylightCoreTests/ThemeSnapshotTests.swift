import XCTest
import SkylightCore

/// Ryan's ratified precedence: an import WINS — it overrides every appearance
/// value already set by hand — and the safety net is a snapshot, not a
/// negotiation. One click puts everything back.
final class ThemeSnapshotTests: XCTestCase {
    private var before: ThemeSnapshot {
        ThemeSnapshot(appearance: "dark", windowBackground: "glass",
                      terminalOpacity: 0.92, terminalFontSize: 14,
                      fontFamily: "Menlo", lightTheme: nil, darkTheme: "Afterglow")
    }

    func testSnapshotCapturesEveryAppearanceKey() throws {
        // Every field the import lane is allowed to overwrite must be in here,
        // or "revert" would restore some of what the user had and quietly keep
        // the rest — worse than no revert at all.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(before)) as? [String: Any])
        XCTAssertEqual(Set(object.keys),
                       ["appearance", "windowBackground", "terminalOpacity",
                        "terminalFontSize", "fontFamily", "lightTheme", "darkTheme"])
    }

    func testCodableRoundTripPreservesNils() throws {
        let back = try JSONDecoder().decode(ThemeSnapshot.self,
                                            from: JSONEncoder().encode(before))
        XCTAssertEqual(back, before)
        XCTAssertNil(back.lightTheme)
    }

    func testRevertRestoresExactlyTheCapturedValues() {
        var store = ThemeSnapshotStore()
        store.capture(before)
        // The import changes everything.
        let after = ThemeSnapshot(appearance: "light", windowBackground: "flat",
                                  terminalOpacity: 0.5, terminalFontSize: 18,
                                  fontFamily: "JetBrains Mono",
                                  lightTheme: "Alabaster", darkTheme: "Catppuccin Mocha")
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(store.revert(), before)
    }

    func testSecondImportReplacesTheSnapshot() {
        var store = ThemeSnapshotStore()
        store.capture(before)
        let middle = ThemeSnapshot(appearance: "light", windowBackground: "flat",
                                   terminalOpacity: 0.7, terminalFontSize: 0,
                                   fontFamily: nil, lightTheme: "Alabaster",
                                   darkTheme: nil)
        store.capture(middle)
        // One slot. Revert undoes the LAST import, not a whole history —
        // an undo stack is a different feature and this is not it.
        XCTAssertEqual(store.revert(), middle)
    }

    /// A hand edit after an import is the newest deliberate act and stands on
    /// its own. It must not throw away the ability to undo the import.
    func testHandEditAfterImportDoesNotClearSnapshot() {
        var store = ThemeSnapshotStore()
        store.capture(before)
        store.noteHandEdit()
        XCTAssertTrue(store.canRevert)
        XCTAssertEqual(store.revert(), before)
    }

    func testRevertWithNoSnapshotIsANoOp() {
        var store = ThemeSnapshotStore()
        XCTAssertFalse(store.canRevert)
        XCTAssertNil(store.revert())
    }

    /// Reverting consumes the snapshot: offering "revert" again after
    /// everything is already back would restore the values the revert itself
    /// just replaced.
    func testRevertConsumesTheSnapshot() {
        var store = ThemeSnapshotStore()
        store.capture(before)
        _ = store.revert()
        XCTAssertFalse(store.canRevert)
        XCTAssertNil(store.revert())
    }
}
