import XCTest
import SkylightCore

final class DockLayoutTests: XCTestCase {
    private func slot(_ weight: CGFloat) -> DockSlot {
        DockSlot(itemID: UUID(), weight: weight)
    }

    private func rail(_ weights: [CGFloat], thickness: CGFloat = 300) -> DockRail {
        DockRail(thickness: thickness, slots: weights.map(slot))
    }

    // MARK: - Normalisation

    func testWeightsNormaliseToOne() {
        let normalised = DockLayout.normalized([.left: rail([2, 1, 1])])
        let weights = normalised[.left]?.slots.map(\.weight) ?? []
        XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(weights[0], 0.5, accuracy: 0.0001)
    }

    /// A hand-edited file is hostile data here exactly as it is for tiles: a
    /// zero or negative weight would divide a rail into nothing, or invert it.
    func testZeroAndNegativeWeightsAreRepairedIntoAnEvenSplit() {
        let weights = DockLayout.normalized([.left: rail([0, -3, 0])])[.left]?
            .slots.map(\.weight) ?? []
        XCTAssertEqual(weights.count, 3)
        for weight in weights {
            XCTAssertEqual(weight, 1.0 / 3, accuracy: 0.0001)
        }
    }

    func testASingleZeroWeightAmongGoodOnesBecomesAFairShare() {
        let weights = DockLayout.normalized([.left: rail([1, 0, 1])])[.left]?
            .slots.map(\.weight) ?? []
        XCTAssertTrue(weights.allSatisfy { $0 > 0 }, "\(weights)")
        XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 0.0001)
    }

    /// An empty rail is not a rail — it would reserve a strip of viewport
    /// holding nothing, and the free canvas would shrink for no reason.
    func testEmptyRailsAreDropped() {
        let normalised = DockLayout.normalized([
            .left: rail([1]), .right: DockRail(thickness: 200, slots: []),
        ])
        XCTAssertNotNil(normalised[.left])
        XCTAssertNil(normalised[.right])
    }

    func testThicknessIsFlooredAtSomethingUsable() {
        let thin = DockLayout.normalized([.left: rail([1], thickness: 4)])
        XCTAssertGreaterThanOrEqual(thin[.left]?.thickness ?? 0,
                                    DockLayout.minimumThickness)
    }

    /// Normalising twice must not drift — the model is normalised on read,
    /// so a value that changed every pass would never settle.
    func testNormalisationIsIdempotent() {
        var seed: UInt64 = 42
        func random() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed % 1000) / 100
        }
        for count in 1...6 {
            let once = DockLayout.normalized(
                [.left: rail((0..<count).map { _ in random() })])
            let twice = DockLayout.normalized(once)
            XCTAssertEqual(once, twice, "count \(count)")
        }
    }

    // MARK: - Shapes (Lattice's vocabulary)

    func testShapeFractions() {
        XCTAssertEqual(DockShape.full.fraction, 1)
        XCTAssertEqual(DockShape.half.fraction, 1.0 / 2)
        XCTAssertEqual(DockShape.third.fraction, 1.0 / 3)
        XCTAssertEqual(DockShape.quarter.fraction, 1.0 / 4)
    }

    func testEveryShapeIsOfferedInACoarseToFineOrder() {
        XCTAssertEqual(DockShape.allCases, [.full, .half, .third, .quarter])
    }
}

// MARK: - Frames

extension DockLayoutTests {
    private var viewport: CGSize { CGSize(width: 1600, height: 1000) }

    private func docked(_ edge: DockEdge, _ count: Int,
                        thickness: CGFloat = 300) -> [DockEdge: DockRail] {
        DockLayout.normalized([edge: DockRail(
            thickness: thickness,
            slots: (0..<count).map { _ in DockSlot(itemID: UUID(), weight: 1) })])
    }

