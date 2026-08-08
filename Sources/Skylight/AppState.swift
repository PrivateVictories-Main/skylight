import Combine
import Foundation
import SwiftUI
import GhosttyTerminal
import SkylightCore

/// What the window is showing: one instance full-window, or a canvas.
enum Selection: Hashable {
    case item(UUID)
    case canvas(UUID)
}

@MainActor
final class AppState: ObservableObject {
    @Published var instances: [TerminalInstance]
    @Published var canvases: [CanvasBoard]
    @Published var selection: Selection?
    /// Instances whose terminal rang the bell while not being viewed.
    @Published var attention: Set<UUID> = []
    /// Instance temporarily filling the window (focus mode). Leaving focus
    /// returns to whatever was selected — the canvas is untouched.
    @Published var focusedInstance: UUID?
    /// Tile to center after opening a canvas from its sidebar row.
    @Published var pendingReveal: UUID?
    /// Non-nil while a sidebar row is mid-drag; the detail area shows the
    /// canvas drop surface for exactly that long.
    @Published var draggingItemID: UUID?
    @Published private(set) var presets: [LaunchPreset]
    @Published private(set) var usage: UsageLog

    let sessions = LiveSessionStore()

    static weak var shared: AppState?
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

    init() {
        var saved: SavedState?
        if let data = try? Data(contentsOf: Self.stateURL) {
            saved = WorkspacePersistence.decode(data)
            if saved == nil {
                // Unreadable state is kept as .bak, never clobbered.
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
                selection = .item(id)
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
        presets = (try? Data(contentsOf: Self.presetsURL))
            .flatMap { try? JSONDecoder().decode([LaunchPreset].self, from: $0) } ?? []
        usage = (try? Data(contentsOf: Self.usageURL))
            .flatMap { try? JSONDecoder().decode(UsageLog.self, from: $0) } ?? UsageLog()

        // Every stored property is initialized before `self` is read.
        if selection == nil { selection = instances.first.map { .item($0.id) } }

        sessions.onBell = { [weak self] id in
            guard let self, !self.isVisible(id) else { return }
            self.attention.insert(id)
        }
        Self.shared = self

        $selection
            .dropFirst()
            .sink { [weak self] selection in
                // Whatever just became visible stops asking for attention,
                // and any navigation leaves focus mode.
                guard let self else { return }
                self.focusedInstance = nil
                switch selection {
                case let .item(id)?:
                    self.attention.remove(id)
                case let .canvas(boardID)?:
                    for tile in self.canvases.first(where: { $0.id == boardID })?.tiles ?? [] {
                        self.attention.remove(tile.itemID)
                    }
                case nil:
                    break
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
    }

    // MARK: - Persistence

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
        let base = name ?? Self.defaultName(for: spec)
        let siblings = instances.filter {
            $0.name == base || $0.name.hasPrefix("\(base) ")
        }.count
        let instance = TerminalInstance(
            name: siblings == 0 ? base : "\(base) \(siblings + 1)", spec: spec)
        instances.append(instance)
        selection = .item(instance.id)
        focusedInstance = nil
        usage.record(spec)
        persistUsage()
        persist()
    }

    static func defaultName(for spec: TerminalSpec) -> String {
        if let harness = spec.harness {
            return Catalog.harnesses.first { $0.id == harness }?.displayName ?? harness
        }
        if let shell = spec.shellPath { return (shell as NSString).lastPathComponent }
        return "Terminal"
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = instances.firstIndex(where: { $0.id == id }) else { return }
        instances[index].name = trimmed
        persist()
    }

    func deleteInstance(_ id: UUID) {
        instances.removeAll { $0.id == id }
        for index in canvases.indices {
            canvases[index].tiles.removeAll { $0.itemID == id }
        }
        sessions.discard(id)
        attention.remove(id)
        if focusedInstance == id { focusedInstance = nil }
        if case let .item(selected)? = selection, selected == id {
            selection = (freeInstances.first ?? instances.first).map { .item($0.id) }
        }
        persist()
    }

    // MARK: - Canvases

    @discardableResult
    func newCanvas() -> CanvasBoard {
        let board = CanvasBoard(name: "Canvas \(canvases.count + 1)")
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
            selection = (freeInstances.first ?? instances.first).map { .item($0.id) }
        }
        persist()
    }

    /// Remember where a canvas is panned; persisted via persistSoon() —
    /// state per event, disk write coalesced.
    func setPan(_ pan: CGPoint, for canvasID: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
        canvases[index].pan = pan
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
            if let point {
                var tile = canvases[index].tiles.remove(at: existing)
                tile.origin = CanvasLayout.snapped(
                    CGPoint(x: point.x - tile.size.width / 2, y: point.y - 24))
                canvases[index].tiles.append(tile)
            }
        } else {
            let size = CanvasLayout.defaultTileSize
            let origin = CanvasLayout.snapped(
                point.map { CGPoint(x: $0.x - size.width / 2, y: $0.y - 24) }
                    ?? CanvasLayout.staggeredOrigin(existing: canvases[index].tiles.count))
            canvases[index].tiles.append(
                CanvasTile(itemID: itemID, origin: origin, size: size))
            // Only a newly placed tile is worth panning to; nudging one that
            // is already on screen must not re-center the whole canvas.
            pendingReveal = itemID
        }
        selection = .canvas(boardID)
        persist()
    }

    /// Take an instance off its board: it is a full-window terminal again.
    func removeFromCanvas(_ itemID: UUID) {
        for index in canvases.indices {
            canvases[index].tiles.removeAll { $0.itemID == itemID }
        }
        focusedInstance = nil
        selection = .item(itemID)
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

    /// Esc / Back: leave focus. Whatever the window now shows stops asking
    /// for attention.
    func endFocus() {
        focusedInstance = nil
        if case let .canvas(boardID)? = selection {
            for tile in canvases.first(where: { $0.id == boardID })?.tiles ?? [] {
                attention.remove(tile.itemID)
            }
        }
    }

    // MARK: - Sidebar drag session

    func beginSidebarDrag(_ itemID: UUID) { draggingItemID = itemID }
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

    /// Fired when a terminal rings the bell (a CLI is done / needs input).
    var onBell: ((UUID) -> Void)?

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

    func terminal(for instance: TerminalInstance) -> TerminalViewState {
        if let existing = terminals[instance.id] { return existing }
        let state: TerminalViewState
        if let harness = instance.spec.harness, let binary = Self.resolveHarness(harness) {
            // Agent terminal: ghostty runs the CLI directly as the surface command.
            let command = ([binary] + instance.spec.arguments).joined(separator: " ")
            state = TerminalViewState(configSource: .generated("command = \(command)\n"))
        } else if let shell = instance.spec.shellPath,
                  FileManager.default.isExecutableFile(atPath: shell) {
            // A shell that vanished since the spec was saved falls back to the
            // login shell (the default branch); the banner says so (Task 9).
            state = TerminalViewState(configSource: .generated("command = \(shell)\n"))
        } else {
            state = TerminalViewState()
        }
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: instance.spec.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
        terminals[instance.id] = state
        // The terminal bell is how agent CLIs signal "done / needs input".
        let id = instance.id
        bellObservers[id] = state.$bellCount
            .dropFirst()
            .sink { [weak self] _ in self?.onBell?(id) }
        return state
    }

    /// Tear down live state for a deleted instance (frees the surface, ends
    /// the process).
    func discard(_ id: UUID) {
        terminals.removeValue(forKey: id)
        terminalNSViews.removeValue(forKey: id)
        bellObservers.removeValue(forKey: id)
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
