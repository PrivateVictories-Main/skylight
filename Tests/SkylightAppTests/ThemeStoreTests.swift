import Foundation
import XCTest
import SkylightCore
@testable import Skylight

final class ThemeStoreTests: XCTestCase {
    @MainActor
    private func withFixture(_ body: (ThemeStore, UserDefaults, URL) throws -> Void) throws {
        let suite = "Skylight.ThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(ThemeStore(defaults: defaults, supportDirectory: directory), defaults, directory)
    }

    private func theme(_ name: String, background: String = "#123456") -> SkylightTheme {
        SkylightTheme(name: name, source: .ghostty, background: Color8(background)!, foreground: Color8("#eeeeee")!)
    }

    @MainActor
    func testImportRevertRestoresUnsetOpacityAndFontAfterRelaunch() async throws {
        try withFixture { store, defaults, directory in
            var imported = theme("Translucent")
            imported.backgroundOpacity = 0.6
            imported.fontSize = 18
            try store.apply(imported)
            XCTAssertEqual(defaults.double(forKey: Appearance.terminalOpacityKey), 0.6)
            XCTAssertEqual(defaults.integer(forKey: Appearance.fontSizeKey), 18)

            let relaunched = ThemeStore(defaults: defaults, supportDirectory: directory)
            XCTAssertEqual(relaunched.dark, imported)
            XCTAssertTrue(try relaunched.revert())
            XCTAssertNil(defaults.object(forKey: Appearance.terminalOpacityKey))
            XCTAssertNil(defaults.object(forKey: Appearance.fontSizeKey))
            XCTAssertNil(defaults.object(forKey: Appearance.appearanceKey))
            XCTAssertTrue(relaunched.isDefault)
            XCTAssertFalse(ThemeStore(defaults: defaults, supportDirectory: directory).canRevert)
        }
    }

    @MainActor
    func testPunctuationAndReservedNamesDoNotOverwriteOtherThemesOrSnapshot() async throws {
        try withFixture { store, defaults, directory in
            let names = ["Solarized Dark", "Solarized-Dark", "pre import snapshot", "../", "."]
            for name in names { try store.apply(theme(name)) }
            let relaunched = ThemeStore(defaults: defaults, supportDirectory: directory)
            XCTAssertEqual(Set(relaunched.importedThemes.map(\.name)), Set(names))
            XCTAssertTrue(relaunched.canRevert)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                           ["__skylight-theme-library-v1.json"])
        }
    }

    @MainActor
    func testEmptyNameCannotApplyAnUnresolvableTheme() async throws {
        try withFixture { store, defaults, directory in
            XCTAssertThrowsError(try store.apply(theme(" \n")))
            XCTAssertTrue(store.isDefault)
            XCTAssertFalse(store.canRevert)
            XCTAssertNil(defaults.string(forKey: ThemeStore.darkKey))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @MainActor
    func testSameNameImportRevertRestoresActualPreviousPalette() async throws {
        try withFixture { store, defaults, directory in
            let first = theme("Personal")
            let replacement = theme("Personal", background: "#292222")
            try store.apply(first)
            try store.apply(replacement)
            XCTAssertEqual(store.dark, replacement)
            let relaunched = ThemeStore(defaults: defaults, supportDirectory: directory)
            XCTAssertTrue(try relaunched.revert())
            XCTAssertEqual(relaunched.dark, first)
            XCTAssertEqual(ThemeStore(defaults: defaults, supportDirectory: directory).dark, first)
        }
    }

    @MainActor
    func testFailedImportKeepsAppearanceLibraryAndPreviousUndoPoint() async throws {
        try withFixture { store, defaults, directory in
            let first = theme("First")
            try store.apply(first)
            let before = defaults.dictionaryRepresentation()
            let url = directory.appendingPathComponent("__skylight-theme-library-v1.json")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

            XCTAssertThrowsError(try store.apply(theme("Second")))
            XCTAssertEqual(store.dark, first)
            XCTAssertEqual(store.importedThemes, [first])
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
            XCTAssertTrue(store.canRevert)
            try FileManager.default.removeItem(at: url)
            XCTAssertTrue(try store.revert())
            XCTAssertTrue(store.isDefault)
        }
    }

    @MainActor
    func testFailedRevertKeepsUndoAvailableForRetry() async throws {
        try withFixture { store, _, directory in
            let imported = theme("Keep until saved")
            try store.apply(imported)
            let url = directory.appendingPathComponent("__skylight-theme-library-v1.json")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.revert())
            XCTAssertEqual(store.dark, imported)
            XCTAssertTrue(store.canRevert)
            try FileManager.default.removeItem(at: url)
            XCTAssertTrue(try store.revert())
            XCTAssertFalse(store.canRevert)
        }
    }

    @MainActor
    func testLegacySidecarsMigrateWithoutChangingOriginalFiles() async throws {
        try withFixture { _, defaults, directory in
            let original = theme("Solarized Dark")
            let legacyURL = directory.appendingPathComponent("solarized-dark.json")
            let bytes = try JSONEncoder().encode(original)
            try bytes.write(to: legacyURL)
            let snapshot = ThemeSnapshot(appearance: "light", windowBackground: "flat",
                terminalOpacity: 0.8, terminalFontSize: nil, fontFamily: nil,
                lightTheme: nil, darkTheme: nil)
            let snapshotBytes = try JSONEncoder().encode(snapshot)
            let snapshotURL = directory.appendingPathComponent("pre-import-snapshot.json")
            try snapshotBytes.write(to: snapshotURL)
            defaults.set(original.name, forKey: ThemeStore.darkKey)

            let migrated = ThemeStore(defaults: defaults, supportDirectory: directory)
            XCTAssertEqual(migrated.dark, original)
            XCTAssertTrue(migrated.canRevert)
            try migrated.apply(theme("Solarized-Dark", background: "#221122"))
            XCTAssertEqual(migrated.importedThemes.count, 2)
            XCTAssertTrue(try migrated.revert())
            XCTAssertEqual(migrated.dark, original)
            XCTAssertEqual(try Data(contentsOf: legacyURL), bytes)
            XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshotBytes)
            let relaunched = ThemeStore(defaults: defaults, supportDirectory: directory)
            XCTAssertEqual(relaunched.importedThemes.count, 2)
            XCTAssertFalse(relaunched.canRevert, "Legacy snapshot must not return after it is consumed")
        }
    }

    @MainActor
    func testUnreadableLibraryCannotBeReplacedByAnotherImport() async throws {
        try withFixture { _, defaults, directory in
            let url = directory.appendingPathComponent("__skylight-theme-library-v1.json")
            let bytes = Data("truncated saved library".utf8)
            try bytes.write(to: url)
            let store = ThemeStore(defaults: defaults, supportDirectory: directory)
            XCTAssertThrowsError(try store.apply(theme("New")))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertNil(defaults.string(forKey: ThemeStore.darkKey))
        }
    }
}
