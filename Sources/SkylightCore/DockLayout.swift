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
