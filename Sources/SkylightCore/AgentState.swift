import Foundation

/// What an agent terminal is doing right now.
///
/// This is the agent-native half of the dual-mode contract: a shell wants to
/// tell you where it is, an agent wants to tell you whether it needs you.
public enum AgentState: Equatable, Hashable, Sendable {
    /// Running, nothing happening.
    case idle
    /// Producing output.
    case working
    /// Rang the bell — it is asking for input. The strongest signal there is.
    case waitingForYou
    /// Finished a command and went quiet.
    case done
    /// The process is over.
    case ended

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waitingForYou: "Needs you"
        case .done: "Done"
        case .ended: "Session ended"
        }
    }

    /// The one state that earns a pulsing dot — preserving exactly what the
    /// bell has always produced.
    public var demandsAttention: Bool { self == .waitingForYou }

    /// Worth animating. A dead session must not breathe.
    public var isLive: Bool { self == .working }
}

public enum AgentEvent: Equatable, Sendable {
    case outputArrived
    case bellRang
    case commandFinished(exitCode: Int?)
    case sessionEnded
    /// The human looked at it.
    case viewed
    /// Any other frame. Carries no meaning of its own — it exists so the
    /// quiet-decay below can be evaluated when something else happens.
    case tick
}

/// Derives `AgentState` from events Skylight already receives.
///
/// **No timer.** The decay from `working` back to `idle` is evaluated when the
/// NEXT event arrives, never on a schedule. An app that wakes up to notice
/// that nothing happened is precisely the idle cost this project refuses to
/// pay, and "idle CPU ≈ 0%" is a published number rather than an aspiration.
///
/// The consequence is honest and worth stating: a terminal that goes silent
/// forever stays `working` until something else happens to it. Since the only
/// thing that reads this is a dot next to a row you are looking at, that is a
/// trade worth making.
public struct AgentStateMachine: Equatable, Sendable {
    /// How long without output before `working` is no longer true.
    public static let quietSeconds: TimeInterval = 20

    public private(set) var state: AgentState = .idle
    private var lastOutput: TimeInterval?

    public init() {}

    @discardableResult
    public mutating func on(_ event: AgentEvent, at time: TimeInterval) -> AgentState {
        // Ended is terminal. A dead session emitting a stray frame must not
        // flicker back to life in the sidebar.
        guard state != .ended else { return state }

        // AGE FIRST, then apply. Every event carries a timestamp, so whatever
        // happens next is also the thing that notices how long ago the last
        // output was — no timer, no tick source, nothing that wakes up to
        // discover that nothing happened.
        //
        // This used to live in a `.tick` case that the app emitted nowhere,
        // which made the decay tested, passing, and completely unreachable: a
        // dot that went green stayed green for the life of the session.
        decay(at: time)

        switch event {
        case .sessionEnded:
            state = .ended
            return state

        case .bellRang:
            // The strongest signal: an agent asking for input.
            state = .waitingForYou
            return state

        case .viewed:
            if state == .waitingForYou || state == .done { state = .idle }
            return state

        case let .commandFinished(exitCode):
            _ = exitCode
            if state != .waitingForYou { state = .done }
            return state

        case .outputArrived:
            lastOutput = time
            // Output must NOT clear "needs you" — only a human looking at it
            // does. Otherwise the dot clears itself while the agent is still
            // waiting, which is the one failure this whole feature exists to
            // prevent.
            if state != .waitingForYou { state = .working }
            return state

        case .tick:
            // Carries no meaning of its own; the ageing above was the point.
            return state
        }
    }

    /// Age a stale `working` down to `idle`. Runs at the top of every event,
    /// never on a schedule.
    private mutating func decay(at time: TimeInterval) {
        guard state == .working, let lastOutput else { return }
        let quiet = time - lastOutput
        // A clock that went backwards (sleep, NTP) must not wedge the machine
        // or decay it early.
        guard quiet >= 0 else { return }
        if quiet >= Self.quietSeconds { state = .idle }
    }
}
