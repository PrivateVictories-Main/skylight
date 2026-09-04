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
    @AppStorage(Appearance.backgroundKey) private var windowBackground = "glass"
    @Environment(\.openSettings) private var openSettings
    // Reduce Transparency outranks the stored choice, live: flipping it in
    // System Settings solidifies the window without a relaunch.
    @State private var reduceTransparency = Appearance.reduceTransparency

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248)
        } detail: {
            DetailView()
        }
        .allowsHitTesting(!state.switcherShown)
        .accessibilityHidden(state.switcherShown)
        .environment(\.sidebarCollapsed, columnVisibility == .detailOnly)
        .frame(minWidth: 1080, minHeight: 700)
        .background(WindowBlur(glass: windowBackground == "glass" && !reduceTransparency)
            .ignoresSafeArea())
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceTransparency = Appearance.reduceTransparency
        }
        // Debug hook, screenshot lane: ⌘, is a click automation can't send,
        // and the supported route to the Settings scene is this environment
        // action — which only exists inside a scene's view tree.
        .onAppear {
            if ProcessInfo.processInfo.environment["SKYLIGHT_OPEN_SETTINGS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { openSettings() }
            }
        }
        // Owned by the split view, not the sidebar: a collapsed sidebar must
        // never strand ⌘T with nowhere to present.
        .onChange(of: state.newSheetShown) { _, shown in
            if shown && state.switcherShown { state.cancelWorkspaceSwitch() }
        }
        .sheet(isPresented: $state.newSheetShown) {
            NewTerminalSheet().environmentObject(state)
        }
        .overlay {
            if state.switcherShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { state.cancelWorkspaceSwitch() }
                    WorkspaceSwitcher()
                        .environmentObject(state)
                        .onDisappear {
                            // Finish after the native field editor has detached;
                            // its teardown would otherwise clear terminal focus.
                            DispatchQueue.main.async { state.completeWorkspaceSwitch() }
                        }
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                        .padding(.top, 72)
                }
                // Search opens and closes in the same window without a sheet
                // animation swallowing the first keystrokes of the next command.
                .transaction { $0.disablesAnimations = true }
            }
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
            // ⌘N is the platform's most reflexive shortcut; on a
            // single-window app it would otherwise be dead air. Both it and
            // ⌘T land on the sheet — the menu keeps advertising ⌘T.
            Button("New Terminal") { state.newSheetShown = true }
                .keyboardShortcut("n", modifiers: [.command])
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
                    // Two deliberate lines — a hint that truncates is a
                    // rough edge, not a hint.
                    Text("⌘T new terminal\n⇧⌘T instant shell")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
            if state.canvases.isEmpty {
                // The product's whole story, gone the moment a canvas
                // exists. Explicit break: List rows truncate rather than
                // wrap, fixedSize or not.
                Text("Drag a terminal here\nto start a canvas")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("Skylight")
        .alert("Rename “\(renameTargetName)”", isPresented: Binding(
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
            // A cleared field silently no-oped; disabled says so up front.
            .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var renameTargetName: String {
        switch renameTarget {
        case let .instance(instance): instance.name
        case let .canvas(board): board.name
        case nil: ""
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
                    .accessibilityLabel("New Terminal")
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
            // The session id, not the item id: a cancelled drag's token can
            // deinit DURING the next drag of the same row, and an item
            // comparison would let it tear that live drag down.
            let session = state.beginSidebarDrag(instance.id)
            token.onEnd = {
                if AppState.shared?.dragSession == session {
                    AppState.shared?.endSidebarDrag()
                }
            }
            return token
        }
        .contextMenu { menu }
        .confirmationDialog("Delete “\(instance.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { state.deleteInstance(instance.id) }
        } message: {
            // A dead session must not be deleted under a live one's warning.
            Text(state.endedInstances.contains(instance.id)
                ? "The session has already ended."
                : "The running session will end.")
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
                if state.endedInstances.contains(instance.id) {
                    Text("Session ended")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let terminal = state.sessions.existingTerminal(for: instance.id) {
                    if instance.spec.kind == .shell {
                        // A shell's useful second line is where it IS — and
                        // its live title when it cannot say (bash, or a zsh
                        // before its first prompt).
                        CwdCaption(terminal: terminal, maxLength: 30,
                                   fallbackName: instance.name)
                    } else {
                        TitleCaption(name: instance.name, terminal: terminal)
                    }
                }
            }
            Spacer(minLength: 4)
            // An agent's row says what it is DOING; a shell's says nothing,
            // because "Working / Needs you" is not a question a shell answers.
            // The bell's pulsing accent dot survives unchanged as the
            // waitingForYou case — it was the right design, it just had no
            // vocabulary around it.
            if state.attention.contains(instance.id) {
                AttentionDot()
            } else if let agent = state.agentState(instance.id), agent != .idle {
                StateDot(state: agent)
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

    /// The vendor mark, or nil for a shell — asked of the instance's KIND
    /// rather than by unwrapping a raw harness id.
    private var harnessBrand: Brand? {
        Catalog.harness(for: instance.spec.kind)?.brand
    }

    /// Where this row sits in the Terminals section, for the reorder commands.
    private var freeIndex: Int? {
        state.freeInstances.firstIndex { $0.id == instance.id }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…") { onRename?(instance) }
        if state.endedInstances.contains(instance.id) {
            // The one thing a dead session is still good for.
            Button("Restart Session") { state.restartInstance(instance.id) }
        }
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
            // Ordering is a command, not a gesture: a row's drag already
            // means "put this on a canvas", and one drag cannot mean two
            // things. See moveFreeInstances.
            if state.freeInstances.count > 1 {
                Divider()
                Button("Move Up") { state.moveFreeInstance(instance.id, by: -1) }
                    .disabled(freeIndex == 0)
                Button("Move Down") { state.moveFreeInstance(instance.id, by: 1) }
                    .disabled(freeIndex == state.freeInstances.count - 1)
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

    private var residentCount: Int { state.residents(of: board).count }

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
            Text("\(residentCount)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .accessibilityLabel(residentCount == 1
                    ? "1 terminal" : "\(residentCount) terminals")
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

/// What an agent terminal is doing, as a dot. Deliberately quiet: only the
/// bell earns a pulse, everything else is a still mark you can read at a
/// glance or ignore entirely.
struct StateDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AgentState
    @State private var breathing = false

    /// Only the mapping from tone to a platform colour lives here; which
    /// tone a state deserves is decided in SkylightCore, where it is tested.
    private var color: Color {
        switch state.tone {
        case .accent: .accentColor
        case .active: .green
        case .muted: .secondary
        }
    }

    var body: some View {
        Circle()
            .fill(color.opacity(state.dotOpacity))
            .frame(width: 6, height: 6)
            // Working breathes, faintly. A dead or finished session must not
            // — motion implies something is happening.
            .opacity(state.isLive && breathing && !reduceMotion ? 0.45 : 1)
            .animation(state.isLive && !reduceMotion
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
                value: breathing)
            .onAppear { breathing = state.isLive && !reduceMotion }
            .onChange(of: state) { _, new in
                breathing = new.isLive && !reduceMotion
            }
            .help(state.label)
            .accessibilityLabel(state.label)
    }
}

/// A soft pulsing dot marking a terminal whose bell rang — it's done or
/// waiting for you — until you open it.
struct AttentionDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .shadow(color: Color.accentColor.opacity(0.7),
                    radius: pulse && !reduceMotion ? 3.5 : 1)
            .scaleEffect(pulse && !reduceMotion ? 1.15 : 0.9)
            // A forever-repeating breath is the one motion Reduce Motion most
            // wants gone, and it cannot be re-timed into honesty — so it is
            // simply not started. The dot still marks the terminal; it just
            // sits still. Three parts, because each covers a different moment:
            // the visuals above read `reduceMotion` directly, so a mid-pulse
            // flip lands the dot back at rest instead of wherever the breath
            // had it; keying `value:` off a constant leaves the repeating
            // animation nothing to attach to; and resting `pulse` at false
            // means it never starts in the first place.
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: reduceMotion ? false : pulse)
            .onAppear { pulse = !reduceMotion }
            .help("This session finished or needs your input")
            .accessibilityLabel("Needs attention")
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
        .animation(Motion.viewport, value: state.focusedInstance)
        // With the sidebar hidden its bottom-bar handle goes with it. The 30pt
        // band the content already steps below becomes a DELIBERATE slim bar —
        // material, hairline edge, window controls at home on it — not a raw
        // slab of leftover container backing. It doubles as the drag handle.
        .overlay(alignment: .top) {
            if sidebarCollapsed {
                WindowDragArea()
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 0.5)
                    }
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: sidebarCollapsed)
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
            "Nothing Selected",
            systemImage: "terminal",
            description: Text("Select a terminal or canvas in the sidebar, or press ⌘T for a new terminal.")
        )
        .toolbarBackground(.hidden, for: .windowToolbar)
        .padding(.top, sidebarCollapsed ? 30 : 0)
        .ignoresSafeArea(edges: .top)
        .animation(.easeOut(duration: 0.22), value: sidebarCollapsed)
    }
}

/// The full-window terminal dress: terminal-toned rounded backing, hard clip,
/// hairline outline, missing-harness banner, and the breathing inset that
/// tracks the sidebar. ONE definition — the no-sharp-edges rule is structural
/// here, not a chain two views have to remember to keep identical. Anything
/// that fills the detail pane with a terminal wears this and nothing else.
private struct TerminalPanel: ViewModifier {
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    /// The backing and hairline are read THROUGH this object, so removing it
    /// fails the build instead of quietly restoring stale chrome.
    @ObservedObject private var themes = ThemeStore.shared
    // The backing tracks the surface's own translucency: ghostty's
    // background-opacity composites OVER this layer, so a slider that only
    // thinned the surface would still hit a near-solid backing and read as
    // dead. Same stored value, both layers, and the glass actually arrives.
    @AppStorage(Appearance.terminalOpacityKey)
    private var terminalOpacity = Appearance.terminalOpacityDefault
    @State private var reduceTransparency = Appearance.reduceTransparency
    let instance: TerminalInstance

    private var backingOpacity: Double {
        guard !reduceTransparency else { return 1.0 }
        return min(max(terminalOpacity, Appearance.terminalOpacityRange.lowerBound),
                   Appearance.terminalOpacityRange.upperBound)
    }

    func body(content: Content) -> some View {
        content
            // Text rides to the very top, Ghostty-style: the terminal NSView
            // handles its own mouseDown, so AppKit yields the titlebar band
            // to it instead of dragging the window (drag by the sidebar).
            .background(themes.panelBacking.opacity(backingOpacity),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                reduceTransparency = Appearance.reduceTransparency
            }
            // Hard clip on top of the layer mask: ghostty's Metal surface is
            // sized in whole cells and overhangs a few pixels on the right —
            // the layer mask misses that sliver, this catches it.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(themes.hairline(opacity: 0.20), lineWidth: 0.5)
            )
            .overlay(alignment: .top) { SurfaceBanners(instance: instance) }
            // A sliver of window glass around all four sides so the hairline
            // outline reads, sidebar-row style. Six points, not four: the
            // window's own corner mask must clear our corners or it slices
            // them — R_window − inset ≤ R_panel, sized for this OS's rounder
            // windows: inset 8 + radius 16 nests under radii up to 24.
            .padding(8)
            // The traffic lights ride over the sidebar column, so the detail
            // side can own every pixel of height — no dead band up top. In
            // focus mode the panel's own header IS the chrome, so neither
            // caller ever wants a toolbar band.
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

extension View {
    /// Wear the full-window terminal panel. The banner reads the instance, so
    /// the panel needs to know whose terminal it is dressing.
    fileprivate func terminalPanel(for instance: TerminalInstance) -> some View {
        modifier(TerminalPanel(instance: instance))
    }
}

/// Full-window view of a single instance.
struct FullInstanceView: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance

    var body: some View {
        PreparedTerminalView(sessions: state.sessions, instance: instance,
                               cornerRadius: 16)
            .terminalPanel(for: instance)
    }
}

/// Focus mode: one canvas tile borrows the whole window. ⌘., the header's Back
/// chip, or a double-click on the header hands it back — the canvas is exactly
/// as you left it. The terminal eats Escape (vim and TUIs need it), so the menu
/// command is the real exit; `.onExitCommand` only fires in the rare case
/// nothing consumed the key.
struct FocusView: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance

    var body: some View {
        VStack(spacing: 0) {
            header
            // cornerRadius 0: the VStack is clipped as one shape by the panel,
            // and a second rounding on the terminal's own layer would
            // double-round the bottom corners.
            PreparedTerminalView(sessions: state.sessions, instance: instance,
                                   cornerRadius: 0)
        }
        // Header and terminal wear ONE panel — clipped, stroked, and inset as
        // a single shape, the same dress FullInstanceView's bare terminal gets.
        .terminalPanel(for: instance)
        // Outside the panel now rather than mid-chain: the exit command is a
        // keyboard route, so nothing the panel does between here and the
        // content changes whether it fires.
        .onExitCommand { state.endFocus() }
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

/// The surface's two honest-state capsules, one slot: a session whose
/// process ended outranks a launch-time fallback note — it is the state
/// with an action attached.
struct SurfaceBanners: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance

    var body: some View {
        if state.endedInstances.contains(instance.id) {
            SessionEndedBanner(instance: instance)
        } else if let harness = Catalog.harness(for: instance.spec.kind),
                  // Only when the surface actually GOT its harness — a
                  // fallback shell's problem is the missing CLI, not its auth.
                  state.sessions.launchOutcome(for: instance.id)?.missingHarness == nil,
                  // Never over the sign-in terminal itself. Telling someone
                  // they are not signed in, on top of the window where they
                  // are in the middle of signing in, is the app arguing with
                  // its own advice.
                  !state.isSignInTerminal(instance.id),
                  let message = SubscriptionCopy.bannerMessage(
                    for: harness, state: state.subscriptionState(harness.id)) {
            SignedOutBanner(instance: instance, harness: harness, message: message)
        } else {
            MissingHarnessBanner(instance: instance)
        }
    }
}

/// Without this, an ended session's surface would pose: frozen scrollback,
/// a keyboard that goes nowhere, and the truth hiding in a sidebar caption.
/// Same capsule as the missing-harness banner — a second tenant of an
/// existing pattern — plus the one affordance a dead session has.
struct SessionEndedBanner: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance

    var body: some View {
        HStack(spacing: 10) {
            Text("Session ended")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Button("Restart") { state.restartInstance(instance.id) }
                .buttonStyle(.pressable(scale: 0.95))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.bar))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .padding(.top, 8)
    }
}

