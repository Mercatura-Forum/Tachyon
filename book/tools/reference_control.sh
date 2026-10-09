#!/usr/bin/env bash
# The controls of the off-chain checks: faults planted in a copy of a green main battery log. For the reference book,
# each of a class it claims to catch: an outcome (a command's effects), a block of the log (a clear's price), an
# order's state (its fill), a balance (an available amount), an order the book never reported. For the regulator's
# replay: a byte changed inside a stored block, a block removed from the log, a fingerprint the book did not state.
# Each check must be green on the unaltered log first and red on every planted copy. A plant that finds no line, or
# changes nothing, is CONTROL BROKEN.
#   book/tools/reference_control.sh <battery log>
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
plant "outcome" '^(C\|[^|]*\|[^|]*\|k=placeOrder[^|]*\|x:6,)([0-9]+)' '\g<1>999999'
plant "clear" '^(B\|[0-9]+\|[0-9]+\|clear\|13,1,)([1-9][0-9]*)' '\g<1>1'
plant "order" '^(O\|[0-9]+\|3\|0\|)([1-9][0-9]*)' '\g<1>7'
plant "balance" '^(Q\|[0-9]+\|cash\|)([1-9][0-9]*)' '\g<1>1'
plant "unreported" '^(O\|)([0-9]+)(\|.*)$' '\g<1>9999999\g<3>'
plant "uncross price" '^(B\|[0-9]+\|[0-9]+\|uncross\|15,1,)([1-9][0-9]*)' '\g<1>1'
plant "phase" '^(I\|1\|)continuous' '\g<1>auction'
plant "risk use" '^(U\|2\|0\|0\|0\|)([1-9][0-9]*)' '\g<1>1'
plant "kill switch" '^(K\|1\|2\|0\|)0' '\g<1>1'
ref="$here/integration/regulator_replay.py"
plant "block byte" '^(L\|500\|.{60}[0-9a-f]*?)([1-9a-f])' '\g<1>0'
plant "block dropped" '^L\|700\|.*$' 'L-removed'
plant "fingerprint" '^(fingerprint\|book\|)(.)' '\g<1>X'
echo "reference control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
