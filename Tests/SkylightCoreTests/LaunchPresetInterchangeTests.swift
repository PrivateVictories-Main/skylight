import Foundation
import XCTest
@testable import SkylightCore

final class LaunchPresetInterchangeTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    func testPortableWorkspaceImportsItsPresetsWithoutChangingLaunchArguments() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/workspace-v2.json"))
        let presets = try LaunchPresetInterchange.decode(data)
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].spec.harness, "codex")
        XCTAssertEqual(presets[0].spec.arguments, ["--model", "example-model"])
        XCTAssertNotNil(WorkspacePersistence.decode(data))
    }
    func testNativePresetArrayRoundTrips() throws {
        let original = [LaunchPreset(name: "Shell", spec: TerminalSpec(shellPath: "/bin/zsh", arguments: ["-l"]))]
        XCTAssertEqual(try LaunchPresetInterchange.decode(LaunchPresetInterchange.encode(original)), original)
    }
    func testPlatformPresetsRoundTripAndReplaceDefaultsCompletely() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/platform-presets.json"))
        let original = try LaunchPresetInterchange.decode(data)
        let preset = try XCTUnwrap(original.first)
        let mac = preset.resolvedSpec(for: .macos)
        XCTAssertNil(mac.harness)
        XCTAssertEqual(mac.arguments, [])
        XCTAssertEqual(mac.shellPath, "/bin/sh")
        XCTAssertEqual(preset.resolvedSpec(for: .windows).arguments, ["/Q", "/D"])
        XCTAssertEqual(preset.resolvedSpec(for: .linux).workingDirectory, "/tmp/linux project")
        XCTAssertEqual(try LaunchPresetInterchange.decode(LaunchPresetInterchange.encode(original)), original)
        let search = WorkspaceSearch.presetItem(preset)
        XCTAssertTrue(search.detail.contains("/tmp/mac project"))
        XCTAssertFalse(search.detail.contains("codex"))
        XCTAssertFalse(search.detail.contains("--default-only"))
    }

    func testMissingPlatformUsesDefaultsAndOtherPlatformEditsStayIndependent() throws {
        var preset = LaunchPreset(name: "Portable", spec: TerminalSpec(harness: "codex", arguments: ["--model", "a"]))
        XCTAssertEqual(preset.resolvedSpec(for: .windows), preset.spec)
        preset.platformSpecs = ["windows": TerminalSpec(shellPath: "cmd.exe", arguments: [])]
        XCTAssertEqual(preset.resolvedSpec(for: .macos), preset.spec)
        XCTAssertNil(preset.resolvedSpec(for: .windows).harness)
        let original = preset
        var local = preset.resolvedSpec(for: .windows)
        local.arguments.append("/Q")
        XCTAssertEqual(preset, original)
        XCTAssertEqual(try LaunchPresetInterchange.decode(LaunchPresetInterchange.encode([preset])), [preset])
    }

    func testExportRejectsFilesItCannotImport() {
        let oversized = LaunchPreset(name: "Large", spec: TerminalSpec(arguments: [String(repeating: "x", count: 4 * 1024 * 1024)]))
        XCTAssertThrowsError(try LaunchPresetInterchange.encode([oversized]))
    }

    func testUnsupportedOrCorruptDocumentIsRejected() {
        for text in ["broken", "{\"version\":3,\"launchPresets\":[]}", "{}"] {
            XCTAssertThrowsError(try LaunchPresetInterchange.decode(Data(text.utf8)))
        }
    }
    func testPortableCatalogMatchesNativeLaunchIdentifiers() throws {
        struct Provider: Decodable { let id: String; let name: String }
        let data = try Data(contentsOf: root.appendingPathComponent("shared/cli-catalog.json"))
        let portable = try JSONDecoder().decode([Provider].self, from: data)
        XCTAssertEqual(portable.map(\.id), Catalog.harnesses.map(\.id))
        XCTAssertEqual(portable.map(\.name), Catalog.harnesses.map(\.displayName))
    }
}
