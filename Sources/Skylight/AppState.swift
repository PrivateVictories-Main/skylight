import AppKit
import Combine
import Foundation
import SwiftUI
import GhosttyTerminal
import SkylightCore
import SkylightDaemonCore

/// What the window is showing: one instance full-window, or a canvas.
enum Selection: Hashable {
    case item(UUID)
    case canvas(UUID)
}

/// A menu-driven zoom on the visible canvas.
enum CanvasZoomAction: Equatable {
    case zoomIn, zoomOut, fit, actual
}

/// One zoom command, addressed to a board. `id` makes two identical requests
/// distinct so `.onChange` fires for a second ⌘+ in a row.
struct CanvasZoomRequest: Equatable {
    let id = UUID()
    let canvasID: UUID
    let action: CanvasZoomAction
}

/// One arrange command, addressed to a board. Arranging needs the LIVE
/// viewport (its aspect sets the row width), and only the mounted CanvasView
/// knows that — so the command travels the way zooms do. `id` keeps a second
/// ⌘⇧A in a row distinct.
struct CanvasArrangeRequest: Equatable {
    let id = UUID()
    let canvasID: UUID
}

@MainActor
final class AppState: ObservableObject {
    @Published var instances: [TerminalInstance]
    @Published var canvases: [CanvasBoard]
    // The three properties that decide what is ON SCREEN carry the surface-
    // visibility sync as didSet observers — a @Published sink fires on
    // willSet, when self still holds the OLD value, and hidden/shown would be
    // computed against the state being left. (Observers do not fire during
    // init; the first sync rides the first real transition, and surfaces are
    // created visible, which is correct — creation only ever happens
    // on-screen.)
    @Published var selection: Selection? {
        didSet { syncSurfaceVisibility() }
    }
    /// Instances whose terminal rang the bell while not being viewed.
    @Published var attention: Set<UUID> = []
    /// Instances whose process ended (shell exited, agent quit, crash) while
    /// the surface stayed on screen. The sidebar says so instead of letting a
    /// dead session pose as a live one.
    @Published private(set) var endedInstances: Set<UUID> = []
    /// Instance temporarily filling the window (focus mode). Leaving focus
    /// returns to whatever was selected — the canvas is untouched.
    @Published var focusedInstance: UUID? {
        didSet { syncSurfaceVisibility() }
    }
    /// Tile to center after opening a canvas from its sidebar row.
    @Published var pendingReveal: UUID?
    /// Menu/keyboard zoom aimed at a canvas — the visible CanvasView owns the
    /// live transform, so commands travel to it the way reveals do.
    @Published var canvasZoomRequest: CanvasZoomRequest?
    /// Menu/keyboard arrange aimed at a canvas — same travel as a zoom.
    @Published var canvasArrangeRequest: CanvasArrangeRequest?
    /// Non-nil while a sidebar row is mid-drag; the detail area shows the
    /// canvas drop surface for exactly that long.
    @Published var draggingItemID: UUID? {
        didSet { syncSurfaceVisibility() }
    }
    /// The New sheet — openable from ⌘T and the sidebar + button alike.
    @Published var newSheetShown = false
    /// Debug-hook companion to SKYLIGHT_OPEN_SHEET=agent: the sheet opens
    /// on its Agent CLI tier so screenshot automation can see it.
    var debugSheetAgentMode = false
    /// Right-click spawn target: the sheet's next launch lands here as a tile.
    var pendingSpawn: (canvasID: UUID, point: CGPoint)?
    @Published private(set) var presets: [LaunchPreset]
    @Published private(set) var usage: UsageLog
    /// Harness ids Ryan has granted full autonomy — they launch with their own
    /// permission prompts skipped. Off for everything until he says otherwise,
    /// once per harness, and it survives relaunches.
    @Published private(set) var trustedHarnesses: Set<String>

    let sessions = LiveSessionStore()

    static weak var shared: AppState?
    /// The app's one window — so a tile drag can pause window movement for
    /// exactly its own duration (see CanvasView.tileInteracting).
    weak var hostWindow: NSWindow?
    private var observers: Set<AnyCancellable> = []
    private let persistRequests = PassthroughSubject<Void, Never>()

    private static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static var stateURL: URL { supportDir.appendingPathComponent("workspace.json") }
    private static var presetsURL: URL { supportDir.appendingPathComponent("presets.json") }
    private static var usageURL: URL { supportDir.appendingPathComponent("usage.json") }
    private static var trustedURL: URL { supportDir.appendingPathComponent("trusted.json") }

