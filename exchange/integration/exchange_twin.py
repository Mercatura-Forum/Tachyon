#!/usr/bin/env python3
"""exchange_twin.py: the exchange foundation's decisions recomputed from the battery's dump with independent code.

    python3 exchange/integration/exchange_twin.py <battery log>

The battery (`exchange/test/Exchange.test.mo`) prints its inputs (each segment's windows, the rest days, the
holidays, the market's UTC offset by the day it took effect) and every outcome it saw (each scheduler act through
2026, executed from one phase to another or refused as unchanged; each ISIN's validity; each price's place on the
tick table). This twin recomputes every outcome from the inputs alone: weekdays and dates from Python's own calendar,
the schedule's phase by its own lookup, ISIN check digits by its own expansion and Luhn sum, ticks by its own band
search; and requires every one equal. It also checks the battery's own counts against the outcomes it reads, so a
dump that lost lines cannot pass.

Exit 0 and VERIFIED when every figure agrees; exit 1 with the first disagreements otherwise.

Attribution: Thebes Core Team.
"""
import datetime
import re
import sys

PHASES = {1: "closed", 2: "preOpen", 3: "openingAuction", 4: "continuous", 5: "closingAuction", 6: "tradeAtClose", 7: "halted"}


def weekday(day):
    return (datetime.date(1970, 1, 1) + datetime.timedelta(days=day)).weekday()   # Monday = 0


def isin_ok(x):
    if not re.fullmatch(r"[A-Z]{2}[A-Z0-9]{9}[0-9]", x):
        return False
    digits = "".join(str(int(ch, 36)) for ch in x[:11])
    total = 0
    for i, ch in enumerate(reversed(digits)):
        v = int(ch)
        if i % 2 == 0:
            v = v * 2 - 9 if v * 2 > 9 else v * 2
        total += v
    return (10 - total % 10) % 10 == int(x[11])


def main():
    lines = [l.strip() for l in open(sys.argv[1]) if l.startswith("dump:") or l.startswith("count:")]
    windows, holidays, rest, offsets = {}, set(), set(), []
    advances, isins, ticks, bands, counts = [], [], [], [], {}
    for l in lines:
        if l.startswith("count:"):
            k, v = l[len("count: "):].rsplit(" = ", 1)
            counts[k] = int(v)
            continue
        f = l[len("dump:"):].split("|")
        kind = f[0]
        if kind == "window":
            windows.setdefault(int(f[1]), []).append((int(f[2]), int(f[3]), int(f[4])))
        elif kind == "holiday":
            holidays.add(int(f[1]))
        elif kind == "restdays":
            rest = {int(x) for x in f[1].split(",")}
        elif kind == "offset":
            offsets.append((int(f[1]), int(f[2])))
        elif kind == "advance":
            advances.append((int(f[1]), int(f[2]), int(f[3]), f[4]))
        elif kind == "isin":
            isins.append((f[1], f[2] == "1"))
        elif kind == "tick":
            ticks.append((int(f[1]), f[2] == "1"))
        elif kind == "tickbands":
            bands = [tuple(int(y) for y in b.split(":")) for b in f[1].split(",")]
    errors = []

    def phase_at(seg, day, sec):
        if weekday(day) in rest or day in holidays:
            return 1
        for (p, a, b) in windows[seg]:
            if a <= sec < b:
                return p
        return 1

    current = {seg: 1 for seg in windows}
    executed = unchanged = 0
    for (seg, day, sec, out) in advances:
        want = phase_at(seg, day, sec)
        if want != current[seg]:
            expect = f"{current[seg]}>{want}"
            current[seg] = want
            executed += 1
        else:
            expect = f"={current[seg]}"
            unchanged += 1
        if out != expect:
            errors.append(f"segment {seg} day {day} second {sec}: the battery saw {out}, the twin computes {expect}")
    # the offsets: two moves in 2026, on the last Friday of April and the last Thursday of October
    moves = [d for (d, _) in offsets[1:]]
    want_moves = []
    for (month, wd) in ((4, 4), (10, 3)):
        d = datetime.date(2026, month + 1, 1) - datetime.timedelta(days=1)
        while d.weekday() != wd:
            d -= datetime.timedelta(days=1)
        want_moves.append((d - datetime.date(1970, 1, 1)).days)
    if moves != want_moves:
        errors.append(f"offset moves on days {moves}, the calendar's summer time is {want_moves}")
    for (x, got) in isins:
        if isin_ok(x) != got:
            errors.append(f"ISIN {x}: the battery says {got}, the twin computes {isin_ok(x)}")
    for (p, got) in ticks:
        tick = [t for (frm, t) in bands if frm <= p][-1]
        want = p > 0 and p % tick == 0
        if want != got:
            errors.append(f"price {p}: the battery says on tick {got}, the twin computes {want}")
    # the battery's own counts against what it dumped
    k_exec = "scheduler acts executed (a new phase at the chain's clock)"
    k_same = "scheduler acts refused because the schedule names the same phase"
    if counts.get(k_exec) != executed:
        errors.append(f"the battery counted {counts.get(k_exec)} executed acts, the dump holds {executed}")
    if counts.get(k_same) != unchanged:
        errors.append(f"the battery counted {counts.get(k_same)} unchanged acts, the dump holds {unchanged}")
    if not advances or not isins or not ticks:
        errors.append("MISS: the dump holds no advances, ISINs or ticks")
    print(f"twin: {len(advances)} scheduler acts ({executed} executed, {unchanged} unchanged), {len(isins)} ISINs, {len(ticks)} prices, {len(offsets)} offsets")
    if errors:
        for e in errors[:10]:
            print("  DISAGREES:", e)
        print(f"twin: {len(errors)} disagreements")
        return 1
    print("twin: VERIFIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
