import SwiftUI
import GhosttyTerminal
import SkylightCore

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
    case instance(TerminalInstance)
    case canvas(CanvasBoard)

    var id: UUID {
        switch self {
        case let .instance(instance): instance.id
        case let .canvas(board): board.id
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var renameTarget: RenameTarget?
    @State private var renameDraft = ""

    var body: some View {
        List(selection: $state.selection) {
            Section {
                ForEach(state.freeInstances) { instance in
                    InstanceRow(instance: instance, onRename: beginRename)
                }
                if state.freeInstances.isEmpty {
                    Text("⌘T opens a new terminal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                // Dropping a canvas-resident row here frees it again.
                Text("Terminals")
                    .dropDestination(for: String.self) { ids, _ in
                        for raw in ids {
                            guard let id = UUID(uuidString: raw) else { continue }
                            state.removeFromCanvas(id)
                        }
                        return true
                    }
            }
            ForEach(state.canvases) { board in
                Section {
                    CanvasRow(board: board, onRename: beginRenameCanvas)
                    ForEach(state.residents(of: board)) { instance in
                        InstanceRow(instance: instance, resident: true, onRename: beginRename)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Skylight")
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                switch renameTarget {
                case let .instance(instance): state.rename(instance.id, to: renameDraft)
                case let .canvas(board): state.renameCanvas(board.id, to: renameDraft)
                case nil: break
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private func beginRename(_ instance: TerminalInstance) {
        renameDraft = instance.name
        renameTarget = .instance(instance)
    }

    private func beginRenameCanvas(_ board: CanvasBoard) {
        renameDraft = board.name
        renameTarget = .canvas(board)
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button {
                state.launch(TerminalSpec())
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("New Terminal (⌘T)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

// MARK: - Rows

struct InstanceRow: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance
    /// True when the row lives under a canvas group in the sidebar.
    var resident = false
    var onRename: ((TerminalInstance) -> Void)?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if resident {
                // Resident rows open their canvas centered on the tile —
                // they are actions, not selection targets.
                Button { state.reveal(instance.id) } label: { label }
                    .buttonStyle(.plain)
            } else {
                label.tag(Selection.item(instance.id))
            }
        }
        .draggable(instance.id.uuidString)
        .contextMenu { menu }
        .confirmationDialog("Delete “\(instance.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { state.deleteInstance(instance.id) }
        } message: {
            Text("The running session will end.")
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            icon
            if let terminal = state.sessions.existingTerminal(for: instance.id) {
                TerminalRowLabel(instance: instance, terminal: terminal)
            } else {
                Text(instance.name)
            }
            if state.attention.contains(instance.id) {
                Spacer(minLength: 4)
                AttentionDot()
            }
        }
        .padding(.vertical, 1)
        .padding(.leading, resident ? 10 : 0)
    }

    @ViewBuilder
    private var icon: some View {
        if let brand = harnessBrand {
            // Agent terminal: brand emblem with a small terminal badge.
            BrandIcon(brand: brand, size: 18)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(1.5)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: 4)
                }
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    private var harnessBrand: Brand? {
        instance.spec.harness.flatMap { id in
            Catalog.harnesses.first { $0.id == id }?.brand
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…") { onRename?(instance) }
        Divider()
        if resident {
            Button("Remove from Canvas") { state.removeFromCanvas(instance.id) }
            if state.canvases.count > 1 {
                Menu("Move to Canvas") {
                    ForEach(state.canvases.filter { board in
                        !board.tiles.contains { $0.itemID == instance.id }
                    }) { board in
                        Button(board.name) {
                            state.addTile(itemID: instance.id, to: board.id, at: nil)
                        }
                    }
                }
            }
        } else {
            Button("Add to New Canvas") {
                state.addTile(itemID: instance.id, to: nil, at: nil)
            }
            if !state.canvases.isEmpty {
                Menu("Add to Canvas") {
                    ForEach(state.canvases) { board in
                        Button(board.name) {
                            state.addTile(itemID: instance.id, to: board.id, at: nil)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { confirmDelete = true }
    }
}

struct CanvasRow: View {
    @EnvironmentObject private var state: AppState
    let board: CanvasBoard
    let onRename: (CanvasBoard) -> Void
    @State private var confirmDelete = false

    var body: some View {
        Label(board.name, systemImage: "square.on.square.dashed")
            .font(.system(size: 13, weight: .semibold))
            .tag(Selection.canvas(board.id))
            .dropDestination(for: String.self) { ids, _ in
                for raw in ids {
                    guard let id = UUID(uuidString: raw) else { continue }
                    state.addTile(itemID: id, to: board.id, at: nil)
                }
                return true
            }
            .contextMenu {
                Button("Rename…") { onRename(board) }
                Divider()
                Button("Delete Canvas", role: .destructive) { confirmDelete = true }
            }
            .confirmationDialog("Delete “\(board.name)”?", isPresented: $confirmDelete) {
                Button("Delete Canvas", role: .destructive) { state.deleteCanvas(board.id) }
            } message: {
                Text("Its terminals return to the sidebar — nothing is closed.")
            }
    }
}

/// A soft pulsing dot marking a terminal whose bell rang — it's done or
/// waiting for you — until you open it.
struct AttentionDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .shadow(color: Color.accentColor.opacity(0.7), radius: pulse ? 3.5 : 1)
            .scaleEffect(pulse ? 1.15 : 0.9)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .help("This session finished or needs your input")
    }
}

/// Terminal row with a live activity caption from ghostty's reported title —
/// glance at the sidebar and see what every session is doing.
struct TerminalRowLabel: View {
    let instance: TerminalInstance
    @ObservedObject var terminal: TerminalViewState

    private var activity: String? {
        let title = terminal.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != instance.name else { return nil }
        return title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(instance.name)
            if let activity {
                Text(activity)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.selection {
        case let .item(id):
            if let instance = state.instance(id) {
                FullInstanceView(instance: instance)
                    .id(id)
            } else {
                EmptyDetail()
            }
        case let .canvas(id):
            if state.canvases.contains(where: { $0.id == id }) {
                CanvasView(boardID: id)
                    .id(id)
            } else {
                EmptyDetail()
            }
        case nil:
            EmptyDetail()
        }
    }
}

struct EmptyDetail: View {
    var body: some View {
        ContentUnavailableView(
            "No Terminal Selected",
            systemImage: "terminal",
            description: Text("Pick a terminal or canvas from the sidebar, or press ⌘T.")
        )
    }
}

/// Full-window view of a single instance.
struct FullInstanceView: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance

    var body: some View {
        PersistentTerminalView(view: state.sessions.terminalHostView(for: instance))
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(instance.name)
    }
}

/// Hosts the store-owned terminal NSView. The ghostty surface (and its shell
/// process) lives exactly as long as the store keeps the view — navigation
/// only reparents it.
struct PersistentTerminalView: NSViewRepresentable {
    let view: TerminalView

    func makeNSView(context: Context) -> TerminalView { view }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
