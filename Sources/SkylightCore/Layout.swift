import CoreGraphics

public enum CanvasLayout {
    public static let grid: CGFloat = 16
    public static let minTileSize = CGSize(width: 320, height: 220)
    public static let defaultTileSize = CGSize(width: 560, height: 400)

    public static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x / grid).rounded() * grid,
            y: (point.y / grid).rounded() * grid
        )
    }

    /// The pan offset that centers a tile in a viewport.
    public static func panToCenter(_ tile: CGRect, in viewport: CGSize) -> CGPoint {
        CGPoint(x: viewport.width / 2 - tile.midX, y: viewport.height / 2 - tile.midY)
    }

    public static func snapped(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(minTileSize.width, (size.width / grid).rounded() * grid),
            height: max(minTileSize.height, (size.height / grid).rounded() * grid)
        )
    }

    /// Rectangle-style magnet: when a dragged frame's edge comes within
    /// `threshold` of another tile's edge, snap to align or abut it (nearest
    /// candidate wins; axes are independent). Grid snap is the fallback on
    /// any axis where no magnet fires — aligning to a neighbor deliberately
    /// beats the grid.
    ///
    /// A magnet is a LOCAL relationship: a candidate only participates when the
    /// two tiles are neighbors on the perpendicular axis — their perpendicular
    /// spans overlap, or come within `proximity` of it. Without that gate a
    /// tile x-aligns to something thousands of points below, which reads as the
    /// drag catching on nothing.
    public static func magnetSnapped(_ frame: CGRect, against others: [CGRect],
                                     threshold: CGFloat = 12,
                                     proximity: CGFloat = 96) -> CGPoint {
        var x = frame.origin.x
        var y = frame.origin.y
        var bestDX = threshold
        var bestDY = threshold
        for other in others {
            // Align left-left, right-right; abut right-of, left-of. Only for a
            // vertical neighbor: the tiles' y-spans must near-overlap.
            if frame.minY - proximity < other.maxY, other.minY - proximity < frame.maxY {
                let xCandidates = [other.minX, other.maxX - frame.width,
                                   other.maxX, other.minX - frame.width]
                for candidate in xCandidates {
                    let distance = abs(frame.origin.x - candidate)
                    if distance < bestDX { bestDX = distance; x = candidate }
                }
            }
            // The horizontal mirror: y magnets need near-overlapping x-spans.
            if frame.minX - proximity < other.maxX, other.minX - proximity < frame.maxX {
                let yCandidates = [other.minY, other.maxY - frame.height,
                                   other.maxY, other.minY - frame.height]
                for candidate in yCandidates {
                    let distance = abs(frame.origin.y - candidate)
                    if distance < bestDY { bestDY = distance; y = candidate }
                }
            }
        }
        return CGPoint(
            x: bestDX < threshold ? x : (frame.origin.x / grid).rounded() * grid,
            y: bestDY < threshold ? y : (frame.origin.y / grid).rounded() * grid
        )
    }

    // MARK: - Window-style edge resize

    /// Per-edge deltas for a window-style resize. Left/top move the origin
    /// and shrink the size; right/bottom only grow it.
    public struct EdgeDeltas: Equatable, Sendable {
        public var left: CGFloat
        public var right: CGFloat
        public var top: CGFloat
        public var bottom: CGFloat

        public init(left: CGFloat = 0, right: CGFloat = 0,
                    top: CGFloat = 0, bottom: CGFloat = 0) {
            self.left = left
            self.right = right
            self.top = top
            self.bottom = bottom
        }

        public var isZero: Bool { self == EdgeDeltas() }
    }

    /// The live frame during an edge resize: clamps keep either edge from
    /// pushing past the minimum, and a clamped edge stops the ORIGIN too —
    /// the far edge never slides. (min-floor at 0: a right/bottom drag can
    /// never move the left/top origin.)
    public static func resized(_ frame: CGRect, by edges: EdgeDeltas) -> CGRect {
        let minW = minTileSize.width
        let minH = minTileSize.height
        let left = min(edges.left, max(0, frame.width - minW + edges.right))
        let top = min(edges.top, max(0, frame.height - minH + edges.bottom))
        return CGRect(
            x: frame.origin.x + left,
            y: frame.origin.y + top,
            width: max(minW, frame.width + edges.right - left),
            height: max(minH, frame.height + edges.bottom - top)
        )
    }

    /// Commit snapping for an edge resize: each edge that MOVED snaps to the
    /// grid; edges that did not move stay byte-exact (independent origin/size
    /// rounding slides the stationary edge on half-grid ties).
    ///
    /// When the snapped span lands under the minimum, the MOVED edge yields —
    /// off-grid if it must. The old width clamp pushed the stationary edge
    /// instead, which on an off-grid frame (reflow produces them) slid the one
    /// edge this function promises never to move.
    public static func resizeCommit(_ frame: CGRect, by edges: EdgeDeltas) -> CGRect {
        let live = resized(frame, by: edges)
        let leftMoved = min(edges.left, max(0, frame.width - minTileSize.width + edges.right)) != 0
        let topMoved = min(edges.top, max(0, frame.height - minTileSize.height + edges.bottom)) != 0
        let rightMoved = edges.right != 0
        let bottomMoved = edges.bottom != 0
        var x0 = leftMoved ? (live.minX / grid).rounded() * grid : frame.minX
        var y0 = topMoved ? (live.minY / grid).rounded() * grid : frame.minY
        var x1 = rightMoved ? (live.maxX / grid).rounded() * grid : frame.maxX
        var y1 = bottomMoved ? (live.maxY / grid).rounded() * grid : frame.maxY
        if x1 - x0 < minTileSize.width {
            if leftMoved, !rightMoved { x0 = x1 - minTileSize.width }
            else { x1 = x0 + minTileSize.width }
        }
        if y1 - y0 < minTileSize.height {
            if topMoved, !bottomMoved { y0 = y1 - minTileSize.height }
            else { y1 = y0 + minTileSize.height }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Window-shrink reflow: keep the whole arrangement visible and readable.
    /// First shifts pan so the tiles' bounding box sits inside the viewport;
    /// if the box no longer fits, scales positions AND sizes proportionally
    /// (never below `minTileSize` — overflow prefers showing the top-left).
    /// Returns nil when nothing needs to change.
    public static func reflowed(tiles: [CanvasTile], pan: CGPoint, viewport: CGSize,
                                margin: CGFloat = 24) -> (tiles: [CanvasTile], pan: CGPoint)? {
        guard !tiles.isEmpty, viewport.width > margin * 2, viewport.height > margin * 2 else {
            return nil
        }
        let frames = tiles.map(\.frame)
        let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let available = CGSize(width: viewport.width - margin * 2,
                               height: viewport.height - margin * 2)
        let scale = min(1, available.width / bounds.width, available.height / bounds.height)

        var newTiles = tiles
        if scale < 1 {
            newTiles = tiles.map { tile in
                var scaled = tile
                scaled.origin = CGPoint(
                    x: (tile.origin.x - bounds.minX) * scale + bounds.minX,
                    y: (tile.origin.y - bounds.minY) * scale + bounds.minY)
                scaled.size = CGSize(
                    width: max(minTileSize.width, tile.size.width * scale),
                    height: max(minTileSize.height, tile.size.height * scale))
                return scaled
            }
        }
        let newFrames = newTiles.map(\.frame)
        let newBounds = newFrames.dropFirst().reduce(newFrames[0]) { $0.union($1) }

        var newPan = pan
        let visible = newBounds.offsetBy(dx: newPan.x, dy: newPan.y)
        if visible.maxX > viewport.width - margin {
            newPan.x -= visible.maxX - (viewport.width - margin)
        }
        if visible.maxY > viewport.height - margin {
            newPan.y -= visible.maxY - (viewport.height - margin)
        }
        // After right/bottom shifts, prefer the top-left when it still overflows.
        let shifted = newBounds.offsetBy(dx: newPan.x, dy: newPan.y)
        if shifted.minX < margin { newPan.x += margin - shifted.minX }
        if shifted.minY < margin { newPan.y += margin - shifted.minY }

        if newPan == pan, newTiles == tiles { return nil }
        return (newTiles, newPan)
    }

    /// Zoom that fits a content bounding box in a viewport with margin,
    /// clamped to [minZoom, 1] — fitting never zooms IN past 100%.
    public static func fitZoom(bounds: CGRect, viewport: CGSize,
                               margin: CGFloat = 48, minZoom: CGFloat = 0.2) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0,
              viewport.width > margin * 2, viewport.height > margin * 2 else { return 1 }
        let scale = min((viewport.width - margin * 2) / bounds.width,
                        (viewport.height - margin * 2) / bounds.height)
        return min(1, max(minZoom, scale))
    }

    /// Pan that centers a content bounding box in the viewport at `zoom`
    /// (screen = content × zoom + pan).
    public static func centeringPan(bounds: CGRect, viewport: CGSize,
                                    zoom: CGFloat) -> CGPoint {
        CGPoint(x: (viewport.width - bounds.width * zoom) / 2 - bounds.minX * zoom,
                y: (viewport.height - bounds.height * zoom) / 2 - bounds.minY * zoom)
    }

    /// The nearest non-overlapping, grid-snapped origin for a new tile of
    /// `size` wanting to land at `desired` (its would-be origin): scans a
    /// spiral of grid steps outward until the tile (inflated by `margin`)
    /// clears every existing frame. Deterministic; returns `desired` snapped
    /// when it is already free.
    public static func freePosition(desired: CGPoint, size: CGSize,
                                    avoiding frames: [CGRect],
                                    margin: CGFloat = 16) -> CGPoint {
        let start = snapped(desired)
        func collides(_ origin: CGPoint) -> Bool {
            let candidate = CGRect(origin: origin, size: size)
                .insetBy(dx: -margin, dy: -margin)
            return frames.contains { $0.intersects(candidate) }
        }
        if !collides(start) { return start }
        let step = grid * 2
        for ring in 1...200 {
            let r = CGFloat(ring) * step
            var candidates: [CGPoint] = []
            let steps = ring * 4
            for i in 0..<steps {
                let side = i * 4 / steps
                let t = CGFloat(i % (steps / 4)) / CGFloat(max(1, steps / 4))
                switch side {
                case 0: candidates.append(CGPoint(x: start.x - r + 2 * r * t, y: start.y - r))
                case 1: candidates.append(CGPoint(x: start.x + r, y: start.y - r + 2 * r * t))
                case 2: candidates.append(CGPoint(x: start.x + r - 2 * r * t, y: start.y + r))
                default: candidates.append(CGPoint(x: start.x - r, y: start.y + r - 2 * r * t))
                }
            }
            for candidate in candidates.map({ snapped($0) }) where !collides(candidate) {
                return candidate
            }
        }
        return start   // pathological density: overlap beats losing the tile
    }

    /// Tidy a board: tiles keep their sizes and their reading order
    /// (row-major by current position), and pack into gapped rows whose
    /// width targets the viewport's aspect so the result fits naturally.
    /// Deterministic; origins grid-snapped; never overlaps.
    ///
    /// Clearance invariant — the row cursor advances from the SNAPPED origin,
    /// never from the raw one, so rounding cannot accumulate into an overlap.
    /// A snap moves an origin by less than half a grid step (`snapped` rounds
    /// half away from zero, so a positive origin moves LEFT by < 8 and RIGHT
    /// by ≤ 8). The next tile's raw x is `prevSnappedX + prevWidth + gap`, so
    /// the residual horizontal gap is `gap + (snapped − raw)` > 24 − 8 = 16pt.
    /// Rows advance from the raw `y` accumulator, where the two independent
    /// snaps can eat from both sides: the residual vertical gap is > 24 − 8 − 8
    /// = 8pt worst case (32pt in the common all-grid-multiple case). Both stay
    /// strictly positive, which is what "never overlaps" means here.
    public static func arranged(tiles: [CanvasTile], viewport: CGSize,
                                gap: CGFloat = 24) -> [CanvasTile] {
        guard !tiles.isEmpty else { return tiles }
        // Reading order: coarse rows by y (half a tile-height tolerance),
        // then x. Sort by (bucketed y, x, id) for determinism.
        let sorted = tiles.sorted { a, b in
            let ay = (a.origin.y / 200).rounded(.down)
            let by = (b.origin.y / 200).rounded(.down)
            if ay != by { return ay < by }
            if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
            return a.id.uuidString < b.id.uuidString
        }
        // Target row width: the viewport's aspect applied to the total area,
        // floored by the widest tile.
        let totalArea = sorted.reduce(CGFloat(0)) { $0 + $1.size.width * $1.size.height }
        // Both dimensions, deliberately: a zero height would divide to NaN and
        // poison every origin, and a zero width would silently collapse the
        // board into one column. An unmeasured viewport gets the honest
        // default instead of either.
        let aspect = viewport.width > 0 && viewport.height > 0
            ? viewport.width / viewport.height
            : 16 / 10
        let widest = sorted.map(\.size.width).max() ?? 0
        let targetWidth = max(widest, (totalArea * aspect).squareRoot())

        var result: [CanvasTile] = []
        let originX: CGFloat = 48
        var y: CGFloat = 48
        var x = originX
        var rowHeight: CGFloat = 0
        for var tile in sorted {
            if x > originX, x + tile.size.width > originX + targetWidth {
                y += rowHeight + gap
                x = originX
                rowHeight = 0
            }
            tile.origin = snapped(CGPoint(x: x, y: y))
            result.append(tile)
            x = tile.origin.x + tile.size.width + gap
            rowHeight = max(rowHeight, tile.size.height)
        }
        return result
    }

    public static func staggeredOrigin(existing: Int) -> CGPoint {
        CGPoint(x: 48 + CGFloat(existing) * 64, y: 48 + CGFloat(existing) * 48)
    }
}
