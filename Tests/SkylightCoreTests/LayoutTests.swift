import XCTest
import SkylightCore

final class LayoutTests: XCTestCase {
    func testSnapsPointToGrid() {
        XCTAssertEqual(CanvasLayout.snapped(CGPoint(x: 23, y: 40)), CGPoint(x: 16, y: 48))
        XCTAssertEqual(CanvasLayout.snapped(CGPoint(x: 8, y: 8)), CGPoint(x: 16, y: 16))
    }

    func testSnappedPointClampsToZero() {
        // Current behavior; Task 6 (endless pan) removes the clamp and updates this test.
        XCTAssertEqual(CanvasLayout.snapped(CGPoint(x: -40, y: -5)), CGPoint(x: 0, y: 0))
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
}
