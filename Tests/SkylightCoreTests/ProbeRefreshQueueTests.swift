import XCTest
import SkylightCore

final class ProbeRefreshQueueTests: XCTestCase {
    func testRoutineRefreshesShareOneCheck() throws {
        var queue = ProbeRefreshQueue()
        let ticket = try XCTUnwrap(queue.request("claude"))
        XCTAssertNil(queue.request("claude"))
        XCTAssertEqual(queue.complete("claude", ticket: ticket), .accept)
    }

    func testSignInDuringCheckDiscardsOldAnswerAndCoalescesRetries() throws {
        var queue = ProbeRefreshQueue()
        let beforeLogin = try XCTUnwrap(queue.request("claude"))
        XCTAssertNil(queue.request("claude", force: true))
        XCTAssertNil(queue.request("claude", force: true))
        XCTAssertEqual(queue.complete("claude", ticket: beforeLogin), .retry)
        let afterLogin = try XCTUnwrap(queue.request("claude"))
        XCTAssertEqual(queue.complete("claude", ticket: beforeLogin), .ignore)
        XCTAssertEqual(queue.complete("claude", ticket: afterLogin), .accept)
    }

    func testOneAccountRefreshDoesNotInvalidateAnother() throws {
        var queue = ProbeRefreshQueue()
        let claude = try XCTUnwrap(queue.request("claude"))
        let codex = try XCTUnwrap(queue.request("codex"))
        XCTAssertNil(queue.request("claude", force: true))
        XCTAssertEqual(queue.complete("codex", ticket: codex), .accept)
        XCTAssertEqual(queue.complete("claude", ticket: claude), .retry)
    }
}
