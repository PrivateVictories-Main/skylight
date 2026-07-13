import Combine
import Foundation
import SwiftUI
import WebKit
import GhosttyTerminal

@MainActor
final class AppState: ObservableObject {
    @Published var items: [WorkspaceItem]
    @Published var canvases: [CanvasBoard]
    @Published var selection: Selection?
    @Published var visibleSections: Set<SidebarSection>
    @Published var profile: UserProfile

    let sessions = LiveSessionStore()

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspace.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            items = saved.items
            canvases = saved.canvases
            visibleSections = saved.visibleSections ?? SidebarSection.defaultVisible
            profile = saved.profile ?? UserProfile()
        } else {
            let claude = WorkspaceItem(kind: .assistant(.claude), name: "Claude")
            let chatgpt = WorkspaceItem(kind: .assistant(.chatgpt), name: "ChatGPT")
            let term = WorkspaceItem(kind: .terminal, name: "Terminal 1")
            items = [claude, chatgpt, term]
            canvases = []
            visibleSections = SidebarSection.defaultVisible
            profile = UserProfile()
        }
        // Restore last selection; fall back to the first item.
        let saved = (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        if let id = saved?.selectedItem, items.contains(where: { $0.id == id }) {
            selection = .item(id)
        } else if let id = saved?.selectedCanvas, canvases.contains(where: { $0.id == id }) {
            selection = .canvas(id)
        } else if let first = items.first {
            selection = .item(first.id)
        }
        sessions.renameChat = { [weak self] id, title in self?.setTitle(title, for: id) }
        // Save selection as it changes (cheap: whole-state persist).
        $selection
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &observers)
    }

    private var observers: Set<AnyCancellable> = []

    private struct SavedState: Codable {
        var items: [WorkspaceItem]
        var canvases: [CanvasBoard]
        var visibleSections: Set<SidebarSection>?
        var profile: UserProfile?
        var selectedItem: UUID?
        var selectedCanvas: UUID?
    }

    func persist() {
        var selectedItem: UUID?
        var selectedCanvas: UUID?
        switch selection {
        case let .item(id): selectedItem = id
        case let .canvas(id): selectedCanvas = id
        case nil: break
        }
        let saved = SavedState(items: items, canvases: canvases,
                               visibleSections: visibleSections, profile: profile,
                               selectedItem: selectedItem, selectedCanvas: selectedCanvas)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Self.stateURL)
        }
    }

    // MARK: - Customization

    func toggleSection(_ section: SidebarSection) {
        if visibleSections.contains(section) { visibleSections.remove(section) }
        else { visibleSections.insert(section) }
        persist()
    }

    func togglePin(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].pinned.toggle()
        persist()
    }

    func updateProfile(_ profile: UserProfile) {
        self.profile = profile
        persist()
    }

    /// Set the auto-derived title for a chat, the first time it gets one.
    func setTitle(_ title: String, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].title == nil else { return }
        items[index].title = title
        persist()
    }

    func rename(_ itemID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if items[index].isChat {
            items[index].title = trimmed
        } else {
            items[index].name = trimmed
        }
        persist()
    }

    func renameCanvas(_ canvasID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
        canvases[index].name = trimmed
        persist()
    }

    func deleteItem(_ itemID: UUID) {
        items.removeAll { $0.id == itemID }
        for index in canvases.indices {
            canvases[index].tiles.removeAll { $0.itemID == itemID }
        }
        sessions.discard(itemID)
        // Remove persisted transcript/history for the item.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight", isDirectory: true)
        try? FileManager.default.removeItem(at: support.appendingPathComponent("chats/\(itemID.uuidString).json"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("webhistory/\(itemID.uuidString).json"))
        if case let .item(selected)? = selection, selected == itemID {
            selection = items.first.map { .item($0.id) }
        }
        persist()
    }

    func deleteCanvas(_ canvasID: UUID) {
        canvases.removeAll { $0.id == canvasID }
        if case let .canvas(selected)? = selection, selected == canvasID {
            selection = items.first.map { .item($0.id) }
        }
        persist()
    }

    func item(_ id: UUID) -> WorkspaceItem? {
        items.first { $0.id == id }
    }

    // MARK: - Mutations

    func addTerminal(_ flavor: TerminalFlavor = .shell, directory: String? = nil) {
        let siblings = items.filter { $0.kind == .terminal && ($0.terminalFlavor ?? .shell) == flavor }.count
        let base = flavor.displayName
        let name = siblings == 0 ? base : "\(base) \(siblings + 1)"
        let item = WorkspaceItem(kind: .terminal, name: name,
                                 terminalFlavor: flavor, workingDirectory: directory)
        items.append(item)
        selection = .item(item.id)
        persist()
    }

    func addAssistant(_ provider: ChatProvider) {
        let count = items.filter { $0.kind == .assistant(provider) }.count
        let name = count == 0 ? provider.displayName : "\(provider.displayName) \(count + 1)"
        let item = WorkspaceItem(kind: .assistant(provider), name: name)
        items.append(item)
        selection = .item(item.id)
        persist()
    }

    func setMode(_ mode: AssistantMode, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].mode = mode
        persist()
    }

    func newCanvas() -> CanvasBoard {
        let board = CanvasBoard(name: "Canvas \(canvases.count + 1)")
        canvases.append(board)
        persist()
        return board
    }

    /// Drop an existing sidebar item onto a canvas (creating the canvas if needed).
    func addTile(itemID: UUID, to canvasID: UUID?, at point: CGPoint?) {
        let boardID: UUID
        if let canvasID, canvases.contains(where: { $0.id == canvasID }) {
            boardID = canvasID
        } else {
            boardID = newCanvas().id
        }
        guard let index = canvases.firstIndex(where: { $0.id == boardID }) else { return }

        // Reference model: the same item may appear on one canvas once.
        guard !canvases[index].tiles.contains(where: { $0.itemID == itemID }) else {
            selection = .canvas(boardID)
            return
        }
        let defaultSize = CGSize(width: 560, height: 400)
        let origin = CanvasLayout.snapped(point.map { CGPoint(x: $0.x - defaultSize.width / 2, y: $0.y - 24) }
            ?? CanvasLayout.staggeredOrigin(existing: canvases[index].tiles.count))
        canvases[index].tiles.append(CanvasTile(itemID: itemID, origin: origin, size: defaultSize))
        selection = .canvas(boardID)
        persist()
    }

    func removeTile(_ tileID: UUID, from canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
        canvases[index].tiles.removeAll { $0.id == tileID }
        persist()
    }

    func updateTile(_ tile: CanvasTile, in canvasID: UUID) {
        guard let boardIndex = canvases.firstIndex(where: { $0.id == canvasID }),
              let tileIndex = canvases[boardIndex].tiles.firstIndex(where: { $0.id == tile.id })
        else { return }
        canvases[boardIndex].tiles[tileIndex] = tile
        persist()
    }
}

