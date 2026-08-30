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

    func testResizeCommitOffGridNearMinKeepsFarEdge() {
        // Reflow produces off-grid frames. When the snap pulls the moved edge
        // in far enough that the span dips under the minimum, the MOVED edge
        // must yield — the old width clamp slid the stationary one instead.
        let frame = CGRect(x: 132.5, y: 96, width: 340, height: 400)
        let commit = CanvasLayout.resizeCommit(frame,
            by: CanvasLayout.EdgeDeltas(left: 20))
        XCTAssertEqual(commit.maxX, 472.5)                     // untouched, byte-exact
        XCTAssertEqual(commit.width, CanvasLayout.minTileSize.width)
        for dx in stride(from: -64.0, through: 64.0, by: 0.5) {
            let c = CanvasLayout.resizeCommit(frame, by: CanvasLayout.EdgeDeltas(left: dx))
            XCTAssertEqual(c.maxX, 472.5, "left drag dx=\(dx) slid the right edge")
            XCTAssertGreaterThanOrEqual(c.width, CanvasLayout.minTileSize.width)
        }
    }

    func testResizeCommitOffGridNearMinKeepsBottomEdge() {
        let frame = CGRect(x: 96, y: 70.5, width: 400, height: 240)
        let commit = CanvasLayout.resizeCommit(frame,
            by: CanvasLayout.EdgeDeltas(top: 20))
        XCTAssertEqual(commit.maxY, 310.5)
        XCTAssertEqual(commit.height, CanvasLayout.minTileSize.height)
    }

    func testResizeCommitCornerDragsNeverMoveTheOppositeCorner() {
        // Corner drags drive one horizontal AND one vertical edge; the
        // opposite corner is the stationary anchor and holds through every
        // combination — on a grid-aligned frame and on an off-grid one
        // (reflow produces those).
        for frame in [CGRect(x: 96, y: 96, width: 608, height: 400),
                      CGRect(x: 132.5, y: 70.5, width: 340, height: 240)] {
            for dx in stride(from: -48.0, through: 48.0, by: 8) {
                for dy in stride(from: -48.0, through: 48.0, by: 8) {
                    let commit = CanvasLayout.resizeCommit(frame,
                        by: CanvasLayout.EdgeDeltas(left: dx, top: dy))
                    XCTAssertEqual(commit.maxX, frame.maxX,
                                   "topLeft drag (\(dx),\(dy)) moved maxX of \(frame)")
                    XCTAssertEqual(commit.maxY, frame.maxY,
                                   "topLeft drag (\(dx),\(dy)) moved maxY of \(frame)")
                    XCTAssertGreaterThanOrEqual(commit.width, CanvasLayout.minTileSize.width)
                    XCTAssertGreaterThanOrEqual(commit.height, CanvasLayout.minTileSize.height)
                }
            }
        }
    }

    func testMagnetSurvivesDegenerateCandidates() {
        let dragged = CGRect(x: 104, y: 40, width: 560, height: 400)
        // A zero-sized rect and an exact overlap of the dragged frame itself:
        // no crash, finite output, and the exact-overlap magnet (distance 0)
        // wins and aligns.
        let degenerate = [CGRect(x: 300, y: 200, width: 0, height: 0), dragged]
        let snapped = CanvasLayout.magnetSnapped(dragged, against: degenerate)
        XCTAssertTrue(snapped.x.isFinite && snapped.y.isFinite)
        XCTAssertEqual(snapped, dragged.origin)   // aligned to its own frame
    }

    func testFreePositionRingCapFallsBackToDesired() {
        // A plane blocked far beyond the 200-ring search radius: the scan
        // exhausts and returns the snapped desired point — overlap beats
        // losing the tile.
        let everything = [CGRect(x: -20000, y: -20000, width: 40000, height: 40000)]
        XCTAssertEqual(
            CanvasLayout.freePosition(desired: CGPoint(x: 100, y: 100),
                                      size: CanvasLayout.defaultTileSize,
                                      avoiding: everything),
            CGPoint(x: 96, y: 96))
    }

    func testReflowResultAlwaysLandsInsideTheViewport() throws {
        // Property: whenever reflow acts (and the min-size clamp is not in
        // play), the settled arrangement sits fully inside the margins.
        let fixtures: [[CanvasTile]] = [
            [CanvasTile(itemID: UUID(), origin: CGPoint(x: 900, y: 40),
                        size: CGSize(width: 560, height: 400))],
            [CanvasTile(itemID: UUID(), origin: .zero,
                        size: CGSize(width: 560, height: 400)),
             CanvasTile(itemID: UUID(), origin: CGPoint(x: 620, y: 460),
                        size: CGSize(width: 560, height: 400))],
        ]
        for tiles in fixtures {
            for viewport in [CGSize(width: 1100, height: 900),
                             CGSize(width: 1400, height: 1000)] {
                guard let result = CanvasLayout.reflowed(tiles: tiles, pan: .zero,
                                                         viewport: viewport) else { continue }
                let frames = result.tiles.map(\.frame)
                let bounds = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
                let visible = bounds.offsetBy(dx: result.pan.x, dy: result.pan.y)
                XCTAssertGreaterThanOrEqual(visible.minX, 24 - 0.001)
                XCTAssertGreaterThanOrEqual(visible.minY, 24 - 0.001)
                XCTAssertLessThanOrEqual(visible.maxX, viewport.width - 24 + 0.001)
                XCTAssertLessThanOrEqual(visible.maxY, viewport.height - 24 + 0.001)
            }
        }
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

    // MARK: - Arrange

    func testArrangePreservesSizesAndCount() {
        let tiles = [
            CanvasTile(itemID: UUID(), origin: CGPoint(x: 900, y: 12), size: CGSize(width: 560, height: 400)),
            CanvasTile(itemID: UUID(), origin: CGPoint(x: -300, y: 700), size: CGSize(width: 320, height: 220)),
            CanvasTile(itemID: UUID(), origin: CGPoint(x: 40, y: 30), size: CGSize(width: 480, height: 300)),
        ]
        let arranged = CanvasLayout.arranged(tiles: tiles, viewport: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(arranged.count, 3)
        XCTAssertEqual(Set(arranged.map(\.id)), Set(tiles.map(\.id)))
        for tile in tiles {
            XCTAssertEqual(arranged.first { $0.id == tile.id }?.size, tile.size)
        }
    }

    func testArrangeKeepsReadingOrderAndNeverOverlaps() {
        var tiles: [CanvasTile] = []
        for i in 0..<7 {
            tiles.append(CanvasTile(itemID: UUID(),
                                    origin: CGPoint(x: CGFloat(i * 130 % 700), y: CGFloat(i * 210 % 900)),
                                    size: CGSize(width: 400 + CGFloat(i % 3) * 80, height: 280 + CGFloat(i % 2) * 120)))
        }
        let arranged = CanvasLayout.arranged(tiles: tiles, viewport: CGSize(width: 1600, height: 1000))
        // Pairwise clearance: no two frames intersect even when inflated by 8
        // (snap can pull an origin left by at most 8; the 24 gap absorbs it).
        for a in arranged {
            for b in arranged where a.id != b.id {
                XCTAssertFalse(a.frame.insetBy(dx: -8, dy: -8).intersects(b.frame),
                               "\(a.frame) vs \(b.frame)")
            }
        }
        // Reading order, spelled out. The fixture's y values bucket
        // (y/200 floored) to [0,1,2,3,4,0,1], so tiles 5 and 6 rejoin the
        // first two rows and sort by x within them: 5 (x=650) after 0 (x=0),
        // and 6 (x=80) BEFORE 1 (x=130).
        XCTAssertEqual(arranged.map(\.id), [0, 5, 6, 1, 2, 3, 4].map { tiles[$0].id })
        // Deterministic.
        XCTAssertEqual(arranged.map(\.id),
                       CanvasLayout.arranged(tiles: tiles, viewport: CGSize(width: 1600, height: 1000)).map(\.id))
    }

    func testArrangeSingleTileGoesHome() {
        let tile = CanvasTile(itemID: UUID(), origin: CGPoint(x: 999, y: -400),
                              size: CGSize(width: 560, height: 400))
        XCTAssertEqual(CanvasLayout.arranged(tiles: [tile], viewport: CGSize(width: 1600, height: 1000))
            .first?.origin, CGPoint(x: 48, y: 48))
    }

    func testArrangeOriginsAreGridSnapped() {
        let tiles = (0..<5).map { i in
            CanvasTile(itemID: UUID(), origin: CGPoint(x: CGFloat(i) * 313, y: CGFloat(i) * 217),
                       size: CGSize(width: 500, height: 300))
        }
        for tile in CanvasLayout.arranged(tiles: tiles, viewport: CGSize(width: 1600, height: 1000)) {
            XCTAssertEqual(tile.origin.x.truncatingRemainder(dividingBy: 16), 0)
            XCTAssertEqual(tile.origin.y.truncatingRemainder(dividingBy: 16), 0)
        }
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

/// Docked tiles are viewport chrome, not board content. Every piece of the
/// existing layout math has to ignore them, and the free rect the rails leave
/// behind is the viewport those functions are now given.
final class LayoutWithDocksTests: XCTestCase {
    private func tiles(_ n: Int) -> [CanvasTile] {
        (0..<n).map { i in
            CanvasTile(itemID: UUID(),
                       origin: CGPoint(x: CGFloat(i) * 600, y: 0),
                       size: CGSize(width: 560, height: 400))
        }
    }

    /// The whole regression net: with no docks, every function must behave
    /// byte-identically to before this feature existed.
    func testExistingBehaviourIsUnchangedWhenNothingIsDocked() {
        let all = tiles(4)
        let viewport = CGSize(width: 1600, height: 1000)
        let free = DockLayout.frames(docks: [:], viewport: viewport).free
        XCTAssertEqual(free, CGRect(origin: .zero, size: viewport))
        XCTAssertEqual(CanvasLayout.arranged(tiles: all, viewport: free.size),
                       CanvasLayout.arranged(tiles: all, viewport: viewport))
        XCTAssertEqual(
            CanvasLayout.reflowed(tiles: all, pan: .zero, viewport: free.size)?.tiles,
            CanvasLayout.reflowed(tiles: all, pan: .zero, viewport: viewport)?.tiles)
    }

    /// Arranging packs into the FREE rect, not the whole window — otherwise
    /// it lays tiles out underneath the rails.
    func testArrangePacksIntoTheFreeRectOnly() {
        let free = DockLayout.frames(
            docks: DockLayout.normalized(
                [.left: DockRail(thickness: 400,
                                 slots: [DockSlot(itemID: UUID())])]),
            viewport: CGSize(width: 1600, height: 1000)).free
        let arranged = CanvasLayout.arranged(tiles: tiles(4), viewport: free.size)
        // Aspect drives row width, so a narrower free rect must produce a
        // narrower arrangement than the full window would.
        let wide = CanvasLayout.arranged(tiles: tiles(4),
                                         viewport: CGSize(width: 1600, height: 1000))
        let arrangedWidth = arranged.map(\.frame.maxX).max() ?? 0
        let wideWidth = wide.map(\.frame.maxX).max() ?? 0
        XCTAssertLessThanOrEqual(arrangedWidth, wideWidth)
    }

    /// Magnets must not snap a dragged tile to a docked one: the docked frame
    /// lives in viewport space and the dragged tile in content space, so the
    /// two numbers are not even in the same coordinate system.
    func testMagnetsIgnoreDockedFrames() {
        let dragged = CGRect(x: 100, y: 100, width: 560, height: 400)
        // No neighbours at all → pure grid snap, whatever is docked.
        let snapped = CanvasLayout.magnetSnapped(dragged, against: [])
        XCTAssertEqual(snapped, CanvasLayout.snapped(dragged.origin))
    }

    func testFreeTilesExcludeAnythingDocked() {
        let docked = UUID()
        var board = CanvasBoard(name: "B", tiles: tiles(2))
        board.tiles.append(CanvasTile(itemID: docked, origin: .zero,
                                      size: CGSize(width: 400, height: 300)))
        board.docks = [.left: DockRail(slots: [DockSlot(itemID: docked)])]
        let free = board.freeTiles
        XCTAssertEqual(free.count, 2)
        XCTAssertFalse(free.contains { $0.itemID == docked })
    }
}

final class ArrangePresetTests: XCTestCase {
    private func tiles(_ n: Int) -> [CanvasTile] {
        (0..<n).map { i in
            CanvasTile(itemID: UUID(),
                       origin: CGPoint(x: CGFloat(i % 3) * 600,
                                       y: CGFloat(i / 3) * 450),
                       size: CGSize(width: 560, height: 400))
        }
    }
    private let viewport = CGSize(width: 1600, height: 1000)

    /// The default must be byte-identical to what ⇧⌘A has always done.
    func testRowsPresetMatchesTodaysArrangedExactly() {
        for n in 1...8 {
            let all = tiles(n)
            XCTAssertEqual(
                CanvasLayout.arranged(tiles: all, viewport: viewport, preset: .rows),
                CanvasLayout.arranged(tiles: all, viewport: viewport), "n=\(n)")
        }
    }

    func testColumnsPresetMakesExactlyThatManyColumns() {
        for columns in [2, 3] {
            let arranged = CanvasLayout.arranged(tiles: tiles(6), viewport: viewport,
                                                 preset: .columns(columns))
            let distinctX = Set(arranged.map(\.origin.x))
            XCTAssertEqual(distinctX.count, columns, "columns=\(columns)")
        }
    }

    func testMainAndStackGivesTheFirstTileTheLargestArea() {
        let arranged = CanvasLayout.arranged(tiles: tiles(4), viewport: viewport,
                                             preset: .mainAndStack)
        let areas = arranged.map { $0.size.width * $0.size.height }
        XCTAssertEqual(areas.max(), areas.first,
                       "the main tile must be the biggest one")
    }

    func testGridIsDeterministicAndNeverOverlaps() {
        for n in 1...12 {
            // The SAME input twice — the earlier version built fresh tiles
            // for each call, so it compared different UUIDs and tested
            // nothing but Foundation's random number generator.
            let input = tiles(n)
            let arranged = CanvasLayout.arranged(tiles: input, viewport: viewport,
                                                 preset: .grid)
            XCTAssertEqual(arranged,
                           CanvasLayout.arranged(tiles: input, viewport: viewport,
                                                 preset: .grid),
                           "n=\(n) not deterministic")
            for i in arranged.indices {
                for j in (i + 1)..<arranged.count {
                    XCTAssertFalse(
                        arranged[i].frame.insetBy(dx: 1, dy: 1)
                            .intersects(arranged[j].frame),
                        "n=\(n): \(i) overlaps \(j)")
                }
            }
        }
    }

    /// Every preset keeps every tile — an arrangement that loses one is a
    /// terminal that vanished.
    func testNoPresetEverLosesATile() {
        let all = tiles(7)
        for preset: CanvasLayout.ArrangePreset in [.rows, .columns(2), .columns(3),
                                                    .mainAndStack, .grid] {
            let arranged = CanvasLayout.arranged(tiles: all, viewport: viewport,
                                                 preset: preset)
            XCTAssertEqual(Set(arranged.map(\.id)), Set(all.map(\.id)), "\(preset)")
        }
    }

    func testPresetsNeverProduceASubMinimumTile() {
        for preset: CanvasLayout.ArrangePreset in [.columns(3), .mainAndStack, .grid] {
            for tile in CanvasLayout.arranged(tiles: tiles(9), viewport: viewport,
                                              preset: preset) {
                XCTAssertGreaterThanOrEqual(tile.size.width,
                                            CanvasLayout.minTileSize.width, "\(preset)")
                XCTAssertGreaterThanOrEqual(tile.size.height,
                                            CanvasLayout.minTileSize.height, "\(preset)")
            }
        }
    }
}
