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
    public static func magnetSnapped(_ frame: CGRect, against others: [CGRect],
                                     threshold: CGFloat = 12) -> CGPoint {
        var x = frame.origin.x
        var y = frame.origin.y
        var bestDX = threshold
        var bestDY = threshold
        for other in others {
            // Align left-left, right-right; abut right-of, left-of.
            let xCandidates = [other.minX, other.maxX - frame.width,
                               other.maxX, other.minX - frame.width]
            for candidate in xCandidates {
                let distance = abs(frame.origin.x - candidate)
                if distance < bestDX { bestDX = distance; x = candidate }
            }
            let yCandidates = [other.minY, other.maxY - frame.height,
                               other.maxY, other.minY - frame.height]
            for candidate in yCandidates {
                let distance = abs(frame.origin.y - candidate)
                if distance < bestDY { bestDY = distance; y = candidate }
            }
        }
        return CGPoint(
            x: bestDX < threshold ? x : (frame.origin.x / grid).rounded() * grid,
            y: bestDY < threshold ? y : (frame.origin.y / grid).rounded() * grid
        )
    }

    public static func staggeredOrigin(existing: Int) -> CGPoint {
        CGPoint(x: 48 + CGFloat(existing) * 64, y: 48 + CGFloat(existing) * 48)
    }
}
