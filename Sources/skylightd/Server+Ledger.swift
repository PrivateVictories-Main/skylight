import Darwin
import Foundation
import SkylightDaemonCore

/// The orphan ledger: no crashed daemon may leak a process.
extension Server {
    // MARK: - Orphan ledger

    var ledgerPath: String { socketPath + ".ledger" }

    func processStartSeconds(_ pid: pid_t) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return Int64(info.pbi_start_tvsec)
    }

    /// Every live child, persisted so a successor can find what a crash of
    /// ours would orphan. Written on spawn, exit, and removal — tiny and
    /// rare; removed outright when nothing is running.
    func persistLedger() {
        let entries = sessions.values.compactMap { session -> LedgerEntry? in
            guard !session.exited else { return nil }
            return LedgerEntry(pid: session.pid, startSeconds: session.startSeconds)
        }
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(atPath: ledgerPath)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: URL(fileURLWithPath: ledgerPath), options: .atomic)
        }
    }

    func sweepOrphans() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ledgerPath)) else { return }
        try? FileManager.default.removeItem(atPath: ledgerPath)
        guard let previous = try? JSONDecoder().decode([LedgerEntry].self, from: data)
        else { return }
        let orphans = OrphanSweep.orphans(in: previous) { processStartSeconds($0) }
        guard !orphans.isEmpty else { return }
        for entry in orphans {
            log("sweeping orphan pid=\(entry.pid) left by a crashed predecessor")
            kill(entry.pid, SIGHUP)
        }
        pendingOrphanKills = orphans
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            for entry in self.pendingOrphanKills
            where self.processStartSeconds(entry.pid) == entry.startSeconds {
                self.log("escalating orphan sweep for pid=\(entry.pid)")
                kill(entry.pid, SIGKILL)
            }
            self.pendingOrphanKills = []
            self.exitIfIdle()
        }
    }
}
