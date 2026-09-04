import Foundation

/// Shared with the portable app: either the native presets.json array, or a
/// version-2 workspace carrying launchPresets. Importing never executes a spec.
public enum LaunchPresetInterchange {
    public enum ImportError: LocalizedError {
        case unsupported, tooLarge

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                "Choose a Skylight preset file or a version-2 workspace containing launch presets."
            case .tooLarge:
                "This preset file is larger than the supported 4 MiB."
            }
        }
    }

    public static func decode(_ data: Data) throws -> [LaunchPreset] {
        guard data.count <= 4 * 1024 * 1024 else { throw ImportError.tooLarge }
        let decoder = JSONDecoder()
        if let presets = try? decoder.decode([LaunchPreset].self, from: data) { return presets }
        struct Document: Decodable { let version: Int; let launchPresets: [LaunchPreset] }
        guard let document = try? decoder.decode(Document.self, from: data), document.version == 2 else {
            throw ImportError.unsupported
        }
        return document.launchPresets
    }

    public static func encode(_ presets: [LaunchPreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(presets)
    }
}
