import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import GhosttyTerminal
import SkylightCore

/// One set of magnification limits for the whole canvas. A second, disagreeing
/// floor somewhere else is exactly how a "safe" divisor stops being safe.
private enum CanvasZoom {
    /// Endless in feel, bounded in fact: below 0.2 tiles are unreadable specks,
    /// above 3 a terminal is a wall of pixels.
    static let minimum: CGFloat = 0.2
    static let maximum: CGFloat = 3.0
    /// How close to 100% still counts as 100%. Inside this band zoom snaps to
    /// exactly 1 — that exactness is what re-arms typing and dragging.
    static let snapTolerance: CGFloat = 0.02

    /// Never divide by a raw zoom: a zero or NaN would send every coordinate on
    /// the board to infinity, and the clamp is one bad edit away.
    static func safe(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite, zoom > minimum else { return minimum }
        return zoom
    }

    static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(maximum, max(minimum, value))
    }

    /// Anything within a hair of 100% *is* 100% — hit-testing keys off the
    /// exact value, so near-misses would leave the canvas subtly untypable.
    static func snapped(_ value: CGFloat) -> CGFloat {
        let value = clamped(value)
        return abs(value - 1) < snapTolerance ? 1 : value
    }
}

/// An endless board of live tiles. There is no content frame — tiles live at
/// absolute coordinates and the whole plane translates and scales under one
/// viewport transform: `screen = content × zoom + pan`.
struct CanvasView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    let boardID: UUID
    /// The drag-preview copy of a board must never rearrange it.
    var reflowEnabled = true

    @State private var pan: CGPoint = .zero
    @State private var zoom: CGFloat = 1
    @State private var viewport: CGSize = .zero
    /// True while a tile is being moved or resized — a reflow must never land
    /// in the middle of a gesture.
    @State private var tileInteracting = false
    @StateObject private var reflowCoalescer = ReflowCoalescer()

    private var board: CanvasBoard? {
        state.canvases.first { $0.id == boardID }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                PanSurface(
                    onPan: { delta in
                        pan.x += delta.width
                        pan.y += delta.height
                    },
                    onPanEnded: { commitViewport() },
                    onMagnify: { magnification, viewPoint in
                        zoomBy(factor: 1 + magnification, around: viewPoint)
                    },
                    onMagnifyEnded: { endZoomGesture() },
                    contextMenu: { viewPoint in
                        spawnMenu(at: contentPoint(viewPoint))
                    }
                )
                DotGrid(pan: pan, zoom: zoom)
                    .allowsHitTesting(false)
                ForEach(board?.tiles ?? []) { tile in
                    if let instance = state.instance(tile.itemID) {
                        TileView(tile: tile, instance: instance, boardID: boardID,
                                 pan: pan, zoom: zoom,
                                 interacting: $tileInteracting,
                                 onOverviewTap: { navigate(to: tile) })
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .dropDestination(for: String.self) { ids, location in
                for raw in ids {
                    guard let id = UUID(uuidString: raw),
                          state.instance(id) != nil else { continue }
                    // Viewport → content coordinates.
                    state.addTile(itemID: id, to: boardID, at: contentPoint(location))
                }
                return true
            }
            .onAppear {
                viewport = geo.size
                pan = board?.pan ?? .zero
                zoom = CanvasZoom.snapped(board?.zoom ?? 1)
                revealIfPending(in: geo.size)
            }
            .onChange(of: geo.size) { old, size in
                viewport = size
                // Reflow only when the window shrinks — growing never rearranges.
                if size.width < old.width || size.height < old.height {
                    if reflowEnabled { reflowCoalescer.send() }
                }
            }
            .onReceive(reflowCoalescer.output) {
                if !tileInteracting { applyReflow(in: viewport) }
            }
            .onChange(of: state.pendingReveal) { _, _ in revealIfPending(in: viewport) }
            .onChange(of: board?.tiles.count ?? 0) { old, new in
                // The board grew: if the arrangement no longer fits, the canvas
                // zooms itself out to show all of it. A fit supersedes centering
                // on the newcomer — it already includes it.
                guard new > old, reflowEnabled else { return }
                if autoFit(in: viewport) { state.pendingReveal = nil }
            }
            .onChange(of: state.canvasZoomRequest) { _, request in
                guard let request, request.canvasID == boardID else { return }
                apply(request.action, in: viewport)
                state.canvasZoomRequest = nil
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        .navigationTitle(board?.name ?? "Canvas")
        // The dot grid reaches the window top: no toolbar band, no safe-area
        // gap between the glass and the traffic lights.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay {
            if board?.tiles.isEmpty ?? true {
                ContentUnavailableView(
                    "Empty Canvas",
                    systemImage: "square.on.square.dashed",
                    description: Text("Right-click anywhere to open a terminal here — or drag one in from the sidebar.")
                )
                .allowsHitTesting(false)
            }
        }
        // Collapsed sidebar = traffic lights float over the detail area. An
        // animatable inset, not a safe-area flip: the content slides with the
        // sidebar instead of jumping a frame ahead of it.
        .padding(.top, sidebarCollapsed ? 30 : 0)
        .ignoresSafeArea(edges: .top)
        .animation(.easeOut(duration: 0.22), value: sidebarCollapsed)
    }

    private func commitViewport() {
        state.setPan(pan, for: boardID)
        state.setZoom(zoom, for: boardID)
        state.persistSoon()
    }

    // MARK: - Viewport transform

    private var safeZoom: CGFloat { CanvasZoom.safe(zoom) }

    /// Screen (viewport) point → content point.
    private func contentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.x) / safeZoom, y: (point.y - pan.y) / safeZoom)
    }

    private var viewportCenter: CGPoint {
        CGPoint(x: viewport.width / 2, y: viewport.height / 2)
    }

    /// Re-zoom keeping `anchor` (a screen point) pinned to the same content —
    /// the cursor stays on the thing it is pointing at.
    private func setZoom(_ newZoom: CGFloat, around anchor: CGPoint) {
        let ratio = newZoom / safeZoom
        pan = CGPoint(x: anchor.x - (anchor.x - pan.x) * ratio,
                      y: anchor.y - (anchor.y - pan.y) * ratio)
        zoom = newZoom
    }

    private func zoomBy(factor: CGFloat, around anchor: CGPoint) {
        let target = CanvasZoom.clamped(zoom * factor)
        guard target != zoom else { return }
        setZoom(target, around: anchor)
    }

    /// Pinch ended: settle onto exactly 100% if we are close, then persist.
    private func endZoomGesture() {
        let settled = CanvasZoom.snapped(zoom)
        if settled != zoom { setZoom(settled, around: viewportCenter) }
        commitViewport()
    }

    /// The whole arrangement's content-space bounding box.
    private var contentBounds: CGRect? {
        let frames = board?.tiles.map(\.frame) ?? []
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private func apply(_ action: CanvasZoomAction, in viewport: CGSize) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            switch action {
            case .zoomIn:
                setZoom(CanvasZoom.snapped(zoom + 0.25), around: viewportCenter)
            case .zoomOut:
                setZoom(CanvasZoom.snapped(zoom - 0.25), around: viewportCenter)
            case .actual:
                setZoom(1, around: viewportCenter)
            case .fit:
                guard let bounds = contentBounds else {
                    setZoom(1, around: viewportCenter)
                    break
                }
                let target = CanvasZoom.snapped(
                    CanvasLayout.fitZoom(bounds: bounds, viewport: viewport,
                                         minZoom: CanvasZoom.minimum))
                zoom = target
                pan = CanvasLayout.centeringPan(bounds: bounds, viewport: viewport,
                                                zoom: target)
            }
        }
        commitViewport()
    }

    /// Drop the whole board back into view when it has outgrown the window.
    /// Returns true when it actually moved the viewport.
    @discardableResult
    private func autoFit(in viewport: CGSize, margin: CGFloat = 24) -> Bool {
        guard let bounds = contentBounds,
              viewport.width > margin * 2, viewport.height > margin * 2 else { return false }
        let onScreen = CGRect(x: bounds.minX * zoom + pan.x, y: bounds.minY * zoom + pan.y,
                              width: bounds.width * zoom, height: bounds.height * zoom)
        let fits = onScreen.minX >= margin && onScreen.minY >= margin
            && onScreen.maxX <= viewport.width - margin
            && onScreen.maxY <= viewport.height - margin
        if fits { return false }
        let target = CanvasZoom.snapped(CanvasLayout.fitZoom(bounds: bounds, viewport: viewport,
                                                     minZoom: CanvasZoom.minimum))
        let targetPan = CanvasLayout.centeringPan(bounds: bounds, viewport: viewport,
                                                  zoom: target)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            zoom = target
            pan = targetPan
        }
        commitViewport()
        return true
    }

    /// Overview → work: a tap on a scaled-down tile flies to it at 100%.
    private func navigate(to tile: CanvasTile) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            zoom = 1
            pan = CanvasLayout.centeringPan(bounds: tile.frame, viewport: viewport, zoom: 1)
        }
        commitViewport()
    }

    /// The right-click spawn menu: everything launchable, one click, landing
    /// at the click point. Only real, installed options — never a dead item.
    private func spawnMenu(at contentPoint: CGPoint) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ run: @escaping () -> Void) {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke),
                                  keyEquivalent: "")
            item.target = action
            item.representedObject = action   // retains the closure box
            menu.addItem(item)
        }
        let spawn: (TerminalSpec, String?) -> Void = { spec, name in
            state.launchTile(spec, name: name, on: boardID, at: contentPoint)
        }
        if let usual = state.usage.topCombo(),
           usual.harness.map({ state.sessions.cachedResolveHarness($0) != nil }) ?? true {
            add("Your Usual — \(AppState.defaultName(for: usual))") { spawn(usual, nil) }
        }
        for preset in state.presets where preset.spec.harness
            .map({ state.sessions.cachedResolveHarness($0) != nil }) ?? true {
            add(preset.name) { spawn(preset.spec, preset.name) }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add("Terminal") { spawn(TerminalSpec(), nil) }
        let installed = Catalog.harnesses.filter {
            state.sessions.cachedResolveHarness($0.id) != nil
        }
        if !installed.isEmpty {
            menu.addItem(.separator())
            for harness in installed {
                add(harness.displayName) { spawn(TerminalSpec(harness: harness.id), nil) }
            }
        }
        menu.addItem(.separator())
        add("More Options…") {
            state.pendingSpawn = (boardID, contentPoint)
            state.newSheetShown = true
        }
        return menu
    }

    /// Center the tile a sidebar row asked for — at whatever zoom the canvas
    /// is currently at, so revealing never silently changes magnification.
    private func revealIfPending(in viewport: CGSize) {
        guard let itemID = state.pendingReveal,
              let tile = board?.tiles.first(where: { $0.itemID == itemID }) else { return }
        state.pendingReveal = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            pan = CanvasLayout.centeringPan(bounds: tile.frame, viewport: viewport,
                                            zoom: zoom)
        }
        commitViewport()
    }

    /// Window shrank: keep the arrangement visible (spec Addendum A3). The
    /// reflow math is content-space, so the viewport it is handed is the
    /// content-space viewport — what is actually VISIBLE at this zoom — and
    /// the pan travels in and out of content space with it.
    private func applyReflow(in viewport: CGSize) {
        guard let board else { return }
        // Zoom-out sees more content; zoom-in must never shrink real tiles.
        let z = min(1, safeZoom)
        let contentViewport = CGSize(width: viewport.width / z, height: viewport.height / z)
        let contentPan = CGPoint(x: pan.x / z, y: pan.y / z)
        guard let result = CanvasLayout.reflowed(tiles: board.tiles, pan: contentPan,
                                                 viewport: contentViewport) else { return }
        let screenPan = CGPoint(x: result.pan.x * z, y: result.pan.y * z)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pan = screenPan
        }
        state.setPan(screenPan, for: boardID)
        state.setTiles(result.tiles, for: boardID)   // state now, disk write coalesced
    }
}