    init() {
        var saved: SavedState?
        // "Exists but can't be READ" must rescue exactly like "can't be
        // decoded": either way a workspace is in that file, and the first
        // persist() would atomically rename right over it — rename needs only
        // directory access, so an unreadable file offers no protection at all.
        if FileManager.default.fileExists(atPath: Self.stateURL.path) {
            if let data = try? Data(contentsOf: Self.stateURL) {
                saved = WorkspacePersistence.decode(data)
            }
            if saved == nil {
                // Kept as .bak, never clobbered.
                try? FileManager.default.removeItem(at: Self.stateURL.appendingPathExtension("bak"))
                try? FileManager.default.moveItem(
                    at: Self.stateURL,
                    to: Self.stateURL.appendingPathExtension("bak"))
            }
        }

        if let saved {
            instances = saved.instances
            canvases = saved.canvases
            if let id = saved.selectedInstance, saved.instances.contains(where: { $0.id == id }) {
                // A canvas resident restored as a full-window `.item` is the
                // one contradictory state the sidebar cannot draw (no row
                // would be highlighted) — its board is what that selection
                // honestly means.
                if let board = Residency.board(of: id, in: saved.canvases) {
                    selection = .canvas(board)
                } else {
                    selection = .item(id)
                }
            } else if let id = saved.selectedCanvas,
                      saved.canvases.contains(where: { $0.id == id }) {
                selection = .canvas(id)
            }
        } else {
            let first = TerminalInstance(name: "Terminal")
            instances = [first]
            canvases = []
            selection = .item(first.id)
        }
        presets = Self.loadSidecar([LaunchPreset].self, from: Self.presetsURL) ?? []
        usage = Self.loadSidecar(UsageLog.self, from: Self.usageURL) ?? UsageLog()
        // Unreadable or absent = trusted nothing. A grant this consequential
        // must never be recovered by guessing.
        trustedHarnesses = Self.loadSidecar(Set<String>.self, from: Self.trustedURL) ?? []

        // Every stored property is initialized before `self` is read.
        if selection == nil { selection = instances.first.map { .item($0.id) } }

        sessions.onBell = { [weak self] id in
            guard let self, !self.isVisible(id) else { return }
            self.attention.insert(id)
        }
        // The surface reports its process gone — the sidebar stops pretending.
        sessions.onSessionEnd = { [weak self] id in
            self?.endedInstances.insert(id)
        }
        // An agent terminal names itself after the first thing you ask it.
        sessions.onAutoName = { [weak self] id, title in
            guard let self,
                  let index = self.instances.firstIndex(where: { $0.id == id })
            else { return }
            self.instances[index].name = title
            // Coalesced: a keyDown is no place for a synchronous disk write.
            self.persistSoon()
        }
        sessions.lookupName = { [weak self] id in
            self?.instance(id)?.name
        }
        sessions.lookupTrusted = { [weak self] harness in
            self?.trustedHarnesses.contains(harness) ?? false
        }
        sessions.lookupKnownInstanceIDs = { [weak self] in
            Set(self?.instances.map(\.id) ?? [])
        }
        // Connect to the keeper in the background NOW — the first surface's
        // render should find the answer waiting, not go looking for it.
        sessions.prewarmDaemon()
        Self.shared = self

        $selection
            .dropFirst()
            .sink { [weak self] selection in
                // Whatever just became visible stops asking for attention,
                // and any navigation leaves focus mode.
                guard let self else { return }
                self.focusedInstance = nil
                // A pending centering is a promise to the canvas that was being
                // opened. Navigating anywhere ELSE first answers it the other
                // way — only a mounted CanvasView consumes the request, so an
                // uncleared one would re-center some canvas opened much later.
                // (A `.canvas` selection is left alone: reveal sets the two
                // together, and clearing here would kill the reveal itself.)
                switch selection {
                case let .item(id)?:
                    self.attention.remove(id)
                    self.pendingReveal = nil
                case let .canvas(boardID)?:
                    for tile in self.canvases.first(where: { $0.id == boardID })?.tiles ?? [] {
                        self.attention.remove(tile.itemID)
                    }
                case nil:
                    self.pendingReveal = nil
                }
            }
            .store(in: &observers)
        $selection
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &observers)
        persistRequests
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &observers)
        // Terminals waiting on you, counted on the Dock like every serious
        // mac app. `dropFirst` for the same reason the selection sinks use it:
        // a @Published publisher replays its current value to a new
        // subscriber, so the first emission lands INSIDE this init — before
        // SwiftUI has finished standing NSApplication up. That emission is
        // always the empty set, i.e. the no-badge state the Dock already
        // shows, so dropping it costs nothing and every surviving emission
        // comes from a bell or a selection change, long after launch. NSApp
        // is an implicitly-unwrapped global, so it is chained rather than
        // forced: a wrong guess about launch order should not be a crash.
        $attention
            .removeDuplicates()
            .dropFirst()
            .sink { attention in
                NSApp?.dockTile.badgeLabel = attention.isEmpty ? nil : "\(attention.count)"
            }
            .store(in: &observers)
    }

    // MARK: - Persistence

    /// Decode a sidecar JSON file, preserving — never clobbering — one that
    /// exists but cannot be read or decoded: it moves to `.bak` exactly like
    /// the workspace, because "corrupt file → .bak" is a rule about files,
    /// not about workspace.json specifically. One truncated write used to
    /// cost every preset silently. Returns nil for absent or rescued.
    private static func loadSidecar<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }
        let bak = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
        return nil
    }

    func persist() {
        var selectedInstance: UUID?
        var selectedCanvas: UUID?
        switch selection {
        case let .item(id): selectedInstance = id
        case let .canvas(id): selectedCanvas = id
        case nil: break
        }
        let state = SavedState(instances: instances, canvases: canvases,
                               selectedInstance: selectedInstance,
                               selectedCanvas: selectedCanvas)
        if let data = WorkspacePersistence.encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    /// Coalesced persist for high-frequency callers (wheel-scroll pan):
    /// state mutates per event, the disk write lands once, trailing.
    func persistSoon() { persistRequests.send(()) }

    private func persistUsage() {
        if let data = try? JSONEncoder().encode(usage) {
            try? data.write(to: Self.usageURL, options: .atomic)
        }
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: Self.presetsURL, options: .atomic)
        }
    }

    private func persistTrusted() {
        if let data = try? JSONEncoder().encode(trustedHarnesses) {
            try? data.write(to: Self.trustedURL, options: .atomic)
        }
    }

    /// Grant or revoke full autonomy for one harness. Takes effect for every
    /// terminal launched from here on — a session already running keeps the
    /// command line it started with, which is what the toggle's copy promises.
    func setTrusted(_ id: String, _ on: Bool) {
        if on { trustedHarnesses.insert(id) } else { trustedHarnesses.remove(id) }
        persistTrusted()
    }

    // MARK: - Lookup

    func instance(_ id: UUID) -> TerminalInstance? {
        instances.first { $0.id == id }
    }

    /// True when an instance is on screen right now — focused, selected
    /// full-window, or a tile on the currently displayed canvas (which a
    /// focused instance would cover).
    private func isVisible(_ id: UUID) -> Bool {
        if let focusedInstance { return focusedInstance == id }
        switch selection {
        case let .item(selected): return selected == id
        case let .canvas(boardID): return Residency.board(of: id, in: canvases) == boardID
        case nil: return false
        }
    }

    /// Push display visibility down to every open surface (see
    /// LiveSessionStore.setSurfaceVisible — display only, the process keeps
    /// running). Errs toward visible: during a sidebar drag the drop overlay
    /// may live-preview ANY board, so everything renders for those moments.
    private func syncSurfaceVisibility() {
        let dragging = draggingItemID != nil
        for id in sessions.openSessionIDs {
            sessions.setSurfaceVisible(dragging || isVisible(id), for: id)
        }
    }

    /// The canvas on screen right now, if any — zoom commands are dead
    /// keystrokes without one.
    var selectedCanvasID: UUID? {
        if case let .canvas(id)? = selection { return id }
        return nil
    }

    /// True only when a canvas is both selected AND actually on screen — focus
    /// mode covers it, and a zoom you cannot see is a silent no-op.
    var canvasZoomAvailable: Bool {
        selectedCanvasID != nil && focusedInstance == nil
    }

    /// Stricter than zoom: arranging also needs something to arrange. Below
    /// two tiles the command does nothing at all (see CanvasView.arrange),
    /// and an enabled menu item that does nothing is a lie.
    var canArrange: Bool {
        guard canvasZoomAvailable, let id = selectedCanvasID,
              let board = canvases.first(where: { $0.id == id }) else { return false }
        return board.tiles.count > 1
    }

    var freeInstances: [TerminalInstance] {
        Residency.free(instances, boards: canvases)
    }

    func residents(of board: CanvasBoard) -> [TerminalInstance] {
        Residency.residents(of: board, from: instances)
    }

    // MARK: - Instances

    /// Launch a terminal from a spec — the single entry point shortcuts,
    /// presets, and the New sheet all use. Records the combo locally so the
    /// most-used launch can become a one-click recommendation.
    func launch(_ spec: TerminalSpec, name: String? = nil) {
        let instance = TerminalInstance(
            name: Names.numbered(base: name ?? Self.defaultName(for: spec),
                                 among: instances.map(\.name)), spec: spec)
        instances.append(instance)
        selection = .item(instance.id)
        focusedInstance = nil
        usage.record(spec)
        persistUsage()
        persist()
    }

    /// The sheet's launches honor a right-click spawn target; every other
    /// entry point (⇧⌘T, command menu) never does.
    func launchFromSheet(_ spec: TerminalSpec, name: String? = nil) {
        if let spawn = pendingSpawn {
            pendingSpawn = nil
            launchTile(spec, name: name, on: spawn.canvasID, at: spawn.point)
            return
        }
        launch(spec, name: name)
    }

    /// Create a new instance directly as a tile on a canvas, at a content
    /// point — the right-click spawn. The canvas stays selected; the tile
    /// appears where the cursor was, no full-window hop.
    func launchTile(_ spec: TerminalSpec, name: String? = nil,
                    on canvasID: UUID, at point: CGPoint) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
        let instance = TerminalInstance(
            name: Names.numbered(base: name ?? Self.defaultName(for: spec),
                                 among: instances.map(\.name)), spec: spec)
        instances.append(instance)
        usage.record(spec)
        persistUsage()
        let size = CanvasLayout.defaultTileSize
        let desired = CGPoint(x: point.x - size.width / 2, y: point.y - 24)
        let origin = CanvasLayout.freePosition(
            desired: desired, size: size,
            avoiding: canvases[index].tiles.map(\.frame))
        canvases[index].tiles.append(
            CanvasTile(itemID: instance.id, origin: origin, size: size))
        selection = .canvas(canvasID)
        persist()
    }

    /// The per-kind defaults live in SkylightCore, where they are pure and
    /// pinned by test. This stays as the app's call site so nothing else has
    /// to learn a new name.
    static func defaultName(for spec: TerminalSpec) -> String {
        KindPolicy.defaultName(for: spec)
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[index].name = trimmed
        // A name you chose stands: no prompt typed later may replace it.
        sessions.cancelTitleCapture(id)
        persist()
    }

    func deleteInstance(_ id: UUID) {
        instances.removeAll { $0.id == id }
        for index in canvases.indices {
            canvases[index].tiles.removeAll { $0.itemID == id }
        }
        sessions.discard(id)
        attention.remove(id)
        endedInstances.remove(id)
        if focusedInstance == id { endFocus() }
        if case let .item(selected)? = selection, selected == id {
            selection = fallbackSelection
        }
        persist()
    }

    /// Somewhere honest to land after a delete: a free terminal full-window,
    /// else the board of the first surviving resident — never a resident as
    /// a full-window `.item`, which is a state the sidebar cannot draw.
    private var fallbackSelection: Selection? {
        if let free = freeInstances.first { return .item(free.id) }
        if let resident = instances.first,
           let board = Residency.board(of: resident.id, in: canvases) {
            return .canvas(board)
        }
        return nil
    }

    /// A dead session's one useful affordance: run the same spec again in the
    /// same instance. The old surface is torn down; the next render lazily
    /// builds a fresh one, exactly like a first open.
    func restartInstance(_ id: UUID) {
        guard endedInstances.contains(id) else { return }
        sessions.discard(id)
        endedInstances.remove(id)
        attention.remove(id)
    }

    /// What ⌘Q would actually kill: sessions that exist and have not ended.
    var liveSessionCount: Int {
        sessions.openSessionIDs.filter { !endedInstances.contains($0) }.count
    }

    /// Reorder within the FREE instances (sidebar Terminals section) while
    /// canvas residents keep their positions in the master array.
    ///
    /// Residents move to the tail. That is invisible while they stay on a
    /// canvas — their sidebar position comes from their board's tile order
    /// (`Residency.residents` walks tiles, not this array) — but it has one
    /// real consequence: a terminal freed from a canvas AFTER a reorder
    /// returns to the BOTTOM of Terminals, because that is where its master
    /// index now sits. Every other reader is order-agnostic (id lookups,
    /// `map(\.name)` for unique naming, a whole-array save that round-trips),
    /// and `Residency.free` is a filter, so free order IS this order.
    func moveFreeInstances(from source: IndexSet, to destination: Int) {
        var free = freeInstances
        free.move(fromOffsets: source, toOffset: destination)
        let residents = instances.filter { Residency.board(of: $0.id, in: canvases) != nil }
        // Free order is what the user arranged; residents keep relative order
        // appended after (their sidebar position comes from canvas groups).
        instances = free + residents
        persist()
    }

    /// Nudge one free terminal a step up or down the Terminals section.
    /// `move(fromOffsets:toOffset:)` measures the destination in PRE-removal
    /// indices, which is why a step down is `index + 2` and not `index + 1`.
    func moveFreeInstance(_ id: UUID, by delta: Int) {
        let free = freeInstances
        guard let index = free.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard target >= 0, target < free.count else { return }
        moveFreeInstances(from: IndexSet(integer: index),
                          to: delta < 0 ? target : target + 1)
    }

    // MARK: - Canvases

    @discardableResult
    func newCanvas() -> CanvasBoard {
        // Counting boards repeats a name the moment one is deleted; the highest
        // suffix does not. Same rule as terminals, deliberately.
        let board = CanvasBoard(
            name: Names.numbered(base: "Canvas", among: canvases.map(\.name)))
        canvases.append(board)
        persist()
        return board
    }

    func renameCanvas(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = canvases.firstIndex(where: { $0.id == id }) else { return }
        canvases[index].name = trimmed
        persist()
    }

    /// The board goes; its terminals return to the sidebar untouched.
    func deleteCanvas(_ id: UUID) {
        canvases.removeAll { $0.id == id }
        if case let .canvas(selected)? = selection, selected == id {
            selection = fallbackSelection
        }
        persist()
    }

    /// Remember where a canvas is panned; persisted via persistSoon() —
    /// state per event, disk write coalesced.
    func setPan(_ pan: CGPoint, for canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
        canvases[index].pan = pan
    }

    /// Zoom persists like pan: state now, disk write coalesced.
    func setZoom(_ zoom: CGFloat, for canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
        canvases[index].zoom = zoom
    }

    /// Aim a zoom command at whatever canvas is on screen. No canvas, no-op —
    /// the menu items are disabled in that state anyway.
    func requestZoom(_ action: CanvasZoomAction) {
        guard let id = selectedCanvasID else { return }
        canvasZoomRequest = CanvasZoomRequest(canvasID: id, action: action)
    }

    /// Aim an arrange at whatever canvas is on screen. Same rule as zoom: no
    /// visible canvas, no command — the menu item is disabled in that state.
    func requestArrange() {
        guard let id = selectedCanvasID else { return }
        canvasArrangeRequest = CanvasArrangeRequest(canvasID: id)
    }

    /// One command, a composed canvas: tiles pack tidily (sizes and reading
    /// order kept) and the board is written back in one mutation, so every
    /// tile springs to its new origin together. The caller fits the view
    /// immediately after — see CanvasView.arrange(in:).
    func arrangeCanvas(_ canvasID: UUID, viewport: CGSize) {
        guard let board = canvases.first(where: { $0.id == canvasID }) else { return }
        setTiles(CanvasLayout.arranged(tiles: board.tiles, viewport: viewport),
                 for: canvasID)
    }

    // MARK: - Tiles

    /// Place an instance on a board — moving it off any other board first.
    /// An instance lives in exactly one place; the sidebar mirrors that truth.
    func addTile(itemID: UUID, to canvasID: UUID?, at point: CGPoint?) {
        guard instance(itemID) != nil else { return }
        let boardID = canvasID.flatMap { id in
            canvases.contains { $0.id == id } ? id : nil
        } ?? newCanvas().id
        for index in canvases.indices where canvases[index].id != boardID {
            canvases[index].tiles.removeAll { $0.itemID == itemID }
        }
        guard let index = canvases.firstIndex(where: { $0.id == boardID }) else { return }
        if let existing = canvases[index].tiles.firstIndex(where: { $0.itemID == itemID }) {
            // Dropping on its own board repositions the tile.
            guard let point else {
                // Pointless drop: the tile is already here and nothing says
                // where to put it. Churning selection and writing disk to
                // accomplish nothing is worse than doing nothing.
                return
            }
            var tile = canvases[index].tiles.remove(at: existing)
            tile.origin = CanvasLayout.snapped(
                CGPoint(x: point.x - tile.size.width / 2, y: point.y - 24))
            canvases[index].tiles.append(tile)
        } else {
            let size = CanvasLayout.defaultTileSize
            let desired = point.map { CGPoint(x: $0.x - size.width / 2, y: $0.y - 24) }
                ?? CanvasLayout.staggeredOrigin(existing: canvases[index].tiles.count)
            let origin = CanvasLayout.freePosition(
                desired: desired, size: size,
                avoiding: canvases[index].tiles.map(\.frame))
            canvases[index].tiles.append(
                CanvasTile(itemID: itemID, origin: origin, size: size))
            // Only a newly placed tile is worth panning to; nudging one that
            // is already on screen must not re-center the whole canvas.
            pendingReveal = itemID
        }
        selection = .canvas(boardID)
        // Membership changed under an unchanged selection (tile moved onto
        // the already-displayed board): the didSet observers saw nothing.
        syncSurfaceVisibility()
        persist()
    }

    /// Take an instance off its board: it is a full-window terminal again.
    func removeFromCanvas(_ itemID: UUID) {
        guard instance(itemID) != nil else { return }
        for index in canvases.indices {
            canvases[index].tiles.removeAll { $0.itemID == itemID }
        }
        focusedInstance = nil
        selection = .item(itemID)
        syncSurfaceVisibility()
        persist()
    }

    func updateTile(_ tile: CanvasTile, in canvasID: UUID) {
        guard let boardIndex = canvases.firstIndex(where: { $0.id == canvasID }),
              let tileIndex = canvases[boardIndex].tiles.firstIndex(where: { $0.id == tile.id })
        else { return }
        // Last-touched tile renders on top (tiles draw in array order).
        canvases[boardIndex].tiles.remove(at: tileIndex)
        canvases[boardIndex].tiles.append(tile)
        persist()
    }

    /// Reflow support: replace a board's tiles wholesale. The write is
    /// coalesced — a live window drag settles into one save, not one per event.
    func setTiles(_ tiles: [CanvasTile], for canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
        canvases[index].tiles = tiles
        persistSoon()
    }

    /// Open whatever an instance's sidebar row points at: its canvas,
    /// centered on its tile — or itself full-window when it lives free.
    func reveal(_ itemID: UUID) {
        guard let boardID = Residency.board(of: itemID, in: canvases) else {
            selection = .item(itemID)
            return
        }
        selection = .canvas(boardID)
        pendingReveal = itemID
    }

    /// ⌘. / Back: leave focus. Whatever the window now shows stops asking
    /// for attention.
    func endFocus() {
        focusedInstance = nil
        if case let .canvas(boardID)? = selection {
            for tile in canvases.first(where: { $0.id == boardID })?.tiles ?? [] {
                attention.remove(tile.itemID)
            }
        }
    }

    // MARK: - Presets

    func savePreset(named name: String, spec: TerminalSpec) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets.append(LaunchPreset(name: trimmed, spec: spec))
        persistPresets()
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persistPresets()
    }

    // MARK: - Sidebar drag session

    /// Identity of the CURRENT drag. A cancelled drag's token deinits at
    /// AppKit's leisure — possibly during the NEXT drag of the same row —
    /// and an item-id comparison alone would let that stale token tear the
    /// live drag down. Returned so the token can check it is still theirs.
    private(set) var dragSession = UUID()

    @discardableResult
    func beginSidebarDrag(_ itemID: UUID) -> UUID {
        // The drop overlay reveals the canvas through the base view — focus
        // would cover it, so dragging leaves focus first.
        focusedInstance = nil
        draggingItemID = itemID
        dragSession = UUID()
        return dragSession
    }
    func endSidebarDrag() { draggingItemID = nil }
}

