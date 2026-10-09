#!/usr/bin/env python3
"""reference_book.py: the book of book/SPEC.md written again in Python, from the text, and compared with the Motoko book.

    python3 book/integration/reference_book.py <battery log>

The battery (`book/test/Book.test.mo`) prints the facts it set up (who owns which account, who may trade what, the
instruments as the book trades them, the market's UTC offset), then every stream it ran: each command with the chain's
time it was submitted at, the role that submitted it, and the outcome the Motoko book gave; after the stream every
block of the book's log (the clears included) and every order's and every account's final state. This reference
replays every stream from the commands alone and requires: every outcome the same (executed with the same effects, or
refused with the same name), every block of the log the same, every order and every balance the same. It also checks,
on its own state, that funds are conserved per ledger after every command.

Exit 0 and VERIFIED when everything agrees; exit 1 with the first disagreements otherwise.

Attribution: Thebes Core Team.
"""
import hashlib
import sys

MAXP = 2 ** 64 - 1
STATUS = {"waiting": 1, "live": 2, "filled": 3, "cancelled": 4}
IMMEDIATE = {"market", "ioc", "fok", "stop", "trailingStop"}
STOPS = {"stop", "stopLimit", "trailingStop"}
MAX_TRAILING = 64


def nat(n):
    if n == 0:
        return b"\x00"
    bs = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([len(bs)]) + bs


def text(t):
    b = t.encode()
    return len(b).to_bytes(2, "big") + b


def order_key(account, side, price, qty, ref):
    payload = nat(account) + bytes([1 if side == "buy" else 2]) + nat(price) + nat(qty) + text(ref)
    return hashlib.sha256(text("tachyon.book.order-key.v1") + payload).digest()


def tick_at(bands, p):
    t = bands[0][1]
    for (f, k) in bands:
        if f <= p:
            t = k
    return t


def on_tick(bands, p):
    return p > 0 and p % tick_at(bands, p) == 0