/// Bridges NSMenuItem's target/action to a closure; retained via representedObject.
@MainActor
final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func invoke() { run() }
}

// MARK: - Pan capture

/// Sits behind the tiles and turns trackpad scrolls, mouse-wheel scrolls, and
/// empty-space drags into canvas pan. AppKit routes scrollWheel to the view
/// under the cursor, so a terminal tile above still scrolls its own buffer.
struct PanSurface: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    let onPanEnded: () -> Void
    /// Pinch: (magnification delta, cursor point in VIEWPORT coordinates).
    let onMagnify: (CGFloat, CGPoint) -> Void
    let onMagnifyEnded: () -> Void
    /// Builds the right-click menu for a point in CONTENT coordinates.
    let contextMenu: (CGPoint) -> NSMenu

    func makeNSView(context: Context) -> PanView {
        let view = PanView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PanView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: PanView) {
        view.onPan = onPan
        view.onPanEnded = onPanEnded
        view.onMagnify = onMagnify
        view.onMagnifyEnded = onMagnifyEnded
        view.contextMenu = contextMenu
    }

    final class PanView: NSView {
        var onPan: ((CGSize) -> Void)?
        var onPanEnded: (() -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onMagnifyEnded: (() -> Void)?
        var contextMenu: ((CGPoint) -> NSMenu)?
        private var dragOrigin: CGPoint?
        private var dragged = false
        /// Nonisolated, Sendable storage: a `deinit` runs outside the main
        /// actor's guarantees, and it is the last chance to let the monitor go.
        private final class MonitorBox: @unchecked Sendable {
            var monitor: Any?
        }
        private let magnify = MonitorBox()

        deinit {
            if let monitor = magnify.monitor { NSEvent.removeMonitor(monitor) }
        }

        /// The view is unflipped; SwiftUI's viewport space is top-left.
        private func viewportPoint(_ locationInWindow: CGPoint) -> CGPoint {
            let p = convert(locationInWindow, from: nil)
            return CGPoint(x: p.x, y: bounds.height - p.y)
        }

        /// A pinch over a tile is delivered to the terminal's view, and the
        /// responder chain walks up through its ancestors — never sideways to
        /// this sibling. A window-local monitor sees the event first, so the
        /// canvas zooms wherever the cursor is, not only over empty space.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = magnify.monitor {
                NSEvent.removeMonitor(monitor)
                magnify.monitor = nil
            }
            guard window != nil else { return }
            magnify.monitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) {
                [weak self] event in
                guard let self, event.window === self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                self.handleMagnify(event, at: p)
                return nil   // consumed — no double handling via the responder chain
            }
        }

        /// Harmless when the monitor already consumed the event; this is the
        /// path for any pinch that reaches us the ordinary way.
        override func magnify(with event: NSEvent) {
            handleMagnify(event, at: convert(event.locationInWindow, from: nil))
        }

        private func handleMagnify(_ event: NSEvent, at p: CGPoint) {
            onMagnify?(event.magnification, CGPoint(x: p.x, y: bounds.height - p.y))
            if event.phase == .ended || event.phase == .cancelled {
                onMagnifyEnded?()
            }
        }

        override func scrollWheel(with event: NSEvent) {
            // Trackpads report precise point deltas with phases; mouse wheels
            // report line-unit deltas with no phase at all — scale them and
            // treat each event as self-terminating so the pan still commits.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
            onPan?(CGSize(width: event.scrollingDeltaX * scale,
                          height: event.scrollingDeltaY * scale))
            if event.phase == .ended || event.momentumPhase == .ended
                || (event.phase == [] && event.momentumPhase == []) {
                onPanEnded?()
            }
        }

        override func mouseDown(with event: NSEvent) {
            // A missed mouseUp must not arm the next bare click.
            dragged = false
            dragOrigin = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOrigin else { return }
            dragged = true
            let p = event.locationInWindow
            // Window coords are bottom-up; SwiftUI's are top-down.
            onPan?(CGSize(width: p.x - origin.x, height: origin.y - p.y))
            dragOrigin = p
        }

        override func mouseUp(with event: NSEvent) {
            if dragged { onPanEnded?() }
            dragOrigin = nil
            dragged = false
        }

        // No super call: the responder chain has nothing better to do with a
        // right-click here, and the pan gesture's state is left untouched.
        override func rightMouseDown(with event: NSEvent) {
            guard let contextMenu else { return }
            NSMenu.popUpContextMenu(contextMenu(viewportPoint(event.locationInWindow)),
                                    with: event, for: self)
        }
    }
}

