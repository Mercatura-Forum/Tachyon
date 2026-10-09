#!/usr/bin/env python3
"""chain_judge.py: a battery's transcript judged on a Thebes chain through the test actor (`custody/integration/VenueJudge.mo`).

The WASI battery writes a transcript (`test/support/Transcript.mo`): every call that can write state, in order, with the
role principal it acted as, the clock it passed, the command's frozen bytes or the proposal id, the justification, and
what it got back. The judge installs the test actor built from the committed tree with the battery's grants and dual
policies (`custody/integration/judge/<battery>.json`), one chain signer per role, and makes every call again from the role's
signer. It requires:
  * every reply the battery's: the same effects, the same proposal ids, the same refusals by name;
  * an in-place upgrade half-way leaving every domain's fingerprint unchanged;
  * at the end every domain's fingerprint the battery's, its log's tip included: the chain's logs are the battery's
    byte for byte;
  * a replay of the chain's own logs, inside the actor, reproducing every fingerprint.

Calls go in windows from the node the client submits to, in order. A reply that differs stops the judge; `--window 1`
runs one call at a time.

Usage: chain_judge.py --wasm VenueJudge.wasm --log <battery log> --config custody/integration/judge/<battery>.json
                      [--chain <chain.json>] [--window 20] [--out evidence.json]
`--chain` names the chain's JSON description (thebes_client.py), else `THEBES_CHAIN` does.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse
import hashlib
import json
import os
import sys
import time

from ic.candid import Types, encode, decode

import thebes_client as TC


def read_transcript(path):
    calls, fps, pending, pending_out = [], {}, "", ""
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("callb|"):
            pending += line[6:]
        elif line.startswith("callo|"):
            pending_out += line[6:]
        elif line.startswith("call|"):
            f = line.split("|", 8)
            dom, op, caller, now, version, arg, just, outcome = f[1:9]
            if outcome == "@":
                outcome = pending_out
            pending_out = ""
            if op == "submit":
                calls.append({"dom": dom, "op": op, "caller": caller, "now": int(now), "version": int(version), "bytes": bytes.fromhex(pending), "just": bytes.fromhex(just).decode("utf-8"), "outcome": outcome})
            else:
                calls.append({"dom": dom, "op": op, "caller": caller, "now": int(now), "proposal": int(arg), "outcome": outcome})
            pending = ""
        elif line.startswith("fingerprint|"):
            _, dom, h = line.split("|")
            fps[dom] = h
    return calls, fps


def init_arg(cfg, roles):
    P = Types.Principal
    fields, value = {}, {}
    fields["roles"] = Types.Vec(Types.Record({"signer": P, "role": P}))
    value["roles"] = [{"signer": s.to_str(), "role": r} for r, s in roles.items()]
    for k, v in cfg.items():
        if k == "battery":
            continue
        if k == "grants":
            fields[k] = Types.Vec(Types.Record({"role": P, "prefixes": Types.Vec(Types.Text), "exact": Types.Vec(Types.Text)}))
        elif k.endswith("Duals") or k == "prefixes":
            fields[k] = Types.Vec(Types.Text)
        elif k == "holders":
            fields[k] = Types.Vec(P)
        elif k == "admin":
            fields[k] = P
        elif isinstance(v, bool):
            fields[k] = Types.Bool
        elif isinstance(v, int):
            fields[k] = Types.Nat
        else:
            fields[k] = Types.Text
        value[k] = v
    return [{"type": Types.Record(fields), "value": value}]


def text_of(reply):
    return decode(reply)[0]["value"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wasm", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--chain", help="the chain's JSON description (else THEBES_CHAIN)")
    ap.add_argument("--window", type=int, default=20)
    ap.add_argument("--out")
    a = ap.parse_args()
    cfg = json.load(open(a.config))
    calls, want_fps = read_transcript(a.log)
    assert calls and want_fps, "the battery's log carries no transcript or no fingerprints"
    name = cfg["battery"]
    chain = TC.ThebesChain(a.chain)
    ev = {"battery": name, "chain": chain.nodes, "counts": {}, "checks": {}}

    deployer = TC.Identity(f"{name}-deployer")
    # one chain signer per role the battery acted as
    roles = {}
    for c in calls:
        if c["caller"] not in roles:
            roles[c["caller"]] = TC.Identity(f"{name}-role-{hashlib.sha256(c['caller'].encode()).hexdigest()[:10]}")
    chain.set_sender(deployer.principal)
    cid = chain.create_canister()
    t0 = time.time()
    inst = chain.install(cid, a.wasm, init_arg(cfg, roles), name=f"{name}-judge")
    ev["install"] = inst
    print(f"installed the {name} judge on {chain.cid_of(cid)}: {inst['bytes']} bytes, {inst['chunks']} chunks, {inst['seconds']}s, sha256 {inst['sha256'][:16]}")

    def fingerprints():
        chain.set_sender(deployer.principal)
        out = {}
        for row in decode(chain.update_call(cid, "fingerprints", encode([])))[0]["value"]:
            vals = list(row.values()) if isinstance(row, dict) else list(row)
            out[vals[0]] = bytes(vals[1]).hex()
        return out

    half, upgraded, i, fuels = len(calls) // 2, False, 0, []
    tally = {"x": 0, "p": 0, "e": 0}
    while i < len(calls):
        part = calls[i:i + max(1, a.window)]
        batch = []
        for c in part:
            who = roles[c["caller"]].principal
            if c["op"] == "submit":
                arg = encode([{"type": Types.Text, "value": c["dom"]}, {"type": Types.Nat8, "value": c["version"]}, {"type": Types.Vec(Types.Nat8), "value": list(c["bytes"])},
                              {"type": Types.Text, "value": c["just"]}, {"type": Types.Nat64, "value": c["now"]}])
                batch.append((who, cid, "submit", arg))
            else:
                arg = encode([{"type": Types.Text, "value": c["dom"]}, {"type": Types.Nat, "value": c["proposal"]}, {"type": Types.Nat64, "value": c["now"]}])
                batch.append((who, cid, "approve", arg))
        replies = chain.update_calls_as(batch)
        for k, (c, rep) in enumerate(zip(part, replies)):
            got = text_of(rep)
            if got != c["outcome"]:
                print(f"MISMATCH at call {i + k} ({c['dom']} {c['op']} by {c['caller']}): the battery had {c['outcome'][:200]!r}, the chain replied {got[:300]!r}")
                ev["checks"]["mismatch"] = {"call": i + k, "domain": c["dom"], "op": c["op"], "battery": c["outcome"], "chain": got,
                                            # the whole window as sent, each call's outcome in the battery and the chain's reply,
                                            # and the client's retries: the evidence that tells a reordering from a misattribution
                                            "window": [{"call": i + j, "now": cc["now"], "battery": cc["outcome"], "chain": text_of(rr)} for j, (cc, rr) in enumerate(zip(part, replies))],
                                            "client retries": dict(chain.retries)}
                if a.out:
                    json.dump(ev, open(a.out, "w"), indent=1)
                sys.exit(1)
            tally[got[0]] += 1
        fuels.extend(chain.last_window_fuel)
        i += len(part)
        if not upgraded and i >= half:
            before = fingerprints()
            chain.set_sender(deployer.principal)
            up = chain.install(cid, a.wasm, init_arg(cfg, roles), name=f"{name}-judge", upgrade=True)
            after = fingerprints()
            assert before == after, f"the in-place upgrade changed a fingerprint: {before} -> {after}"
            ev["checks"]["the in-place upgrade half-way"] = {"call": i, "fingerprints": before, "seconds": up["seconds"]}
            print(f"upgraded in place at call {i} of {len(calls)}: every fingerprint the same")
            upgraded = True
        if (i // max(1, a.window)) % 10 == 0:
            print(f"  {i} of {len(calls)} calls, {round(time.time() - t0)}s")
    got_fps = fingerprints()
    for dom, h in want_fps.items():
        assert got_fps.get(dom) == h, f"{dom}: the chain's fingerprint {got_fps.get(dom)} is not the battery's {h}"
    print("every domain's fingerprint the battery's: " + ", ".join(f"{d} {h[:12]}" for d, h in want_fps.items()))
    chain.set_sender(deployer.principal)
    rp = text_of(chain.update_call(cid, "replayCheck", encode([])))
    replay_fuel = chain.last_fuel
    assert rp.startswith("ok|"), f"the replay on the chain: {rp}"
    print(f"the chain's own logs replayed: {rp}")
    ev["cid"] = chain.cid_of(cid)
    ev["checks"].update({"fingerprints": got_fps, "replay": rp, "fuel": {"max per call": max(fuels) if fuels else 0, "total": sum(fuels), "replay": replay_fuel},
                         "client retries": chain.retries, "signers": {r: s.to_str() for r, s in roles.items()}})
    ev["seconds"] = round(time.time() - t0)
    counts = ev["counts"]
    counts["calls made again with the battery's outcome"] = len(calls)
    counts["executions with the battery's effects"] = tally["x"]
    counts["proposals at the battery's block indices"] = tally["p"]
    counts["refusals by the battery's name"] = tally["e"]
    counts["domains whose fingerprint is the battery's"] = len(want_fps)
    for k, v in counts.items():
        print(f"count: {k} = {v}")
    if a.out:
        json.dump(ev, open(a.out, "w"), indent=1)
    print(f"CHAIN JUDGE GREEN {name} on {len(chain.nodes)} nodes: contract {chain.cid_of(cid)}")


if __name__ == "__main__":
    main()
