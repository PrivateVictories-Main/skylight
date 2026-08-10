import QuartzCore
import SwiftUI
import GhosttyTerminal
import SkylightCore

/// True while the sidebar is collapsed — the window controls then float over
/// the detail area, and content must step below them instead of underlapping.
private struct SidebarCollapsedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarCollapsed: Bool {
        get { self[SidebarCollapsedKey.self] }
        set { self[SidebarCollapsedKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248)
        } detail: {
            DetailView()
        }
        .environment(\.sidebarCollapsed, columnVisibility == .detailOnly)
        .frame(minWidth: 1080, minHeight: 700)
        .background(WindowBlur().ignoresSafeArea())
        // Owned by the split view, not the sidebar: a collapsed sidebar must
        // never strand ⌘T with nowhere to present.
        .sheet(isPresented: $state.newSheetShown) {
            NewTerminalSheet().environmentObject(state)
        }
        // ⌘= is what a US keyboard produces without reaching for shift, and it
        // is what hands expect for Zoom In. The menu keeps ⌘+ as its label;
        // this is a zero-sized shortcut mirror, not a control.
        .background {
            Button("Zoom In") { state.requestZoom(.zoomIn) }
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(!state.canvasZoomAvailable)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
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
                    Text("⌘T for a new terminal · ⇧⌘T for an instant shell")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
            } header: {
                // Dropping a canvas-resident row here frees it again. The
                // whole header row is the target, not just the word.
                HStack {
                    Text("Terminals")
                        // Same caption voice as the New sheet's tier headings,
                        // so the two surfaces read as one app.
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.6)
                    Spacer()
                }
                    .contentShape(Rectangle())
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
            Button {
                state.newSheetShown = true
            } label: {
                Label {
                    Text("New")
                } icon: {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }
                    .foregroundStyle(.primary)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14))
                    )
            }
            .buttonStyle(.pressable(scale: 0.97))
            .help("New Terminal (⌘T)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // The bottom bar doubles as the window's handle — always present while
        // the sidebar is open. Behind the chip, so New still clicks; the empty
        // band around it drags the window.
        .background(WindowDragArea())
        // No flat band behind the chip — it floats on the window glass, so
        // there is not a single square-cornered surface left in the sidebar.
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
        .onDrag {
            let token = DragToken(object: instance.id.uuidString as NSString)
            let id = instance.id
            token.onEnd = {
                if AppState.shared?.draggingItemID == id {
                    AppState.shared?.endSidebarDrag()
                }
            }
            state.beginSidebarDrag(id)
            return token
        }
        .contextMenu { menu }
        .confirmationDialog("Delete “\(instance.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { state.deleteInstance(instance.id) }
        } message: {
            Text("The running session will end.")
        }
    }

    private var label: some View {
        HStack(spacing: 9) {
            icon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(instance.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The caption's live updates come from the terminal's own
                // object, so the observation lives one view deeper — see
                // TitleCaption. Rendering a row still never spawns a process:
                // existingTerminal is non-creating.
                if let terminal = state.sessions.existingTerminal(for: instance.id) {
                    TitleCaption(name: instance.name, terminal: terminal)
                }
            }
            Spacer(minLength: 4)
            if state.attention.contains(instance.id) {
                AttentionDot()
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, resident ? 12 : 0)
    }

    @ViewBuilder
    private var icon: some View {
        if let brand = harnessBrand {
            // The bare official mark, no plate and no terminal badge: the mark
            // itself already says "agent", and anything under it reads as noise.
            BrandIcon(brand: brand, size: 16, filled: false)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
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
        HStack(spacing: 6) {
            // Split-init Label so the glyph can hold its own weight and tone:
            // the name is the loud part of a canvas row, the icon is not.
            Label {
                Text(board.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold))
            Spacer()
            // How many tiles are parked on this board — the one number you
            // want from a collapsed glance at the sidebar.
            Text("\(state.residents(of: board).count)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
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

/// The row's second line: a live activity caption from ghostty's reported
/// title — glance at the sidebar and see what every session is doing. It is
/// its own view purely to hold the `@ObservedObject`; the terminal's title
/// belongs to the terminal, not to AppState, so a row that read it inline
/// would render once and then freeze.
struct TitleCaption: View {
    let name: String
    @ObservedObject var terminal: TerminalViewState

    private var activity: String? {
        let title = terminal.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != name else { return nil }
        return title
    }

    var body: some View {
        if let activity {
            Text(activity)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    var body: some View {
        ZStack {
            if let focusID = state.focusedInstance, let instance = state.instance(focusID) {
                FocusView(instance: instance)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                base
            }
            if let dragID = state.draggingItemID {
                CanvasDropOverlay(itemID: dragID)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.draggingItemID)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.focusedInstance)
        // With the sidebar hidden its bottom-bar handle goes with it. The 30pt
        // band the content already steps below is empty by design — so it
        // becomes the handle, and the window is never without one.
        .overlay(alignment: .top) {
            if sidebarCollapsed {
                WindowDragArea()
                    .frame(height: 30)
                    .ignoresSafeArea(edges: .top)
            }
        }
    }

    @ViewBuilder
    private var base: some View {
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
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    var body: some View {
        ContentUnavailableView(
            "No Terminal Selected",
            systemImage: "terminal",
            description: Text("Pick a terminal or canvas from the sidebar, or press ⌘T.")
        )
        .toolbarBackground(.hidden, for: .windowToolbar)
        .padding(.top, sidebarCollapsed ? 30 : 0)
        .ignoresSafeArea(edges: .top)
        .animation(.easeOut(duration: 0.22), value: sidebarCollapsed)
    }
}

/// Full-window view of a single instance.
struct FullInstanceView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    let instance: TerminalInstance

    var body: some View {
        PersistentTerminalView(view: state.sessions.terminalHostView(for: instance),
                               cornerRadius: 16)
            // Text rides to the very top, Ghostty-style: the terminal NSView
            // handles its own mouseDown, so AppKit yields the titlebar band
            // to it instead of dragging the window (drag by the sidebar).
            .background(Color(nsColor: .textBackgroundColor).opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Hard clip on top of the layer mask: ghostty's Metal surface is
            // sized in whole cells and overhangs a few pixels on the right —
            // the layer mask misses that sliver, this catches it.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.20), lineWidth: 0.5)
            )
            .overlay(alignment: .top) { MissingHarnessBanner(instance: instance) }
            // A sliver of window glass around all four sides so the hairline
            // outline reads, sidebar-row style. Six points, not four: the
            // window's own corner mask must clear our corners or it slices
            // them — R_window − inset ≤ R_panel, sized for this OS's rounder
            // windows: inset 8 + radius 16 nests under radii up to 24.
            .padding(8)
            // The traffic lights ride over the sidebar column, so the detail
            // side can own every pixel of height — no dead band up top.
            .toolbarBackground(.hidden, for: .windowToolbar)
            // Collapsed sidebar = traffic lights float over the detail area;
            // step below them, reclaim the top when the sidebar returns. An
            // animatable inset rather than a safe-area flip: the content
            // travels WITH the sidebar's slide instead of snapping at its end.
            .padding(.top, sidebarCollapsed ? 30 : 0)
            .ignoresSafeArea(edges: .top)
            .animation(.easeOut(duration: 0.22), value: sidebarCollapsed)
    }
}

/// Focus mode: one canvas tile borrows the whole window. ⌘., the header's Back
/// chip, or a double-click on the header hands it back — the canvas is exactly
/// as you left it. The terminal eats Escape (vim and TUIs need it), so the menu
/// command is the real exit; `.onExitCommand` only fires in the rare case
/// nothing consumed the key.
struct FocusView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    let instance: TerminalInstance

    var body: some View {
        VStack(spacing: 0) {
            header
            // cornerRadius 0: the VStack is clipped as one shape below, and a
            // second rounding on the terminal's own layer would double-round
            // the bottom corners.
            PersistentTerminalView(view: state.sessions.terminalHostView(for: instance),
                                   cornerRadius: 0)
        }
        // Same chain as FullInstanceView: terminal-toned fill, hard clip for
        // ghostty's whole-cell overhang, hairline outline, glass margin.
        .background(Color(nsColor: .textBackgroundColor).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.20), lineWidth: 0.5)
        )
        .overlay(alignment: .top) { MissingHarnessBanner(instance: instance) }
        .padding(8)
        .onExitCommand { state.endFocus() }
        // No toolbar band: the header IS the chrome, and it belongs to the
        // panel rather than floating over the text.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .padding(.top, sidebarCollapsed ? 30 : 0)
        .ignoresSafeArea(edges: .top)
        .animation(.easeOut(duration: 0.22), value: sidebarCollapsed)
    }

    /// A slim bar the width of the panel — nothing ever sits on top of the
    /// terminal's text, the way the old floating Back button did.
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                state.endFocus()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Canvas")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable(scale: 0.95))
            .help("Back to the canvas (⌘.)")
            Text(instance.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.endFocus() }
    }
}

/// Honest state for a terminal whose configured CLI or shell has vanished:
/// the surface falls back to the login shell (LiveSessionStore already
/// does), and this banner says so instead of failing silently.
struct MissingHarnessBanner: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance

    private var message: String? {
        if let id = instance.spec.harness,
           state.sessions.cachedResolveHarness(id) == nil {
            let harness = Catalog.harnesses.first { $0.id == id }
            let name = harness?.displayName ?? id
            let install = harness.map { " Install: \($0.installCommand)" } ?? ""
            return "\(name) isn't installed — running your shell.\(install)"
        }
        if let shell = instance.spec.shellPath,
           !FileManager.default.isExecutableFile(atPath: shell) {
            return "\((shell as NSString).lastPathComponent) is gone — running your login shell."
        }
        return nil
    }

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.bar))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }
}

