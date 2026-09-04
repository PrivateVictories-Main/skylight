import AppKit
import XCTest
@testable import Skylight

final class TerminalFocusTests: XCTestCase {
    @MainActor
    private final class InputView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    func testFocusRequestSurvivesUntilHostHasAWindow() async {
        _ = NSApplication.shared
        let host = TerminalHostContainer(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let input = InputView(frame: host.bounds)
        host.hosted = input
        host.focusRequested = true
        host.claim()
        XCTAssertTrue(host.focusRequested)
        let window = NSWindow(contentRect: host.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.claim()
        XCTAssertTrue(window.firstResponder === input)
        XCTAssertFalse(host.focusRequested)
    }

    @MainActor
    func testSheetCompletionRetriesPendingFocusWithoutATimer() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = TerminalHostContainer(frame: window.contentView!.bounds)
        let input = InputView(frame: host.bounds)
        host.hosted = input
        window.contentView = host
        let acquired = expectation(description: "focus after sheet lifecycle event")
        host.onFocusAcquired = { acquired.fulfill() }
        host.focusRequested = true
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        await fulfillment(of: [acquired], timeout: 2)
        XCTAssertTrue(window.firstResponder === input)
    }
}
