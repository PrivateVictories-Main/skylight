import SwiftUI
import UniformTypeIdentifiers
import GhosttyTerminal

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 1080, minHeight: 700)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    private var chats: [WorkspaceItem] {
        state.items.filter(\.isChat)
    }

    private var terminals: [WorkspaceItem] {
        state.items.filter { $0.kind == .terminal }
    }

    var body: some View {
        List(selection: $state.selection) {
            Section("Chats") {
                ForEach(chats) { item in
                    ItemRow(item: item)
                }
            }
            Section("Terminals") {
                ForEach(terminals) { item in
                    ItemRow(item: item)
                }
            }
            Section("Canvases") {
                ForEach(state.canvases) { board in
                    Label(board.name, systemImage: "square.on.square.dashed")
                        .tag(Selection.canvas(board.id))
                        .dropDestination(for: String.self) { ids, _ in
                            dropItems(ids, onto: board.id)
                        }
                }
                if state.canvases.isEmpty {
                    Text("Drag a chat or terminal here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .dropDestination(for: String.self) { ids, _ in
                            dropItems(ids, onto: nil)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Menu {
                    Button("Claude") { state.addAssistant(.claude) }
                    Button("ChatGPT") { state.addAssistant(.chatgpt) }
                    Button("Terminal") { state.addTerminal() }
                    Button("Canvas") { state.selection = .canvas(state.newCanvas().id) }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationTitle("Skylight")
    }

    private func dropItems(_ ids: [String], onto canvasID: UUID?) -> Bool {
        var target = canvasID
        for raw in ids {
            guard let id = UUID(uuidString: raw), state.item(id) != nil else { continue }
            state.addTile(itemID: id, to: target, at: nil)
            if target == nil, case let .canvas(created)? = state.selection { target = created }
        }
        return true
    }
}

private struct ItemRow: View {
    @EnvironmentObject private var state: AppState
    let item: WorkspaceItem

    var body: some View {
        HStack(spacing: 8) {
            if case let .assistant(provider) = item.kind {
                BrandIcon(provider: provider, size: 18)
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 18, height: 18)
            }
            Text(item.name)
        }
        .padding(.vertical, 1)
        .tag(Selection.item(item.id))
        .draggable(item.id.uuidString)
        .contextMenu {
            Button("Add to New Canvas") {
                state.addTile(itemID: item.id, to: nil, at: nil)
            }
            if !state.canvases.isEmpty {
                Menu("Add to Canvas") {
                    ForEach(state.canvases) { board in
                        Button(board.name) {
                            state.addTile(itemID: item.id, to: board.id, at: nil)
                        }
                    }
                }
            }
        }
    }

    private var iconTint: Color {
        switch item.kind {
        case let .assistant(provider): provider.tint
        case .terminal: .secondary
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.selection {
        case let .item(id):
            if let item = state.item(id) {
                FullItemView(item: item)
                    .id(item.id)
            } else {
                EmptyDetail()
            }
        case let .canvas(id):
            if let board = state.canvases.first(where: { $0.id == id }) {
                CanvasView(boardID: board.id)
                    .id(board.id)
            } else {
                EmptyDetail()
            }
        case nil:
            EmptyDetail()
        }
    }
}

private struct EmptyDetail: View {
    var body: some View {
        ContentUnavailableView(
            "Nothing Selected",
            systemImage: "square.grid.2x2",
            description: Text("Pick a chat, terminal, or canvas from the sidebar.")
        )
    }
}

/// Full-window view of a single item — the clean, ChatGPT-app-style surface.
struct FullItemView: View {
    @EnvironmentObject private var state: AppState
    let item: WorkspaceItem

    var body: some View {
        Group {
            switch item.kind {
            case let .assistant(provider):
                AssistantView(item: item, provider: provider)
            case .terminal:
                TerminalSurfaceView(context: state.sessions.terminal(for: item))
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle(item.name)
    }
}

/// One assistant, two surfaces behind a mode dropdown — Chat (the provider's
/// full web experience, with Skylight's native history column) and Code/Codex
/// (native CLI-backed chat). Mirrors the unified ChatGPT app's mode switcher.
struct AssistantView: View {
    @EnvironmentObject private var state: AppState
    let item: WorkspaceItem
    let provider: ChatProvider

    var body: some View {
        Group {
            switch item.mode {
            case .chat, .code:
                // Both modes use our custom native chat — same composer and
                // output rendering, differing only in which CLI/model backs it.
                ProviderChatView(engine: state.sessions.chatEngine(for: item, provider: provider))
            case .web:
                WebChatDetailView(bridge: state.sessions.bridge(for: item, provider: provider))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Mode", selection: Binding(
                    get: { item.mode },
                    set: { state.setMode($0, for: item.id) }
                )) {
                    Text(AssistantMode.chat.displayName(for: provider)).tag(AssistantMode.chat)
                    Text(AssistantMode.code.displayName(for: provider)).tag(AssistantMode.code)
                    Divider()
                    Text(AssistantMode.web.displayName(for: provider)).tag(AssistantMode.web)
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }
}
