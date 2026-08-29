import Darwin
import Foundation
import SkylightDaemonCore

/// The whole daemon lives on one serial queue: session table, pty reads,
/// client sockets, signals. No locks, no races — confinement is the design,
/// and the @unchecked Sendable marks below are that design stated to the
/// compiler: every closure that captures these types runs on `queue`.
final class Server: @unchecked Sendable {
    final class Session: @unchecked Sendable {
        let id: UUID
        let argv: [String]
        var pid: pid_t
        /// The child's kernel start time — with the pid, its identity proof
        /// in the orphan ledger (a recycled pid can never match).
        var startSeconds: Int64 = 0
        /// -1 once the master has drained and closed — INPUT/RESIZE frames
        /// arriving after that must never touch a recycled fd number.
        var masterFD: Int32
        /// Our held slave (see SpawnedChild.slaveFD): released on the first
        /// proof the child owns the tty — first output, or its reap.
        var slaveFD: Int32 = -1
        var readSource: DispatchSourceRead?
        /// Pending keystrokes for a tty whose input queue is full (child
        /// stopped, or just slow). Bounded: past the cap the NEWEST bytes are
        /// dropped with a log line — input to a wedged child is already lost
        /// semantically; unbounded memory would lose the daemon.
        var inputBacklog = Data()
        var inputSource: DispatchSourceWrite?
        /// Flow control (see readFromPTY): true while the read source is
        /// suspended — because an attached client is drowning, or because
        /// nobody is attached and full-rate reading would only overwrite the
        /// ring. A suspended source must be resumed before cancel.
        var readPaused = false
        /// Bytes read since the last pause while detached; bounds the CPU a
        /// client-less flood can burn.
        var detachedBurst = 0
        /// Logged once per overflow EPISODE, not per frame — a pathological
        /// input flood must not grow the log without bound.
        var inputOverflowing = false
        var ring = OutputRing()
        var exitCode: Int32?
        /// Output fully drained from the master after child exit.
        var drained = false
        var exited: Bool { exitCode != nil }
        var exitAnnounced = false
        /// A client asked for this session's end: remove it the moment its
        /// exit completes instead of keeping the corpse for replay.
        var killRequested = false
        var killEscalation: DispatchSourceTimer?

        init(id: UUID, argv: [String], pid: pid_t, masterFD: Int32) {
            self.id = id
            self.argv = argv
            self.pid = pid
            self.masterFD = masterFD
        }
    }

    final class Client: @unchecked Sendable {
        let fd: Int32
        /// True once this connection claimed the APP role via hello. A
        /// status probe never hellos (it lists), so it can neither trip the
        /// one-app gate nor bounce a launching app into the exec lane.
        var isApp = false
        var readSource: DispatchSourceRead?
        var buffer = Data()
        /// Frames waiting for a socket that can't take them right now. A
        /// blocking write here once meant one SIGSTOP'd app froze EVERY
        /// session's IO — the daemon's single queue must never block.
        /// Offset-consumed: removeFirst per write slice memmoved the whole
        /// backlog and pinned a flood at 99% CPU for 14 MB/s.
        var outbound = Data()
        var outboundStart = 0
        var outboundPending: Int { outbound.count - outboundStart }
        var writeSource: DispatchSourceWrite?
        var attached: Set<UUID> = []

        init(fd: Int32) { self.fd = fd }
    }

    /// A client this far behind is not coming back for its bytes. With
    /// backpressure below, output floods can no longer reach this — only a
    /// client ignoring the socket entirely while frames accumulate.
    static let maxClientBacklog = 4 << 20
    /// Keystrokes queued for one tty; far beyond any legitimate typing.
    static let maxInputBacklog = 1 << 20
    /// Flow control: pause a session's pty reads when an attached client is
    /// this far behind…
    static let clientHighWater = 512 << 10
    /// …resume when it drains to here. The child then blocks on its tty
    /// exactly as it would under any real terminal with a slow consumer.
    static let clientLowWater = 64 << 10
    /// A detached flood is read in pulses of this much, then rests 250ms —
    /// nobody is watching a detached session anyway (attach resumes reading
    /// instantly, and the replay carries the tail).
    static let detachedBurstLimit = 256 << 10
    /// How much one read EVENT may drain before yielding the queue: a pty
    /// master hands out ~1 KiB reads, and one-frame-per-read once turned a
    /// flood into ~90k tiny frames/sec of overhead on both ends of the
    /// socket. Draining to EAGAIN (capped, for fairness to other sessions)
    /// coalesces a flood into a few large frames per wake instead.
    static let readBatchLimit = 256 << 10

