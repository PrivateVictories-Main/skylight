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

/// What the rename sheet is targeting.
enum RenameTarget: Identifiable {
    case item(WorkspaceItem)
    case canvas(CanvasBoard)

    var id: UUID {
        switch self {
        case let .item(item): item.id
        case let .canvas(board): board.id
        }
    }

    var currentName: String {
        switch self {
        case let .item(item): item.displayLabel
        case let .canvas(board): board.name
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var showProfile = false
    @State private var showNewPicker = false
    @State private var renameTarget: RenameTarget?
    @State private var renameDraft = ""

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
                    ForEach(pinned) { item in ItemRow(item: item, onRename: beginRename) }
                }
            }
            if isVisible(.chats) {
                Section("Chats") {
                    ForEach(chats) { item in ItemRow(item: item, onRename: beginRename) }
                }
            }
            if isVisible(.terminals) {
                Section("Terminals") {
                    ForEach(terminals) { item in ItemRow(item: item, onRename: beginRename) }
                }
            }
            if isVisible(.canvases) {
                Section("Canvases") {
                    ForEach(state.canvases) { board in
                        Label(board.name, systemImage: "square.on.square.dashed")
                            .tag(Selection.canvas(board.id))
                            .dropDestination(for: String.self) { ids, _ in dropItems(ids, onto: board.id) }
                            .contextMenu {
                                Button("Rename…") {
                                    renameDraft = board.name
                                    renameTarget = .canvas(board)
                                }
                                Divider()
                                Button("Delete Canvas", role: .destructive) {
                                    state.deleteCanvas(board.id)
                                }
                            }
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
        .sheet(isPresented: $showNewPicker) {
            NewItemPicker().environmentObject(state)
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                switch renameTarget {
                case let .item(item): state.rename(item.id, to: renameDraft)
                case let .canvas(board): state.renameCanvas(board.id, to: renameDraft)
                case nil: break
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private func beginRename(_ item: WorkspaceItem) {
        renameDraft = item.displayLabel
        renameTarget = .item(item)
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

            Button {
                showNewPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("New chat, terminal, or canvas")
            .contextMenu {
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
            }
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
    var onRename: ((WorkspaceItem) -> Void)?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 8) {
            if case let .assistant(provider) = item.kind {
                BrandIcon(provider: provider, size: 18)
            } else if let provider = item.terminalFlavor?.provider {
                // Agent terminal: brand emblem with a small terminal badge.
                BrandIcon(provider: provider, size: 18)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(1.5)
                            .background(Circle().fill(.background))
                            .offset(x: 4, y: 4)
                    }
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
            Button("Rename…") { onRename?(item) }
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
            Divider()
            Button("Delete", role: .destructive) {
                confirmDelete = true
            }
        }
        .confirmationDialog("Delete “\(item.displayLabel)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { state.deleteItem(item.id) }
        } message: {
            Text(item.isChat ? "The conversation and its history will be removed." : "The running session will end.")
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