/// The dot grid, drawn modulo the pan offset — a viewport-sized draw that
/// reads as an infinite plane.
private struct DotGrid: View {
    let pan: CGPoint
    let zoom: CGFloat

    var body: some View {
        Canvas { context, size in
            let step = CanvasLayout.grid * 4 * CanvasZoom.safe(zoom)
            // Zoomed far out the dots crowd into noise — a plain field reads
            // better than a grey haze.
            guard step >= 16 else { return }
            let startX = pan.x.truncatingRemainder(dividingBy: step) - step
            let startY = pan.y.truncatingRemainder(dividingBy: step) - step
            var x = startX
            while x < size.width + step {
                var y = startY
                while y < size.height + step {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: .color(.secondary.opacity(0.18))
                    )
                    y += step
                }
                x += step
            }
        }
    }
}

// MARK: - Tile

struct TileView: View {
    @EnvironmentObject private var state: AppState
    let tile: CanvasTile
    let instance: TerminalInstance
    let boardID: UUID
    let pan: CGPoint
    /// The board's magnification. Exactly 1 means "work here"; anything else
    /// means "overview" — see `interactive`.
    let zoom: CGFloat
    /// Raised for the life of a move or resize gesture so the canvas can hold
    /// a queued reflow until the hands are off.
    @Binding var interacting: Bool
    /// Tapping a minified tile flies the canvas to it at 100%.
    var onOverviewTap: () -> Void = {}

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @State private var grabbing = false

