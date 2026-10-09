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
import calendar as pycalendar
import datetime
import hashlib
import sys

MAXP = 2 ** 64 - 1
BOND_FACE = 100_000   # a bond's quantity unit in minor units of face (§28)
EPOCH = datetime.date(1970, 1, 1)
PPM = 1_000_000
STATUS = {"waiting": 1, "live": 2, "filled": 3, "cancelled": 4}
DAY_DOMAIN = "thebes.book.day.v1"   # the day's file (§15)
PHASE = {"closed": 1, "continuous": 2, "auction": 3, "closingAuction": 4, "tradeAtClose": 5, "halted": 6}
CALL = ("auction", "closingAuction")
DUAL = {"openInstrument", "halt", "resume", "revive", "setLimits", "setBlackout", "liftBlackout",
        "setClearing", "setMargin", "admitClearing", "designateClearing", "fundSkin", "declareDefault", "closeDefault",
        "setFeeSchedule", "registerMaker", "defineIndex", "reviewIndex", "corporateAction",
        "setTerms", "defineNav", "issueReceipt", "cancelReceipt", "setAttestors"}
E18, E9 = 10 ** 18, 10 ** 9
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


def civil(day):
    return EPOCH + datetime.timedelta(days=day)


def day_no(d):
    return (d - EPOCH).days


def months_back(d, months):
    """The date `months` whole months before `d`, a day past that month's end its last day (§28)."""
    y, m = divmod(d.year * 12 + d.month - 1 - months, 12)
    return datetime.date(y, m + 1, min(d.day, pycalendar.monthrange(y, m + 1)[1]))


def coupon_around(maturity, per_year, day):
    """The last coupon date on or before `day` and the next, stepping back from the maturity (§28)."""
    mat, step, nxt, k = civil(maturity), 12 // per_year, maturity, 1
    while True:
        c = day_no(months_back(mat, k * step))
        if c <= day:
            return c, nxt
        nxt, k = c, k + 1


def thirty_360(a, b):
    """ISDA 2006 §4.16(f), 30/360 bond basis: D1 31 becomes 30; D2 31 becomes 30 when D1 is then 30."""
    d1 = 30 if a.day == 31 else a.day
    d2 = 30 if b.day == 31 and d1 == 30 else b.day
    return 360 * (b.year - a.year) + 30 * (b.month - a.month) + (d2 - d1)


def accrued(t, qty, day):
    """§28: face × quantity × coupon × the fraction since the last coupon date, in one division, half-even."""
    last, nxt = coupon_around(t["maturity"], t["perYear"], day)
    if t["basis"] == 1:
        num, den = day - last, 365
    elif t["basis"] == 2:
        num, den = thirty_360(civil(last), civil(day)), 360
    else:
        num, den = day - last, t["perYear"] * (nxt - last)
    return 0 if num == 0 else Ref.half_even(BOND_FACE * qty * t["coupon"] * num, 10_000 * den)


