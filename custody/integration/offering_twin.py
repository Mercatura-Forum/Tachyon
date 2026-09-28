#!/usr/bin/env python3
"""The offering's twin: an independent recomputation from the battery's dump (`custody/test/Offering.test.mo`).

From each offering's terms and its orders it rebuilds the book's ladder (the live bids' lots at each price) and its
clearing price, checks the price the offering was given against it, recomputes the pricing (the demand at the price,
the tranches with each taking the other's unfilled lots, a best-efforts offering's failure, the underwriter's
take-up), every order's allocation (the cornerstones in full, the bids at or above the price and the retail
applications pro rata by cumulative rounding with Python's own fractions), the cash due and the refunds, the
allocation file's hash chain with its own canonical writer, the holders, the listing gate's free float and the
hand-off's proceeds and fee (half up with the decimal module), and compares each with what the Motoko domain recorded.

Usage: offering_twin.py <battery log>   Prints counts and `OFFERING TWIN VERIFIED`, or FAULT lines and exits 1.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import hashlib
import sys
from decimal import Decimal, ROUND_HALF_UP
from fractions import Fraction

BPS = 10_000
DOMAIN = "tachyon.offering.allocation.v1"
OPEN, PRICED, ALLOCATED, LISTED, WITHDRAWN = 1, 2, 3, 4, 5


def w_nat(n):
    if n == 0:
        return b"\x00"
    bs = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([len(bs)]) + bs


def w_len(b):
    return bytes([len(b) // 256, len(b) % 256]) + b


def h(payload):
    return hashlib.sha256(w_len(DOMAIN.encode()) + payload).digest()


def share(before, lots, supply, demand):
    """Cumulative rounding, as the difference of two exact floors."""
    if demand == 0:
        return 0
    if supply >= demand:
        return lots
    return int(Fraction((before + lots) * supply, demand)) - int(Fraction(before * supply, demand))


def main(path):
    offers, ladders, orders, priced, slices, handoffs, rows = {}, {}, {}, {}, {}, {}, {}
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("|")
        if f[0] == "offer":
            v = list(map(int, f[3].split(",")))
            keys = ["offered", "outstanding", "low", "high", "tick", "lot", "retailBps", "cornerBps", "uwBps", "firm", "minSold", "minFloat", "minHolders"]
            offers[int(f[1])] = dict(zip(keys, v), code=f[2], underwriter=bytes.fromhex(f[4]))
        elif f[0] == "ladder":
            ladders[int(f[1])] = [tuple(map(int, x.split(":"))) for x in f[2].split(";") if x]
        elif f[0] == "order":
            v = list(map(int, f[5].split(",")))
            orders.setdefault(int(f[2]), []).append(dict(id=int(f[1]), kind=int(f[3]), investor=bytes.fromhex(f[4]), price=v[0], lots=v[1], paid=v[2], live=v[3] == 1, alloc=v[4], due=v[5], refund=v[6]))
        elif f[0] == "priced":
            priced[int(f[1])] = list(map(int, f[2].split(",")))
        elif f[0] == "slice":
            slices.setdefault(int(f[1]), []).append(list(map(int, f[2].split(","))))
        elif f[0] == "handoff":
            handoffs[int(f[1])] = list(map(int, f[2].split(",")))
        elif f[0] == "offering":
            v = list(map(int, f[2].split(",")))
            keys = ["state", "price", "corner", "retailDemand", "retailPaid", "bidDemand", "bidsAlloc", "retailAlloc", "unsold", "uwLots", "allocated", "holders", "cashDue", "refunds"]
            rows[int(f[1])] = dict(zip(keys, v), chain=f[3])
    faults = []
    n = {"offerings": 0, "orders allocated": 0, "chains": 0, "hand-offs": 0}
    for off, t in offers.items():
        os_ = sorted(orders.get(off, []), key=lambda o: o["id"])
        row = rows[off]
        offer_lots = t["offered"] // t["lot"]
        retail_lots = offer_lots * t["retailBps"] // BPS
        inst_lots = offer_lots - retail_lots
        corner = sum(o["lots"] for o in os_ if o["kind"] == 1)
        # the ladder: the live bids at each price, high to low
        lad = {}
        for o in os_:
            if o["kind"] == 2 and o["live"]:
                lad[o["price"]] = lad.get(o["price"], 0) + o["lots"]
        mine = sorted(((p, l) for p, l in lad.items() if l > 0), reverse=True)
        if mine != ladders.get(off, []):
            faults.append(f"offering {off}: ladder {ladders.get(off)} twin {mine}")
        cum, clearing = corner, None
        for p, l in mine:
            cum += l
            if cum >= inst_lots:
                clearing = p
                break
        if clearing is None and cum >= inst_lots:
            clearing = t["high"]
        price = priced[off][1]
        if price > (clearing if clearing is not None else t["low"]) or (price - t["low"]) % t["tick"]:
            faults.append(f"offering {off}: priced at {price} above the book's clearing {clearing}")
        bid_demand = sum(l for p, l in mine if p >= price)
        retail_demand = sum(o["lots"] for o in os_ if o["kind"] == 3)
        retail_paid = sum(o["paid"] for o in os_ if o["kind"] == 3)
        inst_demand = corner + bid_demand
        inst_fill, retail_fill = min(inst_demand, inst_lots), min(retail_demand, retail_lots)
        to_inst = min(retail_lots - retail_fill, inst_demand - inst_fill)
        to_retail = min(inst_lots - inst_fill, retail_demand - retail_fill)
        inst, retail = inst_fill + to_inst, retail_fill + to_retail
        unsold_all = offer_lots - inst - retail
        failed = t["firm"] == 0 and (inst + retail) * BPS < t["minSold"] * offer_lots
        uw = unsold_all if t["firm"] == 1 else 0
        want = [off, price, inst_demand, retail_demand, inst, retail, 0 if failed else uw, unsold_all if failed else unsold_all - uw, 1 if failed else 0]
        if priced[off] != want:
            faults.append(f"offering {off}: pricing {priced[off]} twin {want}")
        n["offerings"] += 1
        if failed:
            if row["state"] != WITHDRAWN or row["refunds"] != retail_paid or any(o["alloc"] for o in os_):
                faults.append(f"offering {off}: a failed offering not withdrawn with every retail payment refunded")
            continue
        bids_alloc = inst - corner
        # the allocation, order by order
        cum_b = cum_r = 0
        chain = h(w_nat(off) + w_len(t["code"].encode()) + w_nat(price))
        holders = allocated = cash = refunds = 0
        for o in os_:
            if o["kind"] == 1:
                a = o["lots"]
            elif o["kind"] == 2:
                if o["live"] and o["price"] >= price:
                    a = share(cum_b, o["lots"], bids_alloc, bid_demand)
                    cum_b += o["lots"]
                else:
                    a = 0
            else:
                a = share(cum_r, o["lots"], retail, retail_demand)
                cum_r += o["lots"]
            due = a * t["lot"] * price
            refund = o["paid"] - due if o["kind"] == 3 else 0
            if (a, due, refund) != (o["alloc"], o["due"], o["refund"]):
                faults.append(f"order {o['id']}: {(o['alloc'], o['due'], o['refund'])} twin {(a, due, refund)}")
            chain = h(w_len(chain) + w_nat(o["id"]) + bytes([o["kind"]]) + w_len(o["investor"]) + w_nat(a) + w_nat(due) + w_nat(refund))
            holders += 1 if a > 0 else 0
            allocated += a
            cash += due
            refunds += refund
            n["orders allocated"] += 1
        chain = h(w_len(chain) + w_nat(0) + w_len(t["underwriter"]) + w_nat(uw))
        holders += 1 if uw > 0 else 0
        if allocated != inst + retail:
            faults.append(f"offering {off}: {allocated} lots allocated, the tranches hold {inst + retail}")
        sl = slices.get(off, [])
        if sum(s[2] for s in sl) != allocated or sum(s[1] for s in sl) != len(os_) or not sl or sl[-1][3] != 1 or any(s[3] for s in sl[:-1]):
            faults.append(f"offering {off}: the slices {sl} do not sum to the allocation")
        withdrawn = row["state"] == WITHDRAWN
        want_row = dict(price=price, corner=corner, retailDemand=retail_demand, retailPaid=retail_paid, bidDemand=bid_demand, bidsAlloc=bids_alloc, retailAlloc=retail, unsold=unsold_all - uw,
                        uwLots=uw, allocated=allocated, holders=holders, cashDue=cash, refunds=retail_paid if withdrawn else refunds)
        got_row = {k: row[k] for k in want_row}
        if got_row != want_row:
            faults.append(f"offering {off}: row {got_row} twin {want_row}")
        if row["chain"] != chain.hex():
            faults.append(f"offering {off}: allocation file {row['chain']} twin {chain.hex()}")
        n["chains"] += 1
        float_bps = (bids_alloc + retail) * t["lot"] * BPS // t["outstanding"]
        passes = float_bps >= t["minFloat"] and holders >= t["minHolders"]
        if off in handoffs:
            gross = (allocated + uw) * t["lot"] * price
            fee = int((Decimal(gross) * Decimal(t["uwBps"]) / Decimal(BPS)).quantize(Decimal(1), rounding=ROUND_HALF_UP))
            want_h = [off, gross, fee, gross - fee, float_bps, holders, uw * t["lot"], price]
            if handoffs[off] != want_h or not passes or row["state"] != LISTED:
                faults.append(f"offering {off}: hand-off {handoffs[off]} twin {want_h} (gate {passes})")
            n["hand-offs"] += 1
        elif passes or not withdrawn:
            faults.append(f"offering {off}: not handed off, yet the gate passes ({float_bps} bps, {holders} holders) or it was not withdrawn")
    for x in faults:
        print("FAULT", x)
    for k, v in n.items():
        print(f"count: {k} recomputed = {v}")
    if faults or min(n.values()) == 0:
        sys.exit(1)
    print("OFFERING TWIN VERIFIED")


if __name__ == "__main__":
    main(sys.argv[1])
