import Darwin
import Foundation
import SkylightDaemonCore

/// `skylightd status` — the daemon explains itself. Connects like any
/// client, asks hello, prints a human summary, exits. Runs in the caller's
/// terminal (no daemonizing, no log redirect).
enum Status {
    static func run(socketPath: String) -> Never {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { path in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                _ = strlcpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self),
                            path, dest.count)
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            print("skylightd is not running.")
            exit(1)
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, socklen_t(MemoryLayout<timeval>.size))
        // list, not hello: a status probe is a reader, never "the app" — it
        // must not trip the one-app gate nor bounce a launching app aside.
        let query = Wire.encode(WireFrame(type: .list))
        _ = query.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<n])
            guard let frames = try? Wire.decodeAvailable(&buffer),
                  let frame = frames.first(where: { $0.type == .listReply }),
                  let reply = try? JSONDecoder().decode(HelloReply.self, from: frame.payload)
            else { continue }
            close(fd)
            printReport(reply)
            exit(0)
        }
        close(fd)
        print("skylightd did not answer.")
        exit(1)
    }

    private static func printReport(_ reply: HelloReply) {
        var headline = "skylightd (protocol \(reply.protocolVersion), pid \(reply.daemonPID))"
        if let start = reply.daemonStartSeconds {
            headline += " — up \(uptime(since: start))"
        }
        if reply.busy == true {
            headline += " — BUSY (another app is connected)"
        }
        print(headline)
        guard !reply.sessions.isEmpty else {
            print("no sessions.")
            return
        }
        let word = reply.sessions.count == 1 ? "session" : "sessions"
        print("\(reply.sessions.count) \(word):")
        for session in reply.sessions.sorted(by: { ($0.startSeconds ?? 0) < ($1.startSeconds ?? 0) }) {
            let mark = session.alive ? "●" : "○"
            let command = session.argv.joined(separator: " ")
            var details: [String] = []
            if session.alive, let start = session.startSeconds {
                details.append("up \(uptime(since: start))")
            }
            if !session.alive, let code = session.exitCode {
                details.append("exited \(code)")
            }
            if let bytes = session.ringBytes, bytes > 0 {
                details.append("\(replaySize(bytes)) replay")
            }
            let suffix = details.isEmpty ? "" : "   (\(details.joined(separator: ", ")))"
            print("  \(mark) \(command)\(suffix)")
        }
    }

    private static func uptime(since startSeconds: Int64) -> String {
        let seconds = max(0, Int64(Date().timeIntervalSince1970) - startSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    private static func replaySize(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? String(format: "%.1f MiB", Double(bytes) / Double(1 << 20))
            : bytes >= 1024 ? "\(bytes / 1024) KiB"
            : "\(bytes) B"
    }
}