/// Hosts the store-owned terminal NSView. The ghostty surface (and its shell
/// process) lives exactly as long as the store keeps the view — navigation
/// only reparents it.
struct PersistentTerminalView: NSViewRepresentable {
    let view: TerminalView
    /// Rounding lives on the terminal's OWN layer, not a SwiftUI clip: a
    /// SwiftUI mask lags the Metal surface during live resize and slices the
    /// corners; the AppKit layer mask moves atomically with the view.
    var cornerRadius: CGFloat = 0
    var maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                       .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    func makeNSView(context: Context) -> TerminalView {
        applyRounding(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        applyRounding(nsView)
    }

    private func applyRounding(_ v: TerminalView) {
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.maskedCorners = maskedCorners
        v.layer?.masksToBounds = cornerRadius > 0
    }
}

/// The whole window carries a soft blur so the app reads as one piece of
/// glass — sidebar, canvas, and terminals all sit on it.
struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentWindowEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A behind-window blur only samples the desktop once the hosting window
/// stops painting an opaque backing behind it.
private final class TransparentWindowEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
        // The window never moves itself. Without this, AppKit's titlebar band
        // (invisible here, but still a drag region) steals the first inches of
        // every tile drag near the top of the canvas and walks the window
        // instead. Two explicit handles replace it — the sidebar's bottom bar,
        // and a strip across the reserved top band when the sidebar is hidden
        // — so there is always exactly one place that moves the window.
        window?.isMovable = false
    }
}

/// A region that moves the window: grab any empty part of it and drag (the
/// canvas never moves the window — tiles always win there).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // The window is deliberately immovable so the canvas can never
            // walk it; lend it movability for exactly this drag. performDrag
            // tracks the mouse modally and returns on mouse-up, so the loan
            // is over by the next line.
            let wasMovable = window.isMovable
            window.isMovable = true
            window.performDrag(with: event)
            window.isMovable = wasMovable
        }
    }
}
