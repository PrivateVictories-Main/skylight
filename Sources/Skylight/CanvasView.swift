import AppKit
import SwiftUI
import GhosttyTerminal
import SkylightCore

/// An endless board of live tiles. There is no content frame — tiles live at
/// absolute coordinates and the whole plane translates under a pan offset.
struct CanvasView: View {
    @EnvironmentObject private var state: AppState
    let boardID: UUID

    @State private var pan: CGPoint = .zero
    @State private var viewport: CGSize = .zero

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
                        TileView(tile: tile, instance: instance, boardID: boardID, pan: pan)
                    }
                }
            }
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
                revealIfPending()
            }
            .onChange(of: geo.size) { _, size in viewport = size }
            .onChange(of: state.pendingReveal) { _, _ in revealIfPending() }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(board?.name ?? "Canvas")
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
        state.persist()
    }

    /// Center the tile a sidebar row asked for.
    private func revealIfPending() {
        guard let itemID = state.pendingReveal,
              let tile = board?.tiles.first(where: { $0.itemID == itemID }) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            pan = CanvasLayout.panToCenter(tile.frame, in: viewport)
        }
        state.pendingReveal = nil
        commitPan()
    }
}

// MARK: - Pan capture

/// Sits behind the tiles and turns trackpad scrolls and empty-space drags
/// into canvas pan. AppKit routes scrollWheel to the view under the cursor,
/// so a terminal tile above still scrolls its own buffer.
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

        override func scrollWheel(with event: NSEvent) {
            onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            if event.phase == .ended || event.momentumPhase == .ended {
                onPanEnded?()
            }
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOrigin else { return }
            let p = event.locationInWindow
            // Window coords are bottom-up; SwiftUI's are top-down.
            onPan?(CGSize(width: p.x - origin.x, height: origin.y - p.y))
            dragOrigin = p
        }

        override func mouseUp(with event: NSEvent) {
            dragOrigin = nil
            onPanEnded?()
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
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(grabbing ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1),
                              lineWidth: grabbing ? 1.5 : 1)
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
                    dragOffset = $0.translation
                }
                .onEnded { value in
                    var updated = tile
                    updated.origin = CanvasLayout.snapped(
                        CGPoint(
                            x: tile.origin.x + value.translation.width,
                            y: tile.origin.y + value.translation.height
                        )
                    )
                    dragOffset = .zero
                    grabbing = false
                    state.updateTile(updated, in: boardID)
                }
        )
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
                    .onChanged { resizeDelta = $0.translation }
                    .onEnded { value in
                        var updated = tile
                        updated.size = CanvasLayout.snapped(
                            CGSize(
                                width: tile.size.width + value.translation.width,
                                height: tile.size.height + value.translation.height
                            )
                        )
                        resizeDelta = .zero
                        state.updateTile(updated, in: boardID)
                    }
            )
    }
}
