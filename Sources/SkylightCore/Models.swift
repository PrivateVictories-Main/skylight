import CoreGraphics
import Foundation

/// Vendor mark identity for the harnesses with official vector logos.
public enum Brand: String, Codable, Sendable {
    case claudeCode, openai, gemini, copilot, cursor, qwen, amp, opencode
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

public extension CanvasBoard {
    /// Pin an instance to an edge of this board.
    ///
    /// The tile entry is REMOVED and its frame remembered inside the slot. A
    /// docked instance holding both was the rails-deleted-on-load bug:
    /// `sanitized` claimed the id for the tile, then dropped the dock slot as
    /// a duplicate and emptied the rail — on every single load.
    mutating func dock(_ itemID: UUID, to target: DockTarget) {
        let frame = tiles.first { $0.itemID == itemID }?.frame
        tiles.removeAll { $0.itemID == itemID }
        docks = DockLayout.docked(docks, item: itemID, to: target,
                                  restoreFrame: frame)
    }

    /// Unpin an instance, putting its tile back where it came from — or as
    /// close as it can get without landing on top of something else.
    mutating func undock(_ itemID: UUID) {
        guard DockLayout.dockedItems(docks).contains(itemID) else { return }
        let remembered = DockLayout.restoreFrame(docks, item: itemID)
        docks = DockLayout.undocked(docks, item: itemID)
        guard !tiles.contains(where: { $0.itemID == itemID }) else { return }
        let size = remembered?.size ?? CanvasLayout.defaultTileSize
        // The board moved while it was docked — arranging, reflowing, new
        // tiles. Its old spot may be occupied now, so the same collision
        // dodge every other placement uses applies here too.
        let origin = CanvasLayout.freePosition(
            desired: remembered?.origin ?? CanvasLayout.staggeredOrigin(
                existing: tiles.count),
            size: size,
            avoiding: tiles.map(\.frame))
        tiles.append(CanvasTile(itemID: itemID, origin: origin, size: size))
    }

    /// The tiles that actually live on the PLANE.
    ///
    /// A docked instance keeps its tile entry so undocking can restore the
    /// size and position it had — but while it is docked it is viewport
    /// chrome, and every piece of board math (arrange, reflow, magnets,
    /// collision) must look straight past it. Feeding a docked tile to
    /// `arranged` would pack a rectangle that is not on the plane; feeding it
    /// to `magnetSnapped` would snap a dragged tile to a frame in a different
    /// coordinate system entirely.
    var freeTiles: [CanvasTile] {
        let docked = DockLayout.dockedItems(docks)
        guard !docked.isEmpty else { return tiles }
        return tiles.filter { !docked.contains($0.itemID) }
    }
}

public struct CanvasBoard: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var tiles: [CanvasTile]
    /// Persisted pan offset so a canvas reopens exactly where you left it.
    public var pan: CGPoint
    /// Persisted zoom scale (screen = content × zoom + pan) so a canvas
    /// reopens at exactly the magnification you left it at.
    public var zoom: CGFloat
    /// Terminals pinned to the edges of the VIEWPORT rather than placed on
    /// the board. They do not pan and they do not zoom — see DockLayout.
    public var docks: [DockEdge: DockRail]

    public init(id: UUID = UUID(), name: String, tiles: [CanvasTile] = [],
                pan: CGPoint = .zero, zoom: CGFloat = 1,
                docks: [DockEdge: DockRail] = [:]) {
        self.id = id
        self.name = name
        self.tiles = tiles
        self.pan = pan
        self.zoom = zoom
        self.docks = docks
    }

    enum CodingKeys: String, CodingKey { case id, name, tiles, pan, zoom, docks }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tiles = try container.decode([CanvasTile].self, forKey: .tiles)
        // Boards saved before pan existed decode with the origin view, and
        // boards saved before zoom existed decode at 100%.
        // NOTE: any new persisted property must be decoded HERE as well —
        // the synthesized encoder writes it, but this initializer silently
        // drops what it doesn't read. Forgetting a key here does not fail
        // loudly: the value simply reverts to its default on every load.
        pan = try container.decodeIfPresent(CGPoint.self, forKey: .pan) ?? .zero
        zoom = try container.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? 1
        // Boards saved before docking existed decode with no rails.
        docks = try container.decodeIfPresent([DockEdge: DockRail].self,
                                              forKey: .docks) ?? [:]
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
    /// An instance lives on the board that holds it as a free tile OR docks
    /// it to an edge. Docking is a way of being ON a board, not an escape
    /// from residency — the sidebar has to keep telling the truth.
    public static func board(of instanceID: UUID, in boards: [CanvasBoard]) -> UUID? {
        boards.first { board in
            board.tiles.contains { $0.itemID == instanceID }
                || DockLayout.dockedItems(board.docks).contains(instanceID)
        }?.id
    }

    public static func free(_ instances: [TerminalInstance],
                            boards: [CanvasBoard]) -> [TerminalInstance] {
        instances.filter { board(of: $0.id, in: boards) == nil }
    }

    /// Free tiles first in board order, then whatever the rails hold — so a
    /// docked terminal still appears under its canvas in the sidebar.
    public static func residents(of board: CanvasBoard,
                                 from instances: [TerminalInstance]) -> [TerminalInstance] {
        let free = board.tiles.compactMap { tile in
            instances.first { $0.id == tile.itemID }
        }
        let dockedIDs = DockEdge.allCases.flatMap { edge in
            board.docks[edge]?.slots.map(\.itemID) ?? []
        }
        let docked = dockedIDs.compactMap { id in instances.first { $0.id == id } }
        return free + docked
    }
}
