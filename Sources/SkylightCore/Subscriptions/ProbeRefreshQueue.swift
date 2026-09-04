import Foundation

/// Coalesces refresh requests per CLI. A sign-in or manual refresh that arrives
/// during a check makes that answer obsolete and requests one fresh check.
/// The caller owns execution; this type starts no tasks or timers.
public struct ProbeRefreshQueue {
    public enum Completion: Equatable {
        case accept, retry, ignore
    }

    private var active: [String: UUID] = [:]
    private var invalidated: Set<String> = []

    public init() {}

    public mutating func request(_ id: String, force: Bool = false) -> UUID? {
        if active[id] != nil {
            if force { invalidated.insert(id) }
            return nil
        }
        let ticket = UUID()
        active[id] = ticket
        return ticket
    }

    public mutating func complete(_ id: String, ticket: UUID) -> Completion {
        guard active[id] == ticket else { return .ignore }
        active.removeValue(forKey: id)
        return invalidated.remove(id) != nil ? .retry : .accept
    }
}
