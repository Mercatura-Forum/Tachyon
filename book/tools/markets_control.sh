#!/usr/bin/env bash
# The controls of the markets battery's off-chain checks (SPEC §22 to §25): faults planted in a copy of a green
# BookMarkets log, each of a class the reference claims to catch: a fill's fee (the clear's effects), a fee total, a
# levy the CCP owes, an open statement's hash, a sealed statement, a reconciliation's hash, a maker's presence, a
# maker's period, a levy account's cash; and for the regulator's replay, a byte of a stored block. Each check must be
# green on the unaltered log first and red on every planted copy. A plant that finds no line, or changes nothing, is
# CONTROL BROKEN.
#   book/tools/markets_control.sh <BookMarkets log>
set -u
log="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"; work="$(mktemp -d)"
ref="$here/integration/reference_book.py"
python3 "$ref" "$log" > /dev/null || { echo "STOP: the reference is red on the unaltered log"; exit 1; }
python3 "$here/integration/regulator_replay.py" "$log" > /dev/null || { echo "STOP: the regulator's replay is red on the unaltered log"; exit 1; }
red=0; total=0
plant() {
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
plant "fee total" '^(T\|f\|1\|1\|)([1-9][0-9]*)' '\g<1>1699'
plant "levy owed" '^(T\|p\|21\|)([0-9]+)' '\g<1>9'
plant "open statement" '^(N\|1\|[0-9]+\|)([0-9a-f])' '\g<1>X'
plant "sealed statement" '^(P\|1\|[0-9]+\|[0-9]+\|)([0-9a-f])' '\g<1>X'
plant "reconciliation" '^(R\|1\|2\|[0-9]+\|3\|)2' '\g<1>3'
plant "maker's presence" '^(X\|1\|2\|[0-9]+\|[0-9]+\|[0-9]+\|[01]\|[01]\|)([1-9][0-9]*)' '\g<1>7'
plant "maker's period" '^(Z\|1\|2\|[0-9]+\|[0-9]+\|[0-9]+\|1\|)124' '\g<1>125'
plant "levy's cash" '^(Q\|21\|cash\|)([1-9][0-9]*)' '\g<1>1'
ref="$here/integration/regulator_replay.py"
plant "block byte" '^(L\|40\|.{60}[0-9a-f]*?)([1-9a-f])' '\g<1>0'
echo "markets control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
