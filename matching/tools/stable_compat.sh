#!/usr/bin/env bash
# The engine's stable state must upgrade from the code it replaces: moc's own check of the old engine's stable types
# against the new one's. Control: the new signature with one stored field's type changed must be refused, or the check
# proves nothing. Under legacy persistence an incompatible change is silent data loss.
#   matching/tools/stable_compat.sh <old commit>
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"; old="$1"; work="$(mktemp -d)"
S="$(cd "$root" && mops sources | sed "s#--package \([^ ]*\) \.mops/#--package \1 $root/.mops/#g")"
mkdir -p "$work/old" "$work/new" "$work/ctl"
for f in Matching MatchLogic MatchTypes ICRC Guards; do git -C "$root" show "$old:matching/src/$f.mo" > "$work/old/$f.mo"; git -C "$root" show "HEAD:matching/src/$f.mo" > "$work/new/$f.mo"; done
moc --legacy-persistence $S --stable-types -o "$work/old/m.wasm" "$work/old/Matching.mo" 2>/dev/null
moc --legacy-persistence $S --stable-types -o "$work/new/m.wasm" "$work/new/Matching.mo" 2>/dev/null
# the control: the new engine's stable signature with one stored field's type changed (the order counter from Nat to
# Text), planted in a copy of the signature the check reads
python3 - "$work/new/m.most" "$work/ctl/m.most" <<'PY'
import re, sys
src, dst = sys.argv[1:3]
s = open(src).read()
n = len(re.findall(r"nextOrderId : Nat\b", s))
assert n == 1, f"CONTROL BROKEN: the order counter occurs {n} times in the signature"
open(dst, "w").write(re.sub(r"nextOrderId : Nat\b", "nextOrderId : Text", s))
PY
if moc --stable-compatible "$work/old/m.most" "$work/new/m.most" 2>"$work/err"; then echo "compatible: $old -> HEAD"; else echo "INCOMPATIBLE: $old -> HEAD"; cat "$work/err"; exit 1; fi
if moc --stable-compatible "$work/old/m.most" "$work/ctl/m.most" 2>/dev/null; then echo "CONTROL GREEN UNDER FAULT: a changed stored type passed"; exit 1; else echo "control: a changed stored type refused"; fi