    func testASingleLeftRailShrinksTheFreeRect() {
        let result = DockLayout.frames(docks: docked(.left, 1), viewport: viewport)
        XCTAssertEqual(result.free, CGRect(x: 300, y: 0, width: 1300, height: 1000))
        XCTAssertEqual(result.docked.count, 1)
        XCTAssertEqual(result.docked.values.first,
                       CGRect(x: 0, y: 0, width: 300, height: 1000))
    }

    func testEachEdgeTakesItsOwnSide() {
        for edge in DockEdge.allCases {
            let frame = DockLayout.frames(docks: docked(edge, 1),
                                          viewport: viewport).docked.values.first
            switch edge {
            case .left: XCTAssertEqual(frame?.minX, 0)
            case .right: XCTAssertEqual(frame?.maxX, viewport.width)
            case .top: XCTAssertEqual(frame?.minY, 0)
            case .bottom: XCTAssertEqual(frame?.maxY, viewport.height)
            }
        }
    }

    func testFourRailsLeaveACentreRect() {
        var docks: [DockEdge: DockRail] = [:]
        for edge in DockEdge.allCases {
            docks[edge] = DockRail(thickness: 200,
                                   slots: [DockSlot(itemID: UUID(), weight: 1)])
        }
        let result = DockLayout.frames(docks: DockLayout.normalized(docks),
                                       viewport: viewport)
        XCTAssertEqual(result.free, CGRect(x: 200, y: 200, width: 1200, height: 600))
        XCTAssertEqual(result.docked.count, 4)
    }

    /// A stated rule, never emergent: left and right own the FULL height, and
    /// top/bottom span only what is left between them. Without deciding this,
    /// the corners belong to whichever rail happened to be laid out first.
    func testCornerPrecedenceGivesVerticalRailsFullHeight() {
        var docks: [DockEdge: DockRail] = [:]
        docks[.left] = DockRail(thickness: 200, slots: [DockSlot(itemID: UUID())])
        docks[.top] = DockRail(thickness: 100, slots: [DockSlot(itemID: UUID())])
        let result = DockLayout.frames(docks: DockLayout.normalized(docks),
                                       viewport: viewport)
        let left = result.docked.first { $0.value.minX == 0 }?.value
        let top = result.docked.first { $0.value.minY == 0 && $0.value.minX > 0 }?.value
        XCTAssertEqual(left?.height, 1000, "left rail must own full height")
        XCTAssertEqual(top?.minX, 200, "top rail must start after the left rail")
        XCTAssertEqual(top?.width, 1400)
    }

    func testSlotsSplitTheRailByWeight() {
        let docks = DockLayout.normalized([.left: DockRail(thickness: 300, slots: [
            DockSlot(itemID: UUID(), weight: 3),
            DockSlot(itemID: UUID(), weight: 1),
        ])])
        let frames = DockLayout.frames(docks: docks, viewport: viewport)
            .docked.values.sorted { $0.minY < $1.minY }
        XCTAssertEqual(frames[0].height, 750, accuracy: 0.001)
        XCTAssertEqual(frames[1].height, 250, accuracy: 0.001)
        XCTAssertEqual(frames[0].maxY, frames[1].minY, accuracy: 0.001)
    }

    /// Docked frames may never overlap each other or the free rect — that is
    /// the entire promise of a tiled region.
    func testFramesNeverOverlap() {
        for edge in DockEdge.allCases {
            for count in 1...6 {
                let result = DockLayout.frames(docks: docked(edge, count),
                                               viewport: viewport)
                let frames = Array(result.docked.values)
                for i in frames.indices {
                    XCTAssertFalse(frames[i].intersects(result.free),
                                   "\(edge) \(count): overlapped the free rect")
                    for j in (i + 1)..<frames.count {
                        XCTAssertFalse(frames[i].insetBy(dx: 0.01, dy: 0.01)
                            .intersects(frames[j]), "\(edge) \(count): slots overlap")
                    }
                }
            }
        }
    }