    let queue = DispatchQueue(label: "skylightd.server")
    let socketPath: String
    var listenFD: Int32 = -1
    var acceptSource: DispatchSourceRead?
    var sigchld: DispatchSourceSignal?
    var sigterm: DispatchSourceSignal?
    var sessions: [UUID: Session] = [:]
    /// Spawns waiting for their surface's size: a pty born at a guessed
    /// 80×24 lets the shell draw its first prompt for the wrong width — a
    /// wrapped right-prompt before the real size ever arrives. The surface
    /// reports a grid within a frame of mounting, but the FIRST report can
    /// still be one layout pass early (padding-balance settles a column
    /// later), so the birth is debounced briefly and takes the latest size:
    /// the child is born into the settled grid, never resized into it.
    final class PendingSpawn: @unchecked Sendable {
        let request: SpawnRequest
        var latest: ResizePayload?
        /// Bumped per resize; a birth timer only fires for its own
        /// generation, so every fresh size restarts the quiet period.
        var generation = 0
        init(request: SpawnRequest) { self.request = request }
    }
    var pendingSpawns: [UUID: PendingSpawn] = [:]
    var clients: [ObjectIdentifier: Client] = [:]
    /// A daemon that never gets a client is an orphan from a crashed launch —
    /// it exits rather than lingering; one that served a client exits when
    /// the last session AND last client are gone.
    var everServed = false
    /// Bumped on every accept so a stale corpse-expiry timer from an earlier
    /// quiet period can never fire against a newer one's clock.
    var clientGeneration = 0
    /// Orphans HUPped at boot whose SIGKILL escalation hasn't run yet. The
    /// daemon must not exit inside that window — the ledger is already gone,
    /// and a HUP-immune straggler would leak with no record anywhere.
    var pendingOrphanKills: [LedgerEntry] = []
    /// One scratch buffer for every pty read, allocated once: a zeroed 64 KiB
    /// Array per wake event plus generic byte-by-byte slice appends was —
    /// per the profiler — most of a core at 14 MB/s. Single-queue confinement
    /// makes sharing it free.
    var readScratch = [UInt8](repeating: 0, count: Server.readBatchLimit)
    var lockFD: Int32 = -1
    let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        queue.async { self.bootstrap() }
    }

    func bootstrap() {
        // One daemon per socket path, settled by flock — not by racy
        // probe-connect-unlink dances. The lock outlives everything (the fd
        // is held for the process lifetime), and ONLY the lock holder ever
        // unlinks the socket, so no interleaving of two starting daemons can
        // destroy a live one's socket.
        lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            log("another daemon holds the lock; exiting")
            exit(0)
        }
        // Under the lock (so no live daemon owns these), hang up whatever a
        // crashed predecessor left running: those children's pty masters
        // died with it, making them unreachable forever — leaked shells and
        // agents this machine would otherwise carry until reboot.
        sweepOrphans()
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { fail("socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { path in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                _ = strlcpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self),
                            path, dest.count)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        var bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, size)
            }
        }
        if bound != 0, errno == EADDRINUSE {
            // We hold the lock, so a socket file here is stale — except
            // during the one transition where a pre-lock-era daemon is still
            // live: a probe connect spares its socket.
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, size)
                }
            }
            close(probe)
            if connected == 0 {
                log("another (pre-lock) daemon is live; exiting")
                exit(0)
            }
            unlink(socketPath)
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, size)
                }
            }
        }
        guard bound == 0 else { fail("bind() failed: \(errno)") }
        chmod(socketPath, 0o600)
        guard listen(listenFD, 4) == 0 else { fail("listen() failed: \(errno)") }

        let accept = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        accept.setEventHandler { [weak self] in self?.acceptClient() }
        accept.resume()
        acceptSource = accept

        let chld = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        chld.setEventHandler { [weak self] in self?.reapChildren() }
        chld.resume()
        sigchld = chld

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        term.setEventHandler { [weak self] in self?.shutdown() }
        term.resume()
        sigterm = term
        signal(SIGTERM, SIG_IGN)

        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.everServed else { return }
            self.log("no client within 60s; exiting")
            self.shutdown()
        }
        log("listening at \(socketPath)")
    }

    /// SIGTERM (or a stale-version replacement): sessions get a HUP — this
    /// path only runs when the user is losing the daemon anyway, and a
    /// half-orphaned shell is worse than a closed one.
    func shutdown() {
        for session in sessions.values where !session.exited {
            kill(session.pid, SIGHUP)
        }
        // A SIGTERM mid-sweep cannot wait 3s (our replacement is waiting on
        // the flock) — settle the escalation right now instead of leaking it.
        for entry in pendingOrphanKills
        where processStartSeconds(entry.pid) == entry.startSeconds {
            log("escalating orphan sweep for pid=\(entry.pid) at shutdown")
            kill(entry.pid, SIGKILL)
        }
        unlink(socketPath)
        exit(0)
    }

}
