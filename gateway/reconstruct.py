#!/usr/bin/env python3
"""reconstruct.py: a member gateway's ExecutionReports again, from the book's log alone.

    python3 gateway/reconstruct.py <log file> <journal> <account>

The log file is the book's certified log as the regulator reads it (`L|<index>|<hex>` lines, as
`book/integration/regulator_replay.py` reads it). `orderlog.Reports` decodes each block: the account's placements and replacements give the New and
Replaced events, and every block's projection to the public feed (the same bytes the venue served the gateway) gives the
fills and the removals. The same rule (`er.Book`) turns them into reports, which are compared with the gateway's
journal, application field by application field, in order, for the orders the gateway entered.

A refused order writes no block: its report (ExecType 8) is in the journal and not in the log, and is counted apart.

Attribution: Thebes Core Team.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "book", "integration"))
import orderlog  # noqa: E402


def from_log(path, account):
    """Every report of the account's orders, from the log's raw blocks alone (`orderlog.Reports`)."""
    reports = orderlog.Reports(accounts={account})
    out = []
    for line in open(path):
        if line.startswith("L|"):
            _, _, raw = line.strip().split("|")
            out += [r for _, r in reports.raw(bytes.fromhex(raw))]
    return out


def main():
    path, journal, account = sys.argv[1], sys.argv[2], int(sys.argv[3])
    sent, rejected = [], 0
    for line in open(journal):
        x = json.loads(line)
        if isinstance(x, dict) and "rejected" in x:
            rejected += 1
        else:
            sent.append([tuple(f) for f in x])
    cls = {dict(r).get("11") for r in sent} | {dict(r).get("41") for r in sent}
    rebuilt = [[tuple(f) for f in r] for r in from_log(path, account)]
    rebuilt = [r for r in rebuilt if dict(r).get("11") in cls or dict(r).get("41") in cls]
    same = sent == rebuilt
    print(f"reconstruct: {len(sent)} reports the gateway sent for accepted orders, {len(rebuilt)} from the log alone: "
          + ("EQUAL" if same else "DIFFERENT"))
    if not same:
        for k, (a, b) in enumerate(zip(sent, rebuilt)):
            if a != b:
                print(f"  first difference at report {k}: gateway {a} | log {b}")
                break
        else:
            print(f"  lengths {len(sent)} and {len(rebuilt)}")
    print(f"reconstruct: {rejected} refusals answered with ExecType 8 (a refusal writes no block)")
    return 0 if same and sent else 1


if __name__ == "__main__":
    sys.exit(main())