def ceil_div(a, b):
    return -(-a // b)


# ── the settlement range (SPEC §19), written from the hashing rules of the kernel's MmrProof: a leaf is
# SHA-256(0x00 || leaf bytes), a node SHA-256(0x01 || left || right); the root bags the peaks from the highest. The
# range is computed here as perfect subtrees over the leaves, not by the book's incremental appends.
def h_leaf(b):
    return hashlib.sha256(b"\x00" + b).digest()


def h_node(l, r):
    return hashlib.sha256(b"\x01" + l + r).digest()


def subtree(leaves):
    if len(leaves) == 1:
        return leaves[0]
    half = len(leaves) // 2
    return h_node(subtree(leaves[:half]), subtree(leaves[half:]))


def mmr_root(leaves):
    peaks, off, n = [], 0, len(leaves)
    for h in range(63, -1, -1):
        if n >> h & 1:
            peaks.append(subtree(leaves[off:off + 2 ** h])); off += 2 ** h
    if not peaks:
        return bytes(32)
    acc = peaks[0]
    for p in peaks[1:]:
        acc = h_node(p, acc)
    return acc


def leg_bytes(kind, ledger_hex, frm, to, units, block):
    lb = bytes.fromhex(ledger_hex)
    return bytes([kind]) + bytes([len(lb)]) + lb + bytes(29 - len(lb)) + b"".join(x.to_bytes(8, "big") for x in (frm, to, units, block))


def statement_head(lines, block_of):
    """§23: the lines chained by SHA-256 from 32 zero bytes, each line its block, order, side, quantity, price, fee."""
    h = bytes(32)
    for (entry, order, side, q, p, fee) in lines:
        h = hashlib.sha256(h + b"".join(nat(x) for x in (block_of[entry], order, side, q, p, fee))).digest()
    return h


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
        self.external = {}    # (account, ledger) -> deposits and loans in, less withdrawals and returns (§19: the rest is legs)
        # the central counterparty (SPEC §18 to §21). Initial margin, the CCP's commitment and the custody's held shares
        # are not kept here: they are recounted from the open orders whenever they are needed.
        self.clearing = None  # the terms
        self.cm = {}          # member -> its clearing row
        self.desig = {}       # account -> its clearing member
        self.custody = {}     # (member, instrument) -> shares the CCP holds for it
        self.margin = {}      # instrument -> initial margin in basis points
        self.closeouts = {}   # close-out order -> the member it is for
        self.oblig = {}       # (member, cycle) -> [owed to it, owed by it]
        self.bought = {}      # (member, instrument, cycle) -> shares bought
        self.cycles = {}      # cycle -> [cut at, settle day, settled]
        self.cycle_no, self.settled, self.last_cut, self.skin = 1, 0, 0, 0
        self.legs = []        # [kind, ledger, from, to, units, the log entry that settled it]
        # fees, statements, reconciliations, makers (SPEC §22 to §25)
        self.fees = {}        # instrument -> [(account, ppm)]
        self.payable = {}     # levy account -> what the CCP owes it, in the order the rows were made
        self.fee_totals = {}  # (member, instrument) -> fees in the makers' open period
        self.stmt = {}        # member -> its open statement's lines (log entry, order, side, qty, price, fee), in row order
        self.stmt_seals = []  # (member, day, lines)
        self.last_stmt_day = 0
        self.recons = []      # (member, day, rows, matched, breaks, hash)
        self.makers = {}      # (member, instrument) -> the registration and its period's figures
        self.maker_days = []  # (member, instrument, day, present, session, met, rebate)
        self.last_maker_day = 0
        # indices and the breaker (SPEC §26, §27)
        self.indices = {}     # index -> its row
        self.constituents = {}  # (index, instrument) -> [shares, factor], in the order the rows were made
        self.path = []        # (index, log entry, level)
        self.prices_moved = False
        self.breaker_due = 0
        self.suspended_at = 0
        # instrument classes (SPEC §28 to §32)
        self.terms = {}         # instrument -> its class terms
        self.navs = {}          # fund -> [units, cash, iNAV]
        self.baskets = []       # (fund, instrument, shares), in row order
        self.nav_path = []      # (fund, log entry, iNAV)
        self.receipts = []      # [warehouse, instrument, account, qty, live, reference]
        self.retirements = []   # (account, instrument, qty, beneficiary)
        self.entitlements = []  # (account, instrument, rights, shares, paid)
        self.value_dates = {}   # bond -> its value date
        # derivatives (SPEC §33 to §35)
        self.attestors = []     # the three attestors' roles
        self.attestations = []  # (instrument, day, attestor, price), in row order
        self.positions = {}     # (account, instrument) -> [member, long, qty, mark, im], in the order the rows were made
        self.derivs = {}        # instrument -> its settlement state
        self.member_im = {}     # member -> its positions' margin

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
        if o["account"] not in self.desig:
            self.release(o["account"], self.ledger(o["instrument"], o["side"]), o["held"])
        o["held"] = 0; o["status"] = status

    def ledger_bytes(self, led):
        return bytes.fromhex(self.f["ledgers"][led])

    # ── fees (SPEC §22) ──
    def ppm(self, inst):
        return sum(x for _, x in self.fees.get(inst, []))

    def fee_on(self, inst, value):
        n, q = value * self.ppm(inst), 0
        if n == 0:
            return 0
        q, r = divmod(n, PPM)
        return q + 1 if 2 * r > PPM else q if 2 * r < PPM else q + q % 2

    def bound(self, inst, qty):
        """§28: the most a bond fill of `qty` can accrue: a period's interest at 31 days a month over 360, rounded up."""
        t = self.terms.get(inst)
        if not t or t["cls"] != "bond":
            return 0
        return ceil_div(BOND_FACE * qty * t["coupon"] * 31 * (12 // t["perYear"]), 10_000 * 360)

    def value_of(self, inst, price, qty):
        return price * qty * self.multiplier(inst) + self.bound(inst, qty)

    def open_value(self, o):
        return self.value_of(o["instrument"], o["price"], o["remaining"])

    def buy_hold(self, inst, price, qty):
        ppm = self.ppm(inst)
        clean = price * qty if ppm == 0 else price * qty + ceil_div(price * qty * ppm, PPM) + qty // self.inst[inst]["lot"]
        return clean + self.bound(inst, qty)

    def fee_parts(self, inst, fee):
        """The largest remainder over the levies' rates, ties to the first (the kernel's allocation, written again)."""
        levies = self.fees.get(inst, [])
        if not fee or not levies:
            return []
        total = sum(x for _, x in levies)
        base = [fee * x // total for _, x in levies]
        rem = [fee * x % total for _, x in levies]
        taken = [False] * len(levies)
        for _ in range(fee - sum(base)):
            best = None
            for k in range(len(levies)):
                if not taken[k] and (best is None or rem[k] > rem[best]):
                    best = k
            base[best] += 1; taken[best] = True
        return [(levies[k][0], base[k]) for k in range(len(levies))]

    def pay_fee(self, inst, account, led, fee):
        for to, part in self.fee_parts(inst, fee):
            if part:
                self.mv(account, to, led, part)
                self.leg(4, led, account, to, part)

    def owe_payable(self, inst, fee):
        for to, part in self.fee_parts(inst, fee):
            if part:
                self.payable[to] = self.payable.get(to, 0) + part

    def has_open_buy(self, inst):
        return any(self.orders[x]["side"] == "buy" for x in self.open_ids("inst", inst))

    # ── market makers (SPEC §25) ──
    def present_now(self, m):
        i = self.inst.get(m["instrument"])
        cont = bool(i) and i["phase"] == "continuous"
        if not cont or not m["bid"]:
            return cont, False
        b, a = self.orders.get(m["bid"]), self.orders.get(m["ask"])
        ok = (b is not None and a is not None and b["status"] == "live" and a["status"] == "live" and b["remaining"] >= m["minQty"]
              and a["remaining"] >= m["minQty"] and a["price"] > b["price"] and (a["price"] - b["price"]) * 20_000 <= m["maxSpread"] * (a["price"] + b["price"]))
        return cont, ok

    def accrue(self, now):
        for m in self.makers.values():
            dt = now - m["lastAt"] if m["lastAt"] and now > m["lastAt"] else 0
            if m["cont"]:
                m["session"] += dt
            if m["present"]:
                m["presentNs"] += dt
            m["cont"], m["present"] = self.present_now(m)
            m["lastAt"] = now

    def apply_all(self, now, c):
        """A block's command applied, then every maker's presence accrued to its time (SPEC §25)."""
        fx = self.clear(c["time"]) if c["k"] == "clear" else self.apply(now, c)
        if self.prices_moved:
            self.prices_moved = False
            self.recompute_indices()
            self.recompute_navs()
        self.accrue(now)
        return fx

    # ── indices (SPEC §26, §27), written from the text ──
    @staticmethod
    def half_even(n, d):
        q, r = divmod(n, d)
        return q + 1 if 2 * r > d else q if 2 * r < d else q + q % 2

    def mark(self, inst):
        i = self.inst[inst]
        return i["last"] or i["ref"]

    def cap_factors(self, m, cap):
        n = len(m)
        if cap == 0:
            return [E9] * n
        capped = [False] * n
        changed = True
        while changed:
            changed = False
            k = sum(capped); rest = sum(m[j] for j in range(n) if not capped[j])
            for j in range(n):
                if not capped[j] and rest > 0 and k * cap < 10_000 and m[j] * (10_000 - k * cap) > cap * rest:
                    capped[j] = True; changed = True
        k = sum(capped); rest = sum(m[j] for j in range(n) if not capped[j])
        return [E9 if (not capped[j] or m[j] == 0 or k * cap >= 10_000) else self.half_even(cap * rest * E9, m[j] * (10_000 - k * cap)) for j in range(n)]

    def put_constituents(self, index, cs, cap):
        factors = self.cap_factors([self.mark(i) * sh for (i, sh) in cs], cap)
        for (i, sh), f in zip(cs, factors):
            self.constituents[(index, i)] = [sh, f]

    def capitalisation(self, index):
        return sum(self.mark(i) * sh * f for (ix, i), (sh, f) in sorted(self.constituents.items()) if ix == index)

    def keep_level(self, index):
        x = self.indices[index]
        m = self.capitalisation(index)
        if m > 0 and x["level"] > 0:
            x["divisor"] = self.half_even(m * E18, x["level"])

    def recompute_indices(self):
        for index in sorted(self.indices):
            x = self.indices[index]
            m = self.capitalisation(index)
            level = self.half_even(m * E18, x["divisor"]) if x["divisor"] else 0
            if level != x["level"]:
                x["level"] = level
                self.path.append((index, len(self.log), level))
            move = abs(level - x["reference"])
            halt = x["tripped"] == 0 and move * 10_000 >= x["halt"] * x["reference"]
            susp = x["tripped"] < 2 and x["suspend"] > 0 and move * 10_000 >= x["suspend"] * x["reference"]
            if (halt or susp) and self.breaker_due == 0:
                self.breaker_due = index

    def to_tick(self, inst, p):
        t = tick_at(self.inst[inst]["bands"], p)
        return max(t, self.half_even(p, t) * t)

    def has_open_order(self, inst):
        return bool(self.open_ids("inst", inst))

    def append_log(self, now, fam, fx):
        """A block appended; the breaker's straight after it when an index crossed a threshold (§27)."""
        self.log.append((now, fam, fx))
        if self.breaker_due:
            c = {"k": "tripBreaker", "index": self.breaker_due}
            self.append_log(now, "tripBreaker", self.apply_all(now, c))

    # ── the central counterparty (SPEC §18 to §21) ──
    def is_ccp(self, a):
        return self.clearing is not None and self.clearing["ccp"] == a

    def ccp_cash(self):
        return self.b(self.clearing["ccp"], self.clearing["cash"])[0] if self.clearing else 0

    def committed(self):
        """The open clearing buys' value."""
        return sum(self.open_value(o) for o in (self.orders[x] for x in self.open_ids("all"))
                   if o["side"] == "buy" and o["account"] in self.desig and not self.derivative(o["instrument"]))

    def ccp_free(self):
        return max(0, self.ccp_cash() - self.committed())

    def im_orders(self, m):
        return sum(self.orders[x]["held"] for x in self.open_ids("member", m)
                   if (self.orders[x]["side"] == "buy" or self.derivative(self.orders[x]["instrument"])) and self.desig.get(self.orders[x]["account"]) == m)

    def custody_held(self, m, inst):
        held = 0
        for x in self.open_ids("inst", inst):
            o = self.orders[x]
            if o["side"] == "sell" and not self.derivative(inst) and (self.desig.get(o["account"]) == m or (self.is_ccp(o["account"]) and self.closeouts.get(x) == m)):
                held += o["held"]
        return held

    def mark(self, inst):
        i = self.inst[inst]
        return i["last"] or i["ref"]

    def variation(self, m):
        r = self.cm[m]
        owes = r["by"] + r["debt"]
        has = r["to"] + sum(q * self.mark(i) for (mm, i), q in self.custody.items() if mm == m and q > 0)
        return max(0, owes - has)

    def margin_refusal(self, m, add, drop, release, fund=True):
        r = self.cm[m]
        if fund and r["fund"] < r["req"]:
            return "FundShort"
        if self.im_orders(m) + add - drop + self.variation(m) + self.member_im.get(m, 0) > r["coll"] + r["credit"] - release:
            return "MarginShort"
        return None

    def sellable(self, m, inst, flagged):
        r = self.cm[m]
        free = self.custody.get((m, inst), 0) - self.custody_held(m, inst)
        return free + (self.b(r["settle"], self.inst[inst]["asset"])[0] if flagged else self.owned_free(r["settle"], inst))

    def sellable_free(self, account, inst):
        m = self.desig.get(account)
        return self.owned_free(account, inst) if m is None else self.sellable(m, inst, False)

    def clearing_refusal(self, m, inst, side, flagged, price, qty, held_before, value_before):
        r = self.cm[m]
        if r["status"] != 1:
            return "NotClearing"
        if self.inst[inst]["cash"] != self.clearing["cash"]:
            return "InvalidTerms"
        if self.derivative(inst):
            im = self.deriv_im(inst, side == "buy", qty, price)
            return self.margin_refusal(m, im, held_before, 0) if im > held_before else None
        if side == "buy":
            if inst not in self.margin:
                return "InvalidTerms"
            value = self.value_of(inst, price, qty)
            im = ceil_div(self.margin[inst] * value, 10_000)
            if im > held_before:
                e = self.margin_refusal(m, im, held_before, 0)
                if e:
                    return e
            if value > value_before and self.ccp_free() < value - value_before:
                return "LiquidityShort"
            return None
        if qty > held_before and qty - held_before > self.sellable(m, inst, flagged):
            return "InsufficientFunds"
        return None

    def mv(self, frm, to, led, x):
        a = self.b(frm, led)
        assert a[0] >= x, "a move beyond available"
        a[0] -= x; self.b(to, led)[0] += x

    def leg(self, kind, led, frm, to, units):
        if units:
            self.legs.append([kind, led, frm, to, units, len(self.log)])

    def pledge(self, m, inst, qty):
        free = self.custody.get((m, inst), 0) - self.custody_held(m, inst)
        if free >= qty:
            return
        self.mv(self.cm[m]["settle"], self.clearing["ccp"], self.inst[inst]["asset"], qty - free)
        self.leg(3, self.inst[inst]["asset"], self.cm[m]["settle"], self.clearing["ccp"], qty - free)
        self.custody[(m, inst)] = self.custody.get((m, inst), 0) + qty - free

    def owe(self, m, cycle, to, by):
        x = self.oblig.setdefault((m, cycle), [0, 0])
        x[0] += to; x[1] += by
        self.cm[m]["to"] += to; self.cm[m]["by"] += by

    def own_clearing(self, role, m):
        if m not in self.cm:
            return "NotClearing"
        me = self.trader_id(role)
        if not me or not self.f["traders"][me]["active"] or self.f["traders"][me]["member"] != m:
            return "NotYourAccount"
        return None

    def business(self, d):
        return (d + 3) % 7 not in self.f["restdays"] and d not in self.f["holidays"]

    def settlement_day(self, today, days):
        d = today
        for _ in range(days):
            d += 1
            while not self.business(d):
                d += 1
        return d

    def active(self):
        return [m for m in sorted(self.cm) if self.cm[m]["status"] == 1]

    def has_live(self, account):
        return bool(self.open_ids("acct", account))

    def account_empty(self, account):
        return all(v == [0, 0] for (a, _), v in self.bal.items() if a == account)

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
        return sum(self.open_value(self.orders[x]) for x in self.open_ids("member", member))

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
            d = self.derivs.get(c["instrument"])
            if d and c["open"] and d["runDay"]:
                return "InvalidTerms"
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
            if self.is_ccp(c["account"]):
                return "InvalidTerms"
            if c["amount"] == 0:
                return "InvalidTerms"
            if len(c["reference"]) != 64:   # hex of the 32 bytes
                return "InvalidTerms"
            if c["reference"] in self.refs:
                return "DuplicateReference"
            if self.receipt_ledger(c["ledger"]):
                return "InvalidTerms"
            return None
        if k == "withdraw":
            e = self.own_account(role, c["account"])
            if e:
                return e
            if self.f["accounts"][c["account"]]["member"] != c["member"]:
                return "InvalidTerms"
            if c["amount"] == 0:
                return "InvalidTerms"
            if self.is_ccp(c["account"]):
                return "InvalidTerms"
            if self.b(c["account"], c["ledger"])[0] < c["amount"]:
                return "InsufficientFunds"
            if self.receipt_ledger(c["ledger"]):
                return "InvalidTerms"
            return None
        if k == "placeOrder":
            e = self.own_account(role, c["account"])
            if e:
                return e
            if self.f["accounts"][c["account"]]["member"] != c["member"] or self.trader_id(role) != c["trader"]:
                return "NotYourAccount"
            if self.is_ccp(c["account"]):
                return "InvalidTerms"
            if self.f["may"][(role, c["instrument"])] != 0:
                return "MayNotTrade"
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if i["phase"] == "halted":
                return "InstrumentHalted"
            e = self.class_refusal(c["instrument"], self.today(now))
            if e:
                return e
            if self.derivative(c["instrument"]) and (c["account"] not in self.desig or c["short"]):
                return "InvalidTerms"
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
            if c["side"] == "sell" and not self.derivative(c["instrument"]):
                if c["short"]:
                    if kind not in ("limit", "ioc", "fok", "stopLimit") or c["price"] < self.short_floor(i):
                        return "ShortSalePrice"
                elif c["qty"] > self.sellable_free(c["account"], c["instrument"]):
                    return "ShortSaleNotFlagged"
            price = collar(c["side"], i["ref"], i["collar"], i["bands"]) if kind in ("market", "stop", "trailingStop") else c["price"]
            e = self.risk(c["member"], c["qty"], self.value_of(c["instrument"], price, c["qty"]), 0)
            if e:
                return e
            need = self.buy_hold(c["instrument"], price, c["qty"]) if c["side"] == "buy" else c["qty"]
            crossing = [] if kind in STOPS else self.crossing_own(c["account"], c["instrument"], c["side"], price)
            if crossing and c["smp"] == "cancelIncoming":
                return "SelfTradePrevented"
            cancelled_in = bool(crossing) and c["smp"] == "cancelBoth"
            if not cancelled_in:
                m = self.desig.get(c["account"])
                if m is None:
                    if self.b(c["account"], self.ledger(c["instrument"], c["side"]))[0] < need:
                        return "InsufficientFunds"
                else:
                    return self.clearing_refusal(m, c["instrument"], c["side"], c["short"], price, c["qty"], 0, 0)
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
                elif c["qty"] > o["remaining"] and c["qty"] - o["remaining"] > self.sellable_free(o["account"], o["instrument"]):
                    return "ShortSaleNotFlagged"
            e = self.risk(o["member"], c["qty"], self.value_of(o["instrument"], c["price"], c["qty"]), self.open_value(o))
            if e:
                return e
            need = self.buy_hold(o["instrument"], c["price"], c["qty"]) if o["side"] == "buy" else c["qty"]
            m = self.desig.get(o["account"])
            if m is None:
                if need > o["held"] and self.b(o["account"], self.ledger(o["instrument"], o["side"]))[0] < need - o["held"]:
                    return "InsufficientFunds"
            else:
                e = self.clearing_refusal(m, o["instrument"], o["side"], o["short"], c["price"], c["qty"], o["held"], self.open_value(o))
                if e:
                    return e
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
            if i["phase"] != "halted":
                return "InvalidTerms"
            if self.suspended_at and self.today(now) <= self.today(self.suspended_at):
                return "InvalidTerms"
            return None
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
                if not kl["trader"] and kl["member"] in self.cm and self.cm[kl["member"]]["status"] == 2:
                    return "InvalidTerms"
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
            if self.is_ccp(c["account"]):
                return "InvalidTerms"
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            if self.cls(c["instrument"]) == "receipt":
                return "InvalidTerms"
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
        return self.validate_clearing(now, role, c)

    def validate_clearing(self, now, role, c):
        """SPEC §18 to §21, in the Motoko book's order of checks."""
        k, t, accts = c["k"], self.clearing, self.f["accounts"]
        if k == "setClearing":
            a = accts.get(c["ccp"])
            if a is None:
                return "UnknownAccount"
            if a["member"] != c["ccpMember"]:
                return "InvalidTerms"
            if not a["open"]:
                return "AccountClosed"
            if c["days"] == 0 and c["secs"] == 0:
                return "InvalidTerms"
            if c["days"] > 10 or c["penalty"] > 10_000 or c["fundBps"] > 10_000 or c["deadline"] == 0:
                return "InvalidTerms"
            if t is not None:
                if (t["ccp"], t["ccpMember"], t["cash"]) != (c["ccp"], c["ccpMember"], c["cash"]):
                    return "InvalidTerms"
            elif c["ccp"] in self.desig or self.has_live(c["ccp"]) or not self.account_empty(c["ccp"]):
                return "InvalidTerms"
            return None
        if k == "setMargin":
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            return "InvalidTerms" if c["bps"] == 0 or c["bps"] > 10_000 else None
        if k == "admitClearing":
            if t is None or c["member"] not in self.f["members"] or c["member"] == t["ccpMember"] or c["member"] in self.cm or len(self.cm) >= 64:
                return "InvalidTerms"
            a = accts.get(c["settle"])
            if a is None:
                return "UnknownAccount"
            if a["member"] != c["member"]:
                return "InvalidTerms"
            return None if a["open"] else "AccountClosed"
        if k == "designateClearing":
            if c["member"] not in self.cm or self.cm[c["member"]]["status"] != 1:
                return "NotClearing"
            a = accts.get(c["account"])
            if a is None:
                return "UnknownAccount"
            if a["member"] != c["member"] or c["account"] in self.desig or self.has_live(c["account"]):
                return "InvalidTerms"
            return None
        if k in ("postCollateral", "withdrawCollateral", "contributeFund"):
            e = self.own_clearing(role, c["member"])
            if e:
                return e
            r = self.cm[c["member"]]
            if k == "contributeFund":
                if r["status"] != 1:
                    return "NotClearing"
                if c["amount"] == 0 or r["fund"] + c["amount"] > r["req"]:
                    return "InvalidTerms"
            else:
                if r["status"] == 2:
                    return "InvalidTerms"
                if k == "postCollateral" and c["amount"] == 0:
                    return "InvalidTerms"
            if k == "withdrawCollateral":
                if c["amount"] == 0 or c["amount"] > r["coll"]:
                    return "InvalidTerms"
                e = self.margin_refusal(c["member"], 0, 0, c["amount"], fund=False)
                if e:
                    return e
                return "LiquidityShort" if self.ccp_free() < c["amount"] else None
            return "InsufficientFunds" if self.b(r["settle"], t["cash"])[0] < c["amount"] else None
        if k == "cutCycle":
            if t is None or c["cycle"] != self.cycle_no:
                return "InvalidTerms"
            if any(d["runDay"] for d in self.derivs.values()):
                return "InvalidTerms"
            if t["days"] == 0:
                if c["settleDay"] != 0 or self.settled + 1 != self.cycle_no:
                    return "InvalidTerms"
                if self.last_cut and now < self.last_cut + t["secs"] * 1_000_000_000:
                    return "CycleNotDue"
            else:
                day = self.settlement_day(self.today(now), t["days"])
                if c["settleDay"] != day:
                    return "InvalidTerms"
                if self.cycle_no > 1 and self.cycles[self.cycle_no - 1][1] >= day:
                    return "InvalidTerms"
            return None
        if k == "settleCycle":
            if t is None or c["cycle"] != self.settled + 1 or c["cycle"] >= self.cycle_no:
                return "InvalidTerms"
            sd = self.cycles[c["cycle"]][1]
            return "CycleNotDue" if sd and self.today(now) < sd else None
        if k == "closeOut":
            if t is None:
                return "InvalidTerms"
            if c["member"] not in self.cm:
                return "NotClearing"
            r = self.cm[c["member"]]
            if r["status"] != 2 and (r["debt"] == 0 or r["fails"] < t["deadline"]):
                return "InvalidTerms"
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            i = self.inst[c["instrument"]]
            if i["phase"] != "continuous":
                return "InvalidTerms"
            free = self.custody.get((c["member"], c["instrument"]), 0) - self.custody_held(c["member"], c["instrument"])
            return "InvalidTerms" if free // i["lot"] == 0 else None
        if k == "callFund":
            return "InvalidTerms" if t is None or not self.active() else None
        if k == "fundSkin":
            if t is None:
                return "InvalidTerms"
            a = accts.get(c["account"])
            if a is None:
                return "UnknownAccount"
            if a["member"] != t["ccpMember"] or c["account"] == t["ccp"] or c["amount"] == 0:
                return "InvalidTerms"
            return "InsufficientFunds" if self.b(c["account"], t["cash"])[0] < c["amount"] else None
        if k == "declareDefault":
            if c["member"] not in self.cm or self.cm[c["member"]]["status"] != 1:
                return "NotClearing"
            return None if 1 <= len(c["reason"].encode()) <= 256 else "InvalidTerms"
        if k == "closeDefault":
            if c["member"] not in self.cm:
                return "NotClearing"
            r = self.cm[c["member"]]
            if r["status"] != 2 or self.open_ids("member", c["member"]):
                return "InvalidTerms"
            if any(q > 0 for (mm, _), q in self.custody.items() if mm == c["member"]):
                return "InvalidTerms"
            return "InvalidTerms" if r["to"] or r["by"] else None
        return self.validate_markets(now, role, c)

    def validate_markets(self, now, role, c):
        """SPEC §22 to §25, in the Motoko book's order of checks."""
        k, accts = c["k"], self.f["accounts"]
        if k == "setFeeSchedule":
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            lv = c["levies"]
            if not 1 <= len(lv) <= 4:
                return "InvalidTerms"
            seen = []
            for (a, ppm) in lv:
                if ppm == 0:
                    return "InvalidTerms"
                if a not in accts:
                    return "UnknownAccount"
                if not accts[a]["open"]:
                    return "AccountClosed"
                if self.is_ccp(a) or a in self.desig or a in seen:
                    return "InvalidTerms"
                seen.append(a)
            if sum(x for _, x in lv) > 100_000 or self.has_open_buy(c["instrument"]):
                return "InvalidTerms"
            return None
        if k in ("sealStatements", "settleMakers"):
            last = self.last_stmt_day if k == "sealStatements" else self.last_maker_day
            return "InvalidTerms" if c["day"] != self.today(now) or c["day"] <= last else None
        if k == "reconcileMember":
            me = self.trader_id(role)
            if not me or not self.f["traders"][me]["active"] or self.f["traders"][me]["member"] != c["member"]:
                return "NotYourAccount"
            if c["day"] > self.today(now) or not 1 <= len(c["balances"]) <= 64:
                return "InvalidTerms"
            seen = set()
            for (a, led, _) in c["balances"]:
                if a not in accts:
                    return "UnknownAccount"
                if accts[a]["member"] != c["member"]:
                    return "NotYourAccount"
                if (a, led) in seen:
                    return "InvalidTerms"
                seen.add((a, led))
            return None
        if k == "registerMaker":
            if c["member"] not in self.f["members"]:
                return "InvalidTerms"
            if not self.f["makers"].get(c["member"]):
                return "NotAMaker"
            if c["instrument"] not in self.inst or not self.inst[c["instrument"]]["opened"]:
                return "UnknownInstrument"
            if (c["member"], c["instrument"]) in self.makers or len(self.makers) >= 32:
                return "InvalidTerms"
            if c["maxSpread"] == 0 or c["maxSpread"] > 10_000 or c["minQty"] == 0 or c["presence"] > 10_000 or c["rebate"] > 10_000:
                return "InvalidTerms"
            return None
        if k in ("quote", "massQuote"):
            return self.quote_refusal(now, role, c)
        if k in ("defineIndex", "reviewIndex"):
            if k == "defineIndex":
                if not 1 <= c["index"] <= 8 or c["index"] in self.indices or c["base"] == 0:
                    return "InvalidTerms"
            elif c["index"] not in self.indices:
                return "InvalidTerms"
            cs = c["constituents"]
            if not 1 <= len(cs) <= 50:
                return "InvalidTerms"
            for n, (i, sh) in enumerate(cs):
                if i not in self.inst or not self.inst[i]["opened"]:
                    return "UnknownInstrument"
                if sh == 0 or any(cs[j][0] == i for j in range(n)):
                    return "InvalidTerms"
            if k == "defineIndex":
                if c["cap"] > 10_000 or (c["cap"] and c["cap"] * len(cs) <= 10_000):
                    return "InvalidTerms"
                if c["halt"] == 0 or c["halt"] > 10_000 or (c["suspend"] and (c["suspend"] <= c["halt"] or c["suspend"] > 10_000)):
                    return "InvalidTerms"
            else:
                mine = {i for (ix, i) in self.constituents if ix == c["index"]}
                if mine != {i for i, _ in cs} or len(mine) != len(cs):
                    return "InvalidTerms"
            return None
        if k == "corporateAction":
            i = self.inst.get(c["instrument"])
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if i["phase"] != "closed" or self.has_open_order(c["instrument"]) or len(c["reference"]) != 64:
                return "InvalidTerms"
            if c["kind"] == "split":
                return "InvalidTerms" if c["num"] == 0 or c["den"] == 0 or c["num"] == c["den"] else None
            return "InvalidTerms" if c["amount"] == 0 or c["amount"] >= self.mark(c["instrument"]) else None
        if k == "tripBreaker":
            return "ClearNotSubmittable"
        return self.validate_classes(now, role, c)

    # ── instrument classes (SPEC §28 to §32), written from the text ──
    def cls(self, inst):
        t = self.terms.get(inst)
        return t["cls"] if t else None

    def receipt_ledger(self, led):
        return any(i["opened"] and i["asset"] == led and self.cls(n) == "receipt" for n, i in self.inst.items())

    def class_refusal(self, inst, today):
        t = self.terms.get(inst)
        if t and t["cls"] == "bond":
            if today >= t["maturity"]:
                return "InvalidTerms"
            v = self.value_dates.get(inst, 0)
            if v == 0 or v < today or v >= t["maturity"]:
                return "InvalidTerms"
        if t and t["cls"] == "right" and today > t["deadline"]:
            return "InvalidTerms"
        if t and t["cls"] in ("future", "option") and (today > t["expiry"] or self.derivs[inst]["expired"]):
            return "InvalidTerms"
        return None

    # ── derivatives (SPEC §33 to §35), written from the text ──
    def derivative(self, inst):
        return self.cls(inst) in ("future", "option")

    def multiplier(self, inst):
        return self.terms[inst]["multiplier"] if self.derivative(inst) else 1

    def level(self, index):
        x = self.indices.get(index)
        return x["level"] if x else 0

    def attested(self, inst, day):
        """§33: the median of the three attestors' prices for the day, when all three attested."""
        got = {n: pr for (i, d, n, pr) in self.attestations if i == inst and d == day}
        return sorted(got.values())[1] if len(got) == 3 else None

    @staticmethod
    def intrinsic(t, u):
        return max(u - t["strike"], 0) if t["call"] else max(t["strike"] - u, 0)

    def deriv_im(self, inst, long, qty, price):
        """§34, §35: a future's notional × its rate rounded up; an option buyer's premium; a writer's premium and the greater
        of a × the index less what it is out of the money and b × the index, × contracts × multiplier, rounded up."""
        t = self.terms[inst]
        if t["cls"] == "future":
            return ceil_div(qty * price * t["multiplier"] * t["imBps"], 10_000)
        if long:
            return qty * price * t["multiplier"]
        u = self.level(t["index"])
        otm = max(t["strike"] - u, 0) if t["call"] else max(u - t["strike"], 0)
        risk = max(max(t["aBps"] * u - otm * 10_000, 0), t["bBps"] * (u if t["call"] else t["strike"]))
        return ceil_div(qty * t["multiplier"] * (price * 10_000 + risk), 10_000)

    def move_position(self, account, member, inst, buy, qty):
        """§34: a fill netted into the account's position, marked at the contract's mark; the margins follow."""
        mark = self.derivs[inst]["mark"]
        p = self.positions.setdefault((account, inst), [member, buy, 0, mark, 0])
        long, q = p[1], p[2]
        if q == 0:
            long, q = buy, qty
        elif long == buy:
            q += qty
        elif q >= qty:
            q -= qty
        else:
            long, q = buy, qty - q
        im = self.deriv_im(inst, long, q, mark) if q else 0
        self.member_im[member] = self.member_im.get(member, 0) + im - p[4]
        p[1], p[2], p[3], p[4] = long, q, mark, im

    def mover(self, role, c):
        """A trader acting on its own member's account, as an order's sender (§31, §32)."""
        e = self.own_account(role, c["account"])
        if e:
            return e
        if self.f["accounts"][c["account"]]["member"] != c["member"] or self.trader_id(role) != c["trader"]:
            return "NotYourAccount"
        return None

    def validate_classes(self, now, role, c):
        k, accts = c["k"], self.f["accounts"]
        today = self.today(now)
        if k == "setTerms":
            inst = c["instrument"]; i = self.inst.get(inst)
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if inst in self.terms or i["phase"] != "closed" or self.has_open_order(inst):
                return "InvalidTerms"
            t = c["terms"]
            if t["cls"] == "bond":
                if t["coupon"] > 10_000 or t["perYear"] not in (1, 2, 4, 12):
                    return "InvalidTerms"
                if t["maturity"] <= today or t["maturity"] > today + 50 * 366 or t["settleDays"] > 5:
                    return "InvalidTerms"
            elif t["cls"] == "receipt":
                ws = t["warehouses"]
                if not 1 <= len(ws) <= 8 or 0 in ws or len(set(ws)) != len(ws):
                    return "InvalidTerms"
                if self.deposited.get(i["asset"], 0) != 0:
                    return "InvalidTerms"
                for n, o in self.inst.items():
                    if n != inst and o["opened"] and (o["asset"] == i["asset"] or o["cash"] == i["asset"]):
                        return "InvalidTerms"
            elif t["cls"] == "certificate":
                if len(t["registry"]) != 64:
                    return "InvalidTerms"
            elif t["cls"] in ("future", "option"):
                if t["index"] not in self.indices or t["multiplier"] == 0 or t["expiry"] < today:
                    return "InvalidTerms"
                if not self.clearing or i["cash"] != self.clearing["cash"]:
                    return "InvalidTerms"
                if t["cls"] == "future" and not 1 <= t["imBps"] <= 10_000:
                    return "InvalidTerms"
                if t["cls"] == "option" and (t["strike"] == 0 or t["bBps"] == 0 or t["bBps"] > t["aBps"] or t["aBps"] > 10_000):
                    return "InvalidTerms"
            else:
                u = self.inst.get(t["underlying"])
                if t["underlying"] == inst or u is None or not u["opened"]:
                    return "InvalidTerms"
                if t["price"] == 0 or t["num"] == 0 or t["den"] == 0 or t["deadline"] < today:
                    return "InvalidTerms"
                if t["issuer"] not in accts:
                    return "UnknownAccount"
                if not accts[t["issuer"]]["open"] or self.is_ccp(t["issuer"]) or accts[t["issuer"]]["member"] != t["issuerMember"]:
                    return "InvalidTerms"
            return None
        if k == "defineNav":
            inst = c["instrument"]
            if inst not in self.inst or not self.inst[inst]["opened"]:
                return "UnknownInstrument"
            if inst in self.navs or c["units"] == 0 or not 1 <= len(c["constituents"]) <= 50:
                return "InvalidTerms"
            for n, (b, sh) in enumerate(c["constituents"]):
                if b == inst:
                    return "InvalidTerms"
                if b not in self.inst or not self.inst[b]["opened"]:
                    return "UnknownInstrument"
                if sh == 0 or any(c["constituents"][j][0] == b for j in range(n)):
                    return "InvalidTerms"
            return None
        if k == "issueReceipt":
            inst = c["instrument"]; i = self.inst.get(inst)
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if self.cls(inst) != "receipt" or c["warehouse"] not in self.terms[inst]["warehouses"]:
                return "InvalidTerms"
            if c["account"] not in accts:
                return "UnknownAccount"
            if accts[c["account"]]["member"] != c["member"]:
                return "InvalidTerms"
            if not accts[c["account"]]["open"]:
                return "AccountClosed"
            if self.is_ccp(c["account"]):
                return "InvalidTerms"
            if c["qty"] == 0 or c["qty"] % i["lot"]:
                return "NotALot"
            if len(c["reference"]) != 64:
                return "InvalidTerms"
            if any(r[5] == c["reference"] for r in self.receipts):
                return "DuplicateReference"
            return None
        if k == "cancelReceipt":
            if not 1 <= c["receipt"] <= len(self.receipts) or not self.receipts[c["receipt"] - 1][4]:
                return "InvalidTerms"
            r = self.receipts[c["receipt"] - 1]
            if c["account"] not in accts:
                return "UnknownAccount"
            if accts[c["account"]]["member"] != c["member"]:
                return "InvalidTerms"
            if self.b(c["account"], self.inst[r[1]]["asset"])[0] < r[3]:
                return "InsufficientFunds"
            return None
        if k in ("retire", "exercise"):
            e = self.mover(role, c)
            if e:
                return e
            inst = c["instrument"]; i = self.inst.get(inst)
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if k == "retire":
                if self.cls(inst) != "certificate" or c["qty"] == 0 or len(c["beneficiary"]) != 64:
                    return "InvalidTerms"
                return "InsufficientFunds" if self.b(c["account"], i["asset"])[0] < c["qty"] else None
            t = self.terms.get(inst)
            if not t or t["cls"] != "right" or today > t["deadline"]:
                return "InvalidTerms"
            if c["qty"] == 0 or c["qty"] % t["den"] or c["account"] == t["issuer"]:
                return "InvalidTerms"
            if self.b(c["account"], i["asset"])[0] < c["qty"]:
                return "InsufficientFunds"
            pay = t["price"] * (c["qty"] // t["den"]) * t["num"]
            return "InsufficientFunds" if self.b(c["account"], i["cash"])[0] < pay else None
        if k == "setAttestors":
            a = c["attestors"]
            return "InvalidTerms" if len(a) != 3 or len(set(a)) != 3 else None
        if k == "attestPrice":
            if not 1 <= c["attestor"] <= len(self.attestors) or self.attestors[c["attestor"] - 1] != role:
                return "InvalidTerms"
            if not self.derivative(c["instrument"]) or c["day"] != today:
                return "InvalidTerms"
            if any(i == c["instrument"] and d == c["day"] and n == c["attestor"] for (i, d, n, _) in self.attestations) or c["price"] == 0:
                return "InvalidTerms"
            return None
        if k == "settleDerivatives":
            inst = c["instrument"]
            if inst not in self.inst or not self.inst[inst]["opened"]:
                return "UnknownInstrument"
            d = self.derivs.get(inst)
            if d is None or c["day"] != today or d["expired"] or c["day"] <= d["settled"]:
                return "InvalidTerms"
            if d["runDay"] and d["runDay"] != c["day"]:
                return "InvalidTerms"
            t = self.terms[inst]
            if c["day"] > t["expiry"] or self.inst[inst]["phase"] != "closed" or not 1 <= c["limit"] <= 500:
                return "InvalidTerms"
            if c["day"] == t["expiry"]:
                return "InvalidTerms" if self.level(t["index"]) == 0 else None
            if not d["runDay"] and self.attested(inst, c["day"]) is None:
                return "InvalidTerms"
            return None
        if k == "valueDate":
            t = self.terms.get(c["instrument"])
            if not t or t["cls"] != "bond":
                return "InvalidTerms"
            if c["day"] != self.settlement_day(today, t["settleDays"]) or c["day"] >= t["maturity"]:
                return "InvalidTerms"
            return None
        raise ValueError(k)

    def quote_refusal(self, now, role, c):
        e = self.own_account(role, c["account"])
        if e:
            return e
        if self.f["accounts"][c["account"]]["member"] != c["member"] or self.trader_id(role) != c["trader"]:
            return "NotYourAccount"
        if self.is_ccp(c["account"]) or c["account"] in self.desig:
            return "InvalidTerms"
        sides = c["sides"]
        if not 1 <= len(sides) <= 16:
            return "InvalidTerms"
        if self.killed(c["member"], c["trader"]):
            return "Killed"
        need = freed = 0
        net = 0
        cash = None
        for n, q in enumerate(sides):
            inst = q["instrument"]
            if any(sides[j]["instrument"] == inst for j in range(n)):
                return "InvalidTerms"
            mk = self.makers.get((c["member"], inst))
            if mk is None:
                return "NotAMaker"
            if self.f["may"][(role, inst)] != 0:
                return "MayNotTrade"
            i = self.inst.get(inst)
            if i is None or not i["opened"]:
                return "UnknownInstrument"
            if i["phase"] == "halted":
                return "InstrumentHalted"
            e = self.class_refusal(inst, self.today(now))
            if e:
                return e
            if self.derivative(inst):
                return "InvalidTerms"
            if self.blacked_out(c["account"], inst, now):
                return "InsiderBlackout"
            if q["qty"] == 0 or q["qty"] % i["lot"]:
                return "NotALot"
            if not 1 <= len(q["ref"].encode()) <= 18:
                return "InvalidTerms"
            for sfx in (".b", ".a"):
                if (c["account"], q["ref"] + sfx) in self.refs_used:
                    return "DuplicateClientRef"
            for p in (q["bid"], q["ask"]):
                if not on_tick(i["bands"], p):
                    return "PriceOffTick"
                if not within(p, i["ref"], i["static"]):
                    return "PriceOutsideBand"
            if q["bid"] >= q["ask"]:
                return "InvalidPrice"
            bh = ah = ov = 0
            if mk["account"] == c["account"]:
                for oid, which in ((mk["bid"], "b"), (mk["ask"], "a")):
                    o = self.orders.get(oid)
                    if o is not None and self.liveish(o):
                        if which == "b":
                            bh = o["held"]
                        else:
                            ah = o["held"]
                        ov += self.open_value(o)
            value = self.value_of(inst, q["bid"], q["qty"]) + self.value_of(inst, q["ask"], q["qty"])
            e = self.risk(c["member"], q["qty"], value, ov)
            if e:
                return e
            net += value - ov
            if c["member"] in self.limits:
                cr = self.limits[c["member"]][2]
                if cr and self.used(c["member"]) + net > cr:
                    return "RiskLimit"
            if cash is not None and cash != i["cash"]:
                return "InvalidTerms"
            cash = i["cash"]
            need += self.buy_hold(inst, q["bid"], q["qty"]); freed += bh
            if q["qty"] > self.owned_free(c["account"], inst) + ah:
                return "ShortSaleNotFlagged"
        if cash is not None and need > self.b(c["account"], cash)[0] + freed:
            return "InsufficientFunds"
        return None

    def enter_quotes(self, now, c, tag):
        fx = [tag, len(c["sides"])]
        for q in c["sides"]:
            mk = self.makers[(c["member"], q["instrument"])]
            cancelled = []
            for oid in (mk["bid"], mk["ask"]):
                o = self.orders.get(oid)
                if o is not None and self.liveish(o):
                    self.close(oid, "cancelled"); cancelled.append(oid)
            eff = []
            for side, price, sfx in (("buy", q["bid"], ".b"), ("sell", q["ask"], ".a")):
                e = self.apply(now, {"k": "placeOrder", "account": c["account"], "instrument": q["instrument"], "side": side, "kind": "limit", "qty": q["qty"],
                                     "price": price, "stop": 0, "peak": 0, "validity": "day", "gtd": 0, "smp": "cancelResting", "oco": 0, "capacity": "principal",
                                     "short": 0, "ref": q["ref"] + sfx, "trail": 0, "member": c["member"], "trader": c["trader"]})
                eff.append(e)
            for e in eff:
                cancelled += e[5:]
            mk.update(account=c["account"], bid=eff[0][1], ask=eff[1][1])
            fx += [q["instrument"], len(cancelled)] + cancelled
            for e in eff:
                fx += e[1:5]
        return fx

    # ── apply ──
    def cancel_oco(self, o, out):
        if o["oco"] and self.liveish(self.orders[o["oco"]]):
            self.close(o["oco"], "cancelled")
            out.append(o["oco"])

    def apply(self, now, c):
        k = c["k"]
        if k == "openInstrument":
            # an instrument opened within a stream (the classes', §28): its terms from the command, closed
            bands = [tuple(int(x) for x in t.split(":")) for t in str(c["bands"]).split(",") if t]
            self.inst[c["instrument"]] = dict(lot=c["lot"], ref=c["price"], collar=c["collar"], bands=bands, asset=c["asset"], cash=c["cash"],
                                              static=c["static"], dynamic=c["dynamic"], secs=c["secs"], phase="closed", last=0, close=0,
                                              endFrom=0, endTo=0, until=0, opened=True)
            return [1, c["instrument"]]
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
            self.external[(c["account"], led)] = self.external.get((c["account"], led), 0) + c["qty"]
            self.borrows[(c["account"], c["instrument"])] = self.borrows.get((c["account"], c["instrument"]), 0) + c["qty"]
            return [25, c["account"], c["qty"]]
        if k == "returnBorrow":
            self.b(c["account"], self.inst[c["instrument"]]["asset"])[0] -= c["qty"]
            self.deposited[self.inst[c["instrument"]]["asset"]] -= c["qty"]
            self.external[(c["account"], self.inst[c["instrument"]]["asset"])] = self.external.get((c["account"], self.inst[c["instrument"]]["asset"]), 0) - c["qty"]
            self.borrows[(c["account"], c["instrument"])] -= c["qty"]
            return [26, c["account"], c["qty"]]
        if k == "sealDay":
            rows, h = self.seal(c["day"])
            return [22, c["day"], rows] + list(h)
        if k == "setReference":
            self.inst[c["instrument"]]["ref"] = c["price"]
            self.prices_moved = True
            return [3, c["instrument"]]
        if k == "deposit":
            self.refs.add(c["reference"])
            self.b(c["account"], c["ledger"])[0] += c["amount"]
            self.deposited[c["ledger"]] = self.deposited.get(c["ledger"], 0) + c["amount"]
            self.external[(c["account"], c["ledger"])] = self.external.get((c["account"], c["ledger"]), 0) + c["amount"]
            return [4, c["account"], c["amount"]]
        if k == "withdraw":
            self.b(c["account"], c["ledger"])[0] -= c["amount"]
            self.deposited[c["ledger"]] -= c["amount"]
            self.external[(c["account"], c["ledger"])] = self.external.get((c["account"], c["ledger"]), 0) - c["amount"]
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
            need = self.buy_hold(c["instrument"], price, c["qty"]) if c["side"] == "buy" else c["qty"]
            status = "cancelled" if cancelled_in else ("waiting" if stop else "live")
            held = 0
            if not cancelled_in:
                m = self.desig.get(c["account"])
                if m is None:
                    self.hold(c["account"], self.ledger(c["instrument"], c["side"]), need); held = need
                elif self.derivative(c["instrument"]):
                    held = self.deriv_im(c["instrument"], c["side"] == "buy", c["qty"], price)
                elif c["side"] == "buy":
                    held = ceil_div(self.margin.get(c["instrument"], 0) * self.value_of(c["instrument"], price, c["qty"]), 10_000)
                else:
                    self.pledge(m, c["instrument"], c["qty"]); held = c["qty"]
            self.orders[oid] = dict(account=c["account"], instrument=c["instrument"], side=c["side"], kind=kind, qty=c["qty"], remaining=c["qty"],
                                    price=price, stop=c["stop"], peak=c["peak"], validity=c["validity"], gtd=c["gtd"], ref=c["ref"], oco=c["oco"],
                                    smp=c["smp"], trail=c["trail"], capacity=c["capacity"], short=c["short"], member=c["member"], trader=c["trader"], prio=now, key=order_key(c["account"], c["side"], price, c["qty"], c["ref"]), status=status,
                                    held=held, filled=0)
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
            need = self.buy_hold(o["instrument"], c["price"], c["qty"]) if o["side"] == "buy" else c["qty"]
            m = self.desig.get(o["account"])
            if m is None:
                if need > o["held"]:
                    self.hold(o["account"], led, need - o["held"])
                else:
                    self.release(o["account"], led, o["held"] - need)
                held = need
            elif self.derivative(o["instrument"]):
                held = self.deriv_im(o["instrument"], o["side"] == "buy", c["qty"], c["price"])
            elif o["side"] == "buy":
                held = ceil_div(self.margin.get(o["instrument"], 0) * self.value_of(o["instrument"], c["price"], c["qty"]), 10_000)
            else:
                if c["qty"] > o["held"]:
                    self.pledge(m, o["instrument"], c["qty"] - o["held"])
                held = c["qty"]
            o["qty"] = o["filled"] + c["qty"]; o["remaining"] = c["qty"]; o["price"] = c["price"]; o["held"] = held
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
        return self.apply_clearing(now, c)

    def apply_clearing(self, now, c):
        k, t = c["k"], self.clearing
        if k == "setClearing":
            self.clearing = {x: c[x] for x in ("ccp", "ccpMember", "cash", "secs", "days", "penalty", "deadline", "fundBps", "floor")}
            return [27, c["ccp"]]
        if k == "setMargin":
            self.margin[c["instrument"]] = c["bps"]
            return [28, c["instrument"], c["bps"]]
        if k == "admitClearing":
            self.cm[c["member"]] = dict(settle=c["settle"], credit=c["credit"], coll=0, fund=0, req=0, to=0, by=0, debt=0, fails=0, peak=0, status=1)
            return [29, c["member"]]
        if k == "designateClearing":
            self.desig[c["account"]] = c["member"]
            return [30, c["account"], c["member"]]
        if k == "postCollateral":
            self.mv(self.cm[c["member"]]["settle"], t["ccp"], t["cash"], c["amount"]); self.cm[c["member"]]["coll"] += c["amount"]
            self.leg(3, t["cash"], self.cm[c["member"]]["settle"], t["ccp"], c["amount"])
            return [31, c["member"], c["amount"]]
        if k == "withdrawCollateral":
            self.mv(t["ccp"], self.cm[c["member"]]["settle"], t["cash"], c["amount"]); self.cm[c["member"]]["coll"] -= c["amount"]
            self.leg(3, t["cash"], t["ccp"], self.cm[c["member"]]["settle"], c["amount"])
            return [32, c["member"], c["amount"]]
        if k == "cutCycle":
            self.cycles[c["cycle"]] = [now, c["settleDay"], False]
            self.cycle_no += 1; self.last_cut = now
            return [33, c["cycle"], c["settleDay"]]
        if k == "settleCycle":
            return self.settle_cycle(c["cycle"])
        if k == "closeOut":
            i = self.inst[c["instrument"]]
            m = c["member"]
            q = (self.custody.get((m, c["instrument"]), 0) - self.custody_held(m, c["instrument"])) // i["lot"] * i["lot"]
            oid = self.next; self.next += 1
            price = collar("sell", i["ref"], i["collar"], i["bands"])
            ref = "closeout " + str(oid)
            self.closeouts[oid] = m
            self.hold(t["ccp"], i["asset"], q)
            self.orders[oid] = dict(account=t["ccp"], instrument=c["instrument"], side="sell", kind="market", qty=q, remaining=q, price=price, stop=0, peak=0,
                                    validity="day", gtd=0, ref=ref, oco=0, smp="cancelResting", trail=0, capacity="principal", short=0,
                                    member=t["ccpMember"], trader=0, prio=now, key=order_key(t["ccp"], "sell", price, q, ref), status="live", held=q, filled=0)
            self.refs_used.add((t["ccp"], ref))
            self.track(oid, self.orders[oid])
            self.limits.setdefault(t["ccpMember"], [0, 0, 0])
            self.due.add(c["instrument"])
            if self.batch == 0:
                self.batch = now
            return [35, oid, STATUS["live"], price, q, m]
        if k == "callFund":
            act = self.active()
            share = ceil_div(t["floor"], len(act))
            fx = [36, len(act)]
            for m in act:
                req = max(share, ceil_div(t["fundBps"] * self.cm[m]["peak"], 10_000))
                self.cm[m]["req"] = req
                fx += [m, req]
            return fx
        if k == "contributeFund":
            self.mv(self.cm[c["member"]]["settle"], t["ccp"], t["cash"], c["amount"]); self.cm[c["member"]]["fund"] += c["amount"]
            self.leg(3, t["cash"], self.cm[c["member"]]["settle"], t["ccp"], c["amount"])
            return [37, c["member"], c["amount"]]
        if k == "fundSkin":
            self.mv(c["account"], t["ccp"], t["cash"], c["amount"]); self.skin += c["amount"]
            self.leg(3, t["cash"], c["account"], t["ccp"], c["amount"])
            return [38, c["account"], c["amount"]]
        if k == "declareDefault":
            self.cm[c["member"]]["status"] = 2
            kid = 0
            if not self.active_kill(member=c["member"]):
                kid = len(self.kills) + 1
                self.kills[kid] = {"member": c["member"], "trader": 0, "active": True}
            return [39, c["member"], kid]
        if k == "closeDefault":
            return self.close_default(c["member"])
        if k == "setFeeSchedule":
            self.fees[c["instrument"]] = list(c["levies"])
            return [41, c["instrument"], len(c["levies"])]
        if k == "sealStatements":
            sealed = []
            for m, lines in self.stmt.items():
                if lines:
                    self.stmt_seals.append((m, c["day"], list(lines)))
                    sealed.append((m, len(lines)))
                    self.stmt[m] = []
            self.last_stmt_day = c["day"]
            return [42, c["day"], len(sealed)] + [x for sl in sealed for x in sl]
        if k == "reconcileMember":
            w = bytearray(text("thebes.book.reconciliation.v1")) + nat(c["member"]) + nat(c["day"]) + nat(len(c["balances"]))
            matched = 0
            for (a, led, amount) in c["balances"]:
                book = sum(self.bal.get((a, led), [0, 0]))
                matched += book == amount
                raw = self.ledger_bytes(led)
                w += nat(a) + bytes([len(raw)]) + raw + nat(amount) + nat(book)
            rid = len(self.recons) + 1
            self.recons.append((c["member"], c["day"], len(c["balances"]), matched, len(c["balances"]) - matched, hashlib.sha256(bytes(w)).hexdigest()))
            return [43, rid, matched, len(c["balances"]) - matched]
        if k == "registerMaker":
            self.makers[(c["member"], c["instrument"])] = dict(member=c["member"], instrument=c["instrument"], maxSpread=c["maxSpread"], minQty=c["minQty"],
                                                               presence=c["presence"], rebate=c["rebate"], account=0, bid=0, ask=0, cont=False, present=False,
                                                               lastAt=now, presentNs=0, session=0)
            return [44, len(self.makers)]
        if k in ("quote", "massQuote"):
            return self.enter_quotes(now, c, 45 if k == "quote" else 46)
        if k == "settleMakers":
            self.accrue(now)
            fx = [47, c["day"], len(self.makers)]
            for (mem, inst), m in self.makers.items():
                met = m["session"] > 0 and m["presentNs"] * 10_000 >= m["presence"] * m["session"]
                fees = self.fee_totals.get((mem, inst), 0)
                q_, r_ = divmod(fees * m["rebate"], 10_000)
                due = q_ + 1 if 2 * r_ > 10_000 else q_ if 2 * r_ < 10_000 else q_ + q_ % 2
                rebate = 0
                levies = self.fees.get(inst, [])
                cash = self.inst[inst]["cash"]
                if met and due and m["account"] and levies and self.b(levies[0][0], cash)[0] >= due:
                    self.mv(levies[0][0], m["account"], cash, due)
                    self.leg(5, cash, levies[0][0], m["account"], due)
                    rebate = due
                self.maker_days.append((mem, inst, c["day"], m["presentNs"], m["session"], met, rebate))
                fx += [mem, inst, m["presentNs"], m["session"], 1 if met else 0, rebate]
                m["presentNs"] = 0; m["session"] = 0
                if (mem, inst) in self.fee_totals:
                    self.fee_totals[(mem, inst)] = 0
            self.last_maker_day = c["day"]
            return fx
        if k == "defineIndex":
            self.put_constituents(c["index"], c["constituents"], c["cap"])
            m = self.capitalisation(c["index"])
            d = self.half_even(m * E18, c["base"] * 100)
            level = self.half_even(m * E18, d)
            self.indices[c["index"]] = dict(base=c["base"], cap=c["cap"], halt=c["halt"], suspend=c["suspend"], divisor=d, level=level, reference=level, tripped=0)
            self.path.append((c["index"], len(self.log), level))
            return [48, c["index"], level]
        if k == "reviewIndex":
            x = self.indices[c["index"]]
            self.put_constituents(c["index"], c["constituents"], x["cap"])
            self.keep_level(c["index"])
            return [49, c["index"], x["level"]]
        if k == "corporateAction":
            inst = c["instrument"]; i = self.inst[inst]
            if c["kind"] == "split":
                adj = lambda p: self.to_tick(inst, self.half_even(p * c["den"], c["num"]))
            else:
                adj = lambda p: self.to_tick(inst, p - min(p - 1, c["amount"]))
            i["ref"] = adj(i["ref"])
            if i["last"]:
                i["last"] = adj(i["last"])
            touched = 0
            for index in sorted(self.indices):
                if (index, inst) in self.constituents:
                    if c["kind"] == "split":
                        row = self.constituents[(index, inst)]
                        row[0] = self.half_even(row[0] * c["num"], c["den"])
                    self.keep_level(index); touched += 1
            return [50, inst, i["ref"], touched]
        if k == "tripBreaker":
            x = self.indices[c["index"]]
            move = abs(x["level"] - x["reference"])
            kind = 2 if x["suspend"] and move * 10_000 >= x["suspend"] * x["reference"] else 1
            x["tripped"] = kind
            if kind == 2:
                self.suspended_at = now
            self.breaker_due = 0
            halted = []
            for inst in sorted(self.inst):
                ii = self.inst[inst]
                if ii["opened"] and ii["phase"] != "halted":
                    ii.update(phase="halted", endFrom=0, endTo=0, until=0)
                    self.due.add(inst); halted.append(inst)
            return [51, c["index"], x["level"], kind, len(halted)] + halted
        return self.apply_classes(now, c)

    def inav(self, fund, units, cash):
        """§29: (cash + Σ mark × shares) over the creation's units, half-even."""
        return self.half_even(cash + sum(self.mark(b) * sh for (f, b, sh) in self.baskets if f == fund), units)

    def recompute_navs(self):
        for fund in sorted(self.navs):
            n = self.navs[fund]
            v = self.inav(fund, n[0], n[1])
            if v != n[2]:
                n[2] = v
                self.nav_path.append((fund, len(self.log), v))

    def unit_out(self, account, led, qty):
        """Units leaving the book from an account's available (§28): its supply and its outside movements follow."""
        b = self.b(account, led)
        assert b[0] >= qty, "units out beyond available"
        b[0] -= qty
        self.deposited[led] = self.deposited.get(led, 0) - qty
        self.external[(account, led)] = self.external.get((account, led), 0) - qty

    def apply_classes(self, now, c):
        k = c["k"]
        if k == "setTerms":
            self.terms[c["instrument"]] = c["terms"]
            if c["terms"]["cls"] in ("future", "option"):
                self.derivs[c["instrument"]] = dict(mark=self.inst[c["instrument"]]["ref"], settled=0, runDay=0, runPrice=0, cursor=0, runTo=0, runBy=0, expired=False)
            return [52, c["instrument"], {"bond": 1, "receipt": 2, "certificate": 3, "right": 4, "future": 5, "option": 6}[c["terms"]["cls"]]]
        if k == "defineNav":
            for (b, sh) in c["constituents"]:
                self.baskets.append((c["instrument"], b, sh))
            v = self.inav(c["instrument"], c["units"], c["cash"])
            self.navs[c["instrument"]] = [c["units"], c["cash"], v]
            self.nav_path.append((c["instrument"], len(self.log), v))
            return [53, c["instrument"], v]
        if k == "issueReceipt":
            led = self.inst[c["instrument"]]["asset"]
            self.receipts.append([c["warehouse"], c["instrument"], c["account"], c["qty"], True, c["reference"]])
            self.b(c["account"], led)[0] += c["qty"]
            self.deposited[led] = self.deposited.get(led, 0) + c["qty"]
            self.external[(c["account"], led)] = self.external.get((c["account"], led), 0) + c["qty"]
            return [54, len(self.receipts), c["account"], c["qty"]]
        if k == "cancelReceipt":
            r = self.receipts[c["receipt"] - 1]
            self.unit_out(c["account"], self.inst[r[1]]["asset"], r[3])
            r[4] = False
            return [55, c["receipt"], c["account"], r[3]]
        if k == "retire":
            self.unit_out(c["account"], self.inst[c["instrument"]]["asset"], c["qty"])
            self.retirements.append((c["account"], c["instrument"], c["qty"], c["beneficiary"]))
            return [56, len(self.retirements), c["qty"]]
        if k == "exercise":
            t, i = self.terms[c["instrument"]], self.inst[c["instrument"]]
            shares = c["qty"] // t["den"] * t["num"]
            pay = t["price"] * shares
            self.unit_out(c["account"], i["asset"], c["qty"])
            self.mv(c["account"], t["issuer"], i["cash"], pay)
            self.leg(7, i["cash"], c["account"], t["issuer"], pay)
            self.entitlements.append((c["account"], c["instrument"], c["qty"], shares, pay))
            return [57, len(self.entitlements), shares, pay]
        if k == "valueDate":
            self.value_dates[c["instrument"]] = c["day"]
            return [58, c["instrument"], c["day"]]
        if k == "setAttestors":
            self.attestors = list(c["attestors"])
            return [59]
        if k == "attestPrice":
            self.attestations.append((c["instrument"], c["day"], c["attestor"], c["price"]))
            return [60, c["instrument"], c["day"], c["attestor"], self.attested(c["instrument"], c["day"]) or 0]
        if k == "settleDerivatives":
            return self.settle_derivatives(c["instrument"], c["day"], c["limit"])
        raise ValueError(k)

    def deliver(self, m, k, out):
        """§19: delivery against payment: the shares held for a member free of its sales, less its later purchases."""
        r, t = self.cm[m], self.clearing
        if r["debt"] or r["status"] != 1:
            return
        for (mm, inst) in sorted(x for x in self.custody if x[0] == m):
            later = sum(self.bought.get((m, inst, j), 0) for j in range(k + 1, self.cycle_no + 1))
            free = self.custody[(m, inst)] - self.custody_held(m, inst)
            if free > later:
                d = free - later
                self.mv(t["ccp"], r["settle"], self.inst[inst]["asset"], d)
                self.custody[(m, inst)] -= d
                self.leg(2, self.inst[inst]["asset"], t["ccp"], r["settle"], d)
                out.append((m, inst, d))

    def settle_cycle(self, k):
        """§19, written from the text: payers first, each all or nothing; then receivers within the CCP's free cash."""
        t = self.clearing
        outcomes, deliveries = [], []
        # each member's side as the cycle was cut, fixed before anything moves
        plan = [(m, *self.oblig.get((m, k), [0, 0]), self.oblig.get((m, k), [0, 0])[1] + self.cm[m]["debt"]) for m in sorted(self.cm)]
        levies = []
        for payers in (True, False):
            if not payers:
                for acct in list(self.payable):
                    amt = self.payable[acct]
                    if amt and self.ccp_free() >= amt:
                        self.mv(t["ccp"], acct, t["cash"], amt)
                        self.leg(4, t["cash"], t["ccp"], acct, amt)
                        self.payable[acct] = 0
                        levies.append((acct, amt))
            for (m, to, by, pay) in plan:
                r = self.cm[m]
                if r["status"] == 3 or (pay > to) != payers:
                    continue
                r["to"] -= to; r["by"] -= by; r["peak"] = max(r["peak"], by)
                if payers:
                    a = pay - to
                    if self.b(r["settle"], t["cash"])[0] >= a:
                        self.mv(r["settle"], t["ccp"], t["cash"], a)
                        self.leg(2, t["cash"], r["settle"], t["ccp"], a)
                        r["debt"] = 0; r["fails"] = 0
                        outcomes.append((m, 1, a))
                    else:
                        pen = ceil_div(a * t["penalty"], 10_000)
                        self.skin += pen
                        r["debt"] = a + pen; r["fails"] += 1
                        outcomes.append((m, 2, a + pen))
                else:
                    a = to - pay
                    r["debt"] = 0; r["fails"] = 0
                    if a > 0:
                        if self.ccp_free() >= a:
                            self.mv(t["ccp"], r["settle"], t["cash"], a)
                            self.leg(2, t["cash"], t["ccp"], r["settle"], a)
                            outcomes.append((m, 3, a))
                        else:
                            self.owe(m, k + 1, a, 0)
                            outcomes.append((m, 4, a))
                    elif to or by:
                        outcomes.append((m, 3, 0))
                self.deliver(m, k, deliveries)
        self.cycles[k][2] = True
        self.settled = k
        return ([34, k, len(outcomes)] + [x for o in outcomes for x in o] + [len(deliveries)] + [x for d in deliveries for x in d]
                + [len(levies)] + [x for lv in levies for x in lv])

    def close_default(self, m):
        """§21: the waterfall in its fixed order; the others' share by the largest remainder, ties in member order."""
        r = self.cm[m]
        rest = r["debt"]
        fc = min(rest, r["coll"]); rest -= fc
        ff = min(rest, r["fund"]); rest -= ff
        fs = min(rest, self.skin); rest -= fs; self.skin -= fs
        others = [x for x in self.active() if x != m and self.cm[x]["fund"] > 0]
        total = sum(self.cm[x]["fund"] for x in others)
        take = min(rest, total)
        exact = [(take * self.cm[x]["fund"], x) for x in others]
        shares = {x: (v // total if total else 0) for v, x in exact}
        left = take - sum(shares.values())
        for v, x in sorted(exact, key=lambda e: -(e[0] % total))[:left]:
            shares[x] += 1
        rest -= take
        fx = [40, m, fc, ff, fs, take, rest, len(others)]
        for x in others:
            self.cm[x]["fund"] -= shares[x]
            fx += [x, shares[x]]
        r["coll"] = r["coll"] - fc + (r["fund"] - ff); r["fund"] = 0; r["req"] = 0; r["debt"] = rest; r["fails"] = 0; r["status"] = 3
        return fx

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
            self.settle_pair(inst, i, b, bo, a, ao, p, q)
            bm = self.desig.get(bo["account"])
            if self.derivative(inst):
                for o in (bo, ao):
                    o["held"] = o["held"] * (o["remaining"] - q) // o["remaining"]
            else:
                bo["held"] = bo["held"] * (bo["remaining"] - q) // bo["remaining"] if bm is not None else self.buy_hold(inst, bo["price"], bo["remaining"] - q)
                ao["held"] -= q
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

    def settle_pair(self, inst, i, b, bo, a, ao, p, q):
        """§18: each side as its party's kind says; the CCP between a pre-funded and a clearing party."""
        if self.derivative(inst):
            return self.settle_derivative_pair(inst, b, bo, a, ao, p, q)
        v = p * q
        t = self.terms.get(inst)
        ai = accrued(t, q, self.value_dates[inst]) if t and t["cls"] == "bond" else 0
        bm, am = self.desig.get(bo["account"]), self.desig.get(ao["account"])
        ccp = self.clearing["ccp"] if self.clearing else 0
        fee_b = fee_s = self.fee_on(inst, v)
        if bm is None:
            after = self.buy_hold(inst, bo["price"], bo["remaining"] - q)
            self.b(bo["account"], i["cash"])[1] -= bo["held"] - after
            self.b(bo["account"], i["cash"])[0] += bo["held"] - after - v - ai
            assert bo["held"] - after - v - ai >= 0, "a buy held less than it paid"
            self.b(bo["account"], i["asset"])[0] += q
        else:
            self.owe(bm, self.cycle_no, 0, v + ai + fee_b)
            self.owe_payable(inst, fee_b)
            self.bought[(bm, inst, self.cycle_no)] = self.bought.get((bm, inst, self.cycle_no), 0) + q
            self.custody[(bm, inst)] = self.custody.get((bm, inst), 0) + q
        if am is None:
            self.b(ao["account"], i["asset"])[1] -= q
            self.b(ao["account"], i["cash"])[0] += v + ai
        else:
            self.owe(am, self.cycle_no, v + ai, fee_s)
            self.owe_payable(inst, fee_s)
            self.custody[(am, inst)] -= q
        if bm is None and am is None:
            self.leg(1, i["cash"], bo["account"], ao["account"], v); self.leg(1, i["asset"], ao["account"], bo["account"], q)
            if ai:
                self.leg(6, i["cash"], bo["account"], ao["account"], ai)
        elif bm is None:
            self.b(ccp, i["cash"])[0] += v + ai; self.b(ccp, i["asset"])[0] -= q
            assert self.b(ccp, i["asset"])[0] >= 0, "the CCP delivered shares it does not hold"
            self.leg(1, i["cash"], bo["account"], ccp, v); self.leg(1, i["asset"], ccp, bo["account"], q)
            if ai:
                self.leg(6, i["cash"], bo["account"], ccp, ai)
        elif am is None:
            assert self.b(ccp, i["cash"])[0] >= v + ai, "the CCP paid beyond its cash"
            self.b(ccp, i["cash"])[0] -= v + ai; self.b(ccp, i["asset"])[0] += q
            self.leg(1, i["cash"], ccp, ao["account"], v); self.leg(1, i["asset"], ao["account"], ccp, q)
            if ai:
                self.leg(6, i["cash"], ccp, ao["account"], ai)
        if bm is None:
            self.pay_fee(inst, bo["account"], i["cash"], fee_b)
        if am is None:
            self.pay_fee(inst, ao["account"], i["cash"], fee_s)
        for (mem, f) in ((bo["member"], fee_b), (ao["member"], fee_s)):
            if f:
                self.fee_totals[(mem, inst)] = self.fee_totals.get((mem, inst), 0) + f
        self.stmt.setdefault(bo["member"], []).append((len(self.log), b, 1, q, p, fee_b))
        self.stmt.setdefault(ao["member"], []).append((len(self.log), a, 2, q, p, fee_s))
        if am is None and ccp and ao["account"] == ccp and a in self.closeouts:
            m = self.closeouts[a]
            self.custody[(m, inst)] -= q
            net = v + ai - fee_s
            paid = min(self.cm[m]["debt"], net)
            self.cm[m]["debt"] -= paid
            if net > paid:
                self.owe(m, self.cycle_no, net - paid, 0)

    def settle_derivative_pair(self, inst, b, bo, a, ao, p, q):
        """§34, §35: a future's trade marked at once to the contract's mark, an option's premium owed; fees; positions."""
        bm, am = self.desig[bo["account"]], self.desig[ao["account"]]
        t = self.terms[inst]
        v = p * q * t["multiplier"]
        if t["cls"] == "future":
            mark = self.derivs[inst]["mark"]
            d = abs(mark - p) * q * t["multiplier"]
            if mark >= p:
                self.owe(bm, self.cycle_no, d, 0); self.owe(am, self.cycle_no, 0, d)
            else:
                self.owe(bm, self.cycle_no, 0, d); self.owe(am, self.cycle_no, d, 0)
        else:
            self.owe(bm, self.cycle_no, 0, v); self.owe(am, self.cycle_no, v, 0)
        fee_b = fee_s = self.fee_on(inst, v)
        self.owe(bm, self.cycle_no, 0, fee_b); self.owe_payable(inst, fee_b)
        self.owe(am, self.cycle_no, 0, fee_s); self.owe_payable(inst, fee_s)
        for (mem, f) in ((bo["member"], fee_b), (ao["member"], fee_s)):
            if f:
                self.fee_totals[(mem, inst)] = self.fee_totals.get((mem, inst), 0) + f
        self.move_position(bo["account"], bm, inst, True, q)
        self.move_position(ao["account"], am, inst, False, q)
        self.stmt.setdefault(bo["member"], []).append((len(self.log), b, 1, q, p, fee_b))
        self.stmt.setdefault(ao["member"], []).append((len(self.log), a, 2, q, p, fee_s))

    def settle_derivatives(self, inst, day, limit):
        """§34, §35: a slice of the daily settlement, `limit` open positions in account order after the run's cursor."""
        d, t = self.derivs[inst], self.terms[inst]
        final = day == t["expiry"]
        price = d["runPrice"] if d["runDay"] else (self.level(t["index"]) if final else self.attested(inst, day))
        start = d["cursor"] + 1 if d["runDay"] else 0
        remaining = sorted((acc, key) for key, p in self.positions.items() if key[1] == inst and p[2] > 0 and key[0] >= start for acc in [key[0]])
        out, n, last, sum_to, sum_by = [], 0, d["cursor"], 0, 0
        for acc, key in remaining[:limit]:
            p = self.positions[key]
            to = by = 0
            if t["cls"] == "future":
                amt = abs(price - p[3]) * p[2] * t["multiplier"]
                if price != p[3]:
                    if (price > p[3]) == p[1]:
                        to = amt
                    else:
                        by = amt
            elif final:
                pay = self.intrinsic(t, price) * p[2] * t["multiplier"]
                if p[1]:
                    to = pay
                else:
                    by = pay
            if to or by:
                self.owe(p[0], self.cycle_no, to, by)
            sum_to += to; sum_by += by
            qty, im = (0, 0) if final else (p[2], self.deriv_im(inst, p[1], p[2], price))
            self.member_im[p[0]] = self.member_im.get(p[0], 0) + im - p[4]
            p[2], p[3], p[4] = qty, price, im
            out += [acc, p[0], to, by]; n += 1; last = acc
        done = len(remaining) <= limit
        if done:
            self.derivs[inst] = dict(mark=price, settled=day, runDay=0, runPrice=0, cursor=0, runTo=0, runBy=0, expired=final)
        else:
            d.update(runDay=day, runPrice=price, cursor=last, runTo=d["runTo"] + sum_to, runBy=d["runBy"] + sum_by)
        return [61, inst, day, price, 1 if done else 0, n] + out

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
        for x in self.indices.values():
            x["reference"] = x["level"]; x["tripped"] = 0
        self.files[day] = bytes(w)
        return len(insts), h

    def end_immediates(self, inst, cancelled):
        for oid in sorted(oid for oid in self.open_ids("inst", inst) if self.orders[oid]["status"] == "live" and self.orders[oid]["kind"] in IMMEDIATE):
            self.close(oid, "cancelled"); cancelled.append(oid)

    def after_trade(self, inst, price):
        i = self.inst[inst]
        i["last"] = price
        self.prices_moved = True
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
            self.append_log(now, "clear", self.apply_all(now, {"k": "clear", "time": pending}))
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
        fx = self.apply_all(now, c)
        self.append_log(now, c["k"], fx)
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
        fx = self.apply_all(now, c)
        self.append_log(now, c["k"], fx)
        return "x:" + ",".join(map(str, fx))

    def reconciled(self):
        """§19: every movement between two of the venue's accounts is a leg, so each account's holding in a ledger is what
        came in from outside (deposits, loans) less what left (withdrawals, returns), plus its legs in, less its legs out."""
        want = dict(self.external)
        for (_, led, frm, to, units, _) in self.legs:
            want[(frm, led)] = want.get((frm, led), 0) - units
            want[(to, led)] = want.get((to, led), 0) + units
        for key in set(want) | set(self.bal):
            have = sum(self.bal.get(key, [0, 0]))
            if have != want.get(key, 0):
                return f"account {key[0]} on {key[1]}: holds {have}, its deposits and legs say {want.get(key, 0)}"
        return None

    def conserved(self):
        # §34: every derivative's long contracts equal its short ones
        for inst in self.derivs:
            if self.derivs[inst]["runDay"]:
                continue   # an expiry's run closes the positions slice by slice
            longs = sum(p[2] for (a, i), p in self.positions.items() if i == inst and p[1])
            shorts = sum(p[2] for (a, i), p in self.positions.items() if i == inst and not p[1])
            if longs != shorts:
                return f"derivative {inst}: {longs} long contracts against {shorts} short"
        for led, total in self.deposited.items():
            have = sum(v[0] + v[1] for (a, l), v in self.bal.items() if l == led)
            if have != total:
                return f"ledger {led}: accounts hold {have}, deposits less withdrawals {total}"
        t = self.clearing
        if t:
            # the CCP's cash is what it holds for the members and the venue, plus what it is owed less what it owes
            # a derivative's run in progress has owed members part of what it will charge others (§34)
            want = (sum(r["coll"] + r["fund"] + r["to"] for r in self.cm.values()) + self.skin + sum(self.payable.values())
                    - sum(r["by"] + r["debt"] for r in self.cm.values())
                    - sum(d["runTo"] - d["runBy"] for d in self.derivs.values()))
            have = sum(self.b(t["ccp"], t["cash"]))
            if have != want:
                return f"the CCP's cash {have}, its resources and obligations {want}"
            for inst, i in self.inst.items():
                held = sum(q for (_, x), q in self.custody.items() if x == inst)
                if self.bal.get((t["ccp"], i["asset"])) is not None or held:
                    if sum(self.b(t["ccp"], i["asset"])) != held:
                        return f"the CCP holds {sum(self.b(t['ccp'], i['asset']))} of instrument {inst}, its custody {held}"
        return None


def new_scls():
    """A checkpoint's lines of the instrument classes (§28 to §32), as the book printed them."""
    return {"TM": {}, "NV": {}, "VD": {}, "NP": [], "RC": [], "RT": [], "EN": [], "SU": {}, "DV": {}, "AT": [], "PO": [], "PM": {}}


def terms_text(t):
    """The terms as the battery prints them."""
    if t["cls"] == "bond":
        return f"cls=bond;coupon={t['coupon']};perYear={t['perYear']};basis={t['basis']};maturity={t['maturity']};settleDays={t['settleDays']}"
    if t["cls"] == "receipt":
        return "cls=receipt;warehouses=" + ",".join(str(w) for w in t["warehouses"])
    if t["cls"] == "certificate":
        return "cls=certificate;registry=" + t["registry"]
    if t["cls"] == "future":
        return f"cls=future;index={t['index']};multiplier={t['multiplier']};expiry={t['expiry']};imBps={t['imBps']}"
    if t["cls"] == "option":
        return (f"cls=option;index={t['index']};strike={t['strike']};call={1 if t['call'] else 0};multiplier={t['multiplier']};expiry={t['expiry']};"
                f"aBps={t['aBps']};bBps={t['bBps']}")
    return (f"cls=right;underlying={t['underlying']};price={t['price']};num={t['num']};den={t['den']};deadline={t['deadline']};"
            f"issuer={t['issuer']};issuerMember={t['issuerMember']}")


def parse_cmd(s):
    c = {}
    for kv in s.split(";"):
        k, _, v = kv.partition("=")
        # a client reference and a deposit's reference are text whatever their characters
        c[k] = v if k in ("ref", "reference", "sides", "levies", "balances", "constituents", "registry", "beneficiary", "warehouses", "bands", "attestors") else (int(v) if v.isdigit() else v)
    if "open" in c:
        c["open"] = c["open"] in (1, True)
    # the nested fields of SPEC §22 to §25: levies (account:ppm), balances (account:ledger:amount), quotes
    # (instrument:bid:ask:qty:ref)
    if "levies" in c:
        c["levies"] = [tuple(int(x) for x in t.split(":")) for t in str(c["levies"]).split(",") if t]
    if "balances" in c:
        c["balances"] = [(int(t.split(":")[0]), t.split(":")[1], int(t.split(":")[2])) for t in str(c["balances"]).split(",") if t]
    if "constituents" in c:
        c["constituents"] = [tuple(int(x) for x in t.split(":")) for t in str(c["constituents"]).split(",") if t]
    if c.get("k") == "setTerms":
        # the class's terms (§28): a bond's, a receipt's warehouses, a certificate's registry, a right's
        t = {"cls": c.pop("cls")}
        for f in ("coupon", "perYear", "basis", "maturity", "settleDays", "underlying", "price", "num", "den", "deadline", "issuer", "issuerMember", "registry",
                  "index", "multiplier", "expiry", "imBps", "strike", "call", "aBps", "bBps"):
            if f in c:
                t[f] = c.pop(f)
        if "warehouses" in c:
            t["warehouses"] = [int(x) for x in str(c.pop("warehouses")).split(",") if x]
        if "call" in t:
            t["call"] = t["call"] in (1, "1", True)
        c["terms"] = t
    if c.get("k") == "setAttestors":
        c["attestors"] = [x for x in str(c["attestors"]).split(",") if x]
    if c.get("k") == "defineNav":
        c["units"] = int(c["units"]); c["cash"] = int(c["cash"])
    if "sides" in c:
        c["sides"] = [dict(zip(("instrument", "bid", "ask", "qty", "ref"), (int(a), int(b), int(d), int(q), r)))
                      for a, b, d, q, r in (t.split(":") for t in str(c["sides"]).split(",") if t)]
    return c


def main():
    lines = []
    kept = False   # whether the physical line before was kept: a piece continues only the line it follows
    for l in open(sys.argv[1]):
        l = l.rstrip("\n")
        if l.startswith("+|"):
            if kept:
                lines[-1] += l[2:]      # a long line printed in pieces
        elif l[:2] in ("H|", "S|", "C|", "A|", "B|", "O|", "Q|", "I|", "U|", "K|", "E|", "G|", "J|", "W|", "M|", "CL", "CP", "N|", "P|", "R|", "X|", "Z|", "T|", "IX", "IP",
                       "TM", "NV", "VD", "NP", "RC", "RT", "EN", "SU", "DV", "AT", "PO", "PM"):
            lines.append(l); kept = True
        else:
            kept = False
    facts = {"accounts": {}, "owns": {}, "may": {}, "instruments": {}, "grants": {}, "offset": 0, "xinstruments": {}, "xbands": None, "members": set(), "traders": {},
             "ledgers": {}, "restdays": set(), "holidays": set(), "makers": {}}
    proposals = {}
    errors = []
    books = []   # every stream's reference book, for the legs' kinds at the end
    streams = cmds = blocks = checkpoints = legs_checked = index_rows_checked = path_checked = class_checked = supply_checked = deriv_checked = 0
    ref = None
    sblocks, sorders, squeue = [], {}, {}
    sinst, slimits, skills = {}, {}, {}
    sclear, scust, sscalars, sroot, sidx = {}, {}, None, None, []
    block_of = {}
    custody_legs, custody_pos = [], {}
    sstmt, sseals, srecons, smakers, smdays, spay, sfees = {}, [], {}, {}, [], {}, {}; sidx_rows, spath = {}, []; scls = new_scls()
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
            elif kind == "ledger":
                facts["ledgers"][f[2]] = f[3]
            elif kind == "restdays":
                facts["restdays"] = {int(x) for x in f[2].split(",") if x}
            elif kind == "holiday":
                facts["holidays"].add(int(f[2]))
            elif kind == "maker":
                facts["makers"][int(f[2])] = f[3] == "1"
            elif kind == "instrument":
                bands = [tuple(int(x) for x in b.split(":")) for b in f[6].split(",")]
                facts["instruments"][int(f[2])] = {"lot": int(f[3]), "ref": int(f[4]), "collar": int(f[5]), "bands": bands, "asset": f[7], "cash": f[8]}
        elif f[0] == "S":
            ref = Ref(facts)
            books.append(ref)
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
            sclear, scust, sscalars, sroot, sidx = {}, {}, None, None, []
            sstmt, sseals, srecons, smakers, smdays, spay, sfees = {}, [], {}, {}, [], {}, {}; sidx_rows, spath = {}, []; scls = new_scls()
            block_of = {}
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
            sblocks.append((int(f[2]), f[3], f[4])); sidx.append(int(f[1]))
        elif f[0] == "G":
            sclear[int(f[1])] = [int(x) for x in f[2:]]
        elif f[0] == "J":
            scust[(int(f[1]), int(f[2]))] = (int(f[3]), int(f[4]))
        elif f[0] == "W":
            sscalars = [int(x) for x in f[1:]]
        elif f[0] == "M":
            sroot = (int(f[1]), f[2])
        elif f[0] == "CL":
            # custody admitted leg i: it must be the reference's own leg i, a shares leg between the accounts
            # whose holders custody named
            i, hf, ht, units = (int(x) for x in f[1:5])
            lg = ref.legs[i] if i < len(ref.legs) else None
            if lg is None or lg[1] != "sharesA" or lg[4] != units:
                errors.append(f"custody admitted leg {i} ({units} units), the reference's leg is {lg}")
            custody_legs.append((lg[2], lg[3], units, hf, ht) if lg else None)
        elif f[0] == "CP":
            custody_pos[int(f[1])] = int(f[2])
        elif f[0] == "IX":
            sidx_rows[int(f[1])] = [int(x) for x in f[2:]]
        elif f[0] == "IP":
            spath.append(tuple(int(x) for x in f[1:]))
        elif f[0] == "TM":
            scls["TM"][int(f[1])] = "|".join(f[2:])
        elif f[0] == "NV":
            scls["NV"][int(f[1])] = [int(x) for x in f[2:]]
        elif f[0] == "VD":
            scls["VD"][int(f[1])] = int(f[2])
        elif f[0] == "NP":
            scls["NP"].append(tuple(int(x) for x in f[1:]))
        elif f[0] == "RC":
            scls["RC"].append([int(x) for x in f[1:7]] + [f[7]])
        elif f[0] == "RT":
            scls["RT"].append([int(x) for x in f[1:5]] + [f[5]])
        elif f[0] == "EN":
            scls["EN"].append([int(x) for x in f[1:]])
        elif f[0] == "SU":
            scls["SU"][f[1]] = int(f[2])
        elif f[0] == "DV":
            scls["DV"][int(f[1])] = [int(x) for x in f[2:]]
        elif f[0] == "AT":
            scls["AT"].append(tuple(int(x) for x in f[1:]))
        elif f[0] == "PO":
            scls["PO"].append([int(x) for x in f[1:]])
        elif f[0] == "PM":
            scls["PM"][int(f[1])] = int(f[2])
        elif f[0] == "N":
            sstmt[int(f[1])] = (int(f[2]), f[3])
        elif f[0] == "P":
            sseals.append((int(f[1]), int(f[2]), int(f[3]), f[4]))
        elif f[0] == "R":
            srecons[int(f[1])] = (int(f[2]), int(f[3]), int(f[4]), int(f[5]), int(f[6]), f[7])
        elif f[0] == "X":
            smakers[(int(f[1]), int(f[2]))] = [int(x) for x in f[3:]]
        elif f[0] == "Z":
            smdays.append(tuple(int(x) for x in f[1:]))
        elif f[0] == "T":
            if f[1] == "p":
                spay[int(f[2])] = int(f[3])
            else:
                sfees[(int(f[2]), int(f[3]))] = int(f[4])
        elif f[0] == "O":
            sorders[int(f[1])] = f[2:]
        elif f[0] == "Q":
            squeue[(int(f[1]), f[2])] = (int(f[3]), int(f[4]))
        elif f[0] == "E":
            entries = [(e, ref.log[e]) for e in range(ref.compared, len(ref.log)) if ref.log[e][1] != "setup"]
            mine = [(t, fam, ",".join(map(str, fx))) for (_, (t, fam, fx)) in entries]
            # every entry of the reference's log is the book's block at the index the book printed for it
            for (e, _), bi in zip(entries, sidx):
                block_of[e] = bi
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
            # the central counterparty (SPEC §18 to §21): every member's row, the custody, the scalars, the settlement range
            if ref.clearing or sclear:
                for m, row in sclear.items():
                    r = ref.cm.get(m)
                    mine = [r["settle"], r["credit"], r["coll"], r["fund"], r["req"], ref.im_orders(m), r["to"], r["by"], r["debt"], r["fails"], r["peak"], r["status"]] if r else None
                    if mine != row:
                        errors.append(f"stream {streams}: clearing member {m}: book {row}, reference {mine}")
                if set(sclear) != set(ref.cm):
                    errors.append(f"stream {streams}: clearing members {sorted(sclear)} in the book, {sorted(ref.cm)} in the reference")
                for key, v in scust.items():
                    mine = (ref.custody.get(key, 0), ref.custody_held(*key))
                    if mine != v:
                        errors.append(f"stream {streams}: custody {key}: book {v}, reference {mine}")
                for key, q in ref.custody.items():
                    if key not in scust and q:
                        errors.append(f"stream {streams}: custody {key}: the book holds no row, the reference {q}")
                mine = [ref.committed(), ref.skin, ref.cycle_no, ref.settled, ref.last_cut]
                if sscalars != mine:
                    errors.append(f"stream {streams}: the clearing's figures: book {sscalars}, reference {mine}")
            if sroot is not None:
                if any(lg[5] not in block_of for lg in ref.legs):
                    errors.append(f"stream {streams}: a settlement leg of an entry the book printed no block for")
                else:
                    leaves = [h_leaf(leg_bytes(lg[0], facts["ledgers"][lg[1]], lg[2], lg[3], lg[4], block_of[lg[5]])) for lg in ref.legs]
                    mine = (len(leaves), mmr_root(leaves).hex())
                    if mine != sroot:
                        errors.append(f"stream {streams}: the settlement range: book {sroot}, reference {mine}")
                    legs_checked += len(leaves)
            # fees, statements, reconciliations, makers (SPEC §22 to §25)
            if sstmt or ref.stmt or sseals or ref.stmt_seals:
                if any(ln[0] not in block_of for lines in list(ref.stmt.values()) + [x[2] for x in ref.stmt_seals] for ln in lines):
                    errors.append(f"stream {streams}: a statement line of an entry the book printed no block for")
                else:
                    mine = {m: (len(lines), statement_head(lines, block_of).hex()) for m, lines in ref.stmt.items()}
                    if mine != sstmt:
                        errors.append(f"stream {streams}: open statements: book {dict(list(sstmt.items())[:4])}, reference {dict(list(mine.items())[:4])}")
                    mine = [(m, d, len(lines), statement_head(lines, block_of).hex()) for (m, d, lines) in ref.stmt_seals]
                    if mine != sseals:
                        errors.append(f"stream {streams}: sealed statements: book {sseals[:3]}, reference {mine[:3]}")
            mine = {n + 1: r for n, r in enumerate(ref.recons)}
            if mine != srecons:
                errors.append(f"stream {streams}: member reconciliations: book {srecons}, reference {mine}")
            mine = {key: [m["account"], m["bid"], m["ask"], int(m["cont"]), int(m["present"]), m["presentNs"], m["session"], m["lastAt"]] for key, m in ref.makers.items()}
            if mine != smakers:
                errors.append(f"stream {streams}: makers: book {smakers}, reference {mine}")
            mine = [(a, b, c_, d, e, int(f_), g) for (a, b, c_, d, e, f_, g) in ref.maker_days]
            if mine != smdays:
                errors.append(f"stream {streams}: makers' periods: book {smdays}, reference {mine}")
            # indices (§26, §27): every row and the whole path, the path's blocks as the book printed them
            mine = {ix: [x["level"], x["reference"], x["tripped"], x["divisor"]] for ix, x in ref.indices.items()}
            if mine != sidx_rows:
                errors.append(f"stream {streams}: indices: book {sidx_rows}, reference {mine}")
            if any(e not in block_of for (_, e, _) in ref.path):
                errors.append(f"stream {streams}: an index level of an entry the book printed no block for")
            elif [(ix, block_of[e], lv) for (ix, e, lv) in ref.path] != spath:
                errors.append(f"stream {streams}: the index path: book {spath[-3:]}, reference {[(ix, block_of[e], lv) for (ix, e, lv) in ref.path][-3:]}")
            index_rows_checked += len(sidx_rows); path_checked += len(spath)
            # the instrument classes (§28 to §32): terms, iNAVs and path, value dates, receipts, retirements,
            # entitlements, and every ledger's units in the book against the reference's deposits less withdrawals
            mine = {i: terms_text(t) for i, t in ref.terms.items()}
            if mine != scls["TM"]:
                errors.append(f"stream {streams}: terms: book {scls['TM']}, reference {mine}")
            if ref.navs != scls["NV"]:
                errors.append(f"stream {streams}: iNAVs: book {scls['NV']}, reference {ref.navs}")
            if ref.value_dates != scls["VD"]:
                errors.append(f"stream {streams}: value dates: book {scls['VD']}, reference {ref.value_dates}")
            if any(e not in block_of for (_, e, _) in ref.nav_path):
                errors.append(f"stream {streams}: an iNAV of an entry the book printed no block for")
            elif [(fd, block_of[e], v) for (fd, e, v) in ref.nav_path] != scls["NP"]:
                errors.append(f"stream {streams}: the iNAV path: book {scls['NP'][-3:]}, reference {ref.nav_path[-3:]}")
            mine = [[n + 1, r[0], r[1], r[2], r[3], 1 if r[4] else 0, r[5]] for n, r in enumerate(ref.receipts)]
            if mine != scls["RC"]:
                errors.append(f"stream {streams}: receipts: book {scls['RC'][-3:]}, reference {mine[-3:]}")
            mine = [[n + 1, r[0], r[1], r[2], r[3]] for n, r in enumerate(ref.retirements)]
            if mine != scls["RT"]:
                errors.append(f"stream {streams}: retirements: book {scls['RT'][-3:]}, reference {mine[-3:]}")
            mine = [[n + 1] + list(r) for n, r in enumerate(ref.entitlements)]
            if mine != scls["EN"]:
                errors.append(f"stream {streams}: entitlements: book {scls['EN'][-3:]}, reference {mine[-3:]}")
            mine = {led: u for led, u in ref.deposited.items() if u}
            have = {led: u for led, u in scls["SU"].items() if u}
            if mine != have:
                errors.append(f"stream {streams}: units in the book: book {have}, reference {mine}")
            # derivatives (§33 to §35): settlement states, attestations, positions, members' positions' margin
            mine = {i: [d["mark"], d["settled"], d["runDay"], d["runPrice"], d["cursor"], d["runTo"], d["runBy"], 1 if d["expired"] else 0] for i, d in ref.derivs.items()}
            if mine != scls["DV"]:
                errors.append(f"stream {streams}: derivatives: book {scls['DV']}, reference {mine}")
            if list(ref.attestations) != scls["AT"]:
                errors.append(f"stream {streams}: attestations: book {scls['AT'][-3:]}, reference {ref.attestations[-3:]}")
            mine = [[a, i, p[0], 1 if p[1] else 0, p[2], p[3], p[4]] for (a, i), p in ref.positions.items()]
            if mine != scls["PO"]:
                errors.append(f"stream {streams}: positions: book {scls['PO'][-3:]}, reference {mine[-3:]}")
            mine = {m: ref.member_im.get(m, 0) for m in ref.cm}
            if scls["PM"] and mine != scls["PM"]:
                errors.append(f"stream {streams}: positions' margin: book {scls['PM']}, reference {mine}")
            deriv_checked += len(scls["DV"]) + len(scls["AT"]) + len(scls["PO"])
            class_checked += len(scls["TM"]) + len(scls["NV"]) + len(scls["RC"]) + len(scls["RT"]) + len(scls["EN"]) + len(scls["NP"])
            supply_checked += len(have)
            if dict(ref.payable) != spay:
                errors.append(f"stream {streams}: levies payable: book {spay}, reference {ref.payable}")
            if dict(ref.fee_totals) != sfees:
                errors.append(f"stream {streams}: fee totals: book {sfees}, reference {ref.fee_totals}")
            bad = ref.reconciled()
            if bad:
                errors.append(f"stream {streams}: the legs do not account for the balances: {bad}")
            checkpoints += 1
            sblocks, sorders, squeue = [], {}, {}
            sinst, slimits, skills = {}, {}, {}
            sclear, scust, sscalars, sroot, sidx = {}, {}, None, None, []
            sstmt, sseals, srecons, smakers, smdays, spay, sfees = {}, [], {}, {}, [], {}, {}; sidx_rows, spath = {}, []; scls = new_scls()
    if custody_pos:
        # the custody register refolded here from the deliveries in and the admitted legs: each linked account's position
        # is the reference's holding of it in instrument 1's shares, and every leg kept its accounts' holders
        holder_of = {}
        for (frm, to, units, hf, ht) in (x for x in custody_legs if x):
            for a, h in ((frm, hf), (to, ht)):
                if holder_of.setdefault(a, h) != h:
                    errors.append(f"custody: account {a} admitted under holders {holder_of[a]} and {h}")
        for a, units in custody_pos.items():
            have = sum(ref.bal.get((a, "sharesA"), [0, 0]))
            if units != have:
                errors.append(f"custody: account {a}'s position {units}, the reference's holding {have}")
        print(f"reference: {len(custody_legs)} legs admitted into custody, each the reference's own; {len(custody_pos)} positions equal to the holdings")
    print(f"reference: {legs_checked} settlement legs hashed into the range's root and compared")
    kinds = {}
    for bk in books:
        for lg in bk.legs:
            kinds[lg[0]] = kinds.get(lg[0], 0) + 1
    print("reference: settlement legs by kind " + ", ".join(f"{k}:{v}" for k, v in sorted(kinds.items())))
    if class_checked:
        print(f"reference: {class_checked} class rows (terms, iNAVs and path, receipts, retirements, entitlements) compared at checkpoints")
    print(f"reference: {supply_checked} ledgers' units in the book compared at checkpoints")
    if deriv_checked:
        print(f"reference: {deriv_checked} derivative rows (settlement states, attestations, positions) compared at checkpoints")
    if index_rows_checked:
        print(f"reference: {index_rows_checked} index rows and {path_checked} path levels compared at checkpoints")
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