// MARK: - Live sessions

/// Keeps each instance's terminal NSView (and thus its ghostty surface and
/// shell/CLI process) alive independent of SwiftUI view churn: the same
/// running session shows full-window, on a canvas, and after navigating
/// away and back. SwiftUI only ever reparents these views.
@MainActor
final class LiveSessionStore {
    private var terminals: [UUID: TerminalViewState] = [:]
    private var terminalNSViews: [UUID: TerminalView] = [:]
    private var bellObservers: [UUID: AnyCancellable] = [:]
    private var resolvedHarnesses: [String: String?] = [:]
    private var cachedShells: [Shell]?
    private var launchOutcomes: [UUID: LaunchOutcome] = [:]
    /// Last visibility pushed per surface, so transitions cost one call and
    /// steady states cost none (the coordinator's own flag is internal).
    private var surfaceVisibility: [UUID: Bool] = [:]
    /// The session keeper. nil = the exec lane carries new terminals
    /// (SKYLIGHT_NO_DAEMON, the daemon would not start, or the connection
    /// was lost mid-run) — the app then behaves exactly as it did before
    /// sessions could survive, truthful quit dialog included.
    private var daemonClient: DaemonClient?
    private var daemonBootstrapped = false
    /// Prewarm rendezvous: bootstrap runs on a background queue starting at
    /// app init so the first terminal's render doesn't pay for the connect;
    /// the semaphore covers the race where the render wins anyway. The box
    /// is the cross-isolation handoff slot (lock-guarded, like MonitorBox).
    private final class PrewarmBox: @unchecked Sendable {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var result: DaemonClient?
    }
    private var prewarmStarted = false
    private let prewarm = PrewarmBox()

