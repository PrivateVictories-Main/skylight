import Darwin
import Foundation
import SkylightDaemonCore

/// The protocol: what each frame from a client means.
extension Server {
    // MARK: - Frames

    func handle(_ frame: WireFrame, from client: Client) {
        switch frame.type {
        case .hello, .list:
            if frame.type == .hello {
                // Serving is an APP thing: a status probe connecting and
                // leaving must neither arm the idle-exit (it once killed the
                // daemon it had just reported on) nor restart the corpse
                // clock. The 60s no-client timer covers a never-helloed run.
                everServed = true
                clientGeneration += 1
            }
            // One app at a time — the spec's single-client rule, enforced
            // where it can be. Two app instances would otherwise fight over
            // the same session ids (SPAWN-replace SIGKILLs the first one's
            // children silently); the loser gets busy=true, falls back to
            // the exec lane, and hurts nothing.
            if frame.type == .hello,
               clients.values.contains(where: { $0 !== client && $0.isApp }) {
                let reply = HelloReply(protocolVersion: Wire.protocolVersion,
                                       daemonPID: getpid(), sessions: [], busy: true)
                send(WireFrame(type: .helloReply,
                               payload: (try? JSONEncoder().encode(reply)) ?? Data()),
                     to: client)
                log("busy: refused a second concurrent client")
                queue.asyncAfter(deadline: .now() + 1) { [weak self, weak client] in
                    guard let self, let client,
                          self.clients[ObjectIdentifier(client)] != nil else { return }
                    self.drop(client)
                }
                return
            }
            if frame.type == .hello { client.isApp = true }
            let appConnected = clients.values.contains { $0.isApp }
            let reply = HelloReply(
                protocolVersion: Wire.protocolVersion,
                daemonPID: getpid(),
                sessions: sessions.values.map {
                    SessionInfo(id: $0.id, argv: $0.argv,
                                alive: !$0.exited, exitCode: $0.exitCode,
                                startSeconds: $0.startSeconds,
                                ringBytes: $0.ring.count)
                },
                busy: frame.type == .list && appConnected ? true : nil,
                daemonStartSeconds: processStartSeconds(getpid()))
            let payload = (try? JSONEncoder().encode(reply)) ?? Data()
            send(WireFrame(type: frame.type == .hello ? .helloReply : .listReply,
                           payload: payload), to: client)
        case .spawn:
            guard let request = try? JSONDecoder().decode(SpawnRequest.self,
                                                          from: frame.payload) else {
                // Malformed spawn is a protocol error — a silent return would
                // leave the client waiting forever for a session that will
                // never exist.
                log("undecodable spawn payload; dropping client")
                return drop(client)
            }
            spawn(request, for: client)
        case .attach:
            guard let id = WirePayload.uuid(from: frame.payload),
                  let session = sessions[id] else { return }
            client.attached.insert(id)
            session.lastAttach = DispatchTime.now()
            // A pulse-paused detached session streams again the moment
            // someone is watching.
            resumeReading(session)
            if session.ring.count > 0 {
                sendOutput(id, session.ring.contents, to: client)
            }
            if session.exited, let code = session.exitCode {
                send(WireFrame(type: .exited,
                               payload: WirePayload.encodeExited(id, code: code)), to: client)
            }
        case .input:
            // masterFD guard as well as exited: drain and reap are
            // independent, and a drained-but-unreaped session's fd number
            // may already belong to someone else.
            guard let (id, bytes) = WirePayload.parseIDPrefixed(frame.payload),
                  let session = sessions[id], !session.exited,
                  session.masterFD >= 0 else { return }
            session.inputBacklog.append(bytes)
            if session.inputBacklog.count > Self.maxInputBacklog {
                if !session.inputOverflowing {
                    session.inputOverflowing = true
                    log("input backlog exceeded for \(id); dropping newest until it drains")
                }
                session.inputBacklog.removeLast(
                    session.inputBacklog.count - Self.maxInputBacklog)
            }
            flushInput(session)
        case .resize:
            guard let resize = WirePayload.parseResize(frame.payload),
                  resize.columns > 0, resize.rows > 0 else { return }
            if let pending = pendingSpawns[resize.id] {
                // Quiet-period birth: the surface's grid moves through
                // transitional sizes while layout settles, and a shell born
                // into one draws its first prompt for a width that is about
                // to be wrong — worse, zsh can miss the corrective SIGWINCH
                // during its own startup. Every DIFFERING size restarts the
                // clock; the child is born only once the grid holds still.
                let changed = pending.latest.map {
                    $0.columns != resize.columns || $0.rows != resize.rows
                } ?? true
                pending.latest = resize
                guard changed else { return }
                pending.generation += 1
                let generation = pending.generation
                // Snappy by default, patient when it matters: the FIRST size
                // births in 60ms — most surfaces report their settled grid
                // immediately — and only an actually-moving grid (a second,
                // DIFFERENT size cancels the fast timer via its generation)
                // pays the full quiet period. Several spawns pending at once
                // means a cold multi-tile restore — the one launch where
                // layout is slowest and a fast birth risks a post-birth
                // resize redrawing the first prompt — so they all wait out
                // the full quiet period; a lone sheet spawn stays snappy.
                let settle = generation == 1 && pendingSpawns.count == 1 ? 0.06 : 0.2
                // Identity- and generation-guarded: a kill-then-respawn
                // replaces the pending object, and a newer size obsoletes
                // this timer.
                queue.asyncAfter(deadline: .now() + settle) { [weak self, weak pending] in
                    guard let self, let pending,
                          self.pendingSpawns[resize.id] === pending,
                          pending.generation == generation,
                          let size = pending.latest else { return }
                    self.pendingSpawns.removeValue(forKey: resize.id)
                    self.performSpawn(pending.request,
                                      columns: size.columns, rows: size.rows,
                                      widthPixels: size.widthPixels,
                                      heightPixels: size.heightPixels)
                }
                return
            }
            guard let session = sessions[resize.id], !session.exited,
                  session.masterFD >= 0 else { return }
            // A reattaching renderer reports TRANSITIONAL sizes while its
            // window builds — forwarding each one SIGWINCHes the child into
            // wrong-width redraws (the reattach-debris artifact: stray %,
            // right-shifted prompts). For a short window after attach, sizes
            // coalesce and only the settled one applies — and a settled size
            // the pty already has is skipped outright, so a relaunch whose
            // layout lands where it left off touches the child not at all:
            // the replayed grid stands byte-perfect. Interactive resizes
            // (attach long past) stay immediate.
            let sinceAttach = DispatchTime.now().uptimeNanoseconds
                &- session.lastAttach.uptimeNanoseconds
            if sinceAttach < 1_500_000_000 {
                session.pendingResize = resize
                session.resizeGeneration += 1
                let generation = session.resizeGeneration
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self, weak session] in
                    guard let self, let session,
                          session.resizeGeneration == generation,
                          let settled = session.pendingResize else { return }
                    session.pendingResize = nil
                    self.applyResize(settled, to: session)
                }
                return
            }
            applyResize(resize, to: session)
        case .kill:
            guard let id = WirePayload.uuid(from: frame.payload) else { return }
            if pendingSpawns.removeValue(forKey: id) != nil {
                for client in clients.values { client.attached.remove(id) }
                return
            }
            guard let session = sessions[id] else { return }
            requestKill(session)
        case .helloReply, .output, .exited, .listReply:
            break   // daemon→client types arriving here are a client bug; ignore
        }
    }

}
