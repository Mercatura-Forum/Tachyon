#!/usr/bin/env bash
# The controls of the derivatives battery's off-chain checks (SPEC §33 to §35): faults planted in a copy of a green
# BookDerivatives log, each of a class the reference claims to catch: a contract's mark, its last day settled, an
# attested price, a position's contracts, a position's margin, a member's positions' margin, the cash the cycle paid member
# 2 out of the variations, premiums and payoffs; and for the regulator's replay, a byte of a stored block. Each check must
# be green on the unaltered log first and red on every planted copy. A plant that finds no line, or changes nothing, is
# CONTROL BROKEN.
#   book/tools/derivatives_control.sh <BookDerivatives log>
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
plant "a contract's mark" '^(DV\|12\|)101000' '\g<1>101001'
plant "a day settled" '^(DV\|13\|2650\|)20514' '\g<1>20513'
plant "an attested price" '^(AT\|12\|20514\|2\|)101200' '\g<1>101300'
plant "a position's contracts" '^(PO\|13\|13\|2\|0\|)2' '\g<1>3'
plant "a position's margin" '^(PO\|13\|14\|2\|0\|3\|1800\|)324000' '\g<1>323999'
plant "a member's positions' margin" '^(PM\|2\|)1081000' '\g<1>1081001'
plant "the cycle's payment" '^(Q\|9\|cash\|)18057820' '\g<1>18057821'
ref="$here/integration/regulator_replay.py"
plant "block byte" '^(L\|70\|.{60}[0-9a-f]*?)([1-9a-f])' '\g<1>0'
echo "derivatives control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
