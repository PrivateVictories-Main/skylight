import Darwin
import Foundation
import SkylightDaemonCore

/// The socket side: accepting, framing in, buffered non-blocking out.
extension Server {
    // MARK: - Clients

    func acceptClient() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.readFromClient(client)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        client.readSource = source
        clients[ObjectIdentifier(client)] = client
        log("client connected (\(clients.count))")
    }

    func readFromClient(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(client.fd, &chunk, chunk.count)
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return drop(client)
        }
        guard n > 0 else { return drop(client) }   // EOF
        client.buffer.append(contentsOf: chunk[0..<n])
        do {
            for frame in try Wire.decodeAvailable(&client.buffer) {
                handle(frame, from: client)
            }
        } catch {
            log("protocol error from client: \(error)")
            drop(client)
        }
    }

    func drop(_ client: Client) {
        // Write source first: its fd is closed by the READ source's cancel
        // handler, and a source must never outlive its descriptor.
        client.writeSource?.cancel()
        client.writeSource = nil
        client.readSource?.cancel()
        client.readSource = nil
        clients.removeValue(forKey: ObjectIdentifier(client))
        // Unborn spawns leave with their requester: a session that never
        // started is not one the quit promise covers, and a fallback-spawned
        // ghost would pin the daemon open for nobody.
        for id in client.attached where pendingSpawns[id] != nil {
            pendingSpawns.removeValue(forKey: id)
        }
        // And any session paused for this client's backlog reads again —
        // the detached pulse takes over from here.
        releaseBackpressure(from: client)
        log("client gone (\(clients.count))")
        exitIfIdle()
    }

    /// Never blocks: what the socket won't take now is buffered and drained
    /// by a write source. The daemon's one queue is every session's lifeline
    /// — a wedged client loses its connection, not everyone's IO.
    func send(_ frame: WireFrame, to client: Client) {
        client.outbound.append(Wire.encode(frame))
        finishEnqueue(client)
    }

    /// The hot path, framed straight into the outbound buffer: the generic
    /// route copied every output byte four times (batch → id-prefix →
    /// encode → outbound); this is a header plus ONE memcpy from wherever
    /// the bytes already live.
    func sendOutput(_ id: UUID, _ raw: UnsafeRawBufferPointer,
                            to client: Client) {
        var header = Data(capacity: 21)
        header.append(WireType.output.rawValue)
        var length = UInt32(16 + raw.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        header.append(WirePayload.uuidData(id))
        client.outbound.append(header)
        if let base = raw.baseAddress, raw.count > 0 {
            client.outbound.append(base.assumingMemoryBound(to: UInt8.self),
                                   count: raw.count)
        }
        finishEnqueue(client)
    }

    func sendOutput(_ id: UUID, _ bytes: Data, to client: Client) {
        bytes.withUnsafeBytes { sendOutput(id, $0, to: client) }
    }

    func finishEnqueue(_ client: Client) {
        guard client.outboundPending <= Self.maxClientBacklog else {
            log("client backlog exceeded; dropping")
            return drop(client)
        }
        flushOutbound(client)
    }

    func flushOutbound(_ client: Client) {
        while client.outboundPending > 0 {
            let start = client.outboundStart
            let n = client.outbound.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress! + start
                return write(client.fd, base, min(raw.count - start, 128 * 1024))
            }
            if n > 0 {
                client.outboundStart += n
                if client.outboundPending <= Self.clientLowWater {
                    releaseBackpressure(from: client)
                }
            } else if n < 0, errno == EAGAIN {
                // Compact opportunistically so a long-lived slow client's
                // buffer doesn't carry a dead prefix forever.
                if client.outboundStart > 1 << 20 {
                    client.outbound.removeFirst(client.outboundStart)
                    client.outboundStart = 0
                }
                armWrite(client)
                return
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return drop(client)
            }
        }
        client.outbound.removeAll(keepingCapacity: true)
        client.outboundStart = 0
        client.writeSource?.cancel()
        client.writeSource = nil
        releaseBackpressure(from: client)
    }

    /// The low-water release: any session paused for this client's backlog
    /// reads again. (A still-slow client just re-pauses it at high water.)
    func releaseBackpressure(from client: Client) {
        for session in sessions.values
        where session.readPaused && client.attached.contains(session.id) {
            resumeReading(session)
        }
    }

    func armWrite(_ client: Client) {
        guard client.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.flushOutbound(client)
        }
        source.resume()
        client.writeSource = source
    }

}
