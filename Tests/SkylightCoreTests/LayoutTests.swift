import XCTest
import SkylightCore

final class LayoutTests: XCTestCase {
    func testSnapsPointToGrid() {
        XCTAssertEqual(CanvasLayout.snapped(CGPoint(x: 23, y: 40)), CGPoint(x: 16, y: 48))
        XCTAssertEqual(CanvasLayout.snapped(CGPoint(x: 8, y: 8)), CGPoint(x: 16, y: 16))
    }

    func testSnappedPointAllowsNegativeCoordinates() {
        // The canvas is endless: tiles can live left of and above the origin.
        XCTAssertEqual(CanvasLayout.snapped(CGPoint(x: -40, y: -5)), CGPoint(x: -48, y: 0))
        // -0.5 and -1.5 both round away from zero: -8 → -16, -24 → -32.
        XCTAssertEqual(CanvasLayout.snapped(CGPoint(x: -8, y: -24)), CGPoint(x: -16, y: -32))
    }

    func testPanToCenterCentersTheTileInTheViewport() {
        let tile = CGRect(x: 200, y: 100, width: 400, height: 200)   // center (400, 200)
        let pan = CanvasLayout.panToCenter(tile, in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(pan, CGPoint(x: 100, y: 200))                 // 500-400, 400-200
    }

    func testSnapsSizeToGridWithMinimum() {
        XCTAssertEqual(CanvasLayout.snapped(CGSize(width: 100, height: 100)),
                       CanvasLayout.minTileSize)
        XCTAssertEqual(CanvasLayout.snapped(CGSize(width: 505, height: 399)),
                       CGSize(width: 512, height: 400))
    }

    func testResizeFarEdgeNeverSlides() {
        let frame = CGRect(x: 96, y: 96, width: 608, height: 400)
        // Sweep half-grid ties and past-min drags on the left edge: the right
        // edge must stay at exactly 704 through every one of them.
        for dx in stride(from: -64.0, through: 64.0, by: 0.5) {
            let commit = CanvasLayout.resizeCommit(frame,
                by: CanvasLayout.EdgeDeltas(left: dx))
            XCTAssertEqual(commit.maxX, 704, "left drag dx=\(dx) slid the right edge")
        }
        for dx in stride(from: -400.0, through: 64.0, by: 0.5) {
            let commit = CanvasLayout.resizeCommit(frame,
                by: CanvasLayout.EdgeDeltas(right: dx))
            XCTAssertEqual(commit.minX, 96, "right drag dx=\(dx) slid the left edge")
        }
    }

    func testResizeClampStopsOriginAtMinimum() {
        let frame = CGRect(x: 96, y: 96, width: 608, height: 400)
        let live = CanvasLayout.resized(frame, by: CanvasLayout.EdgeDeltas(left: 500))
        XCTAssertEqual(live.width, CanvasLayout.minTileSize.width)
        XCTAssertEqual(live.maxX, 704)   // far edge pinned even past the min
    }

    func testResizeNoOpWhenClampedToZero() {
        // Min-width tile, off-grid origin, inward left drag: nothing may move.
        let frame = CGRect(x: 105, y: 96, width: 320, height: 400)
        let commit = CanvasLayout.resizeCommit(frame,
            by: CanvasLayout.EdgeDeltas(left: 30))
        XCTAssertEqual(commit, frame)
    }

    func testStaggeredOriginWalksDiagonally() {
        XCTAssertEqual(CanvasLayout.staggeredOrigin(existing: 0), CGPoint(x: 48, y: 48))
        XCTAssertEqual(CanvasLayout.staggeredOrigin(existing: 2), CGPoint(x: 176, y: 144))
    }

    func testMagnetAlignsEdgesWithinThreshold() {
        let other = CGRect(x: 96, y: 320, width: 560, height: 400)
        let dragged = CGRect(x: 104, y: 40, width: 560, height: 400)
        // x magnets to other's left edge (8pt away); y has no magnet → grid (40 → 48).
        XCTAssertEqual(CanvasLayout.magnetSnapped(dragged, against: [other]),
                       CGPoint(x: 96, y: 48))
    }

    func testMagnetAbutsAdjacentEdges() {
        let other = CGRect(x: 96, y: 320, width: 560, height: 400)   // maxX = 656
        let dragged = CGRect(x: 660, y: 320, width: 560, height: 400)
        XCTAssertEqual(CanvasLayout.magnetSnapped(dragged, against: [other]),
                       CGPoint(x: 656, y: 320))
    }

    func testNearestMagnetWins() {
        let a = CGRect(x: 96, y: 0, width: 100, height: 100)
        let b = CGRect(x: 112, y: 0, width: 100, height: 100)
        let dragged = CGRect(x: 106, y: 0, width: 100, height: 100)
        XCTAssertEqual(CanvasLayout.magnetSnapped(dragged, against: [a, b]).x, 112)
    }

    func testMagnetIgnoresFarPerpendicularNeighbors() {
        // Same x-alignment candidate, but 1000pt below: no magnet — grid wins.
        let farBelow = CGRect(x: 96, y: 1500, width: 560, height: 400)
        let dragged = CGRect(x: 104, y: 40, width: 560, height: 400)
        XCTAssertEqual(CanvasLayout.magnetSnapped(dragged, against: [farBelow]),
                       CGPoint(x: 112, y: 48))   // 104 → grid 112 (no 96 magnet)
    }

    func testMagnetStillFiresWithinProximity() {
        let nearBelow = CGRect(x: 96, y: 520, width: 560, height: 400)   // 80pt gap
        let dragged = CGRect(x: 104, y: 40, width: 560, height: 400)
        XCTAssertEqual(CanvasLayout.magnetSnapped(dragged, against: [nearBelow]).x, 96)
    }

    func testNoMagnetsFallsBackToGridOnBothAxes() {
        let dragged = CGRect(x: 40, y: 40, width: 560, height: 400)
        XCTAssertEqual(CanvasLayout.magnetSnapped(dragged, against: []),
                       CGPoint(x: 48, y: 48))
    }

    func testReflowReturnsNilWhenEverythingFits() {
        let tile = CanvasTile(itemID: UUID(), origin: CGPoint(x: 48, y: 48),
                              size: CGSize(width: 560, height: 400))
        XCTAssertNil(CanvasLayout.reflowed(tiles: [tile], pan: .zero,
                                           viewport: CGSize(width: 1200, height: 800)))
    }

    func testReflowShiftsPanBeforeTouchingTiles() throws {
        let tile = CanvasTile(itemID: UUID(), origin: CGPoint(x: 1000, y: 0),
                              size: CGSize(width: 560, height: 400))
        let result = try XCTUnwrap(CanvasLayout.reflowed(
            tiles: [tile], pan: .zero, viewport: CGSize(width: 800, height: 600)))
        XCTAssertEqual(result.tiles[0].origin, CGPoint(x: 1000, y: 0))   // untouched
        XCTAssertEqual(result.tiles[0].size, CGSize(width: 560, height: 400))
        XCTAssertEqual(result.pan, CGPoint(x: -784, y: 24))
    }

    func testReflowScalesArrangementUniformlyToFit() throws {
        let a = CanvasTile(itemID: UUID(), origin: .zero,
                           size: CGSize(width: 560, height: 400))
        let b = CanvasTile(itemID: UUID(), origin: CGPoint(x: 640, y: 0),
                           size: CGSize(width: 560, height: 400))
        let result = try XCTUnwrap(CanvasLayout.reflowed(
            tiles: [a, b], pan: .zero, viewport: CGSize(width: 800, height: 600)))
        let frames = result.tiles.map(\.frame)
        let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let visible = bounds.offsetBy(dx: result.pan.x, dy: result.pan.y)
        XCTAssertGreaterThanOrEqual(visible.minX, 24)
        XCTAssertGreaterThanOrEqual(visible.minY, 24)
        XCTAssertLessThanOrEqual(visible.maxX, 776 + 0.001)
        XCTAssertLessThanOrEqual(visible.maxY, 576 + 0.001)
        XCTAssertGreaterThanOrEqual(result.tiles[0].size.width,
                                    CanvasLayout.minTileSize.width)
        // Uniform: both tiles shrank by the same factor.
        XCTAssertEqual(result.tiles[0].size.width / 560,
                       result.tiles[1].size.width / 560, accuracy: 0.001)
    }

    func testReflowOverflowPrefersTopLeft() throws {
        let a = CanvasTile(itemID: UUID(), origin: .zero,
                           size: CGSize(width: 560, height: 400))
        let b = CanvasTile(itemID: UUID(), origin: CGPoint(x: 640, y: 0),
                           size: CGSize(width: 560, height: 400))
        let result = try XCTUnwrap(CanvasLayout.reflowed(
            tiles: [a, b], pan: .zero, viewport: CGSize(width: 400, height: 400)))
        let frames = result.tiles.map(\.frame)
        let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let visible = bounds.offsetBy(dx: result.pan.x, dy: result.pan.y)
        XCTAssertEqual(visible.minX, 24, accuracy: 0.001)
        XCTAssertEqual(visible.minY, 24, accuracy: 0.001)
        XCTAssertEqual(result.tiles.map(\.size.width), [320, 320])   // min clamp engaged
    }

    func testFreePositionReturnsDesiredWhenClear() {
        XCTAssertEqual(
            CanvasLayout.freePosition(desired: CGPoint(x: 100, y: 100),
                                      size: CanvasLayout.defaultTileSize,
                                      avoiding: []),
            CGPoint(x: 96, y: 96))   // grid-snapped only
    }

    func testFreePositionDodgesAnOccupiedSpot() {
        let occupied = [CGRect(x: 96, y: 96, width: 560, height: 400)]
        let result = CanvasLayout.freePosition(desired: CGPoint(x: 100, y: 100),
                                               size: CanvasLayout.defaultTileSize,
                                               avoiding: occupied)
        let landed = CGRect(origin: result, size: CanvasLayout.defaultTileSize)
            .insetBy(dx: -16, dy: -16)
        XCTAssertFalse(occupied.contains { $0.intersects(landed) })
        // Deterministic: same inputs, same answer.
        XCTAssertEqual(result,
                       CanvasLayout.freePosition(desired: CGPoint(x: 100, y: 100),
                                                 size: CanvasLayout.defaultTileSize,
                                                 avoiding: occupied))
    }

    func testFreePositionPrefersNearbySpace() {
        // One tile at origin; desired inside it → the found spot is within a
        // couple of rings, not across the plane.
        let occupied = [CGRect(x: 0, y: 0, width: 560, height: 400)]
        let result = CanvasLayout.freePosition(desired: .zero,
                                               size: CGSize(width: 320, height: 220),
                                               avoiding: occupied)
        XCTAssertLessThan(abs(result.x) + abs(result.y), 800)
    }

    func testFreePositionIsGridSnapped() {
        let occupied = [CGRect(x: 96, y: 96, width: 560, height: 400)]
        let r = CanvasLayout.freePosition(desired: CGPoint(x: 100, y: 100),
                                          size: CanvasLayout.defaultTileSize,
                                          avoiding: occupied)
        XCTAssertEqual(r.x.truncatingRemainder(dividingBy: CanvasLayout.grid), 0)
        XCTAssertEqual(r.y.truncatingRemainder(dividingBy: CanvasLayout.grid), 0)
    }

    func testFitZoomShrinksToFitAndNeverZoomsIn() {
        XCTAssertEqual(CanvasLayout.fitZoom(bounds: CGRect(x: 0, y: 0, width: 2000, height: 800),
                                            viewport: CGSize(width: 1048, height: 800)),
                       (1048.0 - 96) / 2000, accuracy: 0.0001)   // width-limited
        XCTAssertEqual(CanvasLayout.fitZoom(bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                                            viewport: CGSize(width: 1000, height: 800)),
                       1)                                        // small content: stay at 100%
    }

    func testFitZoomClampsToMinimum() {
        XCTAssertEqual(CanvasLayout.fitZoom(bounds: CGRect(x: 0, y: 0, width: 100000, height: 100),
                                            viewport: CGSize(width: 1000, height: 800)),
                       0.2)
    }

    func testCenteringPanCentersAtZoom() {
        // bounds 400×200 at (100, 50), viewport 1000×800, zoom 0.5:
        // scaled bounds 200×100 → centered at (400, 350); minX×zoom = 50 → pan.x = 350.
        let pan = CanvasLayout.centeringPan(bounds: CGRect(x: 100, y: 50, width: 400, height: 200),
                                            viewport: CGSize(width: 1000, height: 800),
                                            zoom: 0.5)
        XCTAssertEqual(pan.x, 350, accuracy: 0.0001)
        XCTAssertEqual(pan.y, 325, accuracy: 0.0001)
    }

    /// Ryan's directive end-to-end: dropping instance after instance at the
    /// same spot never stacks them, and the growing arrangement is something
    /// the canvas must zoom OUT to show whole.
    func testAccumulatingTilesNeverOverlapAndForceZoomOut() {
        var frames: [CGRect] = []
        for _ in 0..<5 {
            let origin = CanvasLayout.freePosition(desired: CGPoint(x: 100, y: 100),
                                                   size: CanvasLayout.defaultTileSize,
                                                   avoiding: frames)
            frames.append(CGRect(origin: origin, size: CanvasLayout.defaultTileSize))
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b)) }
        }
        let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        XCTAssertLessThan(CanvasLayout.fitZoom(bounds: bounds,
                                               viewport: CGSize(width: 1200, height: 800)), 1)
    }

    func testReflowReturnsNilWhenClampedTilesCannotShrinkFurther() {
        // A min-sized tile in a viewport it barely fits: scaling clamps to the
        // same size, the pan shift cancels — identical state must return nil.
        let tile = CanvasTile(itemID: UUID(), origin: .zero,
                              size: CanvasLayout.minTileSize)
        XCTAssertNil(CanvasLayout.reflowed(tiles: [tile],
                                           pan: CGPoint(x: 24, y: 24),
                                           viewport: CGSize(width: 360, height: 260)))
    }
}
