import Combine
import Darwin
import SkylightDaemonCore
import XCTest
@testable import Skylight

final class SessionKeeperRecoveryTests: XCTestCase {
    func testIncompatibleKeeperBlocksWithoutStartingReplacement() throws {
        let reply = HelloReply(protocolVersion: Wire.protocolVersion + 1,
                               daemonPID: getpid(), sessions: [])
        try expectBlocked(reply, issue: .incompatible(found: Wire.protocolVersion + 1,
                                                     expected: Wire.protocolVersion))
    }

    func testBusyKeeperCannotCreateDuplicateExecSessions() throws {
        let reply = HelloReply(protocolVersion: Wire.protocolVersion,
                               daemonPID: getpid(), sessions: [], busy: true)
        try expectBlocked(reply, issue: .busy)
    }

    func testUnavailableBinaryAllowsFallbackButUnreachableStartedKeeperDoesNot() {
        var starts = 0
        let unavailable = DaemonClient.bootstrap(connect: { _ in nil }, start: {
            starts += 1
            return false
        })
        guard case .unavailable = unavailable else { return XCTFail("Expected exec fallback") }
        XCTAssertEqual(starts, 1)
        let pending = DaemonClient.bootstrap(connect: { _ in nil }, start: {
            starts += 1
            return true
        })
        guard case .blocked(.unresponsive) = pending else {
            return XCTFail("An unconfirmed keeper must not start duplicate sessions")
        }
        XCTAssertEqual(starts, 2, "Each bootstrap starts at most one keeper")
    }

    private func expectBlocked(_ reply: HelloReply, issue: SessionKeeperIssue) throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        let data = Wire.encode(WireFrame(type: .helloReply,
                                       payload: try JSONEncoder().encode(reply)))
        let written = data.withUnsafeBytes { write(pair[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(written, data.count)
        var starts = 0
        let result = DaemonClient.bootstrap(connect: { _ in pair[0] }, start: {
            starts += 1
            return false
        })
        guard case let .blocked(actual) = result else { return XCTFail("Expected recoverable issue") }
        XCTAssertEqual(actual, issue)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(fcntl(pair[0], F_GETFD), -1, "Rejected connection must close")
    }

    @MainActor
    func testBlockedPreparationCanRetryWithoutCreatingSurfaces() async {
        let blocked = expectation(description: "blocked")
        let ready = expectation(description: "ready after retry")
        let calls = BootstrapSequence()
        let store = LiveSessionStore(bootstrap: { calls.next() })
        let issueObservation = store.$preparationIssue.compactMap { $0 }.sink { issue in
            XCTAssertEqual(issue, .busy)
            blocked.fulfill()
        }
        let readyObservation = store.$isReady.filter { $0 }.sink { _ in ready.fulfill() }
        store.prewarmDaemon()
        await fulfillment(of: [blocked], timeout: 2)
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(store.openSessionIDs.isEmpty)
        store.retryPreparation()
        store.retryPreparation()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertNil(store.preparationIssue)
        XCTAssertTrue(store.isReady)
        XCTAssertTrue(store.openSessionIDs.isEmpty)
        store.retryPreparation()
        XCTAssertEqual(calls.count, 2)
        withExtendedLifetime([issueObservation, readyObservation]) {}
    }
}

private final class BootstrapSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> DaemonClient.BootstrapResult {
        lock.withLock {
            value += 1
            return value == 1 ? .blocked(.busy) : .unavailable
        }
    }
}
