import Foundation

/// The daemon's insurance against its own death: every spawned child is
/// recorded (pid + process start time) in a ledger beside the socket. A
/// fresh daemon sweeps the previous ledger at boot — a recorded pid that is
/// still alive AND started at the recorded time is an orphan from a crashed
/// predecessor, unreachable forever (its pty master died with the crash),
/// and gets hung up rather than leaked. The start time is what makes this
/// safe: a recycled pid never matches.
public struct LedgerEntry: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startSeconds: Int64

    public init(pid: Int32, startSeconds: Int64) {
        self.pid = pid
        self.startSeconds = startSeconds
    }
}

public enum OrphanSweep {
    /// The entries that are provably our orphans: `probe` returns a live
    /// process's start time (seconds) or nil when the pid is gone.
    public static func orphans(in ledger: [LedgerEntry],
                               probe: (Int32) -> Int64?) -> [LedgerEntry] {
        ledger.filter { entry in
            probe(entry.pid) == entry.startSeconds
        }
    }
}
