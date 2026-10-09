#!/usr/bin/env python3
"""hand_reports.py: the ExecutionReports of account 2 in book/test/BookGateway.test.mo, worked by hand, against the ones
`reconstruct.from_log` gives from that battery's log alone.

    python3 gateway/hand_reports.py <BookGateway log>

Attribution: Thebes Core Team.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reconstruct  # noqa: E402

import sys
got = [dict(r) for r in reconstruct.from_log(sys.argv[1], 2)]
keys = ("150", "39", "11", "41", "38", "44", "32", "31", "14", "151", "6")
want = [
    {"150": "0", "39": "0", "11": "G1", "38": "10", "44": "850.00", "14": "0", "151": "10", "6": "0"},
    {"150": "0", "39": "0", "11": "H1", "38": "10", "44": "840.00", "14": "0", "151": "10", "6": "0"},
    {"150": "5", "39": "0", "11": "G2", "41": "G1", "38": "30", "44": "849.90", "14": "0", "151": "30", "6": "0"},
    {"150": "F", "39": "1", "11": "G2", "38": "30", "44": "849.90", "32": "10", "31": "849.90", "14": "10", "151": "20", "6": "849.900000"},
    {"150": "F", "39": "2", "11": "G2", "38": "30", "44": "849.90", "32": "20", "31": "849.90", "14": "30", "151": "0", "6": "849.900000"},
    {"150": "4", "39": "4", "11": "H1", "38": "10", "44": "840.00", "14": "0", "151": "0", "6": "0"},
    {"150": "0", "39": "0", "11": "G1", "38": "10", "44": "840.00", "14": "0", "151": "10", "6": "0"},
]
seen = [{k: r[k] for k in keys if k in r} for r in got]
if seen != want:
    print("gateway: the reports from the log are not the ones worked by hand")
    for k, (a, b) in enumerate(zip(seen + [None] * 9, want)):
        if a != b:
            print(f"  report {k}: log {a} | hand {b}")
    sys.exit(1)
print(f"gateway: {len(got)} ExecutionReports of account 2 from the log alone, equal to the ones worked by hand")
