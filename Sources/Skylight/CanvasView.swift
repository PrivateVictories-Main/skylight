import SwiftUI
import GhosttyTerminal

/// A board of live tiles. Tiles reference sidebar items — the same chat or
/// terminal keeps its running state whether shown here or full-window.
struct CanvasView: View {
    @EnvironmentObject private var state: AppState
    let boardID: UUID

    private var board: CanvasBoard? {
        state.canvases.first { $0.id == boardID }
    }

    var body: some View {
        GeometryReader { _ in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    DotGrid()
                    ForEach(board?.tiles ?? []) { tile in
                        if let item = state.item(tile.itemID) {
                            TileView(tile: tile, item: item, boardID: boardID)
                        }
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: String.self) { ids, location in
            for raw in ids {
                guard let id = UUID(uuidString: raw), state.item(id) != nil else { continue }
                state.addTile(itemID: id, to: boardID, at: location)
            }
            return true
        }
        .navigationTitle(board?.name ?? "Canvas")
        .overlay {
            if board?.tiles.isEmpty ?? true {
                ContentUnavailableView(
                    "Empty Canvas",
                    systemImage: "square.on.square.dashed",
                    description: Text("Drag chats and terminals here from the sidebar.")
                )
                .allowsHitTesting(false)
            }
        }
    }

    private var contentSize: CGSize {
        let tiles = board?.tiles ?? []
        let maxX = tiles.map(\.frame.maxX).max() ?? 0
        let maxY = tiles.map(\.frame.maxY).max() ?? 0
        return CGSize(width: max(maxX + 400, 1600), height: max(maxY + 400, 1200))
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step = CanvasLayout.grid * 4
            var x: CGFloat = step
            while x < size.width {
                var y: CGFloat = step
                while y < size.height {
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

private struct TileView: View {
    @EnvironmentObject private var state: AppState
    let tile: CanvasTile
    let item: WorkspaceItem
    let boardID: UUID

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero

    private var liveFrame: CGRect {
        CGRect(
            x: tile.origin.x + dragOffset.width,
            y: tile.origin.y + dragOffset.height,
            width: max(320, tile.size.width + resizeDelta.width),
            height: max(220, tile.size.height + resizeDelta.height)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .frame(width: liveFrame.width, height: liveFrame.height)
        .offset(x: liveFrame.minX, y: liveFrame.minY)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if case let .assistant(provider) = item.kind {
                BrandIcon(provider: provider, size: 15)
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                state.removeTile(tile.id, from: boardID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from canvas (keeps the item)")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { dragOffset = $0.translation }
                .onEnded { value in
                    var updated = tile
                    updated.origin = CanvasLayout.snapped(
                        CGPoint(
                            x: tile.origin.x + value.translation.width,
                            y: tile.origin.y + value.translation.height
                        )
                    )
                    dragOffset = .zero
                    state.updateTile(updated, in: boardID)
                }
        )
        .onTapGesture(count: 2) { state.selection = .item(item.id) }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case let .assistant(provider):
            switch (item.mode, provider) {
            case (.chat, _):
                WebViewContainer(webView: state.sessions.webView(for: item, provider: provider))
            case (.code, .claude):
                NativeChatView(engine: state.sessions.chatEngine(for: item))
            case (.code, .chatgpt):
                CodexPlaceholderView()
            }
        case .terminal:
            TerminalSurfaceView(context: state.sessions.terminal(for: item))
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
