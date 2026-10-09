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
DAY_DOMAIN = "thebes.book.day.v1"   # the day's file (§15)
PHASE = {"closed": 1, "continuous": 2, "auction": 3, "closingAuction": 4, "tradeAtClose": 5, "halted": 6}
CALL = ("auction", "closingAuction")
DUAL = {"openInstrument", "halt", "resume", "revive", "setLimits", "setBlackout", "liftBlackout"}
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


def band(r, b):
    """SPEC §10: ⌈r(10,000 − b)/10,000⌉ to ⌊r(10,000 + b)/10,000⌋."""
    low = r * (0 if b >= 10_000 else 10_000 - b)
    return -(-low // 10_000), r * (10_000 + b) // 10_000


def within(p, r, b):
    lo, hi = band(r, b)
    return lo <= p <= hi


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
        self.inst = {i: dict(v, phase="closed", last=0, close=0, endFrom=0, endTo=0, until=0, opened=False) for i, v in facts["instruments"].items()}
        self.kills = {}       # id -> {member, trader, active}
        self.limits = {}      # member -> [max quantity, max value, credit]; the order of creation is the rows' order
        self.stats = {}       # instrument -> [first, high, low, last, closing, volume, value, trades] for the session (§15)
        self.days = []        # every sealed day's rows: (day, instrument, statistics, reference)
        self.seals = []       # (day, rows, hash)
        self.files = {}       # day -> the day's file
        self.blackouts = {}   # id -> {instrument, client (hex), until, active} (§16)
        self.borrows = {}     # (account, instrument) -> owed, in the order the rows were made (§17)
        self.last_time = 0    # the time of the log's last block (proposals and approvals included)
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
        self.deposited = {}   # ledger -> deposits and loans in, less withdrawals and returns

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
        for key in (("all",), ("inst", o["instrument"]), ("acct", o["account"]), ("ais", o["account"], o["instrument"], o["side"]),
                    ("member", o["member"]), ("trader", o["trader"])):
            self.opens.setdefault(key, set()).add(oid)

    def open_ids(self, *key):
        ids = self.opens.get(key)
        if not ids:
            return ()
        for oid in [x for x in ids if not self.liveish(self.orders[x])]:
            ids.discard(oid)
        return ids

    # ── the market's day ──
    # ── kills and limits (SPEC §11) ──
    def active_kill(self, member=0, trader=0):
        for kid in sorted(self.kills):
            k = self.kills[kid]
            # a member's kill names no trader; a trader's kill names its trader (and its member)
            if k["active"] and ((member and not k["trader"] and k["member"] == member) or (trader and k["trader"] == trader)):
                return kid
        return None

    def killed(self, member, trader):
        return self.active_kill(member=member) or self.active_kill(trader=trader)

    # ── insider blackouts and short sales (§16, §17) ──
    def blacked_out(self, account, inst, now):
        client = self.f["accounts"].get(account, {}).get("client", "")
        if len(client) != 64:
            return False
        for b in self.blackouts.values():
            if b["active"] and b["instrument"] == inst and b["client"] == client:
                return b["until"] == 0 or self.today(now) <= b["until"]
        return False

    def owned_free(self, account, inst):
        avail = self.b(account, self.inst[inst]["asset"])[0]
        return max(0, avail - self.borrows.get((account, inst), 0))

    @staticmethod
    def short_floor(i):
        return i["last"] or i["ref"]

    def used(self, member):
        return sum(self.orders[x]["price"] * self.orders[x]["remaining"] for x in self.open_ids("member", member))

    def risk(self, member, qty, value, replacing):
        if member not in self.limits:
            return None
        q, v, c = self.limits[member]
        if q and qty > q:
            return "RiskLimit"
        if v and value > v:
            return "RiskLimit"
        if c and self.used(member) + value - replacing > c:
            return "RiskLimit"
        return None

    def trader_id(self, role):
        for tid, t in self.f["traders"].items():
            if t["role"] == role:
                return tid
        return 0

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
        # anonymity: another member's account answers NotYourAccount, never whether it is closed
        if self.f["owns"][(role, account)] != 1:
            return "NotYourAccount"
        if not acc["open"]:
            return "AccountClosed"
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
            if xi["ref"] != c["price"]:
                return "InstrumentMismatch"
            if c["collar"] == 0 or c["collar"] >= 10_000:
                return "InvalidTerms"
            if c["static"] == 0 or c["static"] >= 10_000 or c["collar"] > c["static"]:
                return "InvalidTerms"
            if c["dynamic"] >= 10_000 or c["secs"] > 86_400:
                return "InvalidTerms"
            return None
        if k == "setTrading":
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if i["phase"] == "halted":
                return "InstrumentHalted"
            if i["until"]:
                return "InvalidTerms"
            if c["open"] == (i["phase"] == "continuous"):
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
            if self.f["accounts"][c["account"]]["member"] != c["member"]:
                return "InvalidTerms"
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
            if self.f["accounts"][c["account"]]["member"] != c["member"]:
                return "InvalidTerms"
            if c["amount"] == 0:
                return "InvalidTerms"
            if self.b(c["account"], c["ledger"])[0] < c["amount"]:
                return "InsufficientFunds"
            return None
        if k == "placeOrder":
            e = self.own_account(role, c["account"])
            if e:
                return e
            if self.f["accounts"][c["account"]]["member"] != c["member"] or self.trader_id(role) != c["trader"]:
                return "NotYourAccount"
            if self.f["may"][(role, c["instrument"])] != 0:
                return "MayNotTrade"
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if i["phase"] == "halted":
                return "InstrumentHalted"
            if self.killed(c["member"], c["trader"]):
                return "Killed"
            if self.blacked_out(c["account"], c["instrument"], now):
                return "InsiderBlackout"
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
            if i["phase"] in CALL and kind in ("ioc", "fok"):
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
            if kind in ("limit", "ioc", "fok", "stopLimit") and not within(c["price"], i["ref"], i["static"]):
                return "PriceOutsideBand"
            # §17
            if c["short"] and c["side"] == "buy":
                return "InvalidTerms"
            if c["side"] == "sell":
                if c["short"]:
                    if kind not in ("limit", "ioc", "fok", "stopLimit") or c["price"] < self.short_floor(i):
                        return "ShortSalePrice"
                elif c["qty"] > self.owned_free(c["account"], c["instrument"]):
                    return "ShortSaleNotFlagged"
            price = collar(c["side"], i["ref"], i["collar"], i["bands"]) if kind in ("market", "stop", "trailingStop") else c["price"]
            e = self.risk(c["member"], c["qty"], price * c["qty"], 0)
            if e:
                return e
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
            if i["phase"] == "halted":
                return "InstrumentHalted"
            if self.killed(o["member"], o["trader"]):
                return "Killed"
            if self.blacked_out(o["account"], o["instrument"], now):
                return "InsiderBlackout"
            if c["qty"] == 0 or c["qty"] % i["lot"] != 0:
                return "NotALot"
            if o["peak"] != 0 and o["peak"] >= c["qty"]:
                return "NotALot"
            if not on_tick(i["bands"], c["price"]):
                return "PriceOffTick"
            if c["qty"] == o["remaining"] and c["price"] == o["price"]:
                return "InvalidTerms"
            if not within(c["price"], i["ref"], i["static"]):
                return "PriceOutsideBand"
            if o["side"] == "sell":
                if o["short"]:
                    if c["price"] < self.short_floor(i):
                        return "ShortSalePrice"
                elif c["qty"] > o["remaining"] and c["qty"] - o["remaining"] > self.owned_free(o["account"], o["instrument"]):
                    return "ShortSaleNotFlagged"
            e = self.risk(o["member"], c["qty"], c["price"] * c["qty"], o["price"] * o["remaining"])
            if e:
                return e
            need = c["price"] * c["qty"] if o["side"] == "buy" else c["qty"]
            if need > o["held"] and self.b(o["account"], self.ledger(o["instrument"], o["side"]))[0] < need - o["held"]:
                return "InsufficientFunds"
            if self.crossing_own(o["account"], o["instrument"], o["side"], c["price"]):
                return "SelfTradePrevented"
            return None
        if k == "massCancel":
            e = self.own_account(role, c["account"])
            if e:
                return e
            return "InvalidTerms" if self.f["accounts"][c["account"]]["member"] != c["member"] else None
        if k == "flush":
            return "NothingToClear" if (self.batch == 0 and not self.due) else None
        if k == "endOfDay":
            return None
        if k == "expireGtd":
            return "NotTheChainsDay" if c["day"] != self.today(now) else None
        if k in ("setPhase", "uncross", "halt", "resume"):
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if k == "setPhase":
                if i["phase"] == "halted":
                    return "InstrumentHalted"
                if i["until"] or c["phase"] == "halted" or c["phase"] == i["phase"]:
                    return "InvalidTerms"
                if c["phase"] in CALL:
                    if (c["from"] == 0) != (c["to"] == 0) or c["from"] > c["to"]:
                        return "InvalidTerms"
                elif c["from"] or c["to"]:
                    return "InvalidTerms"
                return None
            if k == "uncross":
                if i["phase"] not in CALL:
                    return "NotInAuction"
                if i["endFrom"] and now < i["endFrom"]:
                    return "AuctionNotEnded"
                if i["until"] and now < i["until"]:
                    return "AuctionNotEnded"
                if c["next"] not in ("continuous", "tradeAtClose", "closed"):
                    return "InvalidTerms"
                return None
            if k == "halt":
                if i["phase"] == "halted":
                    return "InstrumentHalted"
                return None if 1 <= len(c["reason"].encode()) <= 256 else "InvalidTerms"
            return None if i["phase"] == "halted" else "InvalidTerms"
        if k == "kill":
            # §11: a kill names its member; with a trader, a trader of that member
            if c["member"] == 0:
                return "InvalidTerms"
            if not (1 <= len(c["reason"].encode()) <= 256):
                return "InvalidTerms"
            if c["member"] not in self.f["members"]:
                return "InvalidTerms"
            if c["trader"] and (c["trader"] not in self.f["traders"] or self.f["traders"][c["trader"]]["member"] != c["member"]):
                return "InvalidTerms"
            target = c["member"]
            me = self.trader_id(role)
            if me and (not self.f["traders"][me]["active"] or self.f["traders"][me]["member"] != target):
                return "InvalidTerms"
            if (self.active_kill(trader=c["trader"]) if c["trader"] else self.active_kill(member=c["member"])):
                return "InvalidTerms"
            return None
        if k in ("killSweep", "revive"):
            kl = self.kills.get(c["kill"])
            if kl is None:
                return "UnknownKill"
            if not kl["active"]:
                return "InvalidTerms"
            if k == "revive":
                still = self.open_ids("trader", kl["trader"]) if kl["trader"] else self.open_ids("member", kl["member"])
                if still:
                    return "OrdersStillOpen"
            return None
        if k == "setLimits":
            return None if c["member"] in self.f["members"] else "InvalidTerms"
        if k == "setBlackout":
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            if len(c["client"]) != 64:
                return "InvalidTerms"
            if c["until"] != 0 and c["until"] < self.today(now):
                return "InvalidTerms"
            if not (1 <= len(c["reason"].encode()) <= 256):
                return "InvalidTerms"
            if any(b["active"] and b["instrument"] == c["instrument"] and b["client"] == c["client"] for b in self.blackouts.values()):
                return "InvalidTerms"
            return None
        if k == "liftBlackout":
            b = self.blackouts.get(c["blackout"])
            return None if b and b["active"] else "UnknownBlackout"
        if k == "borrow":
            if c["account"] not in self.f["accounts"]:
                return "UnknownAccount"
            if self.f["accounts"][c["account"]]["member"] != c["member"]:
                return "InvalidTerms"
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            if c["qty"] == 0 or len(c["reference"]) != 64:
                return "InvalidTerms"
            if c["reference"] in self.refs:
                return "DuplicateReference"
            return None
        if k == "returnBorrow":
            e = self.own_account(role, c["account"])
            if e:
                return e
            if self.f["accounts"][c["account"]]["member"] != c["member"]:
                return "InvalidTerms"
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            if c["qty"] == 0 or c["qty"] > self.borrows.get((c["account"], c["instrument"]), 0):
                return "InvalidTerms"
            if self.b(c["account"], self.inst[c["instrument"]]["asset"])[0] < c["qty"]:
                return "InsufficientFunds"
            return None
        if k == "sealDay":
            # §15: the market day of the act, later than every day sealed
            if c["day"] != self.today(now) or c["day"] <= (self.seals[-1][0] if self.seals else 0):
                return "InvalidTerms"
            return None
        raise ValueError(k)

    # ── apply ──
    def cancel_oco(self, o, out):
        if o["oco"] and self.liveish(self.orders[o["oco"]]):
            self.close(o["oco"], "cancelled")
            out.append(o["oco"])

    def apply(self, now, c):
        k = c["k"]
        if k == "setTrading":
            self.inst[c["instrument"]]["phase"] = "continuous" if c["open"] else "closed"
            if c["open"]:
                self.due.add(c["instrument"])
            return [2, c["instrument"]]
        if k == "setPhase":
            i = self.inst[c["instrument"]]
            i.update(phase=c["phase"], endFrom=c["from"], endTo=c["to"])
            self.due.add(c["instrument"])
            return [14, c["instrument"], PHASE[c["phase"]]]
        if k == "uncross":
            return self.uncross(now, c["instrument"], c["next"])
        if k == "halt":
            self.inst[c["instrument"]].update(phase="halted", endFrom=0, endTo=0, until=0)
            self.due.add(c["instrument"])
            return [16, c["instrument"]]
        if k == "resume":
            self.inst[c["instrument"]]["phase"] = "auction"
            return [17, c["instrument"]]
        if k == "kill":
            kid = len(self.kills) + 1
            self.kills[kid] = {"member": c["member"], "trader": c["trader"], "active": True}
            return [18, kid]
        if k == "killSweep":
            kl = self.kills[c["kill"]]
            ids = sorted(self.open_ids("trader", kl["trader"]) if kl["trader"] else self.open_ids("member", kl["member"]))[:min(c["limit"], 500)]
            for oid in ids:
                self.close(oid, "cancelled")
            return [19, c["kill"], len(ids)] + ids
        if k == "revive":
            self.kills[c["kill"]]["active"] = False
            return [20, c["kill"]]
        if k == "setLimits":
            self.limits[c["member"]] = [c["qty"], c["value"], c["credit"]]
            return [21, c["member"]]
        if k == "setBlackout":
            bid = len(self.blackouts) + 1
            self.blackouts[bid] = {"instrument": c["instrument"], "client": c["client"], "until": c["until"], "active": True}
            return [23, bid]
        if k == "liftBlackout":
            self.blackouts[c["blackout"]]["active"] = False
            return [24, c["blackout"]]
        if k == "borrow":
            self.refs.add(c["reference"])
            self.b(c["account"], self.inst[c["instrument"]]["asset"])[0] += c["qty"]
            led = self.inst[c["instrument"]]["asset"]; self.deposited[led] = self.deposited.get(led, 0) + c["qty"]
            self.borrows[(c["account"], c["instrument"])] = self.borrows.get((c["account"], c["instrument"]), 0) + c["qty"]
            return [25, c["account"], c["qty"]]
        if k == "returnBorrow":
            self.b(c["account"], self.inst[c["instrument"]]["asset"])[0] -= c["qty"]
            self.deposited[self.inst[c["instrument"]]["asset"]] -= c["qty"]
            self.borrows[(c["account"], c["instrument"])] -= c["qty"]
            return [26, c["account"], c["qty"]]
        if k == "sealDay":
            rows, h = self.seal(c["day"])
            return [22, c["day"], rows] + list(h)
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
                                    smp=c["smp"], trail=c["trail"], capacity=c["capacity"], short=c["short"], member=c["member"], trader=c["trader"], prio=now, key=order_key(c["account"], c["side"], price, c["qty"], c["ref"]), status=status,
                                    held=0 if cancelled_in else need, filled=0)
            self.refs_used.add((c["account"], c["ref"]))
            if status in ("live", "waiting"):
                self.track(oid, self.orders[oid])
                # the member's use row is made at its first open order (or by its limits)
                self.limits.setdefault(c["member"], [0, 0, 0])
            if c["oco"]:
                self.orders[c["oco"]]["oco"] = oid
            if status == "live":
                self.due.add(c["instrument"])
                if self.batch == 0:
                    self.batch = now
            if status == "waiting":
                self.due.add(c["instrument"])
            shows = (c["qty"] if not c["peak"] else min(c["peak"], c["qty"])) if status == "live" else 0
            return [6, oid, STATUS[status], price, shows] + cancelled
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
            return [8, c["order"], 1 if keeps else 0, 0 if o["status"] != "live" else (c["qty"] if not o["peak"] else min(o["peak"], c["qty"]))]
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
    # ── the pricing rules ──
    @staticmethod
    def demand(bids, p):
        return sum(o["qty"] for o in bids if o["price"] >= p)

    @staticmethod
    def supply(asks, p):
        return sum(o["qty"] for o in asks if o["price"] <= p)

    def price_continuous(self, bids, asks):
        """§3.1: the most volume, then the least imbalance, then the lower price."""
        best = None
        for p in sorted({o["price"] for o in bids + asks}):
            d, s = self.demand(bids, p), self.supply(asks, p)
            if min(d, s) == 0:
                continue
            cand = (-min(d, s), abs(d - s), p)
            if best is None or cand < best:
                best = cand
        return None if best is None else best[2]

    def price_uncross(self, reference):
        """§9: the most volume, the least surplus, then market pressure, then the reference."""
        def rule(bids, asks):
            cands = []
            for p in sorted({o["price"] for o in bids + asks}):
                d, s = self.demand(bids, p), self.supply(asks, p)
                if min(d, s):
                    cands.append((min(d, s), abs(d - s), d - s, p))
            if not cands:
                return None
            most = max(c[0] for c in cands)
            rest = [c for c in cands if c[0] == most]
            least = min(c[1] for c in rest)
            rest = [c for c in rest if c[1] == least]
            if len(rest) == 1:
                return rest[0][3]
            lo, hi = min(c[3] for c in rest), max(c[3] for c in rest)
            if all(c[2] > 0 for c in rest):
                return hi
            if all(c[2] < 0 for c in rest):
                return lo
            if least > 0:
                # the reference-price rule: with a bid surplus at some limits and an ask surplus at others, the highest
                # limit with a bid surplus and the lowest with an ask surplus are the ones the reference is held against
                lo = max(c[3] for c in rest if c[2] > 0)
                hi = min(c[3] for c in rest if c[2] < 0)
            return reference if lo <= reference <= hi else (lo if reference < lo else hi)
        return rule

    def price_at(self, price):
        """Trade at close (§8): the closing price, when both sides have an order there."""
        return lambda bids, asks: price if min(self.demand(bids, price), self.supply(asks, price)) > 0 else None

    def auction(self, bids, asks, lot, pricer=None):
        pricer = pricer or self.price_continuous
        killed = []
        while True:
            price, volume, fills = self.once(bids, asks, lot, pricer)
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

    def once(self, bids, asks, lot, pricer):
        p = pricer(bids, asks)
        if p is None:
            return None, 0, {}
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

    # ── the pieces of a clear ──
    @staticmethod
    def view(oid, o):
        return dict(id=oid, price=o["price"], qty=o["remaining"], prio=o["prio"], key=o["key"], fok=o["kind"] == "fok")

    def live_sides(self, inst):
        live = [(oid, self.orders[oid]) for oid in self.open_ids("inst", inst) if self.orders[oid]["status"] == "live"]
        return [x for x in live if x[1]["side"] == "buy"], [x for x in live if x[1]["side"] == "sell"]

    def views(self, inst):
        """The crossing orders when the best buy reaches the best sell: buys from the best sell up, sells to the best buy."""
        buys, sells = self.live_sides(inst)
        if not buys or not sells:
            return None
        bb = max(o["price"] for _, o in buys); ba = min(o["price"] for _, o in sells)
        if bb < ba:
            return None
        return [self.view(oid, o) for oid, o in buys if o["price"] >= ba], [self.view(oid, o) for oid, o in sells if o["price"] <= bb]

    def views_at(self, inst, price):
        buys, sells = self.live_sides(inst)
        return [self.view(oid, o) for oid, o in buys if o["price"] >= price], [self.view(oid, o) for oid, o in sells if o["price"] <= price]

    def execute(self, inst, i, result, time, cancelled, pairs):
        p, v, fills, prs, killed = result
        for k in killed:
            self.close(k, "cancelled"); cancelled.append(k)
        if p is None:
            return 0, 0
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
            self.add_trade(inst, p, q)
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
        return p, v

    # ── the day's statistics (§15) ──
    def add_trade(self, inst, p, q):
        x = self.stats.setdefault(inst, [0] * 8)
        x[0] = p if x[7] == 0 else x[0]
        x[1] = max(x[1], p)
        x[2] = p if x[7] == 0 else min(x[2], p)
        x[3] = p; x[5] += q; x[6] += p * q; x[7] += 1

    def seal(self, day):
        """The day's file: every instrument in id order with its session's figures and its reference price; hashed."""
        w = bytearray(len(DAY_DOMAIN.encode()).to_bytes(2, "big") + DAY_DOMAIN.encode())

        def nat(n):
            if n == 0:
                w.append(0)
            else:
                bs = n.to_bytes((n.bit_length() + 7) // 8, "big"); w.append(len(bs)); w.extend(bs)
        nat(day)
        insts = sorted(self.inst)
        w.extend(len(insts).to_bytes(2, "big"))
        for i in insts:
            st = list(self.stats.get(i, [0] * 8))
            nat(i)
            for v in st + [self.inst[i]["ref"]]:
                nat(v)
            self.days.append((day, i, st, self.inst[i]["ref"]))
            self.stats[i] = [0] * 8
        h = hashlib.sha256(bytes(w)).digest()
        self.seals.append((day, len(insts), h))
        self.files[day] = bytes(w)
        return len(insts), h

    def end_immediates(self, inst, cancelled):
        for oid in sorted(oid for oid in self.open_ids("inst", inst) if self.orders[oid]["status"] == "live" and self.orders[oid]["kind"] in IMMEDIATE):
            self.close(oid, "cancelled"); cancelled.append(oid)

    def after_trade(self, inst, price):
        i = self.inst[inst]
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
        for side in ("buy", "sell"):
            w = [self.orders[x] for x in self.open_ids("inst", inst) if self.orders[x]["status"] == "waiting" and self.orders[x]["side"] == side]
            if w:
                first = min(w, key=lambda o: o["stop"]) if side == "buy" else max(w, key=lambda o: o["stop"])
                if (side == "buy" and price >= first["stop"]) or (side == "sell" and price <= first["stop"]):
                    self.due.add(inst)

    def trigger(self, inst, i, time, triggered, cancelled):
        if not i["last"]:
            return
        for side in ("buy", "sell"):
            stops = sorted(((o["stop"] if side == "buy" else MAXP - o["stop"]), oid) for oid, o in ((x, self.orders[x]) for x in list(self.open_ids("inst", inst)))
                           if o["status"] == "waiting" and o["side"] == side)
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
                triggered.append((oid, 1 if o["side"] == "buy" else 2, o["price"], self.shown(o)))
                # §3.5: judged against the account's own live orders when it is triggered
                crossing = self.crossing_own(o["account"], inst, o["side"], o["price"])
                if crossing:
                    if o["smp"] != "cancelIncoming":
                        for rid in crossing:
                            self.close(rid, "cancelled"); cancelled.append(rid)
                    if o["smp"] != "cancelResting":
                        self.close(oid, "cancelled"); cancelled.append(oid)
                self.cancel_oco(o, cancelled)

    @staticmethod
    def shown(o):
        """§2, §13: an iceberg shows its peak, or what remains when less; any other order what remains."""
        return o["remaining"] if not o["peak"] else min(o["peak"], o["remaining"])

    def shown_after(self, pairs):
        """§13: the icebergs traded that stay live, with what each shows, in the order they first appear in the pairs."""
        out, seen = [], set()
        for (b, a, _) in pairs:
            for oid in (b, a):
                if oid in seen:
                    continue
                seen.add(oid)
                o = self.orders[oid]
                if o["peak"] and o["status"] == "live":
                    out.append((oid, self.shown(o)))
        return out

    def clear(self, time):
        fx = [13]
        for inst in sorted(self.due):
            self.due.discard(inst)
            i = self.inst[inst]
            cancelled, triggered, pairs = [], [], []
            price = volume = 0
            interrupted = False
            if i["phase"] == "continuous":
                self.trigger(inst, i, time, triggered, cancelled)
                v = self.views(inst)
                if v:
                    result = self.auction(v[0], v[1], i["lot"])
                    p = result[0]
                    # §10: a price outside either band trades nothing and interrupts
                    if p is not None and (not within(p, i["ref"], i["static"]) or (i["dynamic"] and not within(p, i["last"] or i["ref"], i["dynamic"]))):
                        interrupted = True
                    else:
                        price, volume = self.execute(inst, i, result, time, cancelled, pairs)
            elif i["phase"] == "tradeAtClose":
                bids, asks = self.views_at(inst, i["close"])
                if bids and asks:
                    price, volume = self.execute(inst, i, self.auction(bids, asks, i["lot"], self.price_at(i["close"])), time, cancelled, pairs)
            if i["phase"] not in CALL:
                self.end_immediates(inst, cancelled)
            if interrupted:
                i.update(phase="auction", until=time + i["secs"] * 1_000_000_000, endFrom=0, endTo=0)
            if price:
                self.after_trade(inst, price)
            shown = self.shown_after(pairs)
            fx += ([inst, price, volume, len(pairs)] + [x for pr in pairs for x in pr] + [len(cancelled)] + cancelled + [len(triggered)]
                   + [x for t in triggered for x in t] + [len(shown)] + [x for t in shown for x in t] + [1 if interrupted else 0])
        self.batch = 0
        return fx

    def uncross(self, now, inst, nxt):
        """§9."""
        i = self.inst[inst]
        cancelled, pairs = [], []
        price = volume = 0
        v = self.views(inst)
        if v:
            result = self.auction(v[0], v[1], i["lot"], self.price_uncross(i["last"] or i["ref"]))
            if result[0] is not None and not within(result[0], i["ref"], i["static"]):
                return [15, inst, 0, 0, 0, 0, 0, PHASE[i["phase"]]]
            price, volume = self.execute(inst, i, result, now, cancelled, pairs)
        self.end_immediates(inst, cancelled)
        last = price or i["last"]
        close = (last or i["ref"]) if i["phase"] == "closingAuction" else i["close"]
        if i["phase"] == "closingAuction":
            self.stats.setdefault(inst, [0] * 8)[4] = close
        i.update(phase=nxt, endFrom=0, endTo=0, until=0, close=close)
        if price:
            self.after_trade(inst, price)
        self.due.add(inst)
        shown = self.shown_after(pairs)
        return ([15, inst, price, volume, len(pairs)] + [x for pr in pairs for x in pr] + [len(cancelled)] + cancelled
                + [len(shown)] + [x for t in shown for x in t] + [PHASE[nxt]])

    def flush_due(self, now):
        """§1: the clear of a batch waiting from an earlier time, or of an instrument left due, recorded first."""
        pending = self.batch if self.batch else (self.last_time if self.due else 0)
        if pending and now > pending:
            self.log.append((now, "clear", self.clear(pending)))
            self.last_time = now

    def submit(self, now, role, c):
        self.flush_due(now)
        if not self.f["grants"].get((role, c["k"]), False):
            return "a:NoGrant"
        e = self.validate(now, role, c)
        if e:
            return "e:" + e
        if c["k"] in DUAL:
            self.last_time = now   # the proposal is a block
            return "p:"
        fx = self.apply(now, c)
        self.log.append((now, c["k"], fx))
        self.last_time = now
        return "x:" + ",".join(map(str, fx))

    def approve(self, now, maker, c):
        """A proposal approved: judged again as its maker gave it, then applied (an approval and an execution, or an
        approval and a rejection, are blocks)."""
        self.flush_due(now)
        self.last_time = now
        e = self.validate(now, maker, c)
        if e:
            return "e:" + e
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
        elif l[:2] in ("H|", "S|", "C|", "A|", "B|", "O|", "Q|", "I|", "U|", "K|", "E|"):
            lines.append(l); kept = True
        else:
            kept = False
    facts = {"accounts": {}, "owns": {}, "may": {}, "instruments": {}, "grants": {}, "offset": 0, "xinstruments": {}, "xbands": None, "members": set(), "traders": {}}
    proposals = {}
    errors = []
    streams = cmds = blocks = checkpoints = 0
    ref = None
    sblocks, sorders, squeue = [], {}, {}
    sinst, slimits, skills = {}, {}, {}
    for l in lines:
        f = l.split("|")
        if f[0] == "H":
            kind = f[1]
            if kind == "account":
                facts["accounts"][int(f[2])] = {"open": f[3] == "1", "member": int(f[4]), "client": f[5] if len(f) > 5 else ""}
            elif kind == "member":
                facts["members"].add(int(f[2]))
            elif kind == "trader":
                facts["traders"][int(f[2])] = {"member": int(f[3]), "active": f[4] == "1", "role": f[5]}
            elif kind == "owns":
                facts["owns"][(f[2], int(f[3]))] = int(f[4])
            elif kind == "may":
                facts["may"][(f[2], int(f[3]))] = int(f[4])
            elif kind == "grant":
                facts["grants"][(f[2], f[3])] = True
            elif kind == "xinstrument":
                facts["xinstruments"][int(f[2])] = {"listed": f[3] == "1", "asset": f[4], "cash": f[5], "lot": int(f[6]), "ref": int(f[7])}
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
            ref.last_time = int(f[1])
            for p in f[2].split(","):
                if p:
                    ref.inst[int(p)]["opened"] = True
            # the terms the stream's instruments were opened with: collar, static and dynamic bands, interruption
            for t in (f[3].split(",") if len(f) > 3 and f[3] else []):
                i, c, st, dy, sx = (int(x) for x in t.split(":"))
                ref.inst[i].update(collar=c, static=st, dynamic=dy, secs=sx)
            sblocks, sorders, squeue = [], {}, {}
            sinst, slimits, skills = {}, {}, {}
            proposals = {}
            streams += 1
        elif f[0] == "C":
            now, role, cmd, want = int(f[1]), f[2], parse_cmd(f[3]), f[4]
            got = ref.submit(now, role, cmd)
            cmds += 1
            if got == "p:" and want.startswith("p:"):
                proposals[int(want[2:])] = (cmd, role)   # proposed: the reference applies it when it is approved
                got = want
            if got != want:
                errors.append(f"stream {streams} command {cmds} {f[3][:80]}: the book gave {want[:120]}, the reference {got[:120]}")
            bad = ref.conserved()
            if bad:
                errors.append(f"stream {streams}: conservation: {bad}")
        elif f[0] == "A":
            now, pid, want = int(f[1]), int(f[3]), f[4]
            cmds += 1
            if pid not in proposals:
                errors.append(f"stream {streams}: an approval of proposal {pid}, which the reference never saw proposed")
                continue
            cmd, maker = proposals.pop(pid)
            got = ref.approve(now, maker, cmd)
            if got != want:
                errors.append(f"stream {streams} approval of {cmd['k']}: the book gave {want[:120]}, the reference {got[:120]}")
        elif f[0] == "I":
            sinst[int(f[1])] = f[2:]
        elif f[0] == "U":
            slimits[int(f[1])] = [int(x) for x in f[2:]]
        elif f[0] == "K":
            skills[int(f[1])] = [int(x) for x in f[2:]]
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
                            str(o["stop"]), "1" if o["capacity"] == "agency" else "2", str(o["short"]), str(o["trail"]), str(o["member"]), str(o["trader"])]
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
            for i, row in sinst.items():
                x = ref.inst[i]
                mine = [x["phase"], str(x["last"]), str(x["close"]), str(x["until"]), str(x["endFrom"]), str(x["endTo"]), str(x["ref"])]
                if mine != row:
                    errors.append(f"stream {streams}: instrument {i}: book {row}, reference {mine}")
            if set(slimits) != set(ref.limits):
                errors.append(f"stream {streams}: limit rows for members {sorted(slimits)} in the book, {sorted(ref.limits)} in the reference")
            for m, row in slimits.items():
                mine = (ref.limits.get(m) or [0, 0, 0]) + [ref.used(m)]
                if mine != row:
                    errors.append(f"stream {streams}: member {m}'s limits and use: book {row}, reference {mine}")
            for kid, row in skills.items():
                kl = ref.kills.get(kid)
                mine = [kl["member"], kl["trader"], 1 if kl["active"] else 0] if kl else None
                if mine != row:
                    errors.append(f"stream {streams}: kill {kid}: book {row}, reference {mine}")
            if len(skills) != len(ref.kills):
                errors.append(f"stream {streams}: {len(skills)} kills in the book, {len(ref.kills)} in the reference")
            checkpoints += 1
            sblocks, sorders, squeue = [], {}, {}
            sinst, slimits, skills = {}, {}, {}
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