    /// A rail may not eat the viewport it is supposed to frame.
    func testThicknessIsCappedAtAShareOfTheViewport() {
        let result = DockLayout.frames(docks: docked(.left, 1, thickness: 5000),
                                       viewport: viewport)
        XCTAssertLessThanOrEqual(result.docked.values.first?.width ?? 0,
                                 viewport.width * DockLayout.maximumViewportShare)
        XCTAssertGreaterThan(result.free.width, 0)
    }

    func testADegenerateViewportYieldsNoNaN() {
        for size in [CGSize(width: 0, height: 0), CGSize(width: 10, height: 10),
                     CGSize(width: -5, height: 100)] {
            let result = DockLayout.frames(docks: docked(.left, 2), viewport: size)
            XCTAssertFalse(result.free.origin.x.isNaN, "\(size)")
            for frame in result.docked.values {
                XCTAssertFalse(frame.width.isNaN || frame.height.isNaN, "\(size)")
            }
        }
    }
}

// MARK: - Hit testing and transitions

extension DockLayoutTests {
    func testAPointNearAnEdgeTargetsThatEdge() {
        let vp = CGSize(width: 1600, height: 1000)
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: 8, y: 500),
                                          viewport: vp)?.edge, .left)
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: 1594, y: 500),
                                          viewport: vp)?.edge, .right)
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: 800, y: 6),
                                          viewport: vp)?.edge, .top)
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: 800, y: 994),
                                          viewport: vp)?.edge, .bottom)
    }

    /// The middle of the canvas is not a dock target. Docking must be a
    /// deliberate act at an edge, or every drag becomes a gamble.
    func testTheCentreTargetsNothing() {
        XCTAssertNil(DockLayout.hitTest(point: CGPoint(x: 800, y: 500),
                                        viewport: CGSize(width: 1600, height: 1000)))
    }

    /// Deeper into the edge means a bigger share — the gesture reads as
    /// "push harder, take more".
    func testShapeCoarsensAsThePointerPushesFurtherIn() {
        let vp = CGSize(width: 1600, height: 1000)
        let atEdge = DockLayout.hitTest(point: CGPoint(x: 1, y: 500), viewport: vp)
        let nearThreshold = DockLayout.hitTest(point: CGPoint(x: 30, y: 500), viewport: vp)
        XCTAssertNotNil(atEdge)
        XCTAssertNotNil(nearThreshold)
        XCTAssertGreaterThanOrEqual(atEdge!.shape.fraction, nearThreshold!.shape.fraction)
    }

    func testInsertionIndexFollowsThePointerAlongTheRail() {
        let vp = CGSize(width: 1600, height: 1000)
        let docks = DockLayout.normalized([.left: DockRail(thickness: 300, slots: [
            DockSlot(itemID: UUID()), DockSlot(itemID: UUID()),
        ])])
        let top = DockLayout.hitTest(point: CGPoint(x: 8, y: 10),
                                     viewport: vp, docks: docks)
        let bottom = DockLayout.hitTest(point: CGPoint(x: 8, y: 990),
                                        viewport: vp, docks: docks)
        XCTAssertEqual(top?.insertionIndex, 0)
        XCTAssertEqual(bottom?.insertionIndex, 2)
    }

    func testDockingInsertsAtTheRequestedIndex() {
        let existing = DockSlot(itemID: UUID())
        let docks: [DockEdge: DockRail] = [.left: DockRail(slots: [existing])]
        let newItem = UUID()
        let result = DockLayout.docked(docks, item: newItem,
                                       to: DockTarget(edge: .left, insertionIndex: 0,
                                                      shape: .half))
        XCTAssertEqual(result[.left]?.slots.map(\.itemID), [newItem, existing.itemID])
    }

    /// Docking something already docked MOVES it — two slots for one terminal
    /// would mean one live NSView claimed twice.
    func testDockingAnAlreadyDockedItemMovesIt() {
        let item = UUID()
        let docks: [DockEdge: DockRail] = [.left: DockRail(slots: [DockSlot(itemID: item)])]
        let result = DockLayout.docked(docks, item: item,
                                       to: DockTarget(edge: .right, insertionIndex: 0,
                                                      shape: .full))
        XCTAssertNil(result[.left])
        XCTAssertEqual(result[.right]?.slots.map(\.itemID), [item])
        XCTAssertEqual(result.values.reduce(0) { $0 + $1.slots.count }, 1)
    }

    func testUndockingRemovesTheSlotAndDropsAnEmptyRail() {
        let item = UUID()
        let docks: [DockEdge: DockRail] = [.left: DockRail(slots: [DockSlot(itemID: item)])]
        XCTAssertTrue(DockLayout.undocked(docks, item: item).isEmpty)
    }

    func testUndockingKeepsSiblings() {
        let item = UUID(), sibling = UUID()
        let docks: [DockEdge: DockRail] = [.left: DockRail(slots: [
            DockSlot(itemID: item), DockSlot(itemID: sibling),
        ])]
        let result = DockLayout.undocked(docks, item: item)
        XCTAssertEqual(result[.left]?.slots.map(\.itemID), [sibling])
    }

    func testDockedItemsAreEnumerable() {
        let a = UUID(), b = UUID()
        let docks: [DockEdge: DockRail] = [
            .left: DockRail(slots: [DockSlot(itemID: a)]),
            .top: DockRail(slots: [DockSlot(itemID: b)]),
        ]
        XCTAssertEqual(DockLayout.dockedItems(docks), Set([a, b]))
    }
}

