import Foundation

/// On-device launch statistics. Nothing recorded here ever leaves the machine.
/// Sendable like every other core model: its storage is already value types
/// all the way down, and being the one exception is how a model quietly
/// becomes un-passable across isolation later.
public struct UsageLog: Codable, Equatable, Sendable {
    public var counts: [String: Int]
    public var specs: [String: TerminalSpec]

    public init(counts: [String: Int] = [:], specs: [String: TerminalSpec] = [:]) {
        self.counts = counts
        self.specs = specs
    }

    /// Distinct combos worth remembering. Every unique argument string used
    /// to mint a permanent entry, so usage.json grew for the life of the
    /// install; past the cap the least-used combos fall off (ties broken by
    /// key, deterministically) — a habit is by definition not among them.
    private static let maximumCombos = 64
    private static let prunedCombos = 48

    public mutating func record(_ spec: TerminalSpec) {
        let key = spec.comboKey
        counts[key, default: 0] += 1
        specs[key] = spec
        if counts.count > Self.maximumCombos {
            let keep = counts.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(Self.prunedCombos).map(\.key)
            let kept = Set(keep)
            counts = counts.filter { kept.contains($0.key) }
            specs = specs.filter { kept.contains($0.key) }
        }
    }

    /// The combo worth surfacing as the one-click recommendation: the most
    /// used launch, once it has actually become a habit (`minimumUses`).
    public func topCombo(minimumUses: Int = 3) -> TerminalSpec? {
        let ranked = counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        guard let best = ranked.first, best.value >= minimumUses else { return nil }
        return specs[best.key]
    }
}
