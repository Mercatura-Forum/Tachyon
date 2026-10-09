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
        c = {"k": "deposit", "account": r.nat(), "ledger": principal_text(r.principal()), "amount": r.nat(), "reference": r.blob()}
    elif tag == 5:
        c = {"k": "withdraw", "account": r.nat(), "ledger": principal_text(r.principal()), "amount": r.nat()}
    elif tag == 6:
        c = {"k": "placeOrder", "account": r.nat(), "instrument": r.nat(), "side": SIDE[r.byte()], "kind": KIND[r.byte()], "qty": r.nat(), "price": r.nat(),
             "stop": r.nat(), "peak": r.nat(), "validity": VALIDITY[r.byte()], "gtd": r.nat(), "smp": SMP[r.byte()], "capacity": CAPACITY[r.byte()],
             "short": 1 if r.boolean() else 0, "ref": r.text(), "oco": r.nat(), "trail": r.nat(), "member": r.nat(), "trader": r.nat()}
    elif tag == 7:
        c = {"k": "cancelOrder", "order": r.nat()}
    elif tag == 8:
        c = {"k": "amendOrder", "order": r.nat(), "qty": r.nat(), "price": r.nat()}
    elif tag == 9:
        c = {"k": "massCancel", "account": r.nat(), "limit": r.nat()}
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

    def apply(self, now, c):
        if c["k"] == "openInstrument":
            self.inst[c["instrument"]] = {"lot": c["lot"], "ref": c["price"], "collar": c["collar"], "bands": c["bands"], "asset": c["asset"],
                                          "cash": c["cash"], "phase": "closed", "last": 0, "close": 0, "endFrom": 0, "endTo": 0, "until": 0,
                                          "static": c["static"], "dynamic": c["dynamic"], "secs": c["secs"], "opened": True}
            return [1, c["instrument"]]
        if c["k"] == "deposit":
            self.reflist.append(c["reference"])
            c = dict(c, reference=c["reference"].hex())
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


def fingerprint(book, proposals, n_blocks, tip):
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
    w.text("log"); w.nat(n_blocks); w.opt_blob(tip)
    return hash_with_domain(FOLD_DOMAIN, bytes(w.b))


def main():
    raw, stated = {}, None
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
    errors = []
    if not raw or stated is None:
        print("MISS: no log or no stated fingerprint"); return 1
    book, proposals = Book(), {}
    prev, executed, clears, pairs = None, 0, 0, 0
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
            got = book.apply(b["time"], c)
            executed += 1
            if got != ev["effects"]:
                errors.append(f"block {i} ({c['k']}): recorded effects {ev['effects'][:12]}, refolded {got[:12]}")
            if c["k"] == "clear":
                clears += 1
                k = 1
                while k < len(got):
                    np = got[k + 3]; pairs += np
                    at = k + 4 + 3 * np; nc = got[at]; nt = got[at + 1 + nc]
                    k = at + 3 + nc + nt   # the interruption flag closes each instrument's entry
            if ev["proposal"] is not None:
                proposals[ev["proposal"]].update(status="executed", at=i)
    if errors:
        for e in errors[:10]:
            print("  DISAGREES:", e)
        return 1
    fp = fingerprint(book, proposals, len(raw), prev).hex()
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
