import CoreGraphics
import Foundation

/// Vendor mark identity for the few harnesses with official vector logos.
public enum Brand: String, Codable, Sendable {
    case claude, openai, gemini
}

/// Everything that defines what a terminal runs. `shellPath` nil = login
/// shell; `harness` set = an agent CLI is the surface command.
public struct TerminalSpec: Codable, Equatable, Hashable, Sendable {
    public var shellPath: String?
    public var harness: String?
    public var arguments: [String]
    public var workingDirectory: String?

    public init(shellPath: String? = nil, harness: String? = nil,
                arguments: [String] = [], workingDirectory: String? = nil) {
        self.shellPath = shellPath
        self.harness = harness
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// Stable key identifying a launch combination for usage counting.
    public var comboKey: String {
        "\(shellPath ?? "login")|\(harness ?? "shell")|\(arguments.joined(separator: " "))"
    }
}

public struct TerminalInstance: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var spec: TerminalSpec

    public init(id: UUID = UUID(), name: String, spec: TerminalSpec = TerminalSpec()) {
        self.id = id
        self.name = name
        self.spec = spec
    }
}

public struct CanvasTile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var itemID: UUID
    public var origin: CGPoint
    public var size: CGSize

    public init(id: UUID = UUID(), itemID: UUID, origin: CGPoint, size: CGSize) {
        self.id = id
        self.itemID = itemID
        self.origin = origin
        self.size = size
    }

    public var frame: CGRect { CGRect(origin: origin, size: size) }
}

public struct CanvasBoard: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var tiles: [CanvasTile]
    /// Persisted pan offset so a canvas reopens exactly where you left it.
    public var pan: CGPoint

    public init(id: UUID = UUID(), name: String, tiles: [CanvasTile] = [], pan: CGPoint = .zero) {
        self.id = id
        self.name = name
        self.tiles = tiles
        self.pan = pan
    }

    enum CodingKeys: String, CodingKey { case id, name, tiles, pan }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tiles = try container.decode([CanvasTile].self, forKey: .tiles)
        // Boards saved before pan existed decode with the origin view.
        // NOTE: any new persisted property must be decoded HERE as well —
        // the synthesized encoder writes it, but this initializer silently
        // drops what it doesn't read.
        pan = try container.decodeIfPresent(CGPoint.self, forKey: .pan) ?? .zero
    }
}

public struct LaunchPreset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var spec: TerminalSpec

    public init(id: UUID = UUID(), name: String, spec: TerminalSpec) {
        self.id = id
        self.name = name
        self.spec = spec
    }
}

/// Where an instance lives — always derived from board membership, never
/// stored, so the sidebar can't drift out of sync with the canvases.
public enum Residency {
    public static func board(of instanceID: UUID, in boards: [CanvasBoard]) -> UUID? {
        boards.first { $0.tiles.contains { $0.itemID == instanceID } }?.id
    }

    public static func free(_ instances: [TerminalInstance],
                            boards: [CanvasBoard]) -> [TerminalInstance] {
        instances.filter { board(of: $0.id, in: boards) == nil }
    }

    public static func residents(of board: CanvasBoard,
                                 from instances: [TerminalInstance]) -> [TerminalInstance] {
        board.tiles.compactMap { tile in instances.first { $0.id == tile.itemID } }
    }
}
