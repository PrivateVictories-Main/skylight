import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import GhosttyTerminal
import SkylightCore

/// An endless board of live tiles. There is no content frame — tiles live at
/// absolute coordinates and the whole plane translates under a pan offset.
struct CanvasView: View {
    @EnvironmentObject private var state: AppState
    let boardID: UUID
    /// The drag-preview copy of a board must never rearrange it.
    var reflowEnabled = true

    @State private var pan: CGPoint = .zero
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
                    onPanEnded: { commitPan() }
                )
                DotGrid(pan: pan)
                    .allowsHitTesting(false)
                ForEach(board?.tiles ?? []) { tile in
                    if let instance = state.instance(tile.itemID) {
                        TileView(tile: tile, instance: instance, boardID: boardID, pan: pan,
                                 interacting: $tileInteracting)
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
                    state.addTile(itemID: id, to: boardID,
                                  at: CGPoint(x: location.x - pan.x, y: location.y - pan.y))
                }
                return true
            }
            .onAppear {
                viewport = geo.size
                pan = board?.pan ?? .zero
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
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        .navigationTitle(board?.name ?? "Canvas")
        // The dot grid reaches the window top: no toolbar band, no safe-area
        // gap between the glass and the traffic lights.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .ignoresSafeArea(edges: .top)
        .overlay {
            if board?.tiles.isEmpty ?? true {
                ContentUnavailableView(
                    "Empty Canvas",
                    systemImage: "square.on.square.dashed",
                    description: Text("Drag terminals here from the sidebar.")
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func commitPan() {
        state.setPan(pan, for: boardID)
        state.persistSoon()
    }

    /// Center the tile a sidebar row asked for.
    private func revealIfPending(in viewport: CGSize) {
        guard let itemID = state.pendingReveal,
              let tile = board?.tiles.first(where: { $0.itemID == itemID }) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            pan = CanvasLayout.panToCenter(tile.frame, in: viewport)
        }
        state.pendingReveal = nil
        commitPan()
    }

    /// Window shrank: keep the arrangement visible (spec Addendum A3).
    private func applyReflow(in viewport: CGSize) {
        guard let board,
              let result = CanvasLayout.reflowed(tiles: board.tiles, pan: pan,
                                                 viewport: viewport) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pan = result.pan
        }
        state.setPan(result.pan, for: boardID)
        state.setTiles(result.tiles, for: boardID)   // state now, disk write coalesced
    }
}

// MARK: - Pan capture

/// Sits behind the tiles and turns trackpad scrolls, mouse-wheel scrolls, and
/// empty-space drags into canvas pan. AppKit routes scrollWheel to the view
/// under the cursor, so a terminal tile above still scrolls its own buffer.
struct PanSurface: NSViewRepresentable {
    let onPan: (CGSize) -> Void
    let onPanEnded: () -> Void

    func makeNSView(context: Context) -> PanView {
        let view = PanView()
        view.onPan = onPan
        view.onPanEnded = onPanEnded
        return view
    }

    func updateNSView(_ nsView: PanView, context: Context) {
        nsView.onPan = onPan
        nsView.onPanEnded = onPanEnded
    }

    final class PanView: NSView {
        var onPan: ((CGSize) -> Void)?
        var onPanEnded: (() -> Void)?
        private var dragOrigin: CGPoint?
        private var dragged = false

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
    }
}

/// The dot grid, drawn modulo the pan offset — a viewport-sized draw that
/// reads as an infinite plane.
private struct DotGrid: View {
    let pan: CGPoint

    var body: some View {
        Canvas { context, size in
            let step = CanvasLayout.grid * 4
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
    /// Raised for the life of a move or resize gesture so the canvas can hold
    /// a queued reflow until the hands are off.
    @Binding var interacting: Bool

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @State private var grabbing = false

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
            PersistentTerminalView(view: state.sessions.terminalHostView(for: instance))
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .top) { MissingHarnessBanner(instance: instance) }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .shadow(color: .black.opacity(grabbing ? 0.28 : 0.14),
                radius: grabbing ? 22 : 12, y: grabbing ? 12 : 5)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .frame(width: liveFrame.width, height: liveFrame.height)
        .scaleEffect(grabbing ? 1.015 : 1, anchor: .center)
        .offset(x: liveFrame.minX + pan.x, y: liveFrame.minY + pan.y)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: grabbing)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tile.origin)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tile.size)
        .zIndex(grabbing ? 1 : 0)
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
                .onChanged {
                    if !grabbing { grabbing = true }
                    if !interacting { interacting = true }
                    dragOffset = $0.translation
                }
                .onEnded { value in
                    var updated = tile
                    let proposed = CGRect(
                        x: tile.origin.x + value.translation.width,
                        y: tile.origin.y + value.translation.height,
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
                        resizeDelta = $0.translation
                    }
                    .onEnded { value in
                        var updated = tile
                        updated.size = CanvasLayout.snapped(
                            CGSize(
                                width: tile.size.width + value.translation.width,
                                height: tile.size.height + value.translation.height
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
                        CanvasView(boardID: board.id, reflowEnabled: false)
                            .allowsHitTesting(false)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                } else {
                    newCanvasSurface
                        .background(Color(nsColor: .windowBackgroundColor))
                }
                if let ghost {
                    let frame = ghostFrame(at: ghost, pan: targetBoard?.pan ?? .zero)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                    let pan = targetBoard?.pan ?? .zero
                    state.addTile(itemID: itemID, to: targetBoard?.id,
                                  at: CGPoint(x: location.x - pan.x, y: location.y - pan.y))
                    state.endSidebarDrag()
                }))
            chipBar
        }
        // Same origin as the CanvasView underneath it: if the overlay kept the
        // safe-area inset the canvas gave up, every ghost would sit ~28pt above
        // where the tile actually lands.
        .ignoresSafeArea(edges: .top)
    }

    /// Mirror of addTile's placement so the ghost never lies — including a
    /// repositioned tile's real size.
    private func ghostFrame(at location: CGPoint, pan: CGPoint) -> CGRect {
        let size = targetBoard?.tiles.first { $0.itemID == itemID }?.size
            ?? CanvasLayout.defaultTileSize
        let origin = CanvasLayout.snapped(
            CGPoint(x: location.x - pan.x - size.width / 2, y: location.y - pan.y - 24))
        return CGRect(x: origin.x + pan.x, y: origin.y + pan.y,
                      width: size.width, height: size.height)
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
        .background(.bar)
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
