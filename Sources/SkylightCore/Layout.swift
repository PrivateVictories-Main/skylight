import CoreGraphics

public enum CanvasLayout {
    public static let grid: CGFloat = 16
    public static let minTileSize = CGSize(width: 320, height: 220)
    public static let defaultTileSize = CGSize(width: 560, height: 400)

    public static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, (point.x / grid).rounded() * grid),
            y: max(0, (point.y / grid).rounded() * grid)
        )
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
