import CoreGraphics
import Foundation

/// Which side of the viewport a rail is pinned to.
public enum DockEdge: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// Left and right own a WIDTH; top and bottom own a HEIGHT.
    public var isVertical: Bool { self == .left || self == .right }
}

/// How much of a rail a newly docked tile takes.
///
/// Halves, thirds, quarters — the vocabulary from Lattice, deliberately. It
/// is what Ryan already reaches for when arranging windows, and inventing a
/// second language for the same gesture in a second app of his would be a
/// worse idea than any of the individual fractions.
public enum DockShape: Equatable, Hashable, Sendable, CaseIterable {
    case full, half, third, quarter

    public var fraction: CGFloat {
        switch self {
        case .full: 1
        case .half: 1.0 / 2
        case .third: 1.0 / 3
        case .quarter: 1.0 / 4
        }
    }

    /// Coarse to fine: the shapes a drag offers as it approaches an edge, in
    /// the order a hand expects to meet them.
    public static let allCases: [DockShape] = [.full, .half, .third, .quarter]
}

/// One docked tile's share of its rail.
public struct DockSlot: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var itemID: UUID
    /// Share of the rail's long axis. Normalised on read — see
    /// `DockLayout.normalized`.
    public var weight: CGFloat

    public init(id: UUID = UUID(), itemID: UUID, weight: CGFloat = 1) {
        self.id = id
        self.itemID = itemID
        self.weight = weight
    }
}

/// A strip pinned to one edge of the viewport.
public struct DockRail: Codable, Equatable, Hashable, Sendable {
    /// Points across the SHORT axis: a width for left/right, a height for
    /// top/bottom.
    public var thickness: CGFloat
    public var slots: [DockSlot]

    public init(thickness: CGFloat = 360, slots: [DockSlot] = []) {
        self.thickness = thickness
        self.slots = slots
    }
}

/// The geometry of docked rails — pure, deterministic, and testable without a
/// window, exactly like `CanvasLayout` beside it.
///
/// Rails are pinned to the VIEWPORT, not to the board: they do not pan and
/// they do not zoom. That is the whole reason this is a separate model rather
/// than more tiles — a "left dock" made of ordinary tiles pans away the
/// moment you scroll the canvas, which is what made docking impossible before.
public enum DockLayout {
    /// A rail thinner than this is a sliver nobody can use or grab.
    public static let minimumThickness: CGFloat = CanvasLayout.minTileSize.width / 2
    /// No rail may eat more than this share of the viewport's short axis —
    /// past it the "free canvas" the rails are supposed to frame stops
    /// existing.
    public static let maximumViewportShare: CGFloat = 0.6

    /// Repair a dock set into something that can be laid out.
    ///
    /// Stored data is hostile here for the same reasons it is for tiles: a
    /// hand-edited or partly-written file can carry zero weights (a rail
    /// divided into nothing), negative weights (an inverted one), or an empty
    /// rail that would reserve a strip of viewport holding nothing while the
    /// free canvas shrank to make room for it.
    ///
    /// Idempotent, because the model is normalised on read: a value that
    /// changed on every pass would never settle.
    public static func normalized(_ docks: [DockEdge: DockRail]) -> [DockEdge: DockRail] {
        var result: [DockEdge: DockRail] = [:]
        for (edge, rail) in docks {
            guard !rail.slots.isEmpty else { continue }
            var rail = rail
            rail.thickness = max(minimumThickness, rail.thickness)

            let usable = rail.slots.filter { $0.weight > 0 && $0.weight.isFinite }
            if usable.isEmpty {
                // Nothing survived: an even split is the only fair reading.
                let share = 1 / CGFloat(rail.slots.count)
                rail.slots = rail.slots.map {
                    var slot = $0
                    slot.weight = share
                    return slot
                }
            } else {
                // A slot with no usable weight gets an average share rather
                // than vanishing — it still has a terminal in it.
                let average = usable.reduce(0) { $0 + $1.weight } / CGFloat(usable.count)
                let repaired = rail.slots.map { slot -> DockSlot in
                    var slot = slot
                    if !(slot.weight > 0 && slot.weight.isFinite) { slot.weight = average }
                    return slot
                }
                let total = repaired.reduce(0) { $0 + $1.weight }
                // Already normal: leave the weights BYTE-IDENTICAL rather
                // than dividing by a sum of 1. Two reasons, and the second is
                // the important one. Repeated division perturbs the last bit,
                // so exact idempotence is otherwise unreachable. And this runs
                // on every read — rewriting equal-but-not-identical values
                // would make the board differ from itself constantly, which
                // invalidates every Equatable diff SwiftUI depends on.
                if abs(total - 1) > 1e-9 || repaired != rail.slots {
                    rail.slots = repaired.map { slot in
                        var slot = slot
                        slot.weight /= total
                        return slot
                    }
                } else {
                    rail.slots = repaired
                }
            }
            result[edge] = rail
        }
        return result
    }
}