def collar(side, ref, c, bands):
    if side == "buy":
        target = ref * (10_000 + c) // 10_000
        return target - target % tick_at(bands, target)
    num = ref * (0 if c >= 10_000 else 10_000 - c)
    target = max(1, -(-num // 10_000))
    t = tick_at(bands, target)
    up = target if target % t == 0 else target + (t - target % t)
    return t if up == 0 else up


class Ref:
    """One book: the state, the log, and the rules, from the specification."""

    def __init__(self, facts):
        self.f = facts
        self.orders = {}      # id -> dict
        self.bal = {}         # (account, ledger) -> [available, held]
        self.refs = set()
        self.inst = {i: dict(v, open=False, last=0, opened=False) for i, v in facts["instruments"].items()}
        self.due = set()
        self.batch = 0
        self.next = 1
        self.log = []         # (time, family, effects)
        self.compared = 0     # the log's blocks compared at the checkpoints so far
        # the open orders (live or waiting), by instrument, by account, by account, instrument and side, and all; an
        # order enters when it opens and leaves lazily once closed (a closed order never opens again). Only where
        # to look changes: every rule below still filters and orders exactly as the specification says.
        self.opens = {}
        self.refs_used = set()
        self.deposited = {}   # ledger -> deposits less withdrawals

    # ── funds ──
    def b(self, a, l):
        return self.bal.setdefault((a, l), [0, 0])

    def hold(self, a, l, x):
        b = self.b(a, l)
        assert b[0] >= x, "hold beyond available"
        b[0] -= x; b[1] += x

    def release(self, a, l, x):
        b = self.b(a, l)
        assert b[1] >= x
        b[0] += x; b[1] -= x

    def ledger(self, i, side):
        return self.inst[i]["cash"] if side == "buy" else self.inst[i]["asset"]

    def close(self, oid, status):
        o = self.orders[oid]
        self.release(o["account"], self.ledger(o["instrument"], o["side"]), o["held"])
        o["held"] = 0; o["status"] = status

    def liveish(self, o):
        return o["status"] in ("live", "waiting")

    def track(self, oid, o):
        for key in (("all",), ("inst", o["instrument"]), ("acct", o["account"]), ("ais", o["account"], o["instrument"], o["side"])):
            self.opens.setdefault(key, set()).add(oid)

    def open_ids(self, *key):
        ids = self.opens.get(key)
        if not ids:
            return ()
        for oid in [x for x in ids if not self.liveish(self.orders[x])]:
            ids.discard(oid)
        return ids

    # ── the market's day ──
    def today(self, now):
        local = now // 1_000_000_000 + self.f["offset"] * 60
        return local // 86_400

    # ── self-trade (§3.5) ──
    def pkey(self, side, price):
        return MAXP - price if side == "buy" else price

    def crossing_own(self, account, inst, side, price):
        other = "sell" if side == "buy" else "buy"
        own = sorted(((self.pkey(other, self.orders[oid]["price"]), oid) for oid in self.open_ids("ais", account, inst, other)
                      if self.orders[oid]["status"] == "live"))
        out = []
        for (_, oid) in own:
            o = self.orders[oid]
            crosses = price >= o["price"] if side == "buy" else price <= o["price"]
            if not crosses:
                break
            out.append(oid)
        return out

    # ── validation, in the Motoko book's order of checks ──
    def own_account(self, role, account):
        acc = self.f["accounts"].get(account)
        if acc is None:
            return "UnknownAccount"
        if not acc["open"]:
            return "AccountClosed"
        if self.f["owns"][(role, account)] != 1:
            return "NotYourAccount"
        return None

    def validate(self, now, role, c):
        k = c["k"]
        if k == "clear":
            return "ClearNotSubmittable"
        if k == "openInstrument":
            i = self.inst.get(c["instrument"])
            if i is not None and i["opened"]:
                return "InstrumentOpenAlready"
            xi = self.f["xinstruments"].get(c["instrument"])
            if xi is None or not xi["listed"]:
                return "UnknownInstrument"
            if xi["asset"] != c["asset"] or xi["cash"] != c["cash"] or xi["lot"] != c["lot"] or self.f["xbands"] != c["bands"]:
                return "InstrumentMismatch"
            if c["collar"] == 0 or c["collar"] >= 10_000:
                return "InvalidTerms"
            bands = [tuple(int(x) for x in b.split(":")) for b in c["bands"].split(",")]
            if not on_tick(bands, c["price"]):
                return "PriceOffTick"
            return None
        if k == "setTrading":
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if i["open"] == c["open"]:
                return "InvalidTerms"
            return None
        if k == "setReference":
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if not on_tick(i["bands"], c["price"]):
                return "PriceOffTick"
            return None
        if k == "deposit":
            if c["account"] not in self.f["accounts"]:
                return "UnknownAccount"
            if c["amount"] == 0:
                return "InvalidTerms"
            if len(c["reference"]) != 64:   # hex of the 32 bytes
                return "InvalidTerms"
            if c["reference"] in self.refs:
                return "DuplicateReference"
            return None
        if k == "withdraw":
            e = self.own_account(role, c["account"])
            if e:
                return e
            if c["amount"] == 0:
                return "InvalidTerms"
            if self.b(c["account"], c["ledger"])[0] < c["amount"]:
                return "InsufficientFunds"
            return None
        if k == "placeOrder":
            e = self.own_account(role, c["account"])
            if e:
                return e
            if self.f["may"][(role, c["instrument"])] != 0:
                return "MayNotTrade"
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if c["qty"] == 0 or c["qty"] % i["lot"] != 0:
                return "NotALot"
            if c["peak"] != 0 and (c["peak"] % i["lot"] != 0 or c["peak"] >= c["qty"]):
                return "NotALot"
            if not (1 <= len(c["ref"].encode()) <= 20):
                return "InvalidTerms"
            if (c["account"], c["ref"]) in self.refs_used:
                return "DuplicateClientRef"
            kind = c["kind"]
            if kind == "market":
                if c["price"] != 0 or c["stop"] != 0:
                    return "InvalidPrice"
            elif kind == "stop":
                if c["price"] != 0:
                    return "InvalidPrice"
                if not on_tick(i["bands"], c["stop"]):
                    return "PriceOffTick"
            elif kind == "trailingStop":
                if c["price"] != 0:
                    return "InvalidPrice"
                if not on_tick(i["bands"], c["stop"]):
                    return "PriceOffTick"
                if c["trail"] == 0 or c["trail"] % tick_at(i["bands"], c["stop"]) != 0:
                    return "InvalidPrice"
            elif kind == "stopLimit":
                if not on_tick(i["bands"], c["price"]):
                    return "PriceOffTick"
                if not on_tick(i["bands"], c["stop"]):
                    return "PriceOffTick"
            else:
                if c["stop"] != 0:
                    return "InvalidPrice"
                if not on_tick(i["bands"], c["price"]):
                    return "PriceOffTick"
            if kind != "trailingStop" and c["trail"] != 0:
                return "InvalidTerms"
            if kind == "trailingStop" and sum(1 for x in self.open_ids("inst", c["instrument"]) if self.orders[x]["status"] == "waiting"
                                              and self.orders[x]["kind"] == "trailingStop" and self.orders[x]["side"] == c["side"]) >= MAX_TRAILING:
                return "TrailingStopsFull"
            if kind in IMMEDIATE and c["validity"] != "day":
                return "InvalidTerms"
            if c["peak"] != 0 and kind != "limit":
                return "InvalidTerms"
            if c["validity"] == "gtd":
                if c["gtd"] < self.today(now):
                    return "NotTheChainsDay"
            elif c["gtd"] != 0:
                return "InvalidTerms"
            if c["oco"] != 0:
                o = self.orders.get(c["oco"])
                if o is None or o["account"] != c["account"] or o["instrument"] != c["instrument"] or not self.liveish(o) or o["oco"] != 0:
                    return "InvalidOco"
            price = collar(c["side"], i["ref"], i["collar"], i["bands"]) if kind in ("market", "stop", "trailingStop") else c["price"]
            need = price * c["qty"] if c["side"] == "buy" else c["qty"]
            crossing = [] if kind in STOPS else self.crossing_own(c["account"], c["instrument"], c["side"], price)
            if crossing and c["smp"] == "cancelIncoming":
                return "SelfTradePrevented"
            cancelled_in = bool(crossing) and c["smp"] == "cancelBoth"
            if not cancelled_in and self.b(c["account"], self.ledger(c["instrument"], c["side"]))[0] < need:
                return "InsufficientFunds"
            return None
        if k in ("cancelOrder", "amendOrder"):
            o = self.orders.get(c["order"])
            if o is None:
                return "UnknownOrder"
            if self.own_account(role, o["account"]):
                return "NotYourOrder"
            if not self.liveish(o):
                return "OrderClosed"
            if k == "cancelOrder":
                return None
            if o["kind"] != "limit" or o["status"] != "live":
                return "InvalidTerms"
            i = self.inst[o["instrument"]]
            if c["qty"] == 0 or c["qty"] % i["lot"] != 0:
                return "NotALot"
            if o["peak"] != 0 and o["peak"] >= c["qty"]:
                return "NotALot"
            if not on_tick(i["bands"], c["price"]):
                return "PriceOffTick"
            if c["qty"] == o["remaining"] and c["price"] == o["price"]:
                return "InvalidTerms"
            need = c["price"] * c["qty"] if o["side"] == "buy" else c["qty"]
            if need > o["held"] and self.b(o["account"], self.ledger(o["instrument"], o["side"]))[0] < need - o["held"]:
                return "InsufficientFunds"
            if self.crossing_own(o["account"], o["instrument"], o["side"], c["price"]):
                return "SelfTradePrevented"
            return None
        if k == "massCancel":
            return self.own_account(role, c["account"])
        if k == "flush":
            return "NothingToClear" if (self.batch == 0 and not self.due) else None
        if k == "endOfDay":
            return None
        if k == "expireGtd":
            return "NotTheChainsDay" if c["day"] != self.today(now) else None
        raise ValueError(k)

    # ── apply ──
    def cancel_oco(self, o, out):
        if o["oco"] and self.liveish(self.orders[o["oco"]]):
            self.close(o["oco"], "cancelled")
            out.append(o["oco"])

    def apply(self, now, c):
        k = c["k"]
        if k == "setTrading":
            self.inst[c["instrument"]]["open"] = c["open"]
            if c["open"]:
                self.due.add(c["instrument"])
            return [2, c["instrument"]]
        if k == "setReference":
            self.inst[c["instrument"]]["ref"] = c["price"]
            return [3, c["instrument"]]
        if k == "deposit":
            self.refs.add(c["reference"])
            self.b(c["account"], c["ledger"])[0] += c["amount"]
            self.deposited[c["ledger"]] = self.deposited.get(c["ledger"], 0) + c["amount"]
            return [4, c["account"], c["amount"]]
        if k == "withdraw":
            self.b(c["account"], c["ledger"])[0] -= c["amount"]
            self.deposited[c["ledger"]] -= c["amount"]
            return [5, c["account"], c["amount"]]
        if k == "placeOrder":
            i = self.inst[c["instrument"]]
            oid = self.next; self.next += 1
            kind = c["kind"]
            price = collar(c["side"], i["ref"], i["collar"], i["bands"]) if kind in ("market", "stop", "trailingStop") else c["price"]
            stop = kind in STOPS
            cancelled = []
            cancelled_in = False
            if not stop:
                crossing = self.crossing_own(c["account"], c["instrument"], c["side"], price)
                for rid in crossing:
                    self.close(rid, "cancelled"); cancelled.append(rid)
                if crossing and c["smp"] == "cancelBoth":
                    cancelled_in = True
            need = price * c["qty"] if c["side"] == "buy" else c["qty"]
            status = "cancelled" if cancelled_in else ("waiting" if stop else "live")
            if not cancelled_in:
                self.hold(c["account"], self.ledger(c["instrument"], c["side"]), need)
            self.orders[oid] = dict(account=c["account"], instrument=c["instrument"], side=c["side"], kind=kind, qty=c["qty"], remaining=c["qty"],
                                    price=price, stop=c["stop"], peak=c["peak"], validity=c["validity"], gtd=c["gtd"], ref=c["ref"], oco=c["oco"],
                                    smp=c["smp"], trail=c["trail"], capacity=c["capacity"], short=c["short"], prio=now, key=order_key(c["account"], c["side"], price, c["qty"], c["ref"]), status=status,
                                    held=0 if cancelled_in else need, filled=0)
            self.refs_used.add((c["account"], c["ref"]))
            if status in ("live", "waiting"):
                self.track(oid, self.orders[oid])
            if c["oco"]:
                self.orders[c["oco"]]["oco"] = oid
            if status == "live":
                self.due.add(c["instrument"])
                if self.batch == 0:
                    self.batch = now
            if status == "waiting":
                self.due.add(c["instrument"])
            return [6, oid, STATUS[status]] + cancelled
        if k == "cancelOrder":
            self.close(c["order"], "cancelled")
            return [7, c["order"]]
        if k == "amendOrder":
            o = self.orders[c["order"]]
            keeps = c["price"] == o["price"] and c["qty"] <= o["remaining"]
            led = self.ledger(o["instrument"], o["side"])
            need = c["price"] * c["qty"] if o["side"] == "buy" else c["qty"]
            if need > o["held"]:
                self.hold(o["account"], led, need - o["held"])
            else:
                self.release(o["account"], led, o["held"] - need)
            o["qty"] = o["filled"] + c["qty"]; o["remaining"] = c["qty"]; o["price"] = c["price"]; o["held"] = need
            if not keeps:
                o["prio"] = now
                o["key"] = order_key(o["account"], o["side"], c["price"], c["qty"], o["ref"])
            self.due.add(o["instrument"])
            if self.batch == 0:
                self.batch = now
            return [8, c["order"], 1 if keeps else 0]
        if k == "massCancel":
            own = sorted((o["instrument"], 1 if o["side"] == "buy" else 2, self.pkey(o["side"], o["price"]), oid)
                         for oid, o in ((x, self.orders[x]) for x in self.open_ids("acct", c["account"])))
            done = [x[3] for x in own][:min(c["limit"], 500)]
            for oid in done:
                self.close(oid, "cancelled")
            return [9, len(done)] + done
        if k == "flush":
            return [10]
        if k == "endOfDay":
            day = sorted(oid for oid in self.open_ids("all") if self.orders[oid]["validity"] == "day")[:min(c["limit"], 500)]
            for oid in day:
                self.close(oid, "cancelled")
            return [11, len(day)] + day
        if k == "expireGtd":
            if c["day"] == 0:
                return [12, 0]
            g = sorted((self.orders[oid]["gtd"], oid) for oid in self.open_ids("all") if self.orders[oid]["validity"] == "gtd" and self.orders[oid]["gtd"] < c["day"])
            g = [oid for (_, oid) in g][:min(c["limit"], 500)]
            for oid in g:
                self.close(oid, "cancelled")
            return [12, len(g)] + g
        raise ValueError(k)

    # ── the auction (§3), written from the text ──
    def auction(self, bids, asks, lot):
        killed = []
        while True:
            price, volume, fills = self.once(bids, asks, lot)
            under = [o for o in bids + asks if o["fok"] and fills.get(o["id"], 0) < o["qty"]]
            if under:
                w = max(under, key=lambda o: (o["prio"], o["key"]))
                killed.append(w["id"])
                bids = [o for o in bids if o["id"] != w["id"]]
                asks = [o for o in asks if o["id"] != w["id"]]
                continue
            bf = [(o, fills[o["id"]]) for o in bids if fills.get(o["id"], 0) > 0]
            af = [(o, fills[o["id"]]) for o in asks if fills.get(o["id"], 0) > 0]
            bf.sort(key=lambda x: (-x[0]["price"], x[0]["prio"], x[0]["key"]))
            af.sort(key=lambda x: (x[0]["price"], x[0]["prio"], x[0]["key"]))
            pairs, i, j, bl, al = [], 0, 0, 0, 0
            while i < len(bf) and j < len(af):
                bl = bl or bf[i][1]; al = al or af[j][1]
                q = min(bl, al)
                pairs.append((bf[i][0]["id"], af[j][0]["id"], q))
                bl -= q; al -= q
                if bl == 0: i += 1
                if al == 0: j += 1
            fl = [(o["id"], q) for (o, q) in bf] + [(o["id"], q) for (o, q) in af]
            return (price if volume else None), volume, fl, pairs, killed

    def once(self, bids, asks, lot):
        best = None
        for p in sorted({o["price"] for o in bids + asks}):
            d = sum(o["qty"] for o in bids if o["price"] >= p)
            s = sum(o["qty"] for o in asks if o["price"] <= p)
            ex = min(d, s)
            if ex == 0:
                continue
            cand = (-ex, abs(d - s), p)
            if best is None or cand < best:
                best = cand
        if best is None:
            return None, 0, {}
        p = best[2]
        eb = [o for o in bids if o["price"] >= p]
        ea = [o for o in asks if o["price"] <= p]
        d = sum(o["qty"] for o in eb); s = sum(o["qty"] for o in ea)
        v = min(d, s)
        fills = {}
        short, long_, aggressive = (eb, ea, lambda o: o["price"]) if d <= s else (ea, eb, lambda o: -o["price"])
        for o in short:
            fills[o["id"]] = o["qty"]
        left = v
        for price in sorted({o["price"] for o in long_}, key=lambda x: aggressive({"price": x})):
            if left == 0:
                break
            level = [o for o in long_ if o["price"] == price]
            total = sum(o["qty"] for o in level)
            if total <= left:
                for o in level:
                    fills[o["id"]] = o["qty"]
                left -= total
                continue
            for pr in sorted({o["prio"] for o in level}):
                if left == 0:
                    break
                group = [o for o in level if o["prio"] == pr]
                g = sum(o["qty"] for o in group)
                if g <= left:
                    for o in group:
                        fills[o["id"]] = o["qty"]
                    left -= g
                    continue
                left_lots, g_lots = left // lot, g // lot
                rems = []
                given = 0
                for o in group:
                    share = left_lots * (o["qty"] // lot) // g_lots
                    if share:
                        fills[o["id"]] = share * lot
                    given += share
                    rems.append((left_lots * (o["qty"] // lot) % g_lots, o))
                extra = left_lots - given
                for (_, o) in sorted(rems, key=lambda x: (-x[0], x[1]["key"])):
                    if extra and fills.get(o["id"], 0) + lot <= o["qty"]:
                        fills[o["id"]] = fills.get(o["id"], 0) + lot
                        extra -= 1
                left = 0
            left = 0
        return p, v, fills

    def clear(self, time):
        fx = [13]
        for inst in sorted(self.due):
            self.due.discard(inst)
            i = self.inst[inst]
            cancelled, triggered, pairs = [], [], []
            price = volume = 0
            if i["open"]:
                if i["last"]:
                    for side in ("buy", "sell"):
                        stops = sorted(((o["stop"] if side == "buy" else MAXP - o["stop"]), oid) for oid, o in ((x, self.orders[x]) for x in list(self.open_ids("inst", inst)))
                                       if o["status"] == "waiting" and o["instrument"] == inst and o["side"] == side)
                        hits = []
                        for (_, oid) in stops:
                            o = self.orders[oid]
                            if not (i["last"] >= o["stop"] if side == "buy" else i["last"] <= o["stop"]):
                                break
                            hits.append(oid)
                        for oid in hits:
                            o = self.orders[oid]
                            if o["status"] != "waiting":
                                continue
                            o["status"] = "live"; o["prio"] = time
                            triggered.append(oid)
                            # §3.5: judged against the account's own live orders when it is triggered
                            crossing = self.crossing_own(o["account"], inst, o["side"], o["price"])
                            if crossing:
                                if o["smp"] != "cancelIncoming":
                                    for rid in crossing:
                                        self.close(rid, "cancelled"); cancelled.append(rid)
                                if o["smp"] != "cancelResting":
                                    self.close(oid, "cancelled"); cancelled.append(oid)
                            self.cancel_oco(o, cancelled)
                live = [(oid, self.orders[oid]) for oid in self.open_ids("inst", inst) if self.orders[oid]["status"] == "live"]
                buys = [x for x in live if x[1]["side"] == "buy"]; sells = [x for x in live if x[1]["side"] == "sell"]
                if buys and sells:
                    bb = max(o["price"] for _, o in buys); ba = min(o["price"] for _, o in sells)
                    if bb >= ba:
                        def view(oid, o):
                            return dict(id=oid, price=o["price"], qty=o["remaining"], prio=o["prio"], key=o["key"], fok=o["kind"] == "fok")
                        bids = [view(oid, o) for oid, o in buys if o["price"] >= ba]
                        asks = [view(oid, o) for oid, o in sells if o["price"] <= bb]
                        p, v, fills, prs, killed = self.auction(bids, asks, i["lot"])
                        for k in killed:
                            self.close(k, "cancelled"); cancelled.append(k)
                        if p is not None:
                            price, volume = p, v
                            for (b, a, q) in prs:
                                bo, ao = self.orders[b], self.orders[a]
                                # the buyer pays p x q from what it holds at its price; the rest returns to it
                                self.b(bo["account"], i["cash"])[1] -= bo["price"] * q
                                self.b(bo["account"], i["cash"])[0] += (bo["price"] - p) * q
                                self.b(ao["account"], i["cash"])[0] += p * q
                                self.b(ao["account"], i["asset"])[1] -= q
                                self.b(bo["account"], i["asset"])[0] += q
                                bo["held"] -= bo["price"] * q; ao["held"] -= q
                                for o in (bo, ao):
                                    o["remaining"] -= q; o["filled"] += q
                                    o["status"] = "filled" if o["remaining"] == 0 else "live"
                                pairs.append((b, a, q))
                            for (oid, f) in fills:
                                o = self.orders[oid]
                                if o["peak"] and o["remaining"] > 0 and f >= min(o["peak"], o["remaining"] + f):
                                    o["prio"] = time
                            for (b, a, _) in prs:
                                for oid in (b, a):
                                    o = self.orders[oid]
                                    self.cancel_oco(o, cancelled)
                                    if o["status"] == "filled" and o["held"] > 0:
                                        self.close(oid, "filled")
            for oid in sorted(oid for oid in self.open_ids("inst", inst) if self.orders[oid]["status"] == "live" and self.orders[oid]["kind"] in IMMEDIATE):
                self.close(oid, "cancelled"); cancelled.append(oid)
            if price:
                i["last"] = price
                # §2: every trailing stop of the instrument follows the price, never the other way
                for o in (self.orders[x] for x in self.open_ids("inst", inst)):
                    if o["status"] == "waiting" and o["kind"] == "trailingStop" and o["instrument"] == inst:
                        if o["side"] == "sell":
                            if price > o["trail"]:
                                c = price - o["trail"]
                                o["stop"] = max(o["stop"], c - c % tick_at(i["bands"], c))
                        else:
                            c = price + o["trail"]
                            t = tick_at(i["bands"], c)
                            o["stop"] = min(o["stop"], c if c % t == 0 else c + (t - c % t))
                hit = False
                for side in ("buy", "sell"):
                    w = [self.orders[x] for x in self.open_ids("inst", inst) if self.orders[x]["status"] == "waiting" and self.orders[x]["side"] == side]
                    if w:
                        first = min(w, key=lambda o: o["stop"]) if side == "buy" else max(w, key=lambda o: o["stop"])
                        if (side == "buy" and price >= first["stop"]) or (side == "sell" and price <= first["stop"]):
                            hit = True
                if hit:
                    self.due.add(inst)
            fx += [inst, price, volume, len(pairs)] + [x for pr in pairs for x in pr] + [len(cancelled)] + cancelled + [len(triggered)] + triggered
        self.batch = 0
        return fx

    def submit(self, now, role, c):
        pending = self.batch if self.batch else (self.log[-1][0] if self.due and self.log else 0)
        if pending and now > pending:
            self.log.append((now, "clear", self.clear(pending)))
        if not self.f["grants"].get((role, c["k"]), False):
            return "a:NoGrant"
        e = self.validate(now, role, c)
        if e:
            return "e:" + e
        if c["k"] == "openInstrument":
            return "p:"   # opening is under four eyes: the battery opens instruments only in a stream's setup
        fx = self.apply(now, c)
        self.log.append((now, c["k"], fx))
        return "x:" + ",".join(map(str, fx))

    def conserved(self):
        for led, total in self.deposited.items():
            have = sum(v[0] + v[1] for (a, l), v in self.bal.items() if l == led)
            if have != total:
                return f"ledger {led}: accounts hold {have}, deposits less withdrawals {total}"
        return None


def parse_cmd(s):
    c = {}
    for kv in s.split(";"):
        k, _, v = kv.partition("=")
        # a client reference and a deposit's reference are text whatever their characters
        c[k] = v if k in ("ref", "reference") else (int(v) if v.isdigit() else v)
    if "open" in c:
        c["open"] = c["open"] in (1, True)
    return c


def main():
    lines = []
    kept = False   # whether the physical line before was kept: a piece continues only the line it follows
    for l in open(sys.argv[1]):
        l = l.rstrip("\n")
        if l.startswith("+|"):
            if kept:
                lines[-1] += l[2:]      # a long line printed in pieces
        elif l[:2] in ("H|", "S|", "C|", "B|", "O|", "Q|", "E|"):
            lines.append(l); kept = True
        else:
            kept = False
    facts = {"accounts": {}, "owns": {}, "may": {}, "instruments": {}, "grants": {}, "offset": 0, "xinstruments": {}, "xbands": None}
    errors = []
    streams = cmds = blocks = checkpoints = 0
    ref = None
    sblocks, sorders, squeue = [], {}, {}
    for l in lines:
        f = l.split("|")
        if f[0] == "H":
            kind = f[1]
            if kind == "account":
                facts["accounts"][int(f[2])] = {"open": f[3] == "1"}
            elif kind == "owns":
                facts["owns"][(f[2], int(f[3]))] = int(f[4])
            elif kind == "may":
                facts["may"][(f[2], int(f[3]))] = int(f[4])
            elif kind == "grant":
                facts["grants"][(f[2], f[3])] = True
            elif kind == "xinstrument":
                facts["xinstruments"][int(f[2])] = {"listed": f[3] == "1", "asset": f[4], "cash": f[5], "lot": int(f[6])}
            elif kind == "xbands":
                facts["xbands"] = f[2]
            elif kind == "offset":
                facts["offset"] = int(f[2])
            elif kind == "instrument":
                bands = [tuple(int(x) for x in b.split(":")) for b in f[6].split(",")]
                facts["instruments"][int(f[2])] = {"lot": int(f[3]), "ref": int(f[4]), "collar": int(f[5]), "bands": bands, "asset": f[7], "cash": f[8]}
        elif f[0] == "S":
            ref = Ref(facts)
            # the setup's blocks (the instruments opened under four eyes) end at the time f[1]: the time a due clear
            # takes when no batch is waiting (§5) may be theirs
            ref.log.append((int(f[1]), "setup", []))
            for p in f[2].split(","):
                if p:
                    ref.inst[int(p)]["opened"] = True
            sblocks, sorders, squeue = [], {}, {}
            streams += 1
        elif f[0] == "C":
            now, role, cmd, want = int(f[1]), f[2], parse_cmd(f[3]), f[4]
            got = ref.submit(now, role, cmd)
            cmds += 1
            if got != want:
                errors.append(f"stream {streams} command {cmds} {f[3][:80]}: the book gave {want[:120]}, the reference {got[:120]}")
            bad = ref.conserved()
            if bad:
                errors.append(f"stream {streams}: conservation: {bad}")
        elif f[0] == "B":
            sblocks.append((int(f[2]), f[3], f[4]))
        elif f[0] == "O":
            sorders[int(f[1])] = f[2:]
        elif f[0] == "Q":
            squeue[(int(f[1]), f[2])] = (int(f[3]), int(f[4]))
        elif f[0] == "E":
            mine = [(t, fam, ",".join(map(str, fx))) for (t, fam, fx) in ref.log[ref.compared:] if fam != "setup"]
            ref.compared = len(ref.log)
            blocks += len(sblocks)
            if mine != sblocks:
                first = next((k for k, (x, y) in enumerate(zip(mine, sblocks)) if x != y), min(len(mine), len(sblocks)))
                errors.append(f"stream {streams}: the logs differ at block {first}: book {sblocks[first] if first < len(sblocks) else None}, reference {mine[first] if first < len(mine) else None}")
            for oid, row in sorders.items():
                o = ref.orders.get(oid)
                if o is None:
                    errors.append(f"stream {streams}: order {oid} unknown to the reference"); continue
                mine_row = [str(STATUS[o["status"]]), str(o["remaining"]), str(o["filled"]), str(o["held"]), str(o["prio"]), str(o["price"]),
                            str(o["stop"]), "1" if o["capacity"] == "agency" else "2", str(o["short"]), str(o["trail"])]
                if mine_row != row:
                    errors.append(f"stream {streams}: order {oid}: book {row}, reference {mine_row}")
            total = int(f[1]) if len(f) > 1 and f[1] else len(sorders)
            if total != len(ref.orders):
                errors.append(f"stream {streams}: {total} orders in the book, {len(ref.orders)} in the reference")
            for key, v in squeue.items():
                mine_v = tuple(ref.bal.get(key, [0, 0]))
                if mine_v != v:
                    errors.append(f"stream {streams}: balance {key}: book {v}, reference {mine_v}")
            for key, v in ref.bal.items():
                if key not in squeue and tuple(v) != (0, 0):
                    errors.append(f"stream {streams}: balance {key}: the book holds no row, the reference {tuple(v)}")
            checkpoints += 1
            sblocks, sorders, squeue = [], {}, {}
    print(f"reference: {streams} streams, {cmds} commands, {blocks} blocks and {checkpoints} checkpoints of every order and balance compared")
    if streams == 0 or cmds == 0 or blocks == 0 or checkpoints == 0:
        errors.append("MISS: the log holds no stream")
    if errors:
        for e in errors[:12]:
            print("  DISAGREES:", e)
        print(f"reference: {len(errors)} disagreements")
        return 1
    print("reference: VERIFIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
