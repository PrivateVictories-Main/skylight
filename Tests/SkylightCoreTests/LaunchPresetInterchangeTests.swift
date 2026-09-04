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
