#!/usr/bin/env python3
"""regulator_replay.py: the regulator's replay. A reader holding only the book's certified log rebuilds the book and
proves it is the book's: it checks every block's hash and its link to the block below, decodes every block (the frozen
command bytes and the effects recorded with them), refolds the book from the commands with the reference book's
semantics (book/SPEC.md, `reference_book.py`), requires every recorded effect reproduced (every fill, every clear), and
computes the book's fingerprint itself from the rows it rebuilt, which must equal the fingerprint the book states.

    python3 book/integration/regulator_replay.py <battery log>

It reads only the `L|index|hex` lines (each block's stored bytes, printed by the battery) and the book's stated
fingerprint (`fingerprint|book|hex`); nothing the battery printed about the commands, the orders or the balances.

Attribution: Thebes Core Team.
"""
import hashlib
import sys

from reference_book import Ref, order_key
import feed_projection as FP

LOG_DOMAIN = "tachyon-book-log"
FOLD_DOMAIN = "THEBES-FOLD-v1"
SIDE = {1: "buy", 2: "sell"}
KIND = {1: "limit", 2: "market", 3: "ioc", 4: "fok", 5: "stop", 6: "stopLimit", 7: "trailingStop"}
VALIDITY = {1: "day", 2: "gtc", 3: "gtd"}
SMP = {1: "cancelIncoming", 2: "cancelResting", 3: "cancelBoth"}
CAPACITY = {1: "agency", 2: "principal"}
STATUS = {"waiting": 1, "live": 2, "filled": 3, "cancelled": 4}
PHASES = {1: "closed", 2: "continuous", 3: "auction", 4: "closingAuction", 5: "tradeAtClose", 6: "halted"}
PHASE_CODE = {v: k for k, v in PHASES.items()}


class Reader:
    def __init__(self, data):
        self.d, self.p = data, 0

    def byte(self):
        b = self.d[self.p]; self.p += 1
        return b

    def take(self, n):
        assert self.p + n <= len(self.d), "past the end"
        b = self.d[self.p:self.p + n]; self.p += n
        return b

    def nat(self):
        n = self.byte()
        return int.from_bytes(self.take(n), "big") if n else 0

    def nat64(self):
        return int.from_bytes(self.take(8), "big")

    def len16(self):
        return int.from_bytes(self.take(2), "big")

    def blob(self):
        return self.take(self.len16())

    def text(self):
        return self.blob().decode()

    def boolean(self):
        b = self.byte()
        assert b in (0, 1)
        return b == 1

    def principal(self):
        return self.take(self.byte())

    def opt(self, f):
        t = self.byte()
        assert t in (0, 1)
        return f() if t else None

    def nats(self):
        return [self.nat() for _ in range(self.len16())]


