import Foundation
import SwiftUI

// MARK: - Sidebar items

enum ChatProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case chatgpt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        }
    }

    var homeURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai")!
        case .chatgpt: URL(string: "https://chatgpt.com")!
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .chatgpt: "bubble.left.and.bubble.right"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.28)
        case .chatgpt: Color(red: 0.20, green: 0.65, blue: 0.55)
        }
    }
}

enum WorkspaceItemKind: Codable, Equatable {
    case chat(ChatProvider)
    case terminal
}

struct WorkspaceItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: WorkspaceItemKind
    var name: String

    init(id: UUID = UUID(), kind: WorkspaceItemKind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }

    var symbolName: String {
        switch kind {
        case let .chat(provider): provider.symbolName
        case .terminal: "terminal"
        }
    }
}

// MARK: - Canvas

struct CanvasTile: Identifiable, Codable, Equatable {
    let id: UUID
    var itemID: UUID
    var origin: CGPoint
    var size: CGSize

    init(id: UUID = UUID(), itemID: UUID, origin: CGPoint, size: CGSize) {
        self.id = id
        self.itemID = itemID
        self.origin = origin
        self.size = size
    }

    var frame: CGRect { CGRect(origin: origin, size: size) }
}

struct CanvasBoard: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var tiles: [CanvasTile]

    init(id: UUID = UUID(), name: String, tiles: [CanvasTile] = []) {
        self.id = id
        self.name = name
        self.tiles = tiles
    }
}

// MARK: - Selection

enum Selection: Hashable {
    case item(UUID)
    case canvas(UUID)
}
