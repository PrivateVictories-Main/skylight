import Foundation
import SwiftUI
import WebKit
import GhosttyTerminal

@MainActor
final class AppState: ObservableObject {
    @Published var items: [WorkspaceItem]
    @Published var canvases: [CanvasBoard]
    @Published var selection: Selection?

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
        } else {
            let native = WorkspaceItem(kind: .nativeClaude, name: "Claude Chat")
            let claude = WorkspaceItem(kind: .chat(.claude), name: "Claude (Web)")
            let chatgpt = WorkspaceItem(kind: .chat(.chatgpt), name: "ChatGPT (Web)")
            let term = WorkspaceItem(kind: .terminal, name: "Terminal 1")
            items = [native, claude, chatgpt, term]
            canvases = []
        }
        if let first = items.first { selection = .item(first.id) }
    }

    private struct SavedState: Codable {
        var items: [WorkspaceItem]
        var canvases: [CanvasBoard]
    }

    func persist() {
        let saved = SavedState(items: items, canvases: canvases)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Self.stateURL)
        }
    }

    func item(_ id: UUID) -> WorkspaceItem? {
        items.first { $0.id == id }
    }

    // MARK: - Mutations

    func addTerminal() {
        let count = items.filter { $0.kind == .terminal }.count
        let item = WorkspaceItem(kind: .terminal, name: "Terminal \(count + 1)")
        items.append(item)
        selection = .item(item.id)
        persist()
    }

    func addChat(_ provider: ChatProvider) {
        let item = WorkspaceItem(kind: .chat(provider), name: "\(provider.displayName) (Web)")
        items.append(item)
        selection = .item(item.id)
        persist()
    }

    func addNativeClaudeChat() {
        let count = items.filter { $0.kind == .nativeClaude }.count
        let item = WorkspaceItem(kind: .nativeClaude, name: count == 0 ? "Claude Chat" : "Claude Chat \(count + 1)")
        items.append(item)
        selection = .item(item.id)
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
    private var chatEngines: [UUID: NativeChatEngine] = [:]

    func bridge(for item: WorkspaceItem, provider: ChatProvider) -> WebChatBridge {
        if let existing = bridges[item.id] { return existing }
        let bridge = WebChatBridge(provider: provider, itemID: item.id)
        bridges[item.id] = bridge
        return bridge
    }

    func chatEngine(for item: WorkspaceItem) -> NativeChatEngine {
        if let existing = chatEngines[item.id] { return existing }
        let engine = NativeChatEngine(itemID: item.id)
        chatEngines[item.id] = engine
        return engine
    }

    func terminal(for item: WorkspaceItem) -> TerminalViewState {
        if let existing = terminals[item.id] { return existing }
        let state = TerminalViewState()
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        terminals[item.id] = state
        return state
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