    /// The workspace's instance ids, so bootstrap can kill daemon sessions
    /// whose instance no longer exists (reachable: a delete raced by an
    /// instant quit can leave its kill frame undelivered).
    var lookupKnownInstanceIDs: (() -> Set<UUID>)?

    /// True when quitting parts with running sessions instead of ending them.
    var sessionsSurviveQuit: Bool { daemonClient != nil }

    /// Let queued daemon frames (a just-sent kill) drain before process exit.
    func flushDaemon() { daemonClient?.flush() }

    /// Start connecting to the keeper now, off the main thread — by the time
    /// the first surface asks, the answer is usually already here.
    func prewarmDaemon() {
        guard !prewarmStarted else { return }
        prewarmStarted = true
        let box = prewarm
        DispatchQueue.global(qos: .userInitiated).async {
            let client = DaemonClient.bootstrap()
            box.lock.lock()
            box.result = client
            box.lock.unlock()
            box.done.signal()
        }
    }

    private func daemon() -> DaemonClient? {
        if !daemonBootstrapped {
            daemonBootstrapped = true
            if prewarmStarted {
                // Bounded wait: covers a first render that beats the
                // background connect by a few hundred ms; a wedged daemon
                // already gave up inside bootstrap's own short deadlines.
                _ = prewarm.done.wait(timeout: .now() + 6)
                prewarm.lock.lock()
                daemonClient = prewarm.result
                prewarm.lock.unlock()
            } else {
                daemonClient = DaemonClient.bootstrap()
            }
            configureDaemonClient()
        }
        return daemonClient
    }

