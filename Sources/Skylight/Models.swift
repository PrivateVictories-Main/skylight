import Foundation
import SwiftUI

// MARK: - Sidebar items

enum ChatProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case chatgpt
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    var homeURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai")!
        case .chatgpt: URL(string: "https://chatgpt.com")!
        case .gemini: URL(string: "https://gemini.google.com")!
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .chatgpt: "bubble.left.and.bubble.right"
        case .gemini: "sparkles"
        }
    }

    var newChatURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/new")!
        case .chatgpt: URL(string: "https://chatgpt.com/")!
        case .gemini: URL(string: "https://gemini.google.com/app")!
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.28)
        case .chatgpt: Color(red: 0.20, green: 0.65, blue: 0.55)
        case .gemini: Color(red: 0.31, green: 0.51, blue: 0.93)
        }
    }
}

/// One assistant item, two surfaces — mirrors the ChatGPT app's Work/Codex dropdown.
enum AssistantMode: String, Codable {
    case chat
    case code
    case web

    func displayName(for provider: ChatProvider) -> String {
        switch self {
        case .chat: "Chat"
        case .code: provider == .chatgpt ? "Codex" : "Code"
        case .web: "Open Web"
        }
    }
}

enum WorkspaceItemKind: Codable, Equatable {
    case assistant(ChatProvider)
    case terminal
}

/// What runs inside a terminal tile. Agent flavors launch the vendor CLI as a
/// full interactive session — the T3 Code / Conductor pattern, but in a real
/// embedded terminal.
enum TerminalFlavor: String, Codable, CaseIterable {
    case shell
    case claudeCode
    case codex
    case gemini

    var displayName: String {
        switch self {
        case .shell: "Terminal"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        }
    }

    /// Brand emblem provider for agent terminals; nil = plain terminal glyph.
    var provider: ChatProvider? {
        switch self {
        case .shell: nil
        case .claudeCode: .claude
        case .codex: .chatgpt
        case .gemini: .gemini
        }
    }

    var command: String? {
        switch self {
        case .shell: nil
        case .claudeCode: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }
}

struct WorkspaceItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: WorkspaceItemKind
    var name: String
    var mode: AssistantMode
    var pinned: Bool
    /// Auto-derived conversation title (what the chat is about). Nil until the
    /// first message. Terminals keep `name`.
    var title: String?
    /// What a terminal runs: plain shell, or an agent CLI inside it.
    var terminalFlavor: TerminalFlavor?
    var workingDirectory: String?

    init(id: UUID = UUID(), kind: WorkspaceItemKind, name: String, mode: AssistantMode = .chat,
         pinned: Bool = false, title: String? = nil,
         terminalFlavor: TerminalFlavor? = nil, workingDirectory: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mode = mode
        self.pinned = pinned
        self.title = title
        self.terminalFlavor = terminalFlavor
        self.workingDirectory = workingDirectory
    }

    /// What the sidebar shows: the conversation title for chats, else the name.
    var displayLabel: String {
        if isChat { return title ?? "New Chat" }
        return name
    }

    var symbolName: String {
        switch kind {
        case let .assistant(provider): provider.symbolName
        case .terminal: "terminal"
        }
    }

    var isChat: Bool {
        if case .assistant = kind { true } else { false }
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

// MARK: - Sidebar customization

/// The sections a user can show or hide, ChatGPT-app style. Some are live
/// today; the rest are scaffolded so they slot in as features land — no
/// section renders unless it's both enabled and has real content.
enum SidebarSection: String, Codable, CaseIterable, Identifiable {
    case pinned
    case chats
    case terminals
    case canvases
    case tasks
    case projects
    case plugins
    case sites
    case pullRequests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .chats: "Chats"
        case .terminals: "Terminals"
        case .canvases: "Canvases"
        case .tasks: "Tasks"
        case .projects: "Projects"
        case .plugins: "Plugins"
        case .sites: "Sites"
        case .pullRequests: "Pull Requests"
        }
    }

    var symbol: String {
        switch self {
        case .pinned: "pin"
        case .chats: "bubble.left.and.bubble.right"
        case .terminals: "terminal"
        case .canvases: "square.on.square.dashed"
        case .tasks: "checklist"
        case .projects: "folder"
        case .plugins: "puzzlepiece.extension"
        case .sites: "globe"
        case .pullRequests: "arrow.triangle.pull"
        }
    }

    /// Sections wired to real content today. Others are opt-in placeholders.
    var isLive: Bool {
        switch self {
        case .pinned, .chats, .terminals, .canvases: true
        default: false
        }
    }

    static let defaultVisible: Set<SidebarSection> = [.pinned, .chats, .terminals, .canvases]
}

struct UserProfile: Codable, Equatable {
    var name: String = "You"
    var accentHex: String = "#D97757"
}
