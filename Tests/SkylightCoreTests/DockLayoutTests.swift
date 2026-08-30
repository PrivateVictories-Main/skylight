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