    private func configureDaemonClient() {
        guard let client = daemonClient else { return }
        client.onExited = { [weak self] id, _ in
            self?.onSessionEnd?(id)
        }
        client.onConnectionLost = { [weak self] ids in
            guard let self else { return }
            // The keeper died under these sessions: their lanes are dead,
            // and pretending otherwise would freeze terminals silently and
            // let ⌘Q claim survival while losing everything. Ended is the
            // honest state on offer — and Restart works (exec lane).
            self.daemonClient = nil
            for id in ids where self.terminals[id] != nil {
                self.onSessionEnd?(id)
            }
        }
        if let known = lookupKnownInstanceIDs?() {
            for id in client.inheritedSessions.keys where !known.contains(id) {
                client.kill(id)
            }
        }
    }

    /// Every instance with a surface right now — what quitting would kill.
    var openSessionIDs: [UUID] { Array(terminals.keys) }

    /// Display-only visibility: a hidden surface stops rendering (ghostty's
    /// display link idles) while its process, bell, and title keep flowing.
    /// This is the idle-CPU bar enforced rather than hoped for — tiles on a
    /// canvas you are not looking at render nothing.
    func setSurfaceVisible(_ visible: Bool, for id: UUID) {
        guard let view = terminalNSViews[id], surfaceVisibility[id] != visible else { return }
        surfaceVisibility[id] = visible
        view.setSurfaceVisible(visible)
    }

    /// What a surface ACTUALLY launched with, recorded when its config was
    /// built. The missing-harness banner reads this, not live install state:
    /// a CLI installed after the fact must not erase the truth that this
    /// running surface fell back to a shell — and uninstalling one must not
    /// hang a false banner on a healthy running agent.
    struct LaunchOutcome {
        var missingHarness: String?
        var missingShell: String?
    }

    func launchOutcome(for id: UUID) -> LaunchOutcome? { launchOutcomes[id] }

    /// Fired when a terminal rings the bell (a CLI is done / needs input).
    var onBell: ((UUID) -> Void)?

    /// Fired when a surface reports its session over — the shell exited, the
    /// agent quit, the process died. The surface stays (its scrollback is
    /// still worth reading); the honesty obligation moves to the caller.
    var onSessionEnd: ((UUID) -> Void)?

    /// Fired once per agent terminal, with a name derived from the first
    /// thing its human asked for.
    var onAutoName: ((UUID, String) -> Void)?

    /// The instance's name as it stands right now. A name chosen between
    /// launch and the first prompt outranks anything derived here, so the
    /// capture asks before it fires.
    var lookupName: ((UUID) -> String?)?

    /// Whether a harness id has been granted full autonomy. Read at surface
    /// creation, like `lookupName`, so the store never holds its own copy of
    /// a setting that lives in AppState.
    var lookupTrusted: ((String) -> Bool)?

    // MARK: - First-prompt title capture

    /// An agent terminal still wearing its launch-issued name, and the line
    /// typed into it so far. We cannot read the pty, but we own the input
    /// path: every keystroke passes through the terminal's NSView.
    private struct TitleCapture {
        let defaultName: String
        var buffer: String = ""
    }
    private var titleCapture: [UUID: TitleCapture] = [:]
    private var keyMonitor: Any?

    /// Long enough for any first prompt worth naming; past it the buffer
    /// stops growing but the capture stays alive.
    private static let bufferLimit = 300

    /// Cached PATH resolution — resolving stats the filesystem, and tile
    /// bodies ask for it during pan. Cache lives for the app run, matching
    /// the session config it feeds.
    func cachedResolveHarness(_ name: String) -> String? {
        if let cached = resolvedHarnesses[name] { return cached }
        let resolved = Self.resolveHarness(name)
        resolvedHarnesses[name] = resolved
        return resolved
    }

