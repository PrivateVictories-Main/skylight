import Foundation

/// On-device launch statistics. Nothing recorded here ever leaves the machine.
public struct UsageLog: Codable, Equatable {
    public var counts: [String: Int]
    public var specs: [String: TerminalSpec]

    public init(counts: [String: Int] = [:], specs: [String: TerminalSpec] = [:]) {
        self.counts = counts
        self.specs = specs
    }

    public mutating func record(_ spec: TerminalSpec) {
        let key = spec.comboKey
        counts[key, default: 0] += 1
        specs[key] = spec
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