    /// AppKit hit-tests by untransformed frames, so a scaled-down terminal
    /// cannot reliably receive a click anyway. Below/above 100% the tile is a
    /// thumbnail you navigate to, not a surface you type in.
    private var interactive: Bool { zoom == 1 }

    /// Gestures arrive in screen points; the board thinks in content points.
    private var safeZoom: CGFloat {
        CanvasZoom.safe(zoom)
    }

    private var liveFrame: CGRect {
        CGRect(
            x: tile.origin.x + dragOffset.width,
            y: tile.origin.y + dragOffset.height,
            width: max(CanvasLayout.minTileSize.width, tile.size.width + resizeDelta.width),
            height: max(CanvasLayout.minTileSize.height, tile.size.height + resizeDelta.height)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PersistentTerminalView(view: state.sessions.terminalHostView(for: instance),
                                   cornerRadius: 16,
                                   maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .top) { MissingHarnessBanner(instance: instance) }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    grabbing
                        ? AnyShapeStyle(Color.accentColor.opacity(0.5))
                        : AnyShapeStyle(LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.05),
                                     .black.opacity(0.12)],
                            startPoint: .top, endPoint: .bottom)),
                    lineWidth: grabbing ? 1.5 : 1
                )
        )
        // Lift is stroke and shadow only. A scale on a live Metal surface
        // resamples every glyph — the tile shimmers exactly while you are
        // watching it move.
        .shadow(color: .black.opacity(grabbing ? 0.30 : 0.14),
                radius: grabbing ? 24 : 12, y: grabbing ? 14 : 5)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        // The tile keeps its 100% LAYOUT size at every zoom: the pty is never
        // resized, the layer transform does the minifying.
        .frame(width: liveFrame.width, height: liveFrame.height)
        .allowsHitTesting(interactive)
        .overlay { overviewTapTarget }
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(x: liveFrame.minX * zoom + pan.x, y: liveFrame.minY * zoom + pan.y)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: grabbing)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tile.origin)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tile.size)
        .zIndex(grabbing ? 1 : 0)
    }

    /// In overview the whole tile is one button: tap it and the canvas flies
    /// there at 100%, where it becomes a terminal again.
    @ViewBuilder
    private var overviewTapTarget: some View {
        if !interactive {
            Button(action: onOverviewTap) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open “\(instance.name)” at 100%")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let brand = harnessBrand {
                BrandIcon(brand: brand, size: 15)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(instance.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                state.focusedInstance = instance.id
            } label: {
                Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.8))
            .help("Focus — fill the window (⌘. returns)")
            Button {
                state.removeFromCanvas(instance.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.8))
            .help("Return to a full-window terminal")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                // Nothing but the offset moves here: any extra state written
                // per event is a stutter you can see.
                .onChanged {
                    if !grabbing { grabbing = true }
                    if !interacting { interacting = true }
                    dragOffset = CGSize(width: $0.translation.width / safeZoom,
                                        height: $0.translation.height / safeZoom)
                }
                .onEnded { value in
                    var updated = tile
                    let proposed = CGRect(
                        x: tile.origin.x + value.translation.width / safeZoom,
                        y: tile.origin.y + value.translation.height / safeZoom,
                        width: tile.size.width,
                        height: tile.size.height
                    )
                    let others = (state.canvases.first { $0.id == boardID }?.tiles ?? [])
                        .filter { $0.id != tile.id }
                        .map(\.frame)
                    updated.origin = CanvasLayout.magnetSnapped(proposed, against: others)
                    dragOffset = .zero
                    grabbing = false
                    interacting = false
                    state.updateTile(updated, in: boardID)
                }
        )
        .onTapGesture(count: 2) { state.focusedInstance = instance.id }
    }

    private var harnessBrand: Brand? {
        instance.spec.harness.flatMap { id in
            Catalog.harnesses.first { $0.id == id }?.brand
        }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(5)
            .background(Circle().fill(.bar))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
            .padding(5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged {
                        if !interacting { interacting = true }
                        resizeDelta = CGSize(width: $0.translation.width / safeZoom,
                                             height: $0.translation.height / safeZoom)
                    }
                    .onEnded { value in
                        var updated = tile
                        updated.size = CanvasLayout.snapped(
                            CGSize(
                                width: tile.size.width + value.translation.width / safeZoom,
                                height: tile.size.height + value.translation.height / safeZoom
                            )
                        )
                        resizeDelta = .zero
                        interacting = false
                        state.updateTile(updated, in: boardID)
                    }
            )
    }
}