/// Where a drag would dock, if released now.
public struct DockTarget: Equatable, Sendable {
    public let edge: DockEdge
    /// Where in the rail's slot order it would land.
    public let insertionIndex: Int
    public let shape: DockShape

    public init(edge: DockEdge, insertionIndex: Int, shape: DockShape) {
        self.edge = edge
        self.insertionIndex = insertionIndex
        self.shape = shape
    }
}

public extension DockLayout {
    /// How close to an edge counts as aiming at it.
    static let edgeThreshold: CGFloat = 36

    /// Screen-space frames for every docked tile, plus what is left for the
    /// free canvas.
    ///
    /// **Corner precedence is a stated rule, never emergent.** Left and right
    /// rails own the FULL height; top and bottom span only what remains
    /// between them. Without deciding that, the corners would belong to
    /// whichever rail happened to be laid out first — which is to say, to
    /// dictionary iteration order, which is to say, to nothing.
    static func frames(docks: [DockEdge: DockRail],
                       viewport: CGSize) -> (docked: [UUID: CGRect], free: CGRect) {
        let width = max(0, viewport.width)
        let height = max(0, viewport.height)
        var free = CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0 else { return ([:], free) }

        /// A rail may never eat the viewport it exists to frame.
        func thickness(_ rail: DockRail, along axis: CGFloat) -> CGFloat {
            min(max(minimumThickness, rail.thickness), axis * maximumViewportShare)
        }

        // Vertical rails first — they own the corners.
        var leftWidth: CGFloat = 0
        var rightWidth: CGFloat = 0
        if let rail = docks[.left] { leftWidth = thickness(rail, along: width) }
        if let rail = docks[.right] { rightWidth = thickness(rail, along: width) }
        // Both together must still leave something in the middle.
        let verticalTotal = leftWidth + rightWidth
        if verticalTotal > width * maximumViewportShare, verticalTotal > 0 {
            let scale = (width * maximumViewportShare) / verticalTotal
            leftWidth *= scale
            rightWidth *= scale
        }

        var topHeight: CGFloat = 0
        var bottomHeight: CGFloat = 0
        if let rail = docks[.top] { topHeight = thickness(rail, along: height) }
        if let rail = docks[.bottom] { bottomHeight = thickness(rail, along: height) }
        let horizontalTotal = topHeight + bottomHeight
        if horizontalTotal > height * maximumViewportShare, horizontalTotal > 0 {
            let scale = (height * maximumViewportShare) / horizontalTotal
            topHeight *= scale
            bottomHeight *= scale
        }

        let middleX = leftWidth
        let middleWidth = max(0, width - leftWidth - rightWidth)

        var result: [UUID: CGRect] = [:]

        /// Divide a rail's long axis by weight.
        func place(_ rail: DockRail, in bounds: CGRect, vertical: Bool) {
            let span = vertical ? bounds.height : bounds.width
            var offset: CGFloat = vertical ? bounds.minY : bounds.minX
            for slot in rail.slots {
                let length = span * slot.weight
                result[slot.itemID] = vertical
                    ? CGRect(x: bounds.minX, y: offset, width: bounds.width, height: length)
                    : CGRect(x: offset, y: bounds.minY, width: length, height: bounds.height)
                offset += length
            }
        }

        if let rail = docks[.left] {
            place(rail, in: CGRect(x: 0, y: 0, width: leftWidth, height: height),
                  vertical: true)
        }
        if let rail = docks[.right] {
            place(rail, in: CGRect(x: width - rightWidth, y: 0,
                                   width: rightWidth, height: height), vertical: true)
        }
        if let rail = docks[.top] {
            place(rail, in: CGRect(x: middleX, y: 0,
                                   width: middleWidth, height: topHeight), vertical: false)
        }
        if let rail = docks[.bottom] {
            place(rail, in: CGRect(x: middleX, y: height - bottomHeight,
                                   width: middleWidth, height: bottomHeight),
                  vertical: false)
        }

        free = CGRect(x: middleX, y: topHeight, width: middleWidth,
                      height: max(0, height - topHeight - bottomHeight))
        return (result, free)
    }

