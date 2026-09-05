import Foundation
import XCTest
import SkylightCore
@testable import Skylight

final class ThemeDiscoveryTests: XCTestCase {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Skylight.ThemeDiscoveryTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testGhosttyDiscoveryReadsModernMacConfigAndXDGOverridesInOrder() throws {
        try withHome { home in
            let sources = ThemeDiscovery.sources(home: home.path,
                environment: ["XDG_CONFIG_HOME": home.appendingPathComponent("custom config").path])
            let source = try XCTUnwrap(sources.first { $0.id == "ghostty" })
            try write("background = #123456\nforeground = #abcdef\npalette = 1=#112233", to: source.paths[0])
            try write("background = #223344", to: source.paths[1])
            try write("foreground = #ffeecc\nbackground-opacity = 0.8", to: source.paths[2])
            let imported = try XCTUnwrap(try ThemeDiscovery.load(source).get().first)
            XCTAssertEqual(imported.background, Color8("#223344"))
            XCTAssertEqual(imported.foreground, Color8("#ffeecc"))
            XCTAssertEqual(imported.palette[1], Color8("#112233"))
            XCTAssertEqual(imported.backgroundOpacity, 0.8)
            XCTAssertEqual(ThemeDiscovery.usable(sources).map(\.id), ["ghostty"])
        }
    }

    func testGhosttyMacOnlyConfigIsDiscoveredWithEmptyXDGVariable() throws {
        try withHome { home in
            let sources = ThemeDiscovery.sources(home: home.path, environment: ["XDG_CONFIG_HOME": ""])
            let source = try XCTUnwrap(sources.first { $0.id == "ghostty" })
            XCTAssertTrue(source.paths[0].hasPrefix(home.appendingPathComponent(".config").path))
            try write("background = #212121\nforeground = #dddddd", to: source.paths[2])
            XCTAssertEqual(ThemeDiscovery.usable(sources).map(\.id), ["ghostty"])
            XCTAssertEqual(try ThemeDiscovery.load(source).get().first?.background, Color8("#212121"))
        }
    }

    func testFolderImportIncludesModernAndExtensionlessGhosttyConfigs() throws {
        try withHome { home in
            try write("background = #111111\nforeground = #dddddd", to: home.appendingPathComponent("one/config.ghostty").path)
            try write("background = #222222\nforeground = #ffffff", to: home.appendingPathComponent("two/config").path)
            let imported = try ThemeDiscovery.load(home.path).get()
            XCTAssertEqual(imported.count, 2)
            XCTAssertEqual(Set(imported.map(\.background)), [Color8("#111111")!, Color8("#222222")!])
        }
    }

    func testUnresolvedGhosttyThemeReferenceCannotInventAReplacementPalette() throws {
        try withHome { home in
            let path = home.appendingPathComponent("config.ghostty").path
            try write("theme = Skylight nonexistent custom test theme", to: path)
            guard case .failure(.malformed) = ThemeDiscovery.load(path) else {
                return XCTFail("An unresolved theme must not apply invented black and white colors")
            }
            try write("theme = Skylight nonexistent custom test theme\nbackground = #111111\nforeground = #eeeeee", to: path)
            let explicit = try XCTUnwrap(try ThemeDiscovery.load(path).get().first)
            XCTAssertEqual(explicit.background, Color8("#111111"))
            XCTAssertTrue(explicit.skipped.contains { $0.contains("not found") })
        }
    }
}
