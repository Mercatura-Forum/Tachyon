#!/usr/bin/env python3
"""standin.py (test only): the gateway's FIX side against QuickFIX/J with a stand-in venue in place of the chain.

    python3 gateway/test/standin.py <conformance dir> [--version 4.4|5.0sp2] [--plant drop-leaves|resend-without-possdup]

The gateway under test is `gateway.Gateway` itself: its session layer (`fix.Session`), its translation of D, F and G and
its reports (`er.Book`). Only the two calls that reach the chain are replaced: `call` answers place, cancel and replace as
the venue does (an instrument 999 refused; a cancel's removal and B1's fill come back on the feed), and the feed is a
queue. The same session runs against the venue on a chain through the same gateway; that run's harness is not part of
this repository.

A plant injects a fault the conformance must catch: `drop-leaves` sends reports without LeavesQty (151), which the
engine's dictionary requires; `resend-without-possdup` resends without PossDupFlag (43), which the session protocol
requires. With a plant, the run must be RED. `--version 5.0sp2` runs the same session in FIX 5.0 SP2 over FIXT.1.1
(Conformance50.java).

Attribution: Thebes Core Team.
"""
import argparse
import asyncio
import os
import socket
import sys
import threading
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import gateway as G  # noqa: E402
import er  # noqa: E402
import fix  # noqa: E402


class StandIn(G.Gateway):
    def __init__(self, a):
        self.a, self.chain = a, None
        self.book, self.by_cl, self.session = er.Book(a.account), {}, None
        self.lock, self.journal = asyncio.Lock(), open(os.devnull, "w")
        self.orders, self.queue, self.qlock, self.feed = 0, [], threading.Lock(), self

    def poll(self, chain, venue):
        with self.qlock:
            out, self.queue = self.queue, []
        return out

    def push(self, ev):
        with self.qlock:
            self.queue.append(ev)

    def call(self, method, args):
        if method == "place":
            if args[0]["value"]["instrument"] == 999:
                return {"err": "UnknownInstrument"}
            self.orders += 1
            return {"ok": {"order": self.orders}}
        if method == "cancel":
            self.push(("cancel", args[0]["value"]))
            return f"x=7,{args[0]['value']}"
        if method == "replace":
            return f"x=67,{args[0]['value']},0,{args[1]['value']}"
        raise ValueError(f"the stand-in venue has no {method}")


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    return p


async def run(a):
    if a.plant == "drop-leaves":
        report = er.Book.report
        er.Book.report = lambda self, *x, **k: [f for f in report(self, *x, **k) if f[0] != "151"]
    elif a.plant == "resend-without-possdup":
        encode = fix.encode
        fix.encode = lambda t, f, seq, s, d, now=None, extra=(), begin="FIX.4.4": encode(t, f, seq, s, d, now, tuple(e for e in extra if e[0] not in ("43", "122")), begin)
    ns = types.SimpleNamespace(account=2, comp="THEBES", client="CLIENT", port=free_port(), dropcopy_port=0, venue="stand-in")
    g = StandIn(ns)
    server = await asyncio.start_server(g.handle, "127.0.0.1", ns.port)
    follower = asyncio.ensure_future(g.follow())
    jars = [os.path.join(a.dir, j) for j in sorted(os.listdir(a.dir)) if j.endswith(".jar")]
    p = await asyncio.create_subprocess_exec("java", "-cp", ":".join(jars + [os.path.join(a.dir, "classes")]), {"4.4": "Conformance", "5.0sp2": "Conformance50"}[a.version], "127.0.0.1", str(ns.port), "1", "2",
                                             "100.00", "99.90", "99.00", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    passed = failed = 0
    while True:
        line = (await p.stdout.readline()).decode()
        if not line:
            break
        line = line.rstrip()
        if line.startswith(("PASS", "FAIL", "CONFORMANCE")):
            print(line, flush=True)
        passed += line.startswith("PASS"); failed += line.startswith("FAIL")
        if line.startswith("CROSS "):
            g.push(("fill", g.by_cl[line[6:]], 5, 10_000))
    rc = await p.wait()
    follower.cancel(); server.close()
    return rc, passed, failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--plant", default="")
    ap.add_argument("--version", default="4.4", choices=("4.4", "5.0sp2"))
    a = ap.parse_args()
    rc, passed, failed = asyncio.run(run(a))
    print(f"count: conformance checks passed = {passed}")
    green = rc == 0 and failed == 0 and passed == 12
    print(f"STAND-IN CONFORMANCE FIX {a.version} " + ("GREEN" if green else f"RED ({failed} failed)"))
    return 0 if green else 1


if __name__ == "__main__":
    sys.exit(main())
