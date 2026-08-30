import CoreGraphics
import Foundation

public struct SavedState: Codable, Equatable {
    public var version: Int
    public var instances: [TerminalInstance]
    public var canvases: [CanvasBoard]
    public var selectedInstance: UUID?
    public var selectedCanvas: UUID?

    public init(version: Int = 2, instances: [TerminalInstance] = [],
                canvases: [CanvasBoard] = [],
                selectedInstance: UUID? = nil, selectedCanvas: UUID? = nil) {
        self.version = version
        self.instances = instances
        self.canvases = canvases
        self.selectedInstance = selectedInstance
        self.selectedCanvas = selectedCanvas
    }
}

public enum WorkspacePersistence {
    /// Decode the current format, or migrate the pre-carve one (chat items
    /// dropped, terminal flavors mapped to harnesses). nil = unreadable —
    /// the caller keeps the file as .bak rather than clobbering it.
    public static func decode(_ data: Data) -> SavedState? {
        let decoder = JSONDecoder()
        if let v2 = try? decoder.decode(SavedState.self, from: data), v2.version >= 2 {
            return sanitized(v2)
        }
        guard let legacy = try? decoder.decode(LegacyState.self, from: data) else { return nil }
        return migrate(legacy)
    }

    /// Stored data is hostile on the CURRENT format too, not just the legacy
    /// one: the whole app leans on single residency and on tiles pointing at
    /// real instances, and a hand-edited or corrupted v2 file used to load
    /// verbatim — one live terminal view claimed by two boards, orphan tiles
    /// counting toward arrange geometry. Same rules the migration enforces:
    /// orphan tiles dropped, first board keeps a doubly-tiled instance,
    /// selections must point at something that exists.
    private static func sanitized(_ state: SavedState) -> SavedState {
        var state = state
        let ids = Set(state.instances.map(\.id))
        var seen = Set<UUID>()
        state.canvases = state.canvases.map { board in
            var board = board
            // DOCK SLOTS ARE CLAIMED FIRST, and the order is the whole point.
            //
            // Running the tile pass first is what deleted every rail on every
            // load: it claimed the instance for its tile entry, and the dock
            // slot then looked like a duplicate and was dropped, emptying the
            // rail. `dock()` no longer leaves a tile entry behind, so the
            // clash only arises in a hand-edited file — and there the dock
            // has to win, because it is the shape a rail depends on.
            var docks: [DockEdge: DockRail] = [:]
            for edge in DockEdge.allCases {
                guard var rail = board.docks[edge] else { continue }
                rail.slots = rail.slots.filter {
                    ids.contains($0.itemID) && seen.insert($0.itemID).inserted
                }
                if !rail.slots.isEmpty { docks[edge] = rail }
            }
            board.docks = DockLayout.normalized(docks)
            board.tiles = board.tiles.filter {
                ids.contains($0.itemID) && seen.insert($0.itemID).inserted
            }
            return board
        }
        state.selectedInstance = state.selectedInstance.flatMap { ids.contains($0) ? $0 : nil }
        state.selectedCanvas = state.selectedCanvas.flatMap { id in
            state.canvases.contains { $0.id == id } ? id : nil
        }
        return state
    }

    public static func encode(_ state: SavedState) -> Data? {
        try? JSONEncoder().encode(state)
    }

    // MARK: - Legacy (pre-carve) format

    private struct LegacyState: Decodable {
        var items: [LegacyItem]
        var canvases: [LegacyBoard]
        var selectedItem: UUID?
        var selectedCanvas: UUID?
    }

    private struct LegacyItem: Decodable {
        var id: UUID
        var kind: LegacyKind
        var name: String
        var terminalFlavor: String?
        var workingDirectory: String?
    }

    /// Old `WorkspaceItemKind` encoded as a one-key object:
    /// {"terminal":{}} or {"assistant":{"_0":"claude"}}.
    private enum LegacyKind: Decodable {
        case terminal
        case other

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            self = container.allKeys.contains { $0.stringValue == "terminal" } ? .terminal : .other
        }
    }

    private struct LegacyBoard: Decodable {
        var id: UUID
        var name: String
        var tiles: [LegacyTile]
    }

    private struct LegacyTile: Decodable {
        var id: UUID
        var itemID: UUID
        var origin: CGPoint
        var size: CGSize
    }

    private static func harness(fromFlavor flavor: String?) -> String? {
        switch flavor {
        case "claudeCode": "claude"
        case "codex": "codex"
        case "gemini": "gemini"
        default: nil
        }
    }

    private static func migrate(_ legacy: LegacyState) -> SavedState {
        let instances: [TerminalInstance] = legacy.items.compactMap { item in
            guard case .terminal = item.kind else { return nil }
            return TerminalInstance(
                id: item.id, name: item.name,
                spec: TerminalSpec(harness: harness(fromFlavor: item.terminalFlavor),
                                   workingDirectory: item.workingDirectory))
        }
        let ids = Set(instances.map(\.id))
        var seen = Set<UUID>()   // single residency: the first board keeps the tile
        let boards = legacy.canvases.map { board in
            CanvasBoard(id: board.id, name: board.name,
                        tiles: board.tiles.compactMap { tile in
                            guard ids.contains(tile.itemID),
                                  seen.insert(tile.itemID).inserted else { return nil }
                            return CanvasTile(id: tile.id, itemID: tile.itemID,
                                              origin: tile.origin, size: tile.size)
                        })
        }
        let selected = legacy.selectedItem.flatMap { ids.contains($0) ? $0 : nil }
        let selectedBoard = legacy.selectedCanvas.flatMap { id in
            boards.contains { $0.id == id } ? id : nil
        }
        return SavedState(instances: instances, canvases: boards,
                          selectedInstance: selected, selectedCanvas: selectedBoard)
    }
}
