import Combine
import XCTest
@testable import Skylight

final class SessionPreparationTests: XCTestCase {
    @MainActor
    func testSlowBootstrapLeavesMainActorResponsiveAndRunsOnlyOnce() async {
        let started = expectation(description: "bootstrap started once")
        started.assertForOverFulfill = true
        let ready = expectation(description: "fallback ready")
        let release = DispatchSemaphore(value: 0)
        let store = LiveSessionStore(bootstrap: {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return .unavailable
        })
        let observation = store.$isReady.filter { $0 }.sink { _ in ready.fulfill() }
        store.prewarmDaemon()
        store.prewarmDaemon()
        await fulfillment(of: [started], timeout: 2)
        // This continuation must run while bootstrap is still blocked.
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(store.openSessionIDs.isEmpty)
        XCTAssertFalse(store.sessionsSurviveQuit)
        release.signal()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.sessionsSurviveQuit)
        store.prewarmDaemon()
        withExtendedLifetime(observation) {}
    }
}