/// I3: the drag must hit-test the POINTER, not the tile's corner.
///
/// The reviewer's case, reproduced: a 1400x900 viewport with a 560x400 tile.
/// Hit-testing the corner means the right rail needs the corner at x≥1364,
/// i.e. the pointer roughly 280pt outside the window — unreachable. Left and
/// top fire half a tile early, and once the corner goes negative the
/// non-negative filter drops the edge entirely, so pushing further in makes
/// the ghost vanish.
final class DockPointerHitTestTests: XCTestCase {
    private let viewport = CGSize(width: 1400, height: 900)

    /// Grab the middle of a 560x400 tile and drag it until the POINTER is at
    /// each edge. Every edge must be reachable.
    func testEveryEdgeIsReachableWhenDraggingByThePointer() {
        for (name, point) in [("left", CGPoint(x: 6, y: 450)),
                              ("right", CGPoint(x: 1394, y: 450)),
                              ("top", CGPoint(x: 700, y: 6)),
                              ("bottom", CGPoint(x: 700, y: 894))] {
            XCTAssertNotNil(DockLayout.hitTest(point: point, viewport: viewport),
                            "\(name) edge unreachable at \(point)")
        }
    }

    /// A pointer past the window edge still targets that edge rather than
    /// falling off the end of the world — dragging hard into the left must
    /// not make the ghost disappear.
    func testAPointerBeyondAnEdgeStillTargetsIt() {
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: -20, y: 450),
                                          viewport: viewport)?.edge, .left)
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: 1420, y: 450),
                                          viewport: viewport)?.edge, .right)
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: 700, y: -10),
                                          viewport: viewport)?.edge, .top)
        XCTAssertEqual(DockLayout.hitTest(point: CGPoint(x: 700, y: 910),
                                          viewport: viewport)?.edge, .bottom)
    }

    /// Pushing further past an edge must not change which edge is chosen.
    func testPushingHarderKeepsTheSameEdge() {
        for x in stride(from: 20.0, through: -200.0, by: -20.0) {
            XCTAssertEqual(
                DockLayout.hitTest(point: CGPoint(x: x, y: 450),
                                   viewport: viewport)?.edge, .left,
                "lost the left edge at x=\(x)")
        }
    }

    /// A tile's CORNER at the middle of the canvas means the pointer is
    /// nowhere near an edge: dragging by the middle of a tile must not dock
    /// half a tile early.
    func testTheCentreStillTargetsNothing() {
        XCTAssertNil(DockLayout.hitTest(point: CGPoint(x: 700, y: 450),
                                        viewport: viewport))
    }
}
