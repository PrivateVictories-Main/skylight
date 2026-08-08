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

    func testNoMagnetsFallsBackToGridOnBothAxes() {
        let dragged = CGRect(x: 40, y: 40, width: 560, height: 400)
        XCTAssertEqual(CanvasLayout.magnetSnapped(dragged, against: []),
                       CGPoint(x: 48, y: 48))
    }
}
