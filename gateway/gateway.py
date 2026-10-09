#!/usr/bin/env python3
"""gateway.py: the FIX gateway a member runs at its own edge : FIX 4.4, and FIX 5.0 SP2 over FIXT.1.1, the
version each session's Logon names (`fix.Session`).

    python3 gateway/gateway.py --venue <cid> --identity <name> --port <n> --account <a> --member <m> --journal <file>
                               [--chain <chain.json>] [--comp THEBES] [--client CLIENT]

It terminates one FIX session (`fix.Session`), translates NewOrderSingle (D), OrderCancelRequest (F) and
OrderCancelReplaceRequest (G) into the venue's typed calls (`place`, `cancel`, `replace`) signed with the member's own
trader identity, and answers with ExecutionReports (8) and OrderCancelRejects (9). Fills and every way an order leaves
the book without filling come from the public feed (the log's projection: no account, no member, no client reference),
matched to the orders this gateway entered. The gateway holds no authority the member's key does not: the venue judges
every call as the trader's own, and a gateway signing with any other key is refused by the contract.

Every report it sends is also written to `--journal` (one JSON line: the application fields), for `reconstruct.py` to
compare with the reports the log alone gives.

With `--dropcopy-port`, a second session (the drop copy) streams the reports of every order of the member's accounts, from the
member's scoped page of the log (`dropCopy`, book/SPEC.md §14) through `orderlog.Reports`: the same rule, so the same
reports for the orders the first session entered. Its reports are written to `--dropcopy-journal`.

Attribution: Thebes Core Team.
"""
import argparse
import asyncio
import json
import os
import sys
from decimal import Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "custody", "integration"))
import fix  # noqa: E402
import er  # noqa: E402
import feedwatch  # noqa: E402
import orderlog  # noqa: E402
import venue_candid as VC  # noqa: E402
from venue_candid import Types, encode, decode, variant, field  # noqa: E402
import thebes_client as TC  # noqa: E402

NAT, TEXT = Types.Nat, Types.Text
TIF = {"0": "day", "1": "gtc", "6": "gtd"}
KIND = {"2": "limit"}


def minor(price):
    """A FIX Price in pounds as the venue's minor units; refused unless it is a whole number of them."""
    d = Decimal(price) * 100
    if d != d.to_integral_value() or d < 0:
        raise ValueError("a price in whole piastres")
    return int(d)


def ok(reply):
    """A typed reply's `#ok`, its tag arriving as its name or its Candid hash."""
    return variant(reply)[0] in ("ok", "_" + str(VC.chash("ok")))


