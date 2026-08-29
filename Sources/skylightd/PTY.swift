import Darwin
import Foundation

enum PTYError: Error {
    case openptyFailed(Int32)
    case ptsnameFailed
    case spawnFailed(Int32)
}

struct SpawnedChild {
    let pid: pid_t
    let masterFD: Int32
}

enum PTY {
    /// Spawn `argv` on a fresh pty and return the child plus the master fd.
    ///
    /// The controlling-terminal dance, spelled out because every piece is
    /// load-bearing: `POSIX_SPAWN_SETSID` makes the child a session leader
    /// with no controlling tty; the first file action then OPENS the slave
    /// by path as fd 0 — and on macOS a session leader's first tty open
    /// becomes its controlling terminal. dup2 fans it out to stdout/stderr.
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes everything else (our master fd,
    /// the socket, the log) in the child, so hygiene is structural.
    static func spawn(argv: [String], cwd: String?,
                      extraEnv: [String: String]) throws -> SpawnedChild {
        precondition(!argv.isEmpty)
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PTYError.openptyFailed(errno)
        }
        // The child re-opens the slave by path; our copy would only leak.
        close(slave)
        guard let slaveNamePtr = ptsname(master) else {
            close(master)
            throw PTYError.ptsnameFailed
        }
        let slavePath = String(cString: slaveNamePtr)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if let cwd {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETSIGDEF is load-bearing: signal DISPOSITIONS inherit through
        // posix_spawn, and a launcher that ignores SIGHUP (test runners do,
        // to survive terminal loss) would hand every shell a child that
        // ignores it too — sessions that only SIGKILL can end. Reset all.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        posix_spawnattr_setflags(
            &attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF))

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        for (key, value) in extraEnv { environment[key] = value }
        let envStrings = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPtr in
            withCStrings(envStrings) { envPtr in
                posix_spawn(&pid, argv[0], &actions, &attr, argvPtr, envPtr)
            }
        }
        guard result == 0 else {
            close(master)
            throw PTYError.spawnFailed(result)
        }
        return SpawnedChild(pid: pid, masterFD: master)
    }

    static func resize(masterFD: Int32, columns: UInt16, rows: UInt16,
                       widthPixels: UInt16, heightPixels: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns,
                           ws_xpixel: widthPixels, ws_ypixel: heightPixels)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    /// Null-terminated C string array with proper lifetime for one call.
    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        let cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = cStrings
        argv.append(nil)
        return argv.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