    /// Shell detection, once per run: reading /etc/shells and stat-ing every
    /// path in it is a filesystem walk, and the New sheet used to pay for it
    /// inside `.onAppear` — i.e. on its first frame, every single open.
    func detectedShells() -> [Shell] {
        if let cachedShells { return cachedShells }
        let fm = FileManager.default
        let contents = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        let shells = Catalog.installedShells(fromShellsFile: contents,
                                             isExecutable: { fm.isExecutableFile(atPath: $0) })
        cachedShells = shells
        return shells
    }

    /// The sheet re-samples install state when the app comes back to the
    /// front; drop BOTH detection caches so a CLI — or a shell — installed
    /// mid-run is honored by the next sample and the next launch alike.
    func invalidateHarnessCache() {
        resolvedHarnesses.removeAll()
        cachedShells = nil
    }

    func terminalHostView(for instance: TerminalInstance) -> TerminalView {
        if let existing = terminalNSViews[instance.id] { return existing }
        let state = terminal(for: instance)
        let view = TerminalView(frame: .zero)
        view.delegate = state
        view.controller = state.controller
        view.configuration = state.configuration
        terminalNSViews[instance.id] = view
        return view
    }

    /// Non-creating: nil until the terminal has actually been opened once.
    /// Sidebar rows use this so rendering a row never spawns a process.
    func existingTerminal(for id: UUID) -> TerminalViewState? {
        terminals[id]
    }

    /// Quote a word for ghostty's command line iff it contains whitespace or
    /// quotes (minimal shell-style quoting; single words pass through).
    /// Ghostty word-splits the `command` value, so an unquoted "/Applications/
    /// My Tool/bin/agent" silently becomes two arguments and the launch fails.
    ///
    /// Control characters do not survive at all: the generated config is
    /// LINE-based, so a newline smuggled inside a stored argument would end
    /// the command line early and turn the remainder into an arbitrary config
    /// directive — the terminal running something other than every field the
    /// UI shows. Stored specs are hostile data; this is where that rule meets
    /// the config file.
    nonisolated private static func quoted(_ word: String) -> String {
        let word = String(String.UnicodeScalarView(word.unicodeScalars.filter {
            !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }))
        guard word.rangeOfCharacter(from: .whitespaces) != nil || word.contains("\"") else {
            return word
        }
        return "\"" + word.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// What the daemon runs for an instance: a real argv, no quoting layer —
    /// the word-splitting concern of the exec lane's command string does not
    /// exist here. The fallback chain itself is pure and unit-tested
    /// (SkylightCore.Launch); this wires in the live filesystem and the
    /// trust-gated autonomy arguments.
    private func daemonArgv(for instance: TerminalInstance) -> [String] {
        let harness = instance.spec.harness
        let binary = harness.flatMap { cachedResolveHarness($0) }
        return Launch.argv(
            shellPath: instance.spec.shellPath,
            harnessBinary: binary,
            harnessArguments: harness.map { autonomousArguments(for: instance.spec, harness: $0) } ?? [],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            loginShell: Catalog.loginShell(environment: ProcessInfo.processInfo.environment))
    }

    /// The spec's arguments, with the harness's verified autonomy flag in
    /// front when Ryan has granted that harness. Local to building the command
    /// line: the saved spec is never rewritten, so revoking the grant is
    /// enough to un-grant it — nothing has to be scrubbed back out.
    ///
    /// The flag leads rather than trails because agent CLIs take a positional
    /// prompt; appending would risk landing after one. It is skipped entirely
    /// when the spec already passes it by hand, so nobody gets it twice.
    private func autonomousArguments(for spec: TerminalSpec, harness: String) -> [String] {
        guard let flag = Catalog.harness(harness)?.autonomyFlag,
              lookupTrusted?(harness) == true,
              !spec.arguments.contains(flag) else { return spec.arguments }
        return [flag] + spec.arguments
    }

    /// The generated per-surface config: translucency plus balanced inner
    /// padding so no row — least of all an agent's bottom status line — ever
    /// clips against the rounded chrome. The opacity is the Settings slider's
    /// stored choice (default 0.92 — readability beats effect, spec Addendum
    /// A1; going clearer than that is the user's own deliberate call, floored
    /// where text still reads).
    static func surfaceConfig() -> String {
        """
        window-padding-x = 10
        window-padding-y = 10
        window-padding-balance = true

        """
    }

    /// The dynamic half of a surface's look, on the library's composition
    /// lane: the renderer layers base config → this → theme, so overrides
    /// here never strip the color theme, and appended commands outrank the
    /// library default's own font-size = 14 (last key wins in ghostty
    /// config). The opacity default 0.92 lives in Appearance (spec Addendum
    /// A1); font size only when chosen, so the engine default keeps ruling
    /// rather than being frozen to today's number.
    static func surfaceConfiguration() -> TerminalConfiguration {
        var configuration = TerminalConfiguration.default
            .backgroundOpacity(Appearance.terminalOpacity)
        if Appearance.terminalFontSize > 0 {
            configuration = configuration.fontSize(Float(Appearance.terminalFontSize))
        }
        // Validated on read, not just on import: a face can be uninstalled
        // after it was chosen, and asking ghostty for one that is not there
        // renders in something else with nothing on screen to explain why.
        if let family = Appearance.terminalFontFamily {
            configuration = configuration.fontFamily(family)
        }
        return configuration
    }

    /// Apply the current stored appearance config to every LIVE surface —
    /// the Settings controls work on open terminals, not just future ones.
    /// setTerminalConfiguration (not updateConfigSource: that lane replaces
    /// the whole source WITHOUT theme composition — a slider drag would
    /// have washed the colors off every open terminal). Coalesced: a drag
    /// fires continuously, ghostty re-parses a config per apply, and the
    /// latest values are read at fire time, so ≤20 applies/second always
    /// converge on where the controls stopped.
    private var configRefreshQueued = false
    func refreshSurfaceConfig() {
        guard !configRefreshQueued else { return }
        configRefreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.configRefreshQueued = false
            let configuration = Self.surfaceConfiguration()
            for terminal in self.terminals.values {
                terminal.controller.setTerminalConfiguration(configuration)
            }
        }
    }

