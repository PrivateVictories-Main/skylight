import XCTest
import SkylightCore

/// What an agent terminal is doing, derived only from signals Skylight
/// already receives. No polling, no scraping, no parsing of agent output —
/// and no timer, which is the constraint that shapes the whole design.
final class AgentStateTests: XCTestCase {
    private var machine = AgentStateMachine()

    private func send(_ event: AgentEvent, at time: TimeInterval) -> AgentState {
        machine.on(event, at: time)
    }

    func testStartsIdle() {
        XCTAssertEqual(AgentStateMachine().state, .idle)
    }

    func testOutputMovesIdleToWorking() {
        XCTAssertEqual(send(.outputArrived, at: 0), .working)
    }

    func testBellMeansItIsWaitingForYou() {
        _ = send(.outputArrived, at: 0)
        XCTAssertEqual(send(.bellRang, at: 1), .waitingForYou)
    }

    /// A bell is the strongest signal there is — an agent asking for input.
    /// Output arriving afterwards must not quietly downgrade it, or the dot
    /// clears itself while the agent is still waiting.
    func testOutputDoesNotClearWaitingForYou() {
        _ = send(.bellRang, at: 0)
        XCTAssertEqual(send(.outputArrived, at: 1), .waitingForYou)
    }

    /// Only the human looking at it does.
    func testViewingClearsWaitingForYou() {
        _ = send(.bellRang, at: 0)
        XCTAssertEqual(send(.viewed, at: 1), .idle)
    }

    func testCommandFinishedMeansDone() {
        _ = send(.outputArrived, at: 0)
        XCTAssertEqual(send(.commandFinished(exitCode: 0), at: 5), .done)
    }

    /// The decay is evaluated when the NEXT event arrives, never by a timer:
    /// an app that wakes up to notice nothing happened is exactly the idle
    /// cost this project refuses to pay.
    func testQuietAfterWorkingDecaysToIdleOnTheNextEvent() {
        _ = send(.outputArrived, at: 0)
        XCTAssertEqual(machine.state, .working)
        // A long gap, then anything at all.
        XCTAssertEqual(send(.tick, at: AgentStateMachine.quietSeconds + 1), .idle)
    }

    func testAShortGapDoesNotDecay() {
        _ = send(.outputArrived, at: 0)
        XCTAssertEqual(send(.tick, at: 1), .working)
    }

    /// C1: the decay was only reachable from `.tick`, and `.tick` was emitted
    /// nowhere in the app — so a dot that went green stayed green forever.
    /// Tested, passing, and completely unreachable.
    ///
    /// Decay is now evaluated at the TOP of every event: whatever happens
    /// next first ages the state past its quiet window, then applies itself.
    /// No new event source, no timer.
    func testAnyLaterEventAgesTheStateFirst() {
        _ = send(.outputArrived, at: 0)
        XCTAssertEqual(machine.state, .working)
        // A bell long after the work went quiet: the state was already stale
        // when it arrived, and the bell still wins.
        XCTAssertEqual(send(.bellRang, at: AgentStateMachine.quietSeconds + 5),
                       .waitingForYou)
    }

    func testOutputLongAfterQuietStartsAFreshWorkingPeriod() {
        _ = send(.outputArrived, at: 0)
        // Aged to idle on arrival, then this output makes it working again.
        XCTAssertEqual(send(.outputArrived, at: AgentStateMachine.quietSeconds + 5),
                       .working)
    }

    /// The real-world shape: a title-driven `working`, then something
    /// unrelated much later. It must read idle, not "working since Tuesday".
    func testTitleDrivenWorkingDecaysOnAnUnrelatedLaterEvent() {
        _ = send(.outputArrived, at: 100)
        XCTAssertEqual(machine.state, .working)
        XCTAssertEqual(send(.viewed, at: 100 + AgentStateMachine.quietSeconds + 1),
                       .idle)
    }

    func testSessionEndStillWinsOverADecayedState() {
        _ = send(.outputArrived, at: 0)
        XCTAssertEqual(send(.sessionEnded, at: AgentStateMachine.quietSeconds + 99),
                       .ended)
    }

    /// The idle-CPU promise, expressed as the thing that is actually true:
    /// the machine has no clock of its own, so reading it changes nothing.
    /// (The previous version of this test compared `state` to itself and
    /// could not fail.)
    func testReadingTheStateNeverAdvancesIt() {
        _ = send(.outputArrived, at: 0)
        let snapshot = machine
        _ = machine.state
        _ = machine.state
        XCTAssertEqual(machine, snapshot)
    }

    func testEndedIsTerminal() {
        _ = send(.sessionEnded, at: 0)
        XCTAssertEqual(machine.state, .ended)
        // Nothing resurrects it: a dead session that emits a stray frame must
        // not flicker back to life in the sidebar.
        XCTAssertEqual(send(.outputArrived, at: 1), .ended)
        XCTAssertEqual(send(.bellRang, at: 2), .ended)
        XCTAssertEqual(send(.commandFinished(exitCode: 0), at: 3), .ended)
    }

    func testDoneReturnsToWorkingWhenOutputResumes() {
        _ = send(.outputArrived, at: 0)
        _ = send(.commandFinished(exitCode: 0), at: 1)
        XCTAssertEqual(send(.outputArrived, at: 2), .working)
    }

    /// Time going backwards (sleep, NTP) must not wedge the machine.
    func testAClockGoingBackwardsDoesNotDecay() {
        _ = send(.outputArrived, at: 100)
        XCTAssertEqual(send(.tick, at: 50), .working)
    }

    // MARK: - Presentation

    func testEveryStateHasADistinctLabel() {
        let labels = [AgentState.idle, .working, .waitingForYou, .done, .ended]
            .map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertFalse(labels.contains { $0.isEmpty })
    }

    /// The shipped behaviour must not regress: a bell today produces the
    /// accent-coloured attention dot, and that is what waitingForYou is.
    func testWaitingForYouIsTheOneThatDemandsAttention() {
        XCTAssertTrue(AgentState.waitingForYou.demandsAttention)
        for state: AgentState in [.idle, .working, .done, .ended] {
            XCTAssertFalse(state.demandsAttention, state.label)
        }
    }

    func testOnlyLiveStatesAnimate() {
        XCTAssertTrue(AgentState.working.isLive)
        XCTAssertFalse(AgentState.ended.isLive)
        XCTAssertFalse(AgentState.idle.isLive)
    }
}
