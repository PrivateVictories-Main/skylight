import AppKit
import XCTest
@testable import Skylight

final class CanvasZoomTests: XCTestCase {
    func testCanvasZoomRecognizesItsMenuShortcutsOnly() {
        XCTAssertEqual(CanvasZoom.shortcut("-", modifiers: .command), .zoomOut)
        XCTAssertEqual(CanvasZoom.shortcut("=", modifiers: .command), .zoomIn)
        XCTAssertEqual(CanvasZoom.shortcut("+", modifiers: [.command, .shift]), .zoomIn)
        XCTAssertEqual(CanvasZoom.shortcut("0", modifiers: .command), .actual)
        XCTAssertEqual(CanvasZoom.shortcut("9", modifiers: .command), .fit)
        XCTAssertNil(CanvasZoom.shortcut("-", modifiers: []))
        XCTAssertNil(CanvasZoom.shortcut("-", modifiers: [.command, .control]))
        XCTAssertNil(CanvasZoom.shortcut("-", modifiers: [.command, .option]))
        XCTAssertNil(CanvasZoom.shortcut("0", modifiers: [.command, .shift]))
        XCTAssertNil(CanvasZoom.shortcut("c", modifiers: .command))
    }

    func testPinchSettleKeepsContentUnderPointerInsteadOfViewportCenter() {
        let pan = CGPoint(x: -230, y: 78)
        let pointer = CGPoint(x: 1010, y: 170)
        let zoom: CGFloat = 1.015
        let content = CGPoint(x: (pointer.x - pan.x) / zoom,
                              y: (pointer.y - pan.y) / zoom)
        let target = CanvasZoom.snapped(zoom)
        let settled = CanvasZoom.anchoredPan(pan, from: zoom, to: target, at: pointer)
        XCTAssertEqual(target, 1)
        XCTAssertEqual(content.x * target + settled.x, pointer.x, accuracy: 0.000001)
        XCTAssertEqual(content.y * target + settled.y, pointer.y, accuracy: 0.000001)
    }

    func testZoomRoundTripDoesNotDriftAfterPanning() {
        let original = CGPoint(x: -723, y: 211)
        let pointer = CGPoint(x: 980, y: 143)
        for zoom: CGFloat in [0.2, 0.5, 1.5, 3] {
            let zoomed = CanvasZoom.anchoredPan(original, from: 1, to: zoom, at: pointer)
            let restored = CanvasZoom.anchoredPan(zoomed, from: zoom, to: 1, at: pointer)
            XCTAssertEqual(restored.x, original.x, accuracy: 0.000001)
            XCTAssertEqual(restored.y, original.y, accuracy: 0.000001)
        }
    }
}
