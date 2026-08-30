#!/usr/bin/env python3
"""Measure the session keeper. The README's numbers come from here.

Talks the daemon's wire protocol directly over a private socket (never the
real one), so nothing you have running is touched. Reports:
  - keystroke echo round trip (client -> daemon -> pty -> echo -> back)
  - attached flood throughput and daemon CPU per byte
  - detached-flood CPU (the pulse-sampling lane)
  - daemon RSS under load

Usage:  ./scripts/bench.py            (expects a built daemon; builds run
                                       `swift build -c release` first)
"""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DAEMON = os.path.join(REPO, ".build", "release", "skylightd")

OUTPUT, RESIZE, INPUT, SPAWN, KILL, HELLO, HELLO_REPLY = 0x82, 0x05, 0x04, 0x02, 0x06, 0x01, 0x81
ATTACH = 0x03


def frame(kind, payload):
    return bytes([kind]) + struct.pack(">I", len(payload)) + payload


def cputime(pid):
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    minutes, seconds = out.split(":")
    return int(minutes) * 60 + float(seconds)


def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    return int(out) / 1024


def spawn_session(sock, argv, cols=200, rows=50):
    sid = uuid.uuid4()
    request = {"id": str(sid).upper(), "argv": argv, "cwd": None, "env": {}}
    sock.sendall(frame(SPAWN, json.dumps(request).encode()))
    sock.sendall(frame(RESIZE, sid.bytes + struct.pack(">HHHH", cols, rows, 0, 0)))
    time.sleep(0.4)   # birth settle
    return sid


def main():
    if not os.path.exists(DAEMON):
        print("building release daemon…")
        subprocess.run(["swift", "build", "-c", "release"], cwd=REPO, check=True)

    workdir = tempfile.mkdtemp(prefix="skylight-bench-")
    sock_path = os.path.join(workdir, "bench.sock")
    daemon = subprocess.Popen(
        [DAEMON],
        env={**os.environ, "SKYLIGHTD_SOCKET": sock_path,
             "SKYLIGHTD_LOG": os.path.join(workdir, "bench.log")})
    time.sleep(1)

    try:
        # ---- echo latency
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.settimeout(10)
        sid = spawn_session(s, ["/bin/cat"], cols=80, rows=24)
        latencies = []
        buf = b""
        for _ in range(300):
            t0 = time.perf_counter()
            s.sendall(frame(INPUT, sid.bytes + b"x"))
            got = False
            while not got:
                buf += s.recv(65536)
                i = 0
                while i + 5 <= len(buf):
                    length = struct.unpack(">I", buf[i + 1:i + 5])[0]
                    if i + 5 + length > len(buf):
                        break
                    if buf[i] == OUTPUT and buf[i + 5:i + 21] == sid.bytes:
                        got = True
                    i += 5 + length
                buf = buf[i:]
            latencies.append((time.perf_counter() - t0) * 1e6)
        latencies.sort()
        print(f"echo round trip : median {latencies[150]:.0f} µs, "
              f"p95 {latencies[285]:.0f} µs")
        s.sendall(frame(KILL, sid.bytes))
        time.sleep(0.3)
        s.close()

        # ---- attached flood
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.settimeout(10)
        sid = spawn_session(
            s, ["/bin/sh", "-c",
                "yes abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"])
        t_cpu0, total, t0 = cputime(daemon.pid), 0, time.time()
        while time.time() - t0 < 4:
            total += len(s.recv(262144))
        util = (cputime(daemon.pid) - t_cpu0) / 4
        mbs = total / 4 / 1e6
        print(f"attached flood  : {mbs:.0f} MB/s at {util * 100:.0f}% daemon CPU "
              f"= {mbs / max(0.01, util):.0f} MB/s per core; "
              f"RSS {rss_mb(daemon.pid):.1f} MB")

        # ---- detached flood (pulse lane)
        s.close()
        time.sleep(2)
        t_cpu0 = cputime(daemon.pid)
        time.sleep(5)
        print(f"detached flood  : {(cputime(daemon.pid) - t_cpu0) / 5 * 100:.1f}% daemon CPU")

        # ---- reattach replay (the survival lane's first frame)
        # The flood session's ring is full (it keeps the newest ~1 MiB), so
        # this times the worst case: connect, attach, and receive the whole
        # ring as the replay frame — what a relaunching app waits for before
        # the terminal shows its scrollback again.
        times, replay_len = [], 0
        for _ in range(20):
            r = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            r.connect(sock_path)
            r.settimeout(10)
            t0 = time.perf_counter()
            r.sendall(frame(ATTACH, sid.bytes))
            buf, done = b"", False
            while not done:
                buf += r.recv(1 << 20)
                i = 0
                while i + 5 <= len(buf):
                    length = struct.unpack(">I", buf[i + 1:i + 5])[0]
                    if i + 5 + length > len(buf):
                        break
                    if buf[i] == OUTPUT and buf[i + 5:i + 21] == sid.bytes:
                        done = True
                        replay_len = length - 16
                        break
                    i += 5 + length
                buf = buf[i:]
            times.append((time.perf_counter() - t0) * 1e3)
            r.close()
        times.sort()
        print(f"reattach replay : {replay_len / 1e6:.1f} MB ring in "
              f"{times[10]:.1f} ms median, {times[19]:.1f} ms max")

        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        s.sendall(frame(KILL, sid.bytes))
        time.sleep(0.4)
        s.close()
    finally:
        daemon.terminate()
        subprocess.run(["rm", "-rf", workdir])


if __name__ == "__main__":
    main()
