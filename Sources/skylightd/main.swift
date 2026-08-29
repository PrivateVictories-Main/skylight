import Darwin
import Foundation

// skylightd — Skylight's session keeper. Owns one pty per terminal session
// so the sessions outlive the app; the app is a reattaching client over a
// user-only unix socket. No network, no TCP, nothing beyond this machine.

signal(SIGPIPE, SIG_IGN)

let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Skylight", isDirectory: true)
try? FileManager.default.createDirectory(at: supportDir,
                                         withIntermediateDirectories: true)

let socketPath = ProcessInfo.processInfo.environment["SKYLIGHTD_SOCKET"]
    ?? supportDir.appendingPathComponent("daemon.sock").path

// `skylightd status` — introspection in the caller's terminal, then out.
// Before any daemonizing: status must keep stdout and never detach.
if CommandLine.arguments.dropFirst().first == "status" {
    Status.run(socketPath: socketPath)
}

// Detach from whatever launched us: our lifetime must not be the app's.
// setsid fails harmlessly if we already lead a session.
_ = setsid()
_ = chdir("/")
// Everything this process creates — socket, lock, log — is user-only from
// birth; the later chmod is belt-and-braces, not the mechanism.
umask(0o077)

// stdio → log file (stdin → /dev/null). Truncate a log that outgrew 1 MiB —
// it is a diagnostic, not a record.
let logPath = ProcessInfo.processInfo.environment["SKYLIGHTD_LOG"]
    ?? supportDir.appendingPathComponent("daemon.log").path
if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
   let size = attrs[.size] as? Int, size > 1 << 20 {
    try? FileManager.default.removeItem(atPath: logPath)
}
let logFD = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
if logFD >= 0 {
    dup2(logFD, 1)
    dup2(logFD, 2)
    if logFD > 2 { close(logFD) }
}
let nullFD = open("/dev/null", O_RDONLY)
if nullFD >= 0 {
    dup2(nullFD, 0)
    if nullFD > 2 { close(nullFD) }
}

let server = Server(socketPath: socketPath)
server.start()
dispatchMain()
