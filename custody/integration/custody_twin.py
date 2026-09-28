#!/usr/bin/env python3
"""The custody register's twin: an independent recomputation from the battery's dump (`custody/test/Custody.test.mo`).

From the receipts it refolds every holder's position and the register's total; from each action's terms and the
entitlements' units at the record date it recomputes every entitlement (the dividend, the split and bonus with
their fractions and cash in lieu, the rights and the subscription payable, the redemption), the action's totals,
the positions after each paid action and the issued supply; it recomputes every entitlement file's hash and every
reconciliation's hash with its own canonical writer.

Usage: custody_twin.py <battery log>   Prints counts and `CUSTODY TWIN VERIFIED`, or FAULT lines and exits 1.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import hashlib
import sys

BPS = 10_000
FILE_DOMAIN, RECON_DOMAIN = "tachyon.custody.entitlements.v1", "tachyon.custody.reconciliation.v1"
KIND_CODE = {"cashDividend": 1, "split": 2, "bonus": 3, "rights": 4, "redemption": 5}


def w_nat(n):
    if n == 0:
        return b"\x00"
    bs = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([len(bs)]) + bs


def w_text(t):
    b = t.encode("utf-8")
    return bytes([len(b) // 256, len(b) % 256]) + b


def w_kind(kind, terms):
    out = bytes([KIND_CODE[kind]])
    for t in terms:
        out += w_nat(t)
    return out


def entitlement(kind, terms, units):
    if kind == "cashDividend":
        return units * terms[0], 0, 0, 0
    if kind in ("split", "bonus"):
        num, den, lieu = terms
        whole, frac = (units * num) // den, (units * num) % den
        return frac * lieu // den, whole, 0, frac
    if kind == "rights":
        num, den = terms[0], terms[1]
        return 0, 0, (units * num) // den, (units * num) % den
    ratio, price = terms
    whole, frac = (units * ratio) // BPS, (units * ratio) % BPS
    return whole * price, whole, 0, frac


def main(path):
    holders, asset, receipts, actions, ents, recons, recon_rows = {}, None, [], {}, {}, {}, {}
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("|")
        if f[0] == "holder":
            holders[int(f[1])] = int(f[2])
        elif f[0] == "asset":
            asset = {"supply": int(f[3]), "initial": int(f[4]), "issuer": int(f[5])}
        elif f[0] == "receipt":
            receipts.append({"kind": f[2], "from": int(f[4]), "to": int(f[5]), "units": int(f[6]), "day": int(f[7])})
        elif f[0] == "action":
            actions[int(f[1])] = {"kind": f[2], "terms": [int(x) for x in f[3].split(",")], "record": int(f[4]), "payment": int(f[5]), "state": f[6], "cash": int(f[7]), "units": int(f[8]), "hash": f[9]}
        elif f[0] == "entitlement":
            ents.setdefault(int(f[1]), []).append([int(x) for x in f[2:11]])
        elif f[0] == "reconciliation":
            recons[int(f[1])] = {"day": int(f[2]), "block": int(f[3]), "holders": int(f[4]), "total": int(f[5]), "supply": int(f[6]), "matched": int(f[7]), "breaks": int(f[8]), "hash": f[9]}
        elif f[0] == "reconciliationRows":
            recon_rows[int(f[1])] = [tuple(int(v) for v in r.split(":")) for r in f[2].split(",")]
    faults = []
    # the positions: the supply to the issuer, then the receipts in order, then the paid actions in order
    pos = {h: 0 for h in holders}
    pos[asset["issuer"]] = asset["initial"]
    supply = asset["initial"]
    for r in receipts:
        if pos[r["from"]] < r["units"]:
            faults.append(f"a receipt moves more than the holder had: {r}")
        pos[r["from"]] -= r["units"]
        pos[r["to"]] += r["units"]
    files = 0
    for aid, a in sorted(actions.items()):
        lines = ents.get(aid, [])
        cash_total = units_total = 0
        for l in lines:
            holder, at_record, cash_due, cash_payable, units_due, units_taken, rights, rights_taken, fraction = l
            cd, ud, rg, fr = entitlement(a["kind"], a["terms"], at_record)
            if a["kind"] == "rights":
                ud, cash_payable_want = rights_taken, rights_taken * a["terms"][2]
                if rights_taken > rg:
                    faults.append(f"action {aid} holder {holder}: rights taken above the rights")
            else:
                cash_payable_want = 0
            if (cash_due, cash_payable, units_due, rights, fraction) != (cd, cash_payable_want, ud, rg, fr):
                faults.append(f"action {aid} holder {holder}: {(cash_due, cash_payable, units_due, rights, fraction)} vs twin {(cd, cash_payable_want, ud, rg, fr)}")
            cash_total += cd
            units_total += ud
            if a["state"] == "paid":
                if units_taken != units_due:
                    faults.append(f"action {aid} holder {holder}: paid units {units_taken} vs due {units_due}")
                if a["kind"] == "split":
                    pos[holder] = pos[holder] - at_record + units_due
                    supply += units_due - at_record
                elif a["kind"] in ("bonus", "rights"):
                    pos[holder] += units_due
                    supply += units_due
                elif a["kind"] == "redemption":
                    pos[holder] -= units_due
                    supply -= units_due
        if (a["cash"], a["units"]) != (cash_total, units_total):
            faults.append(f"action {aid}: totals {(a['cash'], a['units'])} vs twin {(cash_total, units_total)}")
        if a["hash"]:
            payload = w_nat(aid) + w_nat(1) + w_kind(a["kind"], a["terms"]) + w_nat(a["record"]) + w_nat(a["payment"]) + w_nat(len(lines))
            for l in sorted(lines):
                for v in l:
                    payload += w_nat(v)
            h = hashlib.sha256(w_text(FILE_DOMAIN) + payload).hexdigest()
            if h != a["hash"]:
                faults.append(f"action {aid}: file hash {a['hash'][:16]} vs twin {h[:16]}")
            files += 1
    for h, units in holders.items():
        if pos[h] != units:
            faults.append(f"holder {h}: position {units} vs the refold {pos[h]}")
    if supply != asset["supply"] or sum(holders.values()) != asset["supply"]:
        faults.append(f"the supply {asset['supply']} vs the refold {supply} and the positions' sum {sum(holders.values())}")
    for rid, r in sorted(recons.items()):
        rows = recon_rows[rid]
        payload = w_nat(1) + w_nat(r["day"]) + w_nat(r["block"]) + w_nat(len(rows))
        for hh, p, b in rows:
            payload += w_nat(hh) + w_nat(p) + w_nat(b)
        h = hashlib.sha256(w_text(RECON_DOMAIN) + payload).hexdigest()
        matched = sum(1 for _, p, b in rows if p == b)
        breaks = len(rows) - matched
        if r["total"] != r["supply"]:
            faults.append(f"reconciliation {rid}: the register's total {r['total']} is not the issued supply {r['supply']}")
        if (r["holders"], r["matched"], r["breaks"], r["hash"]) != (len(rows), matched, breaks, h):
            faults.append(f"reconciliation {rid}: {(r['holders'], r['matched'], r['breaks'], r['hash'][:16])} vs twin {(len(rows), matched, breaks, h[:16])}")
    print(f"count: holders whose position the twin refolded from the receipts and the paid actions = {len(holders)}")
    print(f"count: entitlements recomputed from the terms = {sum(len(v) for v in ents.values())}")
    print(f"count: entitlement files whose hash the twin reproduced = {files}")
    print(f"count: reconciliations recomputed with their hashes = {len(recons)}")
    for f in faults:
        print("FAULT: " + f)
    if faults or not holders or not ents or files == 0:
        sys.exit(1)
    print("CUSTODY TWIN VERIFIED")


if __name__ == "__main__":
    main(sys.argv[1])
