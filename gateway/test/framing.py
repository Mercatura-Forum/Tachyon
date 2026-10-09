#!/usr/bin/env python3
"""framing.py (test): the gateway's framing over a stream, as TCP delivers it.

    python3 gateway/test/framing.py [fix.py to test]

For a message of each BeginString (FIX.4.4, FIXT.1.1), the bytes are fed in two pieces split at every position: each
split must give the message whole and nothing else, the first piece alone giving none (an incomplete message waits, it
is not a framing error). Then a message of another BeginString, a BodyLength that is not a number and a wrong CheckSum
must each be a framing error. Prints one count line; exits non-zero on any failure.

Attribution: Thebes Core Team.
"""
import importlib.util
import os
import sys

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fix.py")
spec = importlib.util.spec_from_file_location("fix_under_test", path)
fix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fix)

fails, splits = [], 0
for begin in ("FIX.4.4", "FIXT.1.1"):
    raw = fix.encode("D", [("11", "A1"), ("55", "1"), ("54", "1"), ("38", "10"), ("40", "2"), ("44", "100.00")], 7, "CLIENT", "THEBES",
                     "20261009-00:00:00.000", (), begin) if "begin" in fix.encode.__code__.co_varnames else None
    if raw is None:
        raw = (b"8=" + begin.encode() + b"\x01" + b"9=5\x0135=0\x01")
        raw += b"10=%03d\x01" % (sum(raw) % 256)
    for k in range(1, len(raw)):
        splits += 1
        try:
            m, rest = fix.take_message(raw[:k])
            if m is not None or rest != raw[:k]:
                fails.append(f"{begin} split {k}: a message from a part"); continue
            m, rest = fix.take_message(rest + raw[k:])
            if m is None or rest != b"" or m.get("8") != begin:
                fails.append(f"{begin} split {k}: not the whole message")
        except fix.FramingError as e:
            fails.append(f"{begin} split {k}: {e}")
for name, bad in (("another BeginString", b"8=FIX.4.2\x019=5\x0135=0\x0110=000\x01"),
                  ("BodyLength not a number", b"8=FIX.4.4\x019=x\x0135=0\x0110=000\x01"),
                  ("a wrong CheckSum", b"8=FIX.4.4\x019=5\x0135=0\x0110=000\x01")):
    try:
        fix.take_message(bad)
        fails.append(f"{name}: accepted")
    except fix.FramingError:
        pass
for f in fails[:5]:
    print("FAIL", f)
print(f"count: stream splits of a message given whole = {splits - len(fails)}")
print("FRAMING " + ("GREEN" if not fails else f"RED ({len(fails)} failures)"))
sys.exit(1 if fails else 0)