    /// What a drag at this point would do, or nil for "nothing" — the middle
    /// of the canvas is not a dock target, because docking has to be a
    /// deliberate act at an edge rather than a gamble on every drag.
    static func hitTest(point: CGPoint, viewport: CGSize,
                        docks: [DockEdge: DockRail] = [:]) -> DockTarget? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let distances: [(DockEdge, CGFloat)] = [
            (.left, point.x),
            (.right, viewport.width - point.x),
            (.top, point.y),
            (.bottom, viewport.height - point.y),
        ]
        guard let (edge, depth) = distances.filter({ $0.1 >= 0 })
            .min(by: { $0.1 < $1.1 }), depth <= edgeThreshold else { return nil }

        // Deeper in means a BIGGER share: the gesture reads as "push harder,
        // take more", and the coarse shape is the one you meet first.
        let progress = max(0, min(1, depth / edgeThreshold))
        let shape: DockShape
        switch progress {
        case ..<0.25: shape = .full
        case ..<0.5: shape = .half
        case ..<0.75: shape = .third
        default: shape = .quarter
        }

        // Where along the rail the pointer is, in existing slot terms.
        let existing = docks[edge]?.slots.count ?? 0
        var insertionIndex = 0
        if existing > 0 {
            let along = edge.isVertical
                ? point.y / max(1, viewport.height)
                : point.x / max(1, viewport.width)
            insertionIndex = min(existing, max(0, Int((along * CGFloat(existing)).rounded())))
        }
        return DockTarget(edge: edge, insertionIndex: insertionIndex, shape: shape)
    }

    /// Dock an item, moving it if it was docked elsewhere.
    ///
    /// A terminal in two slots would be one live NSView claimed twice — the
    /// same invariant single residency protects for tiles.
    static func docked(_ docks: [DockEdge: DockRail], item: UUID,
                       to target: DockTarget) -> [DockEdge: DockRail] {
        var docks = undocked(docks, item: item)
        var rail = docks[target.edge] ?? DockRail()
        let index = min(max(0, target.insertionIndex), rail.slots.count)
        // The new slot's share of the rail is the shape it was dropped with;
        // normalisation turns that into a weight against its siblings.
        let siblingTotal = rail.slots.reduce(0) { $0 + $1.weight }
        let weight = rail.slots.isEmpty
            ? 1
            : max(0.05, siblingTotal * target.shape.fraction / max(0.05, 1 - target.shape.fraction))
        rail.slots.insert(DockSlot(itemID: item, weight: weight), at: index)
        docks[target.edge] = rail
        return normalized(docks)
    }

    /// Remove an item from whatever rail holds it, dropping a rail that ends
    /// up empty.
    static func undocked(_ docks: [DockEdge: DockRail], item: UUID) -> [DockEdge: DockRail] {
        var result: [DockEdge: DockRail] = [:]
        for (edge, rail) in docks {
            var rail = rail
            rail.slots.removeAll { $0.itemID == item }
            if !rail.slots.isEmpty { result[edge] = rail }
        }
        return result
    }

    /// Every instance currently docked anywhere on this board.
    static func dockedItems(_ docks: [DockEdge: DockRail]) -> Set<UUID> {
        Set(docks.values.flatMap { $0.slots.map(\.itemID) })
    }
}