    /// The colour half of the same lane: an imported or picked theme reaches
    /// every LIVE surface, not just the next one opened. Same 50ms coalescer
    /// and same latest-wins reading as refreshSurfaceConfig — a theme picker
    /// with a preview fires as fast as a slider drag does.
    ///
    /// `setTheme`, deliberately, and never `updateConfigSource`: that lane
    /// replaces the whole config source WITHOUT theme composition, which is
    /// how you wash the colours off every open terminal. The library layers
    /// base → configuration → theme with last-key-wins, so this and
    /// refreshSurfaceConfig can both be in flight without fighting.
    private var themeRefreshQueued = false
    func refreshSurfaceTheme() {
        guard !themeRefreshQueued else { return }
        themeRefreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.themeRefreshQueued = false
            let theme = ThemeStore.shared.terminalTheme()
            for terminal in self.terminals.values {
                terminal.controller.setTheme(theme)
            }
        }
    }

    func terminal(for instance: TerminalInstance) -> TerminalViewState {
        if let existing = terminals[instance.id] { return existing }
        let config = Self.surfaceConfig()
        // Record what this surface ACTUALLY gets — the banner's source of
        // truth for the life of the session, immune to installs/uninstalls
        // that happen after the process is already running.
        var outcome = LaunchOutcome()
        if let harness = instance.spec.harness, cachedResolveHarness(harness) == nil {
            outcome.missingHarness = harness
        }
        if let shell = instance.spec.shellPath,
           !FileManager.default.isExecutableFile(atPath: shell) {
            outcome.missingShell = shell
        }
        launchOutcomes[instance.id] = outcome
        // Born already wearing the theme. Applying it after creation would
        // paint one frame of the engine default first — a flash of the wrong
        // colours on every single terminal you open.
        let state = TerminalViewState(configSource: .generated(config),
                                      theme: ThemeStore.shared.terminalTheme(),
                                      terminalConfiguration: Self.surfaceConfiguration())
        if let daemon = daemon() {
            // The survival lane: the daemon owns the pty; this surface is a
            // renderer attached over the socket. Keystrokes and resizes go
            // out through the session's closures; output lands via receive
            // on the client's read queue (thread-safe by library contract).
            let id = instance.id
            let session = InMemoryTerminalSession(
                write: { [weak daemon] data in daemon?.input(id, data) },
                resize: { [weak daemon] viewport in
                    daemon?.resize(ResizePayload(
                        id: id,
                        columns: UInt16(clamping: viewport.columns),
                        rows: UInt16(clamping: viewport.rows),
                        widthPixels: UInt16(clamping: viewport.widthPixels),
                        heightPixels: UInt16(clamping: viewport.heightPixels)))
                })
            if daemon.inheritedSessions[id] != nil {
                // A previous app run's session: attach and replay. A dead one
                // still replays — its final output and honest ending arrive
                // exactly like a live exit would.
                daemon.attach(id, session: session)
            } else {
                daemon.spawn(SpawnRequest(
                    id: id,
                    argv: daemonArgv(for: instance),
                    cwd: instance.spec.workingDirectory
                        ?? FileManager.default.homeDirectoryForCurrentUser.path),
                    session: session)
            }
            state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        } else {
            // The exec lane. The command travels as PER-SURFACE configuration,
            // not a line in the generated config file: both reach the same
            // ghostty field with the same word-splitting (so quoted() still
            // matters), but a string that never crosses a line-based file
            // cannot become a second directive — the injection class dies
            // structurally, not just by sanitizing.
            var command: String?
            if let harness = instance.spec.harness,
               let binary = cachedResolveHarness(harness) {
                // Agent terminal: ghostty runs the CLI as the surface command.
                command = ([binary] + autonomousArguments(for: instance.spec, harness: harness))
                    .map(Self.quoted).joined(separator: " ")
            } else if let shell = instance.spec.shellPath,
                      FileManager.default.isExecutableFile(atPath: shell) {
                // A shell that vanished since the spec was saved falls back to
                // the login shell (the default branch); the banner says so.
                command = Self.quoted(shell)
            }
            state.configuration = TerminalSurfaceOptions(
                backend: .exec,
                workingDirectory: instance.spec.workingDirectory
                    ?? FileManager.default.homeDirectoryForCurrentUser.path,
                command: command
            )
        }
        terminals[instance.id] = state
        // The terminal bell is how agent CLIs signal "done / needs input".
        let id = instance.id
        bellObservers[id] = state.$bellCount
            .dropFirst()
            .sink { [weak self] _ in self?.onBell?(id) }
        // The surface's close report is the one honest "this session is over"
        // signal there is. processAlive is ignored on purpose: alive or not,
        // the surface is done hosting it.
        state.onClose = { [weak self] _ in self?.onSessionEnd?(id) }
        // Only agents name themselves, and only while they still answer to
        // the name the launcher gave them.
        if instance.spec.kind.isAgent, Self.wearsLaunchName(instance) {
            titleCapture[id] = TitleCapture(defaultName: instance.name)
            installKeyMonitorIfNeeded()
        }
        return state
    }

    /// Tear down live state for a deleted instance (frees the surface, ends
    /// the process).
    ///
    /// The onClose hook is detached FIRST: surface teardown kills the child,
    /// and a close report racing out of the dying surface would arrive under
    /// this same instance id — after a restart, that late echo would mark the
    /// FRESH session as ended. Detaching makes the race unlosable instead of
    /// merely unlikely.
    func discard(_ id: UUID) {
        terminals[id]?.onClose = nil
        terminals.removeValue(forKey: id)
        terminalNSViews.removeValue(forKey: id)
        bellObservers.removeValue(forKey: id)
        launchOutcomes.removeValue(forKey: id)
        surfaceVisibility.removeValue(forKey: id)
        // Ending the instance ends its kept session — delete means delete,
        // and a restart's respawn under the same id replaces it anyway.
        daemonClient?.kill(id)
        cancelTitleCapture(id)
    }

    /// A deliberate name ends the auto-naming conversation for good — a hand
    /// rename must never be overwritten by a prompt typed later.
    func cancelTitleCapture(_ id: UUID) {
        titleCapture.removeValue(forKey: id)
        removeKeyMonitorIfIdle()
    }

    /// True while an instance still wears exactly what `launch` issued it —
    /// "Claude Code", or "Claude Code 2" for a sibling. Names outlive
    /// captures (they persist to disk; captures do not), so a terminal that
    /// already named itself in an earlier run, or was renamed by hand, is not
    /// eligible again after a relaunch.
    private static func wearsLaunchName(_ instance: TerminalInstance) -> Bool {
        let base = AppState.defaultName(for: instance.spec)
        if instance.name == base { return true }
        guard instance.name.hasPrefix("\(base) ") else { return false }
        let suffix = instance.name.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil, !titleCapture.isEmpty else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureKey(event)
            return event   // NEVER consume — the terminal gets every key
        }
    }

    /// No captures left, no monitor: the feature costs nothing once every
    /// agent terminal has a name.
    private func removeKeyMonitorIfIdle() {
        guard titleCapture.isEmpty, let monitor = keyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        keyMonitor = nil
    }

    /// Watches; never intercepts. Every path out of here leaves the event
    /// exactly as it arrived — the monitor returns it verbatim, and nothing
    /// below may consume, rewrite, or defer a keystroke.
    private func captureKey(_ event: NSEvent) {
        guard !titleCapture.isEmpty else { return }
        // Which terminal owns the keyboard — nil for a sheet's text field, a
        // sidebar rename, or anything else that is not a live terminal.
        guard let id = instanceID(forResponder: event.window?.firstResponder),
              var capture = titleCapture[id] else { return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A long first prompt usually ARRIVES by paste. Plain ⌘V pastes the
        // string flavor, which is exactly what the terminal is about to
        // receive, so read it and move on — the event still goes through
        // untouched. The paste-special variants (⌘⇧V, ⌘⌥V) are excluded: they
        // may paste something other than `.string`.
        //
        // Matched on `charactersIgnoringModifiers` (keyCode 9 on ANSI) for the
        // same reason `abandonsLine` is: on Dvorak the raw keyCode would both
        // miss the real ⌘V and read the pasteboard on ⌘K.
        if modifiers.contains(.command),
           modifiers.isDisjoint(with: [.shift, .option, .control]),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if capture.buffer.count < Self.bufferLimit,
               let pasted = NSPasteboard.general.string(forType: .string) {
                // Sanitize BEFORE the cap, so the 300 counts prompt text and
                // not the escape bytes of some copied terminal output.
                let clean = Titles.sanitizedPaste(pasted)
                if !clean.isEmpty {
                    capture.buffer += clean.prefix(Self.bufferLimit - capture.buffer.count)
                    titleCapture[id] = capture
                }
            }
            return
        }
        // Abandon gestures wipe the line in the CLI — mirror them, or an old
        // fragment glues onto the real prompt.
        if Self.abandonsLine(keyCode: event.keyCode, modifiers: modifiers,
                             keyIgnoringModifiers: event.charactersIgnoringModifiers) {
            titleCapture[id]?.buffer = ""
            return
        }
        // Chords belong to the app and the CLI, never to a title. (.function
        // is deliberately NOT screened here — the numeric keypad can carry it,
        // and arrows/F-keys are screened by `isTypedText` instead.)
        guard modifiers.isDisjoint(with: [.command, .control]) else { return }

        let characters = event.characters ?? ""
        // Agent CLIs spell "newline, not send" as ⇧/⌥Return; a multi-line
        // first prompt must not be named off its opening line.
        let softNewline = !modifiers.isDisjoint(with: [.shift, .option])
        switch event.keyCode {
        case 36, 76:                       // Return, keypad Enter
            if softNewline {
                guard capture.buffer.count < Self.bufferLimit else { return }
                capture.buffer += "\n"     // derivation collapses it to a space
                titleCapture[id] = capture
            } else {
                finalize(id, capture)
            }
        case 51:                           // Delete
            capture.buffer = String(capture.buffer.dropLast())
            titleCapture[id] = capture
        default:
            if !softNewline, characters == "\r" || characters == "\n" {
                finalize(id, capture)      // a remapped Return still submits
                return
            }
            guard Self.isTypedText(characters),
                  capture.buffer.count < Self.bufferLimit else { return }
            capture.buffer += characters
            titleCapture[id] = capture
        }
    }

    /// The gestures that throw away the line you were typing: Esc (an agent
    /// CLI's "clear the prompt"), ⌃C / ⌃U / ⌃W (every readline), and ⌘⌫.
    /// Matched on `charactersIgnoringModifiers` so a Dvorak ⌃U is still ⌃U.
    private static func abandonsLine(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                                     keyIgnoringModifiers: String?) -> Bool {
        if keyCode == 53 { return true }                              // Esc
        if modifiers.contains(.command), keyCode == 51 { return true }  // ⌘⌫
        guard modifiers.contains(.control),
              let key = keyIgnoringModifiers?.lowercased() else { return false }
        return key == "c" || key == "u" || key == "w"
    }

    /// Text a person typed, not a key event dressed as text: arrows, F-keys,
    /// and Esc/Tab are all reported as characters and none belong in a name.
    /// Shares `Titles.isNameSafe` with the paste path on purpose — typed and
    /// pasted text differ only in what they allow ON TOP of that one rule, and
    /// a second copy of it here is exactly how the two would drift apart.
    private static func isTypedText(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy(Titles.isNameSafe)
    }

    /// Return was pressed: name the terminal if the line was worth a name.
    ///
    /// Known blind spots — all of them fail toward "no name" or "a name from
    /// slightly different text", never toward a lost keystroke:
    /// - **Paste.** ⌘V IS captured: the pasteboard's string flavor is appended
    ///   as the paste happens. Every other paste path — middle-click primary
    ///   selection, drag-and-drop, a CLI's own bracketed-paste plumbing —
    ///   reaches the pty without a keyDown, so it leaves the buffer short and
    ///   the line simply fails to earn a name.
    /// - **Word-delete drift.** The buffer is append-only apart from single
    ///   deletes: ⌥⌫ removes one character here while the CLI removes a whole
    ///   word, so a heavily edited line can derive from slightly stale text.
    ///   (⌃W is treated as an abandon instead, which is the safe direction.)
    /// - **IME composition.** Marked text is not committed text; a Japanese or
    ///   Chinese prompt can name itself from the romaji that was typed rather
    ///   than the characters that were chosen.
    /// - **Re-arming.** Renaming an instance back to the launch pattern
    ///   ("Claude Code 2") makes it eligible again on the next relaunch —
    ///   `wearsLaunchName` reads the name, and that name is once again the
    ///   one the launcher would have issued.
    private func finalize(_ id: UUID, _ capture: TitleCapture) {
        guard let title = Titles.derived(fromPrompt: capture.buffer) else {
            // A bare Return, a "y", a slash-command: the real first prompt
            // has not happened yet.
            titleCapture[id]?.buffer = ""
            return
        }
        if lookupName?(id) == capture.defaultName {
            onAutoName?(id, title)
        }
        // Named, or renamed by hand while we watched — either way, done.
        titleCapture.removeValue(forKey: id)
        removeKeyMonitorIfIdle()
    }

    /// Ghostty's focused view may be a subview of the view we store, so this
    /// walks ancestors rather than comparing identity. A responder that lives
    /// in no terminal (a sheet field editor, a SwiftUI host) matches nothing
    /// and the capture stands down.
    private func instanceID(forResponder responder: NSResponder?) -> UUID? {
        guard let view = responder as? NSView else { return nil }
        return terminalNSViews.first { _, terminal in
            view.isDescendant(of: terminal)
        }?.key
    }

    static func resolveHarness(_ name: String) -> String? {
        Catalog.resolve(
            name,
            pathVariable: ProcessInfo.processInfo.environment["PATH"],
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}
