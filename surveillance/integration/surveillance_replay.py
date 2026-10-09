#!/usr/bin/env python3
"""surveillance_replay.py: the surveillance desk's rules (surveillance/SPEC.md) written again, applied to the book's log
alone. For every desk the battery printed (`SV|` sections), it decodes the book's blocks the desk read (`L|` lines, the
regulator's decoder), folds them into its own projections, raises its own alerts and builds its own report chain, and
requires every alert (rule, block, instrument, owners, evidence), the chain's lines and its hash equal to the desk's.

    python3 surveillance/integration/surveillance_replay.py <battery log>

It reads the facts the battery states (`H|account` with each account's client code, `H|trader` with each trader's
principal) and the desk's thresholds (`SP|`); nothing the desk computed.

Attribution: Thebes Core Team.
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "book", "integration"))
from regulator_replay import read_block  # noqa: E402

DOMAIN = "thebes.surveillance.report.v1"
SEC = 1_000_000_000


def be(n, w):
    return n.to_bytes(w, "big")


def text_bytes(t):
    e = t.encode()
    return len(e).to_bytes(2, "big") + e


def nat(n):
    if n == 0:
        return b"\x00"
    bs = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([len(bs)]) + bs


class Desk:
    def __init__(self, params, accounts, traders):
        (self.paint_count, self.paint_secs, self.stuff_count, self.stuff_secs, self.spoof_qty, self.spoof_secs,
         self.mark_share, self.mark_bps, self.position_level) = params
        self.accounts, self.traders = accounts, traders
        self.orders, self.windows, self.spoof, self.pos, self.inst = {}, {}, {}, {}, {}
        self.alerts, self.head, self.lines = [], bytes(32), 0

    def owner(self, account, member):
        c = self.accounts.get(account, "")
        return bytes.fromhex(c) if len(c) == 64 else b"\x01" + be(member, 8)

    def raise_(self, rule, block, inst, owner, other, e):
        self.alerts.append((rule, block, inst, owner.hex(), other.hex(), *e))

    def window(self, key, t, block, secs):
        w = self.windows.get(key)
        if w is None or w["count"] == 0 or t - w["start"] > secs * SEC:
            w = {"start": t, "startBlock": block, "count": 1}
        else:
            w["count"] += 1
        self.windows[key] = w
        return w

    def spoof_row(self, owner, inst, t):
        r = self.spoof.get((owner, inst))
        if r is None or t - r["start"] > self.spoof_secs * SEC:
            r = {"start": t, "cb": 0, "cs": 0, "tb": 0, "ts": 0, "alerted": False}
            self.spoof[(owner, inst)] = r
        return r

    def spoof_check(self, owner, inst, r, block):
        q = self.spoof_qty
        if not r["alerted"] and ((r["cb"] >= q and r["ts"] > 0) or (r["cs"] >= q and r["tb"] > 0)):
            buy = r["cb"] >= q and r["ts"] > 0
            self.raise_(4, block, inst, owner, b"", (1 if buy else 2, r["cb"] if buy else r["cs"], r["ts"] if buy else r["tb"], 0))
            r["alerted"] = True

    def owner_cancel(self, oid, t, block):
        o = self.orders.get(oid)
        if o is None or o["filled"] != 0 or t - o["placedAt"] > self.spoof_secs * SEC:
            return
        r = self.spoof_row(o["owner"], o["instrument"], t)
        r["cb" if o["side"] == 1 else "cs"] += o["qty"]
        self.spoof_check(o["owner"], o["instrument"], r, block)

    def line(self, data):
        self.head = hashlib.sha256(text_bytes(DOMAIN) + self.head + data).digest(); self.lines += 1

    def position(self, owner, inst, bought, sold, block):
        r = self.pos.setdefault((owner, inst), {"bought": 0, "sold": 0, "reported": False})
        r["bought"] += bought; r["sold"] += sold
        long_ = r["bought"] >= r["sold"]
        net = abs(r["bought"] - r["sold"])
        if not r["reported"] and net >= self.position_level:
            self.line(b"\x02" + nat(block) + len(owner).to_bytes(2, "big") + owner + nat(inst) + bytes([1 if long_ else 2]) + nat(net))
            r["reported"] = True

    def pair(self, block, t, inst, b, a, q, p):
        ob, oa = self.orders[b], self.orders[a]
        if ob["owner"] == oa["owner"]:
            self.raise_(1, block, inst, ob["owner"], b"", (b, a, q, p))
        else:
            lo, hi = sorted((ob["owner"], oa["owner"]))
            w = self.window(("paint", lo, hi), t, block, self.paint_secs)
            if w["count"] == self.paint_count:
                self.raise_(2, block, inst, lo, hi, (w["startBlock"], w["count"], 0, 0))
        rb = self.spoof_row(ob["owner"], inst, t); rb["tb"] += q; self.spoof_check(ob["owner"], inst, rb, block)
        ra = self.spoof_row(oa["owner"], inst, t); ra["ts"] += q; self.spoof_check(oa["owner"], inst, ra, block)
        ob["filled"] += q; oa["filled"] += q
        self.line(b"\x01" + b"".join(nat(x) for x in (block, inst, b, a, q, p, ob["member"], oa["member"], ob["account"], oa["account"])) + bytes([1 if oa["short"] else 0]))
        self.position(ob["owner"], inst, q, 0, block)
        self.position(oa["owner"], inst, 0, q, block)

    def stuff(self, caller, t, block):
        tid = self.traders.get(caller)
        if tid is None:
            return
        ident = b"\x02" + be(tid, 8)
        w = self.window(("stuff", ident), t, block, self.stuff_secs)
        if w["count"] == self.stuff_count:
            self.raise_(3, block, 0, ident, b"", (w["startBlock"], w["count"], 0, 0))

    def mark(self, block, inst, price, volume, pairs, last):
        if price == 0 or volume == 0 or last == 0:
            return
        bought, sold = {}, {}
        for b, a, q in pairs:
            bought[self.orders[b]["owner"]] = bought.get(self.orders[b]["owner"], 0) + q
            sold[self.orders[a]["owner"]] = sold.get(self.orders[a]["owner"], 0) + q
        best = None
        for m in (bought, sold):
            for o in sorted(m):
                if best is None or m[o] > best[1] or (m[o] == best[1] and o < best[0]):
                    best = (o, m[o])
        owner, q = best
        if q * 100 >= self.mark_share * volume and abs(price - last) * 10_000 >= self.mark_bps * last:
            self.raise_(5, block, inst, owner, b"", (price, last, q, volume))

    def read(self, blk):
        ev = blk["event"]
        if ev["t"] != "executed":
            return
        c, e, t, i, k = ev["command"], ev["effects"], blk["time"], blk["index"], ev["command"]["k"]
        st = lambda n: self.inst.setdefault(n, {"phase": 1, "last": 0})  # noqa: E731
        if k == "openInstrument":
            self.inst[c["instrument"]] = {"phase": 1, "last": 0}
        elif k == "setTrading":
            st(c["instrument"])["phase"] = 2 if c["open"] else 1
        elif k == "setPhase":
            st(c["instrument"])["phase"] = {"closed": 1, "continuous": 2, "auction": 3, "closingAuction": 4, "tradeAtClose": 5, "halted": 6}[c["phase"]]
        elif k == "halt":
            st(c["instrument"])["phase"] = 6
        elif k == "resume":
            st(c["instrument"])["phase"] = 3
        elif k == "placeOrder":
            self.orders[e[1]] = {"account": c["account"], "member": c["member"], "owner": self.owner(c["account"], c["member"]), "side": 1 if c["side"] == "buy" else 2,
                                 "instrument": c["instrument"], "qty": c["qty"], "short": bool(c["short"]), "placedAt": t, "filled": 0}
            self.stuff(blk["caller"], t, i)
        elif k == "cancelOrder":
            self.owner_cancel(c["order"], t, i); self.stuff(blk["caller"], t, i)
        elif k == "amendOrder":
            if c["order"] in self.orders:
                self.orders[c["order"]]["qty"] = self.orders[c["order"]]["filled"] + c["qty"]
            self.stuff(blk["caller"], t, i)
        elif k == "massCancel":
            for oid in e[2:2 + e[1]]:
                self.owner_cancel(oid, t, i)
            self.stuff(blk["caller"], t, i)
        elif k == "clear":
            j = 1
            while j < len(e):
                inst, price, np_ = e[j], e[j + 1], e[j + 3]
                before = dict(st(inst)); p = j + 4
                for _ in range(np_):
                    self.pair(i, t, inst, e[p], e[p + 1], e[p + 2], price); p += 3
                p += 1 + e[p]; p += 1 + 4 * e[p]; p += 1 + 2 * e[p]
                r = st(inst)
                if e[p] == 1:
                    r["phase"] = 3
                if before["phase"] == 2 and price > 0:
                    r["last"] = price
                j = p + 1
        elif k == "uncross":
            inst, price, volume, np_ = c["instrument"], e[2], e[3], e[4]
            before = dict(st(inst)); p = 5; prs = []
            for _ in range(np_):
                self.pair(i, t, inst, e[p], e[p + 1], e[p + 2], price); prs.append((e[p], e[p + 1], e[p + 2])); p += 3
            if before["phase"] == 4:
                self.mark(i, inst, price, volume, prs, before["last"])
            st(inst)["phase"] = e[-1]


def main():
    accounts, traders, sections, cur = {}, {}, [], None
    pending = None
    for l in open(sys.argv[1], encoding="utf-8"):
        l = l.rstrip("\n")
        if l.startswith("+|") and pending is not None:
            cur["raw"][pending] += l[2:]; continue
        pending = None
        f = l.split("|")
        if l.startswith("H|account|"):
            accounts[int(f[2])] = f[5] if len(f) > 5 else ""
        elif l.startswith("H|trader|") and len(f) > 6:
            traders[f[6]] = int(f[2])
        elif l.startswith("SV|"):
            cur = {"tag": f[1], "raw": {}, "alerts": [], "params": None}; sections.append(cur)
        elif cur is not None and l.startswith("SP|"):
            cur["params"] = tuple(int(x) for x in f[1:10])
        elif cur is not None and l.startswith("L|"):
            pending = int(f[1]); cur["raw"][pending] = f[2]
        elif cur is not None and l.startswith("SA|"):
            cur["alerts"].append((int(f[2]), int(f[3]), int(f[4]), f[5], f[6], int(f[7]), int(f[8]), int(f[9]), int(f[10])))
        elif cur is not None and l.startswith("SC|"):
            cur["cursor"], cur["lines"], cur["head"] = int(f[1]), int(f[2]), f[3]
        elif l.startswith("SR|") and sections:
            sections[0]["sealed"] = (int(f[2]), f[3])
    errors, alerts, lines = [], 0, 0
    for sec in sections:
        d = Desk(sec["params"], accounts, traders)
        missing = [i for i in range(sec["cursor"]) if i not in sec["raw"]]
        if missing:
            errors.append(f"{sec['tag']}: block {missing[0]} of the book's log the desk read is not in the log given"); continue
        for i in range(sec["cursor"]):
            d.read(read_block(bytes.fromhex(sec["raw"][i])))
        if d.alerts != sec["alerts"]:
            first = next((k for k in range(min(len(d.alerts), len(sec["alerts"]))) if d.alerts[k] != sec["alerts"][k]), min(len(d.alerts), len(sec["alerts"])))
            errors.append(f"{sec['tag']}: {len(sec['alerts'])} alerts from the desk, {len(d.alerts)} here; first difference at {first}: "
                          f"desk {sec['alerts'][first] if first < len(sec['alerts']) else None}, here {d.alerts[first] if first < len(d.alerts) else None}")
        if "sealed" in sec:
            if sec["sealed"] != (d.lines, d.head.hex()) or sec["lines"] != 0:
                errors.append(f"{sec['tag']}: the sealed report {sec['sealed']}, here {(d.lines, d.head.hex())}")
        elif (sec["lines"], sec["head"]) != (d.lines, d.head.hex()):
            errors.append(f"{sec['tag']}: the report's chain {(sec['lines'], sec['head'])}, here {(d.lines, d.head.hex())}")
        alerts += len(d.alerts); lines += d.lines
    print(f"surveillance: {len(sections)} desks, {alerts} alerts and {lines} report lines raised again from the book's logs alone")
    if errors or not sections:
        for e in errors[:10]:
            print("  DISAGREES:", e)
        return 1
    print("surveillance: every alert, its evidence and every report's hash the desk's: VERIFIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