class Writer:
    def __init__(self):
        self.b = bytearray()

    def nat(self, n):
        if n == 0:
            self.b += b"\x00"
        else:
            bs = n.to_bytes((n.bit_length() + 7) // 8, "big")
            self.b += bytes([len(bs)]) + bs

    def nat64(self, n):
        self.b += n.to_bytes(8, "big")

    def len16(self, n):
        self.b += n.to_bytes(2, "big")

    def blob(self, x):
        self.len16(len(x)); self.b += x

    def text(self, t):
        self.blob(t.encode())

    def opt_blob(self, x):
        if x is None:
            self.b += b"\x00"
        else:
            self.b += b"\x01"; self.blob(x)


def hash_with_domain(domain, payload):
    w = Writer(); w.text(domain)
    return hashlib.sha256(bytes(w.b) + payload).digest()


def principal_text(raw):
    """The textual form of a principal (CRC32 then base32, grouped by five)."""
    import base64
    import zlib
    s = base64.b32encode(zlib.crc32(raw).to_bytes(4, "big") + raw).decode().lower().rstrip("=")
    return "-".join(s[i:i + 5] for i in range(0, len(s), 5))


def principal_raw(text):
    import base64
    s = text.replace("-", "").upper()
    s += "=" * (-len(s) % 8)
    return base64.b32decode(s)[4:]


# ── the command bytes (book/src/BookCanonical.mo, version 1) ──
def read_bands(r):
    return [(r.nat(), r.nat()) for _ in range(r.len16())]


def read_command(data):
    r = Reader(data)
    tag = r.byte()
    if tag == 1:
        c = {"k": "openInstrument", "instrument": r.nat(), "asset": principal_text(r.principal()), "cash": principal_text(r.principal()),
             "lot": r.nat(), "price": r.nat(), "bands": read_bands(r), "collar": r.nat(), "static": r.nat(), "dynamic": r.nat(), "secs": r.nat()}
    elif tag == 2:
        c = {"k": "setTrading", "instrument": r.nat(), "open": r.boolean()}
    elif tag == 3:
        c = {"k": "setReference", "instrument": r.nat(), "price": r.nat()}
    elif tag == 4:
        c = {"k": "deposit", "account": r.nat(), "member": r.nat(), "ledger": principal_text(r.principal()), "amount": r.nat(), "reference": r.blob()}
    elif tag == 5:
        c = {"k": "withdraw", "account": r.nat(), "member": r.nat(), "ledger": principal_text(r.principal()), "amount": r.nat()}
    elif tag == 6:
        c = {"k": "placeOrder", "account": r.nat(), "instrument": r.nat(), "side": SIDE[r.byte()], "kind": KIND[r.byte()], "qty": r.nat(), "price": r.nat(),
             "stop": r.nat(), "peak": r.nat(), "validity": VALIDITY[r.byte()], "gtd": r.nat(), "smp": SMP[r.byte()], "capacity": CAPACITY[r.byte()],
             "short": 1 if r.boolean() else 0, "ref": r.text(), "oco": r.nat(), "trail": r.nat(), "member": r.nat(), "trader": r.nat()}
    elif tag == 7:
        c = {"k": "cancelOrder", "order": r.nat()}
    elif tag == 8:
        c = {"k": "amendOrder", "order": r.nat(), "qty": r.nat(), "price": r.nat()}
    elif tag == 9:
        c = {"k": "massCancel", "account": r.nat(), "member": r.nat(), "limit": r.nat()}
    elif tag == 10:
        c = {"k": "flush"}
    elif tag == 11:
        c = {"k": "endOfDay", "limit": r.nat()}
    elif tag == 12:
        c = {"k": "expireGtd", "day": r.nat(), "limit": r.nat()}
    elif tag == 13:
        c = {"k": "clear", "time": r.nat64()}
    elif tag == 14:
        c = {"k": "setPhase", "instrument": r.nat(), "phase": PHASES[r.byte()], "from": r.nat64(), "to": r.nat64()}
    elif tag == 15:
        c = {"k": "uncross", "instrument": r.nat(), "next": PHASES[r.byte()]}
    elif tag == 16:
        c = {"k": "halt", "instrument": r.nat(), "reason": r.text()}
    elif tag == 17:
        c = {"k": "resume", "instrument": r.nat()}
    elif tag == 18:
        c = {"k": "kill", "member": r.nat(), "trader": r.nat(), "reason": r.text()}
    elif tag == 19:
        c = {"k": "killSweep", "kill": r.nat(), "limit": r.nat()}
    elif tag == 20:
        c = {"k": "revive", "kill": r.nat()}
    elif tag == 21:
        c = {"k": "setLimits", "member": r.nat(), "qty": r.nat(), "value": r.nat(), "credit": r.nat()}
    elif tag == 22:
        c = {"k": "sealDay", "day": r.nat()}
    elif tag == 23:
        c = {"k": "setBlackout", "instrument": r.nat(), "client": r.blob(), "until": r.nat(), "reason": r.text()}
    elif tag == 24:
        c = {"k": "liftBlackout", "blackout": r.nat()}
    elif tag == 25:
        c = {"k": "borrow", "account": r.nat(), "member": r.nat(), "instrument": r.nat(), "qty": r.nat(), "reference": r.blob()}
    elif tag == 26:
        c = {"k": "returnBorrow", "account": r.nat(), "member": r.nat(), "instrument": r.nat(), "qty": r.nat()}
    elif tag == 27:
        c = {"k": "setClearing", "ccp": r.nat(), "ccpMember": r.nat(), "cash": principal_text(r.principal()), "secs": r.nat(), "days": r.nat(), "penalty": r.nat(),
             "deadline": r.nat(), "fundBps": r.nat(), "floor": r.nat()}
    elif tag == 28:
        c = {"k": "setMargin", "instrument": r.nat(), "bps": r.nat()}
    elif tag == 29:
        c = {"k": "admitClearing", "member": r.nat(), "settle": r.nat(), "credit": r.nat()}
    elif tag == 30:
        c = {"k": "designateClearing", "account": r.nat(), "member": r.nat()}
    elif tag in (31, 32, 37):
        c = {"k": {31: "postCollateral", 32: "withdrawCollateral", 37: "contributeFund"}[tag], "member": r.nat(), "amount": r.nat()}
    elif tag == 33:
        c = {"k": "cutCycle", "cycle": r.nat(), "settleDay": r.nat()}
    elif tag == 34:
        c = {"k": "settleCycle", "cycle": r.nat()}
    elif tag == 35:
        c = {"k": "closeOut", "member": r.nat(), "instrument": r.nat()}
    elif tag == 36:
        c = {"k": "callFund"}
    elif tag == 38:
        c = {"k": "fundSkin", "account": r.nat(), "amount": r.nat()}
    elif tag == 39:
        c = {"k": "declareDefault", "member": r.nat(), "reason": r.text()}
    elif tag == 40:
        c = {"k": "closeDefault", "member": r.nat()}
    elif tag == 41:
        c = {"k": "setFeeSchedule", "instrument": r.nat(), "levies": [(r.nat(), r.nat()) for _ in range(r.len16())]}
    elif tag in (42, 47):
        c = {"k": "sealStatements" if tag == 42 else "settleMakers", "day": r.nat()}
    elif tag == 43:
        c = {"k": "reconcileMember", "member": r.nat(), "day": r.nat(), "balances": [(r.nat(), principal_text(r.principal()), r.nat()) for _ in range(r.len16())]}
    elif tag == 44:
        c = {"k": "registerMaker", "member": r.nat(), "instrument": r.nat(), "maxSpread": r.nat(), "minQty": r.nat(), "presence": r.nat(), "rebate": r.nat()}
    elif tag in (45, 46):
        c = {"k": "quote" if tag == 45 else "massQuote", "account": r.nat(), "member": r.nat(), "trader": r.nat()}
        n = 1 if tag == 45 else r.len16()
        c["sides"] = [{"instrument": r.nat(), "bid": r.nat(), "ask": r.nat(), "qty": r.nat(), "ref": r.text()} for _ in range(n)]
    else:
        raise ValueError(f"family tag {tag}")
    assert r.p == len(data), "bytes after the command"
    return c


def read_block(raw):
    """A stored block: its fields, its event, the hash recomputed over its preimage and the stored one."""
    r = Reader(raw)
    version = r.byte()
    assert version == 1, f"log codec version {version}"
    index, ts, caller, parent = r.nat(), r.nat64(), r.principal(), r.opt(r.blob)
    tag = r.byte()
    if tag == 1:
        ev = {"t": "proposed", "permission": r.text(), "partition": r.opt(r.text), "maker": r.principal(), "required": r.nat(),
              "role": r.text(), "expiresAt": r.nat64(), "justification": r.text(), "commandHash": r.blob(), "encoding": r.byte()}
    elif tag == 2:
        ev = {"t": "approved", "proposal": r.nat(), "checker": r.principal(), "commandHash": r.blob()}
    elif tag == 3:
        ev = {"t": "rejected", "proposal": r.nat(), "checker": r.principal(), "reason": r.text()}
    elif tag == 4:
        ev = {"t": "expired", "proposal": r.nat()}
    elif tag == 5:
        ev = {"t": "executed", "proposal": r.opt(r.nat), "version": r.byte(), "command": read_command(r.blob()), "effects": r.nats()}
    else:
        raise ValueError(f"event tag {tag}")
    pre = r.p
    stored = r.take(32)
    return {"index": index, "time": ts, "caller": principal_text(caller), "parent": parent, "event": ev, "hash": stored,
            "recomputed": hash_with_domain(LOG_DOMAIN, raw[:pre])}


class Book(Ref):
    """The reference book refolded from executed commands alone: no facts about members, accounts or grants (a log
    holds only what executed); instruments come from their opening commands; balances are keyed by ledger principal."""

    def __init__(self):
        super().__init__({"instruments": {}, "accounts": {}, "owns": {}, "may": {}, "grants": {}, "offset": 0, "xinstruments": {}, "xbands": None})
        self.reflist = []

    def ledger_bytes(self, led):
        return principal_raw(led)

    def apply(self, now, c):
        if c["k"] == "openInstrument":
            self.inst[c["instrument"]] = {"lot": c["lot"], "ref": c["price"], "collar": c["collar"], "bands": c["bands"], "asset": c["asset"],
                                          "cash": c["cash"], "phase": "closed", "last": 0, "close": 0, "endFrom": 0, "endTo": 0, "until": 0,
                                          "static": c["static"], "dynamic": c["dynamic"], "secs": c["secs"], "opened": True}
            return [1, c["instrument"]]
        if c["k"] in ("deposit", "borrow"):
            self.reflist.append(c["reference"])
            c = dict(c, reference=c["reference"].hex())
        if c["k"] == "setBlackout":
            c = dict(c, client=c["client"].hex())
        if c["k"] == "clear":
            return self.clear(c["time"])
        return super().apply(now, c)


# ── the rows as the book stores them (book/src/BookCore.mo) and the fold's fingerprint (kernel Fold.mo) ──
def be(n, w):
    return n.to_bytes(w, "big")


def principal_field(text):
    raw = principal_raw(text)
    return bytes([len(raw)]) + raw + b"\x00" * (29 - len(raw))


def order_row(o):
    b = (be(o["account"], 8) + be(o["instrument"], 8) + bytes([1 if o["side"] == "buy" else 2, {v: k for k, v in KIND.items()}[o["kind"]]])
         + be(o["qty"], 8) + be(o["remaining"], 8) + be(o["price"], 8) + be(o["stop"], 8) + be(o["peak"], 8)
         + bytes([{v: k for k, v in VALIDITY.items()}[o["validity"]]]) + be(o["gtd"], 4)
         + bytes([{v: k for k, v in SMP.items()}[o["smp"]], {v: k for k, v in CAPACITY.items()}[o["capacity"]], 1 if o["short"] else 0])
         + o["ref"].encode().ljust(20, b"\x00") + be(o["oco"], 8) + be(o["prio"], 8) + o["key"] + bytes([STATUS[o["status"]]])
         + be(o["held"], 8) + be(o["filled"], 8) + be(o["trail"], 8) + be(o["member"], 8) + be(o["trader"], 8))
    assert len(b) == 175
    return b + b"\x00" * (176 - len(b))


def balance_row(account, ledger, available, held):
    b = be(account, 8) + principal_field(ledger) + be(available, 8) + be(held, 8)
    return b + b"\x00" * (64 - len(b))


def instrument_row(i):
    b = principal_field(i["asset"]) + principal_field(i["cash"]) + be(i["lot"], 8) + be(i["ref"], 8) + bytes([len(i["bands"])])
    for k in range(16):
        f, t = i["bands"][k] if k < len(i["bands"]) else (0, 0)
        b += be(f, 8) + be(t, 8)
    b += be(i["collar"], 4) + bytes([PHASE_CODE[i["phase"]]]) + be(i["last"], 8)
    b += be(i["static"], 4) + be(i["dynamic"], 4) + be(i["secs"], 4) + be(i["endFrom"], 8) + be(i["endTo"], 8) + be(i["until"], 8) + be(i["close"], 8)
    assert len(b) == 390
    return b + b"\x00" * (400 - len(b))


def proposal_row(p):
    tag, at = {"awaiting": (0, 0), "executed": (1, p.get("at", 0)), "rejected": (2, p.get("at", 0)), "expired": (3, p.get("at", 0))}[p["status"]]
    b = bytes([tag]) + be(at, 8) + be(p["expiresAt"], 8) + bytes([len(p["approvals"])])
    for k in range(8):
        b += be(p["approvals"][k] if k < len(p["approvals"]) else 0, 8)
    assert len(b) == 82
    return b


def concerned(block, order_member, kill_member):
    """SPEC §14: the members a block concerns, each with whether it is the member's own act, in member order."""
    out = {}
    ev = block["event"]
    if ev["t"] != "executed":
        return []
    c, e, k = ev["command"], ev["effects"], ev["command"]["k"]

    def own(m):
        if m:
            out[m] = True

    def touched(oid):
        m = order_member.get(oid)
        if m is not None and m not in out:
            out[m] = False
    def mentioned(m):
        if m and m not in out:
            out[m] = False
    if k in ("placeOrder", "deposit", "withdraw", "massCancel", "kill", "setLimits", "borrow", "returnBorrow", "admitClearing", "designateClearing",
             "postCollateral", "withdrawCollateral", "contributeFund", "declareDefault", "closeOut"):
        own(c["member"])
    elif k == "closeDefault":
        own(c["member"])
        for j in range(e[7]):
            mentioned(e[8 + 2 * j])
    elif k in ("reconcileMember", "registerMaker"):
        own(c["member"])
    elif k in ("quote", "massQuote"):
        own(c["member"]); p = 2
        for _ in range(e[1]):
            nc = e[p + 1]
            for oid in e[p + 2:p + 2 + nc]:
                touched(oid)
            p += 2 + nc + 8
    elif k == "sealStatements":
        for j in range(e[2]):
            mentioned(e[3 + 2 * j])
    elif k == "settleMakers":
        for j in range(e[2]):
            mentioned(e[3 + 6 * j])
    elif k == "callFund":
        for j in range(e[1]):
            mentioned(e[2 + 2 * j])
    elif k == "settleCycle":
        n = e[2]
        for j in range(n):
            mentioned(e[3 + 3 * j])
        for j in range(e[3 + 3 * n]):
            mentioned(e[4 + 3 * n + 3 * j])
    elif k in ("cancelOrder", "amendOrder"):
        own(order_member.get(c["order"], 0))
    elif k in ("revive", "killSweep"):
        own(kill_member.get(c["kill"], 0))
    elif k in ("endOfDay", "expireGtd"):
        for oid in e[2:2 + e[1]]:
            touched(oid)
    elif k == "clear":
        i = 1
        while i < len(e):
            np_ = e[i + 3]; p = i + 4
            for _ in range(np_):
                touched(e[p]); touched(e[p + 1]); p += 3
            nc = e[p]
            for oid in e[p + 1:p + 1 + nc]:
                touched(oid)
            p += 1 + nc; nt = e[p]
            for j in range(nt):
                touched(e[p + 1 + 4 * j])
            p += 1 + 4 * nt; ns = e[p]
            for j in range(ns):
                touched(e[p + 1 + 2 * j])
            i = p + 1 + 2 * ns + 1
    elif k == "uncross":
        np_ = e[4]; p = 5
        for _ in range(np_):
            touched(e[p]); touched(e[p + 1]); p += 3
        nc = e[p]
        for oid in e[p + 1:p + 1 + nc]:
            touched(oid)
        p += 1 + nc; ns = e[p]
        for j in range(ns):
            touched(e[p + 1 + 2 * j])
    return sorted(out.items())


def fingerprint(book, proposals, n_blocks, tip, feed_next, feed_head, drops):
    w = Writer()
    w.text("orders"); w.nat(len(book.orders) + 1)
    for oid in sorted(book.orders):
        w.nat(oid); w.blob(order_row(book.orders[oid]))
    w.text("balances"); w.nat(len(book.bal) + 1)
    for k, ((account, ledger), (avail, held)) in enumerate(book.bal.items(), start=1):
        w.nat(k); w.blob(balance_row(account, ledger, avail, held))
    w.text("depositrefs"); w.nat(len(book.reflist) + 1)
    for k, ref in enumerate(book.reflist, start=1):
        w.nat(k); w.blob(ref)
    w.text("instruments")
    for i in sorted(book.inst):
        w.nat(i); w.blob(instrument_row(book.inst[i]))
    w.text("due")
    for i in sorted(book.due):
        w.nat(i)
    w.text("batch"); w.nat64(book.batch)
    w.text("proposals")
    for i in sorted(proposals):
        w.nat(i); w.blob(proposal_row(proposals[i]))
    w.text("kills"); w.nat(len(book.kills) + 1)
    for kid in sorted(book.kills):
        k = book.kills[kid]
        w.nat(kid); w.blob(be(k["member"], 8) + be(k["trader"], 8) + bytes([1 if k["active"] else 0]) + b"\x00" * 7)
    w.text("limits"); w.nat(len(book.limits) + 1)
    for n, (member, (q, v, c)) in enumerate(book.limits.items(), start=1):
        w.nat(n); w.blob(be(member, 8) + be(q, 8) + be(v, 8) + be(c, 8) + be(book.used(member), 8))
    w.text("feed"); w.nat(feed_next); w.b += feed_head
    w.text("drops"); w.nat(len(drops) + 1)
    for n, (member, block, own_) in enumerate(drops, start=1):
        w.nat(n); w.blob(be(member, 8) + be(block, 8) + bytes([1 if own_ else 0]))
    # the day's statistics (§15): the session's by instrument, the sealed days' rows, the seals
    w.text("stats")
    for i in sorted(book.stats):
        w.nat(i); w.blob(b"".join(be(v, 8) for v in book.stats[i]))
    w.text("days"); w.nat(len(book.days) + 1)
    for n, (day, inst, st, ref) in enumerate(book.days, start=1):
        w.nat(n); w.blob(be(day, 8) + be(inst, 8) + b"".join(be(v, 8) for v in st) + be(ref, 8))
    w.text("seals"); w.nat(len(book.seals) + 1)
    for n, (day, rows, h) in enumerate(book.seals, start=1):
        w.nat(n); w.blob(be(day, 8) + be(rows, 8) + h)
    # insider blackouts and securities loans (§16, §17)
    w.text("blackouts"); w.nat(len(book.blackouts) + 1)
    for bid in sorted(book.blackouts):
        b = book.blackouts[bid]
        w.nat(bid); w.blob(be(b["instrument"], 8) + bytes.fromhex(b["client"]) + be(b["until"], 8) + bytes([1 if b["active"] else 0]))
    w.text("borrows"); w.nat(len(book.borrows) + 1)
    for n, ((account, inst), owed) in enumerate(book.borrows.items(), start=1):
        w.nat(n); w.blob(be(account, 8) + be(inst, 8) + be(owed, 8))
    clearing_sections(w, book)
    w.text("log"); w.nat(n_blocks); w.opt_blob(tip)
    return hash_with_domain(FOLD_DOMAIN, bytes(w.b))


def mmr_nodes(leaves):
    """The settlement range's nodes in post-order, built by appending each leaf and the parents it completes."""
    nodes, peaks = [], []   # peaks: (height, hash), the lowest last
    for leaf in leaves:
        h, height = leaf, 0
        nodes.append(h)
        while peaks and peaks[-1][0] == height:
            _, left = peaks.pop()
            h = hashlib.sha256(b"\x01" + left + h).digest(); height += 1
            nodes.append(h)
        peaks.append((height, h))
    return nodes


def clearing_sections(w, book):
    """SPEC §18 to §21: the clearing's rows as the book stores them."""
    t = book.clearing
    w.text("clearing")
    if t:
        terms = (be(t["ccp"], 8) + be(t["ccpMember"], 8) + principal_field(t["cash"])
                 + b"".join(be(t[x], 8) for x in ("secs", "days", "penalty", "deadline", "fundBps", "floor")))
        w.opt_blob(terms)
    else:
        w.opt_blob(None)
    w.nat(book.cycle_no); w.nat(book.settled); w.nat64(book.last_cut); w.nat(book.committed()); w.nat(book.skin)
    w.text("clearingmembers"); w.nat(len(book.cm) + 1)
    for n, (m, r) in enumerate(book.cm.items(), start=1):
        w.nat(n); w.blob(b"".join(be(x, 8) for x in (m, r["settle"], r["credit"], r["coll"], r["fund"], r["req"], book.im_orders(m), r["to"], r["by"],
                                                       r["debt"], r["fails"], r["peak"])) + bytes([r["status"]]))
    w.text("designations"); w.nat(len(book.desig) + 1)
    for n, (a, m) in enumerate(book.desig.items(), start=1):
        w.nat(n); w.blob(be(a, 8) + be(m, 8))
    w.text("ccpcustody"); w.nat(len(book.custody) + 1)
    for n, ((m, i), q) in enumerate(book.custody.items(), start=1):
        w.nat(n); w.blob(be(m, 8) + be(i, 8) + be(q, 8) + be(book.custody_held(m, i), 8))
    w.text("margins")
    for i in sorted(book.margin):
        w.nat(i); w.nat(book.margin[i])
    w.text("closeouts"); w.nat(len(book.closeouts) + 1)
    for n, (o, m) in enumerate(book.closeouts.items(), start=1):
        w.nat(n); w.blob(be(o, 8) + be(m, 8))
    w.text("obligations"); w.nat(len(book.oblig) + 1)
    for n, ((m, cy), (to, by)) in enumerate(book.oblig.items(), start=1):
        w.nat(n); w.blob(be(m, 8) + be(cy, 8) + be(to, 8) + be(by, 8))
    w.text("bought"); w.nat(len(book.bought) + 1)
    for n, ((m, i, cy), q) in enumerate(book.bought.items(), start=1):
        w.nat(n); w.blob(be(m, 8) + be(i, 8) + be(cy, 8) + be(q, 8))
    w.text("cycles"); w.nat(book.cycle_no)
    for cy in sorted(book.cycles):
        cut, sd, done = book.cycles[cy]
        w.nat(cy); w.blob(be(cut, 8) + be(sd, 8) + bytes([1 if done else 0]))
    legs = [bytes([lg[0]]) + principal_field(lg[1]) + be(lg[2], 8) + be(lg[3], 8) + be(lg[4], 8) + be(lg[5] - 1, 8) for lg in book.legs]
    w.text("settlementlegs"); w.nat(len(legs) + 1)
    for n, lb in enumerate(legs, start=1):
        w.nat(n); w.blob(lb)
    nodes = mmr_nodes([hashlib.sha256(b"\x00" + lb).digest() for lb in legs])
    w.text("settlementnodes"); w.nat(len(nodes) + 1)
    for n, x in enumerate(nodes, start=1):
        w.nat(n); w.blob(x)
    markets_sections(w, book)


def markets_sections(w, book):
    """SPEC §22 to §25: fee schedules, levies payable, fee totals, statements, seals, reconciliations, makers."""
    import reference_book as RB
    w.text("fees")
    for i in sorted(book.fees):
        lv = book.fees[i]
        row = bytes([len(lv)]) + b"".join(be(lv[k][0], 8) + be(lv[k][1], 4) if k < len(lv) else bytes(12) for k in range(4))
        w.nat(i); w.blob(row)
    w.nat(book.last_stmt_day); w.nat(book.last_maker_day)
    w.text("levypayable"); w.nat(len(book.payable) + 1)
    for n, (a, x) in enumerate(book.payable.items(), start=1):
        w.nat(n); w.blob(be(a, 8) + be(x, 8))
    w.text("feetotals"); w.nat(len(book.fee_totals) + 1)
    for n, ((m, i), x) in enumerate(book.fee_totals.items(), start=1):
        w.nat(n); w.blob(be(m, 8) + be(i, 8) + be(x, 8))
    blocks = {e: e - 1 for e in range(len(book.log) + 1)}
    w.text("statements"); w.nat(len(book.stmt) + 1)
    for n, (m, lines) in enumerate(book.stmt.items(), start=1):
        w.nat(n); w.blob(be(m, 8) + RB.statement_head(lines, blocks) + be(len(lines), 8))
    w.text("statementseals"); w.nat(len(book.stmt_seals) + 1)
    for n, (m, d, lines) in enumerate(book.stmt_seals, start=1):
        w.nat(n); w.blob(be(m, 8) + be(d, 8) + RB.statement_head(lines, blocks) + be(len(lines), 8))
    w.text("memberrecons"); w.nat(len(book.recons) + 1)
    for n, (m, d, rows, matched, breaks, h) in enumerate(book.recons, start=1):
        w.nat(n); w.blob(be(m, 8) + be(d, 8) + be(rows, 8) + be(matched, 8) + be(breaks, 8) + bytes.fromhex(h))
    w.text("makers"); w.nat(len(book.makers) + 1)
    for n, m in enumerate(book.makers.values(), start=1):
        row = b"".join(be(m[x], 8) for x in ("member", "instrument", "maxSpread", "minQty", "presence", "rebate", "account", "bid", "ask"))
        row += bytes([1 if m["cont"] else 0, 1 if m["present"] else 0]) + be(m["lastAt"], 8) + be(m["presentNs"], 8) + be(m["session"], 8)
        w.nat(n); w.blob(row)
    w.text("makerdays"); w.nat(len(book.maker_days) + 1)
    for n, (m, i, d, pr, se, met, rb) in enumerate(book.maker_days, start=1):
        w.nat(n); w.blob(be(m, 8) + be(i, 8) + be(d, 8) + be(pr, 8) + be(se, 8) + bytes([1 if met else 0]) + be(rb, 8))


def main():
    raw, stated, printed, files_given = {}, None, [], {}
    pending = None
    for line in open(sys.argv[1], encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("+|") and pending is not None:
            raw[pending] += line[2:]
        elif line.startswith("L|"):
            _, idx, hx = line.split("|")
            pending = int(idx); raw[pending] = hx
        else:
            pending = None
            if line.startswith("fingerprint|book|"):
                stated = line.split("|")[2]
            elif line.startswith("Y|"):
                _, d, hx = line.split("|")
                files_given[int(d)] = bytes.fromhex(hx)
            elif line.startswith("D|"):
                _, m, blk, own_, h = line.split("|")
                printed.append((int(m), int(blk), own_ == "1", h))
    errors = []
    if not raw or stated is None:
        print("MISS: no log or no stated fingerprint"); return 1
    book, proposals = Book(), {}
    prev, executed, clears, pairs = None, 0, 0, 0
    feed_head, feed_next = FP.GENESIS, 0
    drops, order_member, kill_member, entry_hash = [], {}, {}, {}
    for i in range(max(raw) + 1):
        if i not in raw:
            errors.append(f"block {i} is missing from the log"); break
        try:
            b = read_block(bytes.fromhex(raw[i]))
        except (ValueError, AssertionError, IndexError, KeyError, UnicodeDecodeError) as e:
            errors.append(f"block {i} does not decode: {str(e)[:60]}"); break
        if b["index"] != i:
            errors.append(f"block {i} carries index {b['index']}")
        if b["recomputed"] != b["hash"]:
            errors.append(f"block {i}: its hash is not the hash of its bytes")
        if b["parent"] != prev:
            errors.append(f"block {i}: does not link to the block below")
        prev = b["hash"]
        # the public feed (SPEC §13): this block's message, written from the block, chained
        msg = FP.message(b)
        feed_head = FP.chain(feed_head, msg); feed_next += 1
        book.log.append((b["time"], "block", []))
        ev = b["event"]
        if ev["t"] == "proposed":
            proposals[i] = {"status": "awaiting", "expiresAt": ev["expiresAt"], "approvals": []}
        elif ev["t"] == "approved":
            proposals[ev["proposal"]]["approvals"].append(i)
        elif ev["t"] in ("rejected", "expired"):
            proposals[ev["proposal"]].update(status=ev["t"], at=i)
        else:
            c = ev["command"]
            got = book.apply_all(b["time"], c)
            executed += 1
            if got != ev["effects"]:
                errors.append(f"block {i} ({c['k']}): recorded effects {ev['effects'][:12]}, refolded {got[:12]}")
            if c["k"] == "clear":
                clears += 1
                k = 1
                while k < len(got):
                    np = got[k + 3]; pairs += np
                    at = k + 4 + 3 * np; nc = got[at]
                    tp = at + 1 + nc; nt = got[tp]              # triggered: (order, side, price, shown) each
                    sp = tp + 1 + 4 * nt; ns = got[sp]          # icebergs traded: (order, shown) each
                    k = sp + 1 + 2 * ns + 1                     # the interruption flag closes each instrument's entry
            if ev["proposal"] is not None:
                proposals[ev["proposal"]].update(status="executed", at=i)
            if c["k"] == "placeOrder":
                order_member[ev["effects"][1]] = c["member"]
            if c["k"] == "kill":
                kill_member[ev["effects"][1]] = c["member"]
            if c["k"] == "closeOut":
                order_member[ev["effects"][1]] = book.clearing["ccpMember"]
            if c["k"] in ("quote", "massQuote"):
                p = 2
                for _ in range(got[1]):
                    nc = got[p + 1]; p += 2 + nc
                    order_member[got[p]] = c["member"]; order_member[got[p + 4]] = c["member"]; p += 8
            if c["k"] == "declareDefault" and ev["effects"][2]:
                kill_member[ev["effects"][2]] = c["member"]
        # the drop copy (SPEC §14): the members this block concerns, and what each is given
        for member, own_ in concerned(b, order_member, kill_member):
            drops.append((member, i, own_))
            entry_hash[(member, i)] = hashlib.sha256(bytes.fromhex(raw[i]) if own_ else msg).hexdigest()
    if errors:
        for e in errors[:10]:
            print("  DISAGREES:", e)
        return 1
    # the drop copy as the book gave it, page by page, against the drop copy computed from the log alone
    if printed:
        members = sorted({m for m, _, _ in drops} | {p[0] for p in printed})
        for m in members:
            want = [(blk, own_, entry_hash[(m, blk)]) for mm, blk, own_ in drops if mm == m]
            got = [(blk, own_, h) for mm, blk, own_, h in printed if mm == m]
            if got != want:
                first = next((k for k in range(min(len(got), len(want))) if got[k] != want[k]), min(len(got), len(want)))
                errors.append(f"member {m}'s drop copy: {len(got)} entries given, {len(want)} in the log; first difference at entry {first}: "
                              f"given {got[first] if first < len(got) else None}, the log {want[first] if first < len(want) else None}")
        if errors:
            for e in errors[:10]:
                print("  DISAGREES:", e)
            return 1
        print(f"regulator: the drop copies of {len(members)} members, {len(printed)} entries, each the member's blocks in the log and nothing else: VERIFIED")
    # the day's files (§15) as the book gave them, against the files rebuilt here from the log alone
    for d, f in sorted(files_given.items()):
        if book.files.get(d) != f:
            print(f"  DISAGREES: day {d}: the book's file is not the file rebuilt from the log"); return 1
    if files_given:
        print(f"regulator: {len(files_given)} days' files rebuilt from the log alone, byte for byte the book's: VERIFIED")
    # the visible book at the log's end, as the replay rebuilt it (§13), in the encoding the feed's consumer digests
    vw = bytearray(len(b"thebes.book.visible.v1").to_bytes(2, "big") + b"thebes.book.visible.v1")

    def vnat(n):
        if n == 0:
            vw.append(0)
        else:
            bs = n.to_bytes((n.bit_length() + 7) // 8, "big"); vw.append(len(bs)); vw.extend(bs)
    for inst in sorted(book.inst):
        live = sorted((oid, o) for oid, o in book.orders.items() if o["instrument"] == inst and o["status"] == "live")
        vnat(inst); vw.append(PHASE_CODE[book.inst[inst]["phase"]]); vw.extend(len(live).to_bytes(2, "big"))
        for oid, o in live:
            vnat(oid); vw.append(1 if o["side"] == "buy" else 2); vnat(o["price"]); vnat(book.shown(o))
    print(f"regulator: the visible book at block {len(raw) - 1}: {hashlib.sha256(bytes(vw)).hexdigest()}")
    fp = fingerprint(book, proposals, len(raw), prev, feed_next, feed_head, drops).hex()
    print(f"regulator: {len(raw)} blocks chained and hashed, {executed} executions refolded with their effects, {clears} clears, {pairs} pairs")
    if fp != stated:
        errors.append(f"the fingerprint of the refolded book {fp[:16]} is not the book's {stated[:16]}")
    if errors:
        for e in errors[:10]:
            print("  DISAGREES:", e)
        return 1
    print(f"regulator: the refolded book's fingerprint is the book's ({fp[:16]}): VERIFIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