/// A running agent terminal whose CLI is signed out. Same capsule as the
/// other two banners — a third tenant of the pattern — with the one
/// affordance that helps: the vendor's own login, in a terminal.
struct SignedOutBanner: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance
    let harness: Harness
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let spec = SubscriptionCopy.signInSpec(for: harness) {
                Button("Sign in") { state.launchSignIn(spec, harness: harness) }
                    .buttonStyle(.pressable(scale: 0.95))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.bar))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .padding(.top, 8)
    }
}

/// Honest state for a terminal whose configured CLI or shell was missing at
/// LAUNCH: the surface fell back (LiveSessionStore already did), and this
/// banner says so instead of failing silently. It reads the outcome recorded
/// when the surface was configured — not live install state, which changes
/// under a running session: installing the CLI afterwards must not erase the
/// truth that THIS surface is a fallback shell, and uninstalling one must
/// not hang a false banner on a healthy running agent.
struct MissingHarnessBanner: View {
    @EnvironmentObject private var state: AppState
    let instance: TerminalInstance

    private var message: String? {
        guard let outcome = state.sessions.launchOutcome(for: instance.id) else { return nil }
        if let id = outcome.missingHarness {
            let harness = Catalog.harness(id)
            let name = harness?.displayName ?? id
            let install = harness.map { " Install: \($0.installCommand)" } ?? ""
            return "\(name) isn't installed — running your shell.\(install)"
        }
        if let shell = outcome.missingShell {
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

/// Where a terminal currently IS, for a tile header.
///
/// Its own view purely to hold the `@ObservedObject`: the working directory
/// belongs to the terminal, not to AppState, so a header that read it inline
/// would render once and then freeze — the same reason `TitleCaption` exists.
///
/// Nothing here spawns anything: callers pass a terminal that has already
/// been opened.
struct CwdCaption: View {
    @ObservedObject var terminal: TerminalViewState
    var maxLength = 28
    /// The name to compare a title against, so a caption never just repeats
    /// the row's own label back at it.
    var fallbackName: String?

    private var cwd: String? {
        guard let cwd = terminal.workingDirectory else { return nil }
        return Titles.abbreviatedPath(
            cwd,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            maxLength: maxLength)
    }

    /// The live title, which is what this line showed before directories
    /// existed. Kept as the fallback because bash gets no shell integration
    /// and a zsh shows nothing until its first prompt — replacing the title
    /// outright left both of them staring at a blank line where they used to
    /// have information. A regular terminal must never come out of a wave
    /// worse off than it went in.
    private var title: String? {
        let title = terminal.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != fallbackName else { return nil }
        return title
    }

    var body: some View {
        if let text = cwd ?? title {
            Text(text)
                .font(.system(size: 10.5,
                              design: cwd == nil ? .default : .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(cwd == nil ? .tail : .head)
                .help(terminal.workingDirectory ?? terminal.title)
        }
    }
}

/// The last command's cost, when it cost anything worth saying.
///
/// A non-zero exit is the part people actually want and terminals usually
/// bury — the badge says so plainly rather than making someone scroll back
/// to find it.
struct CommandResultBadge: View {
    @ObservedObject var terminal: TerminalViewState

    private var failed: Bool {
        (terminal.lastCommandExitCode ?? 0) != 0
    }

    private var duration: String? {
        terminal.lastCommandDurationNanos.flatMap(Titles.duration(nanos:))
    }

    var body: some View {
        // A FAILURE is worth saying however fast it was. It was nested inside
        // the duration, which is suppressed below half a second — so
        // `cat missing` failing in 4ms, the most common failure shape there
        // is, showed nothing at all. The duration threshold exists to stop
        // clutter, not to hide the one thing worth reporting.
        if failed || duration != nil {
            HStack(spacing: 3) {
                if failed, let code = terminal.lastCommandExitCode {
                    Text("exit \(code)")
                        .foregroundStyle(.red.opacity(0.85))
                }
                if let duration {
                    Text(duration)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .help(failed ? "The last command failed" : "How long the last command took")
        }
    }
}

/// Hosts the store-owned terminal NSView. The ghostty surface (and its shell
/// process) lives exactly as long as the store keeps the view — navigation
/// only reparents it.
///
/// The container indirection is the double-hosting defense. During an
/// animated branch swap (entering focus, the drop overlay fading out after a
/// drop) TWO representables briefly exist for the SAME terminal NSView, and
/// an NSView renders in exactly one hierarchy: whoever called `addSubview`
/// last owns it, and SwiftUI dismantling the loser used to be able to rip the
/// view out of the winner. Each representable now owns a plain container;
/// `claim()` re-parents the shared view into whichever container needs it,
/// dismantle removes only the dying container, and the reclaim notification
/// wakes the survivor to take the view back. Self-healing by construction.
struct PreparedTerminalView: View {
    @ObservedObject var sessions: LiveSessionStore
    let instance: TerminalInstance
    var cornerRadius: CGFloat = 0
    var maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                       .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    var body: some View {
        Group {
            if sessions.isReady {
                PersistentTerminalView(view: sessions.terminalHostView(for: instance),
                                       cornerRadius: cornerRadius,
                                       maskedCorners: maskedCorners,
                                       focusRequested: sessions.requestedFocusID == instance.id,
                                       onFocusAcquired: { sessions.didAcquireKeyboardFocus(instance.id) })
            } else {
                SessionPreparationView(issue: sessions.preparationIssue,
                                       retry: sessions.retryPreparation)
            }
        }
        // Readiness is not a layout animation: replay must land at the final
        // grid size, including when a parent is animating a navigation change.
        .transaction { $0.animation = nil }
    }
}

struct PersistentTerminalView: NSViewRepresentable {
    let view: TerminalView
    /// Rounding lives on the terminal's OWN layer, not a SwiftUI clip: a
    /// SwiftUI mask lags the Metal surface during live resize and slices the
    /// corners; the AppKit layer mask moves atomically with the view.
    var cornerRadius: CGFloat = 0
    var maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                       .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    var focusRequested = false
    var onFocusAcquired: () -> Void = {}

    func makeNSView(context: Context) -> TerminalHostContainer {
        let container = TerminalHostContainer()
        container.hosted = view
        container.focusRequested = focusRequested
        container.onFocusAcquired = onFocusAcquired
        applyRounding(view)
        container.claim()
        return container
    }

    func updateNSView(_ container: TerminalHostContainer, context: Context) {
        container.hosted = view
        container.focusRequested = focusRequested
        container.onFocusAcquired = onFocusAcquired
        applyRounding(view)
        container.claim()
    }

    static func dismantleNSView(_ container: TerminalHostContainer, coordinator: ()) {
        // The dying host must never claim again — and whoever still wants the
        // view gets a deterministic chance to take it back, next runloop turn
        // (the view may still be this container's subview until AppKit
        // finishes the removal).
        container.hosted = nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: TerminalHostContainer.reclaim, object: nil)
        }
    }

    private func applyRounding(_ v: TerminalView) {
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.maskedCorners = maskedCorners
        v.layer?.masksToBounds = cornerRadius > 0
    }
}

/// The claiming container behind PersistentTerminalView.
final class TerminalHostContainer: NSView {
    static let reclaim = Notification.Name("SkylightReclaimTerminalHosts")

    weak var hosted: NSView?
    var focusRequested = false
    var onFocusAcquired: () -> Void = {}
    private let observer = ObserverBox()

    /// Nonisolated, Sendable storage for the notification token — a deinit
    /// runs outside the main actor's guarantees (same pattern as PanView's
    /// MonitorBox).
    private final class ObserverBox: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
        var sheetToken: (any NSObjectProtocol)?
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observer.token = NotificationCenter.default.addObserver(
            forName: Self.reclaim, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.claim() }
        }
        observer.sheetToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // SwiftUI's onDismiss can precede AppKit clearing attachedSheet.
            // Retry on that lifecycle event instead of guessing a delay.
            DispatchQueue.main.async { self?.claim() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let token = observer.token {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = observer.sheetToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func claim() {
        // Only a container that is actually ON SCREEN may take the view — a
        // live-but-unparented host answering the reclaim broadcast would
        // otherwise steal the terminal into an invisible hierarchy.
        guard window != nil, let hosted else { return }
        if hosted.superview !== self {
            hosted.removeFromSuperview()
            hosted.frame = bounds
            hosted.autoresizingMask = [.width, .height]
            addSubview(hosted)
        } else {
            hosted.frame = bounds
        }
        if focusRequested, let window, window.attachedSheet == nil,
           window.makeFirstResponder(hosted) {
            focusRequested = false
            let acquired = onFocusAcquired
            DispatchQueue.main.async { acquired() }
        }
    }

    override func layout() {
        super.layout()
        claim()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { claim() }
    }
}

/// The whole window carries a soft blur so the app reads as one piece of
/// glass — sidebar, canvas, and terminals all sit on it. Or none of it does:
/// the Settings choice flips the window between glass and a standard solid
/// background, live, because the choice is the WINDOW's — flipping opacity
/// here also turns the sidebar's own material flat, which no overlay painted
/// on top of the blur could ever do.
struct WindowBlur: NSViewRepresentable {
    var glass = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentWindowEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.glass = glass
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        (nsView as? TransparentWindowEffectView)?.glass = glass
    }
}

/// A behind-window blur only samples the desktop once the hosting window
/// stops painting an opaque backing behind it — and stops sampling the
/// moment that backing returns.
private final class TransparentWindowEffectView: NSVisualEffectView {
    var glass = true {
        didSet { if glass != oldValue { applyBackground() } }
    }

    private func applyBackground() {
        guard let window else { return }
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : .windowBackgroundColor
        isHidden = !glass
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground()
        // The window moves like any macOS window — titlebar band, plus the
        // explicit handles (sidebar bottom bar, collapsed-sidebar top strip).
        // Tile drags are protected surgically instead: CanvasView flips
        // isMovable off for exactly the duration of a tile gesture, via this
        // reference. A blanket isMovable=false shipped once and made moving
        // the window a hunt — never again.
        window?.isMovable = true
        MainActor.assumeIsolated {
            AppState.shared?.hostWindow = window
        }
    }
}

/// A region that always moves the window: grab any empty part of it and drag
/// — works even where the titlebar band doesn't reach.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