class Gateway:
    def __init__(self, a):
        self.a = a
        self.chain = TC.ThebesChain(a.chain)
        self.me = TC.Identity(a.identity)
        self.book = er.Book(a.account)
        self.by_cl = {}            # ClOrdID -> order
        self.session = None
        self.lock = asyncio.Lock()
        self.journal = open(a.journal, "a")
        self.feed = feedwatch.Watch()

    def call(self, method, args):
        self.chain.set_sender(self.me.principal)
        return decode(self.chain.update_call(self.a.venue, method, encode(args)))[0]["value"]

    def emit(self, fields):
        self.session.send_app("8", fields)
        self.journal.write(json.dumps(fields) + "\n"); self.journal.flush()

    # ── the application ──
    async def on_app(self, m):
        async with self.lock:
            loop = asyncio.get_running_loop()
            if m.type == "D":
                await loop.run_in_executor(None, self.new_order, m)
            elif m.type == "F":
                await loop.run_in_executor(None, self.cancel, m)
            elif m.type == "G":
                await loop.run_in_executor(None, self.replace, m)
            else:
                self.session._send("j", [("45", str(m.seq)), ("372", m.type), ("380", "3"), ("58", "an unsupported message type")])

    def missing(self, m, tags):
        gone = [t for t in tags if m.get(t) is None]
        if gone:
            self.session.reject(m.seq, 1, f"required tag {gone[0]} missing", gone[0])
        return bool(gone)

    def new_order(self, m):
        if self.missing(m, ["11", "55", "54", "38", "40", "44"]):
            return
        cl, symbol = m.get("11"), m.get("55")
        side = {"1": "buy", "2": "sell"}.get(m.get("54"))
        if side is None or m.get("40") not in KIND or m.get("59", "0") not in TIF:
            return self.rejected(cl, symbol, m, "an order type, side or time in force the venue takes")
        try:
            price = minor(m.get("44")); qty = int(m.get("38"))
        except ValueError as e:
            return self.rejected(cl, symbol, m, str(e))
        v = {"account": self.a.account, "instrument": int(symbol), "side": {side: None}, "kind": {"limit": None}, "qty": qty, "price": price, "stopPrice": 0,
             "peak": int(m.get("111", "0")), "validity": {TIF[m.get("59", "0")]: None}, "gtdDay": 0, "selfTrade": {"cancelResting": None},
             "capacity": {"agency": None}, "shortSale": False, "clientRef": cl, "oco": 0, "trail": 0}
        r = self.call("place", [{"type": VC.Place, "value": v}])
        if not ok(r):
            return self.rejected(cl, symbol, m, str(r)[:120])
        order = field(variant(r)[1], "order")
        self.by_cl[cl] = order
        for fields in self.book.apply(("new", order, cl, symbol, side, qty, price)):
            self.emit(fields)

    def rejected(self, cl, symbol, m, why):
        """A refused order: ExecType 8. A refusal writes no block, so this report is the one the log does not hold."""
        fields = [("37", "NONE"), ("11", cl or ""), ("17", f"REJ.{cl}"), ("150", "8"), ("39", "8"), ("103", "99"), ("1", str(self.a.account)),
                  ("55", symbol or ""), ("54", m.get("54", "1")), ("38", m.get("38", "0")), ("151", "0"), ("14", "0"), ("6", "0"), ("58", why)]
        self.session.send_app("8", fields)
        self.journal.write(json.dumps({"rejected": fields}) + "\n"); self.journal.flush()

    def cancel_reject(self, m, response, why):
        self.session.send_app("9", [("37", str(self.by_cl.get(m.get("41"), "NONE"))), ("11", m.get("11", "")), ("41", m.get("41", "")),
                                    ("39", "8"), ("434", response), ("102", "1"), ("58", why)])

    def cancel(self, m):
        if self.missing(m, ["11", "41"]):
            return
        order = self.by_cl.get(m.get("41"))
        if order is None:
            return self.cancel_reject(m, "1", "an order this session entered")
        r = self.call("cancel", [{"type": NAT, "value": order}])
        if not str(r).startswith("x=7,"):
            return self.cancel_reject(m, "1", str(r)[:120])
        # the cancel is reported when the feed shows the order removed, as every other removal is

    def replace(self, m):
        if self.missing(m, ["11", "41", "38", "44"]):
            return
        orig, cl = m.get("41"), m.get("11")
        order = self.by_cl.get(orig)
        if order is None:
            return self.cancel_reject(m, "2", "an order this session entered")
        try:
            price = minor(m.get("44")); qty = int(m.get("38"))
        except ValueError as e:
            return self.cancel_reject(m, "2", str(e))
        cum = self.book.orders[order]["cum"]
        r = self.call("replace", [{"type": NAT, "value": order}, {"type": NAT, "value": qty - cum}, {"type": NAT, "value": price}, {"type": TEXT, "value": cl}])
        if not str(r).startswith("x=67,"):
            return self.cancel_reject(m, "2", str(r)[:120])
        self.by_cl[cl] = order
        for fields in self.book.apply(("replace", order, cl, orig, qty - cum, price)):
            self.emit(fields)

    # ── the feed ──
    async def follow(self):
        """The public feed's events for this gateway's orders, reported in the feed's order. A placement holds the lock
        until its reply has recorded the order, and the feed is applied under the same lock: an event of an order not
        recorded by then is another participant's."""
        loop = asyncio.get_running_loop()
        while True:
            events = await loop.run_in_executor(None, self.feed.poll, self.chain, self.a.venue)
            async with self.lock:
                for ev in events:
                    if ev[1] in self.book.orders:
                        for fields in self.book.apply(ev):
                            self.emit(fields)
            await asyncio.sleep(0.3)

    async def handle(self, reader, writer):
        def transport(raw):
            writer.write(raw)
        self.session = fix.Session(self.a.comp, self.a.client, transport, None)
        self.session.on_app = lambda m: asyncio.ensure_future(self.on_app(m))
        buf = b""
        try:
            while not self.session.closed:
                try:
                    data = await asyncio.wait_for(reader.read(65536), timeout=self.session.heartbeat)
                except asyncio.TimeoutError:
                    self.session._send("0", [])
                    continue
                if not data:
                    break
                buf += data
                while True:
                    try:
                        m, buf = fix.take_message(buf)
                    except fix.FramingError as e:
                        self.session.logout(f"framing: {e}")
                        break
                    if m is None:
                        break
                    self.session.receive(m)
                await writer.drain()
        finally:
            writer.close()

    # ── the drop copy ──
    def drop_page(self, start):
        r = self.call("dropCopy", [{"type": NAT, "value": start}, {"type": NAT, "value": 200}])
        tag, val = variant(r)
        if tag not in ("ok", "_" + str(VC.chash("ok"))):
            raise RuntimeError(f"drop copy: {r}")
        entries = [(e[0], e[1], bytes(e[2])) if isinstance(e, (list, tuple)) else (e["_0_"], e["_1_"], bytes(e["_2_"])) for e in field(val, "entries")]
        nxt = field(val, "next")
        return entries, (nxt[0] if isinstance(nxt, list) and nxt else None)

    async def drop_copy(self, reader, writer):
        session = fix.Session(self.a.comp, self.a.client + "DC", lambda raw: writer.write(raw), lambda m: None)
        reports = orderlog.Reports(member=self.a.member)
        journal = open(self.a.dropcopy_journal, "a")
        loop = asyncio.get_running_loop()
        start, buf = 0, b""

        async def stream():
            nonlocal start
            while not session.closed:
                if session.logged_on:
                    entries, nxt = await loop.run_in_executor(None, self.drop_page, start)
                    for block, own, data in entries:
                        for _, fields in reports.entry(own, data):
                            session.send_app("8", fields)
                            journal.write(json.dumps(fields) + "\n"); journal.flush()
                        start = block + 1
                    await writer.drain()
                await asyncio.sleep(0.5)

        task = asyncio.ensure_future(stream())
        try:
            while not session.closed:
                data = await reader.read(65536)
                if not data:
                    break
                buf += data
                while True:
                    m, buf = fix.take_message(buf)
                    if m is None:
                        break
                    session.receive(m)
                await writer.drain()
        finally:
            task.cancel()
            writer.close()

    async def main(self):
        server = await asyncio.start_server(self.handle, "127.0.0.1", self.a.port)
        asyncio.ensure_future(self.follow())
        servers = [server]
        if self.a.dropcopy_port:
            servers.append(await asyncio.start_server(self.drop_copy, "127.0.0.1", self.a.dropcopy_port))
        await asyncio.gather(*(x.serve_forever() for x in servers))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--venue", type=int, required=True, help="the venue's contract id")
    ap.add_argument("--identity", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--account", type=int, required=True)
    ap.add_argument("--member", type=int, required=True)
    ap.add_argument("--journal", required=True)
    ap.add_argument("--chain", default=os.environ.get("THEBES_CHAIN"), help="the chain's JSON description (thebes_client.py)")
    ap.add_argument("--comp", default="THEBES")
    ap.add_argument("--client", default="CLIENT")
    ap.add_argument("--dropcopy-port", type=int, default=0)
    ap.add_argument("--dropcopy-journal", default=os.devnull)
    a = ap.parse_args()
    asyncio.run(Gateway(a).main())


if __name__ == "__main__":
    main()
