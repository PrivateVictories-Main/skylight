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

    public static func staggeredOrigin(existing: Int) -> CGPoint {
        CGPoint(x: 48 + CGFloat(existing) * 64, y: 48 + CGFloat(existing) * 48)
    }
}
