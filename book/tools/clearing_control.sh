#!/usr/bin/env bash
# The controls of the clearing battery's off-chain checks (SPEC §18 to §21): faults planted in a copy of a green
# BookClearing log, each of a class the reference claims to catch: a cycle's settlement (its effects), a clearing
# member's row, a custody row, the clearing's figures, the settlement range's root, a leg custody admitted, a position
# custody holds, the CCP's cash; and for the regulator's replay, a byte of a stored block. Each check must be green on
# the unaltered log first and red on every planted copy. A plant that finds no line, or changes nothing, is CONTROL
# BROKEN.
#   book/tools/clearing_control.sh <BookClearing log>
set -u
log="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"; work="$(mktemp -d)"
ref="$here/integration/reference_book.py"
python3 "$ref" "$log" > /dev/null || { echo "STOP: the reference is red on the unaltered log"; exit 1; }
python3 "$here/integration/regulator_replay.py" "$log" > /dev/null || { echo "STOP: the regulator's replay is red on the unaltered log"; exit 1; }
red=0; total=0
plant() {  # name, python: a regular expression and its replacement, applied to the first line it matches
  total=$((total+1)); out="$work/$1.log"
  python3 - "$log" "$out" "$2" "$3" <<'PY'
import re, sys
src, dst, pat, rep = sys.argv[1:5]
lines = open(src).read().split("\n")
for i, l in enumerate(lines):
    if re.search(pat, l):
        lines[i] = re.sub(pat, rep, l, count=1)
        open(dst, "w").write("\n".join(lines)); sys.exit(0)
sys.exit(3)
PY
  rc=$?
  if [ $rc -ne 0 ]; then echo "$1: CONTROL BROKEN (no line matches $2)"; return; fi
  if cmp -s "$log" "$out"; then echo "$1: CONTROL BROKEN (the plant changed nothing)"; return; fi
  if python3 "$ref" "$out" > /dev/null; then echo "$1: GREEN UNDER FAULT"; else echo "$1: RED"; red=$((red+1)); fi
}
plant "cycle settled" '^(C\|[^|]*\|scheduler\|k=settleCycle;cycle=1\|x:34,1,2,1,1,)8500000' '\g<1>8400000'
plant "waterfall" '^(A\|[^|]*\|director1\|[0-9]+\|x:40,2,)2000000' '\g<1>1999999'
plant "clearing member" '^(G\|1\|1\|5000000\|)([1-9][0-9]*)' '\g<1>1'
plant "custody row" '^(J\|1\|1\|)([1-9][0-9]*)' '\g<1>7'
plant "figures" '^(W\|[0-9]+\|)([1-9][0-9]*)' '\g<1>1'
plant "settlement root" '^(M\|[0-9]+\|)([0-9a-f])' '\g<1>X'
plant "admitted leg" '^(CL\|[0-9]+\|[0-9]+\|[0-9]+\|)([1-9][0-9]*)' '\g<1>9999'
plant "custody position" '^(CP\|1\|)([1-9][0-9]*)' '\g<1>1'
plant "the CCP's cash" '^(Q\|18\|cash\|)([1-9][0-9]*)' '\g<1>1'
ref="$here/integration/regulator_replay.py"
plant "block byte" '^(L\|60\|.{60}[0-9a-f]*?)([1-9a-f])' '\g<1>0'
echo "clearing control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
