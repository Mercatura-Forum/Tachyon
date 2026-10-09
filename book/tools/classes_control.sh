#!/usr/bin/env bash
# The controls of the instruments battery's off-chain checks (SPEC §28 to §32): faults planted in a copy of a green
# BookInstruments log, each of a class the reference claims to catch: a bond's terms, its value date, a fund's iNAV and a
# level on its path, a receipt's state, a retirement's quantity, an entitlement's shares, a ledger's units in the book,
# the cash a bond's buyer holds after paying the accrued interest; and for the regulator's replay, a byte of a stored
# block. Each check must be green on the unaltered log first and red on every planted copy. A plant that finds no line,
# or changes nothing, is CONTROL BROKEN.
#   book/tools/classes_control.sh <BookInstruments log>
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
plant "bond terms" '^(TM\|5\|cls=bond;coupon=)1850' '\g<1>1851'
plant "value date" '^(VD\|5\|)20515' '\g<1>20516'
plant "iNAV" '^(NV\|6\|1000\|500500\|)13100' '\g<1>13101'
plant "iNAV path" '^(NP\|6\|[0-9]+\|)12990' '\g<1>12991'
plant "receipt state" '^(RC\|1\|3\|7\|10\|50\|)0' '\g<1>1'
plant "retirement" '^(RT\|1\|10\|8\|)40' '\g<1>41'
plant "entitlement" '^(EN\|1\|2\|9\|120\|)24' '\g<1>25'
plant "units in the book" '^(SU\|wheat\|)30' '\g<1>31'
plant "bond buyer's cash" '^(Q\|2\|cash\|)([0-9]+)' '\g<1>1\g<2>'
ref="$here/integration/regulator_replay.py"
plant "block byte" '^(L\|80\|.{60}[0-9a-f]*?)([1-9a-f])' '\g<1>0'
echo "classes control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