// MARK: - Drag-reveals-canvas

/// An NSItemProvider that reports when its drag session ends — AppKit
/// releases the provider on drop AND on cancel, so `deinit` is the one
/// reliable end-of-session signal SwiftUI gives us.
final class DragToken: NSItemProvider, @unchecked Sendable {
    var onEnd: (@MainActor () -> Void)?

    deinit {
        if let onEnd { Task { @MainActor in onEnd() } }
    }
}

/// Shown in the detail area the moment a sidebar row starts dragging: the
/// target canvas with a live ghost of where the tile will land, plus chips
/// for every other canvas and a new one.
struct CanvasDropOverlay: View {
    @EnvironmentObject private var state: AppState
    // Must mirror CanvasView's safe-area claim exactly, or the drag ghost
    // and the landed tile disagree by the titlebar height when collapsed.
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    let itemID: UUID
    @State private var ghost: CGPoint?

    private var targetBoard: CanvasBoard? {
        if case let .canvas(id) = state.selection {
            return state.canvases.first { $0.id == id }
        }
        // Never preview a board that hosts the instance the base is showing
        // full-window — a live terminal view can't be in two places at once.
        var candidates = state.canvases
        if case let .item(selected) = state.selection {
            candidates.removeAll { board in
                board.tiles.contains { $0.itemID == selected }
            }
        }
        return candidates.last
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let board = targetBoard {
                    if state.selection == .canvas(board.id) {
                        // The base DetailView already shows this exact board —
                        // a second CanvasView would steal its live terminal
                        // NSViews (one superview each). Let the base show through.
                        Color.clear
                    } else {
                        // The overlay already took the top inset; telling the
                        // embedded copy the sidebar is open keeps it from
                        // taking a second one and sliding every tile 30pt away
                        // from the ghost.
                        CanvasView(boardID: board.id, reflowEnabled: false)
                            .environment(\.sidebarCollapsed, false)
                            .allowsHitTesting(false)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                } else {
                    newCanvasSurface
                        .background(Color(nsColor: .windowBackgroundColor))
                }
                if let ghost {
                    let frame = ghostFrame(at: ghost, pan: targetBoard?.pan ?? .zero,
                                           zoom: targetBoard?.zoom ?? 1)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.7),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        )
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.text], delegate: GhostDropDelegate(
                ghost: $ghost,
                drop: { location in
                    state.addTile(itemID: itemID, to: targetBoard?.id,
                                  at: Self.contentPoint(location,
                                                        pan: targetBoard?.pan ?? .zero,
                                                        zoom: targetBoard?.zoom ?? 1))
                    state.endSidebarDrag()
                }))
            chipBar
        }
        // Same origin as the CanvasView underneath it: if the overlay took a
        // different inset, every ghost would sit 30pt from where the tile
        // actually lands.
        .padding(.top, sidebarCollapsed ? 30 : 0)
        .ignoresSafeArea(edges: .top)
        .animation(.easeOut(duration: 0.22), value: sidebarCollapsed)
    }

    /// Screen → content under a board's viewport transform, guarded against a
    /// zero zoom the way CanvasView's own conversion is.
    private static func contentPoint(_ point: CGPoint, pan: CGPoint,
                                     zoom: CGFloat) -> CGPoint {
        let z = CanvasZoom.safe(zoom)
        return CGPoint(x: (point.x - pan.x) / z, y: (point.y - pan.y) / z)
    }

    /// Mirror of addTile's placement so the ghost never lies — including a
    /// repositioned tile's real size, and the same free-space dodge a new
    /// tile's drop will take. Content-space placement, screen-space rectangle.
    private func ghostFrame(at location: CGPoint, pan: CGPoint, zoom: CGFloat) -> CGRect {
        let z = CanvasZoom.safe(zoom)
        let resident = targetBoard?.tiles.first { $0.itemID == itemID }
        let size = resident?.size ?? CanvasLayout.defaultTileSize
        let content = Self.contentPoint(location, pan: pan, zoom: zoom)
        let desired = CGPoint(x: content.x - size.width / 2, y: content.y - 24)
        // Already on this board → the user's exact drop (magnets align it).
        // New here → the identical freePosition call addTile is about to make,
        // against the identical frames, so the ghost cannot promise a spot the
        // tile then dodges away from.
        let origin = resident == nil
            ? CanvasLayout.freePosition(desired: desired, size: size,
                                        avoiding: targetBoard?.tiles.map(\.frame) ?? [])
            : CanvasLayout.snapped(desired)
        return CGRect(x: origin.x * z + pan.x, y: origin.y * z + pan.y,
                      width: size.width * z, height: size.height * z)
    }

    private var newCanvasSurface: some View {
        ContentUnavailableView(
            "Drop to Create a Canvas",
            systemImage: "square.on.square.dashed",
            description: Text("This terminal becomes the first tile.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chipBar: some View {
        HStack(spacing: 8) {
            ForEach(state.canvases) { board in
                chip(board.name, active: board.id == targetBoard?.id)
                    .dropDestination(for: String.self) { _, _ in
                        state.addTile(itemID: itemID, to: board.id, at: nil)
                        state.endSidebarDrag()
                        return true
                    }
            }
            chip("New Canvas", active: state.canvases.isEmpty)
                .dropDestination(for: String.self) { _, _ in
                    state.addTile(itemID: itemID, to: nil, at: nil)
                    state.endSidebarDrag()
                    return true
                }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func chip(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(active ? Color.accentColor.opacity(0.18)
                                      : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(active ? Color.accentColor.opacity(0.5)
                                              : Color.primary.opacity(0.1))
            )
    }
}

/// Tracks the cursor for the ghost and performs the drop. The dragged id is
/// threaded through AppState, so no provider decoding is needed.
struct GhostDropDelegate: DropDelegate {
    @Binding var ghost: CGPoint?
    let drop: (CGPoint) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        ghost = info.location
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        ghost = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        ghost = nil
        drop(info.location)
        return true
    }
}

// MARK: - Reflow coalescing

/// Turns a stream of shrink events into one trailing reflow tick — a live
/// window drag settles once instead of scaling per event. The tick carries
/// no size: the subscriber reads the live viewport at fire time, so a
/// shrink that grew back before the debounce fires reflows against the
/// real window (and correctly no-ops).
@MainActor
final class ReflowCoalescer: ObservableObject {
    private let events = PassthroughSubject<Void, Never>()
    let output: AnyPublisher<Void, Never>

    init() {
        output = events
            .debounce(for: .seconds(0.25), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

    func send() { events.send(()) }
}