// MARK: - Live sessions

/// Keeps terminal surfaces and web views alive independent of SwiftUI view churn,
/// so an item shows the same running state full-window, on a canvas, or after
/// navigating away and back.
@MainActor
final class LiveSessionStore {
    private var terminals: [UUID: TerminalViewState] = [:]
    private var bridges: [UUID: WebChatBridge] = [:]
    private var chatEngines: [UUID: ProviderChatEngine] = [:]

    func bridge(for item: WorkspaceItem, provider: ChatProvider) -> WebChatBridge {
        if let existing = bridges[item.id] { return existing }
        let bridge = WebChatBridge(provider: provider, itemID: item.id)
        bridges[item.id] = bridge
        return bridge
    }

    /// Set by AppState so a chat can rename its sidebar item from the first message.
    var renameChat: ((UUID, String) -> Void)?

    /// Tear down live state for a deleted item.
    func discard(_ itemID: UUID) {
        if let engine = chatEngines.removeValue(forKey: itemID) { engine.stop() }
        terminals.removeValue(forKey: itemID)
        bridges.removeValue(forKey: itemID)
    }

    func chatEngine(for item: WorkspaceItem, provider: ChatProvider) -> ProviderChatEngine {
        if let existing = chatEngines[item.id] { return existing }
        let engine = ProviderChatEngine(provider: provider, itemID: item.id)
        engine.onTitle = { [weak self] title in self?.renameChat?(item.id, title) }
        // Backfill a title for a chat that already has history but no title yet.
        if item.title == nil, let firstUser = engine.messages.first(where: { $0.role == .user }) {
            renameChat?(item.id, ProviderChatEngine.deriveTitle(from: firstUser.text, attachments: firstUser.attachments))
        }
        chatEngines[item.id] = engine
        return engine
    }

    func terminal(for item: WorkspaceItem) -> TerminalViewState {
        if let existing = terminals[item.id] { return existing }
        let state: TerminalViewState
        let flavor = item.terminalFlavor ?? .shell
        if let command = flavor.command, let binary = Self.resolveBinary(command) {
            // Agent terminal: ghostty runs the CLI directly as the surface command.
            state = TerminalViewState(configSource: .generated("command = \(binary)\n"))
        } else {
            state = TerminalViewState()
        }
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: item.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
        terminals[item.id] = state
        return state
    }

    nonisolated static func resolveBinary(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/\(name)", "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func webView(for item: WorkspaceItem, provider: ChatProvider) -> WKWebView {
        bridge(for: item, provider: provider).webView
    }
}

// MARK: - Layout helpers

enum CanvasLayout {
    static let grid: CGFloat = 16

    static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, (point.x / grid).rounded() * grid),
            y: max(0, (point.y / grid).rounded() * grid)
        )
    }

    static func snapped(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(320, (size.width / grid).rounded() * grid),
            height: max(220, (size.height / grid).rounded() * grid)
        )
    }

    static func staggeredOrigin(existing: Int) -> CGPoint {
        CGPoint(x: 48 + CGFloat(existing) * 64, y: 48 + CGFloat(existing) * 48)
    }
}
