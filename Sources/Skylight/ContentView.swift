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
    @State private var showProfile = false

    private var pinned: [WorkspaceItem] { state.items.filter(\.pinned) }
    private var chats: [WorkspaceItem] { state.items.filter(\.isChat) }
    private var terminals: [WorkspaceItem] { state.items.filter { $0.kind == .terminal } }

    private func isVisible(_ section: SidebarSection) -> Bool {
        state.visibleSections.contains(section)
    }

    var body: some View {
        List(selection: $state.selection) {
            if isVisible(.pinned), !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { item in ItemRow(item: item) }
                }
            }
            if isVisible(.chats) {
                Section("Chats") {
                    ForEach(chats) { item in ItemRow(item: item) }
                }
            }
            if isVisible(.terminals) {
                Section("Terminals") {
                    ForEach(terminals) { item in ItemRow(item: item) }
                }
            }
            if isVisible(.canvases) {
                Section("Canvases") {
                    ForEach(state.canvases) { board in
                        Label(board.name, systemImage: "square.on.square.dashed")
                            .tag(Selection.canvas(board.id))
                            .dropDestination(for: String.self) { ids, _ in dropItems(ids, onto: board.id) }
                    }
                    if state.canvases.isEmpty {
                        Text("Drag a chat or terminal here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .dropDestination(for: String.self) { ids, _ in dropItems(ids, onto: nil) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Skylight")
        .popover(isPresented: $showProfile, arrowEdge: .bottom) {
            ProfileEditor().environmentObject(state)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { showProfile = true } label: {
                HStack(spacing: 8) {
                    ProfileAvatar(profile: state.profile, size: 24)
                    Text(state.profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.pressable(scale: 0.97))

            Spacer()

            Menu {
                Button { state.addAssistant(.claude) } label: { Label("Claude Chat", systemImage: "plus") }
                Button { state.addAssistant(.chatgpt) } label: { Label("ChatGPT", systemImage: "plus") }
                Button { state.addTerminal() } label: { Label("Terminal", systemImage: "plus") }
                Button { state.selection = .canvas(state.newCanvas().id) } label: { Label("Canvas", systemImage: "plus") }
                Divider()
                Menu("Customize Sidebar") {
                    ForEach(SidebarSection.allCases) { section in
                        Toggle(isOn: Binding(
                            get: { state.visibleSections.contains(section) },
                            set: { _ in state.toggleSection(section) }
                        )) {
                            Label(section.title + (section.isLive ? "" : " (soon)"), systemImage: section.symbol)
                        }
                        .disabled(!section.isLive)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
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

// MARK: - Profile

struct ProfileAvatar: View {
    let profile: UserProfile
    var size: CGFloat = 24

    private var initials: String {
        let parts = profile.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    var body: some View {
        Circle()
            .fill(Color(hex: profile.accentHex) ?? .accentColor)
            .frame(width: size, height: size)
            .overlay(
                Text(initials.isEmpty ? "Y" : initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var state: AppState
    @State private var draft = UserProfile()

    private let swatches = ["#D97757", "#10A37F", "#3B82F6", "#8B5CF6", "#EF4444", "#111111"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProfileAvatar(profile: draft, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Profile").font(.headline)
                    Text("Shown across Skylight").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(swatches, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(draft.accentHex == hex ? 0.9 : 0), lineWidth: 2)
                        )
                        .onTapGesture { draft.accentHex = hex }
                }
            }
        }
        .padding(18)
        .frame(width: 280)
        .onAppear { draft = state.profile }
        .onDisappear { state.updateProfile(draft) }
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
            Text(item.displayLabel)
        }
        .padding(.vertical, 1)
        .tag(Selection.item(item.id))
        .draggable(item.id.uuidString)
        .contextMenu {
            Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") {
                state.togglePin(item.id)
            }
            Divider()
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
        .navigationTitle(item.displayLabel)
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
