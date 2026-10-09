#!/usr/bin/env bash
# The controls of the index battery's off-chain checks (SPEC §26, §27): faults planted in a copy of a green BookIndex
# log, each of a class the reference claims to catch: an index's level, its reference, its breaker's state, its
# divisor, a level on the path, the block a level is recorded at, an instrument the breaker halted shown trading; and
# for the regulator's replay, a byte of the stored tripBreaker block. Each check must be green on the unaltered log
# first and red on every planted copy. A plant that finds no line, or changes nothing, is CONTROL BROKEN.
#   book/tools/index_control.sh <BookIndex log>
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
plant "index level" '^(IX\|1\|)101103' '\g<1>101104'
plant "index reference" '^(IX\|1\|[0-9]+\|)100000' '\g<1>99999'
plant "breaker state" '^(IX\|1\|77698\|100000\|)2' '\g<1>1'
plant "divisor" '^(IX\|1\|[0-9]+\|[0-9]+\|[0-9]\|)962675803487532516344717763073301' '\g<1>962675803487532516344717763073302'
plant "path level" '^(IP\|1\|[0-9]+\|)89400' '\g<1>89401'
plant "path block" '^(IP\|1\|)20(\|101103)' '\g<1>21\g<2>'
plant "breaker halt" '^(I\|2\|)halted' '\g<1>continuous'
ref="$here/integration/regulator_replay.py"
# the tripBreaker block: the one straight after the block that recorded the last level on the path (SPEC §27)
blk="$(awk -F'|' '$1 == "IP" { b = $3 } END { if (b != "") print b + 1 }' "$log")"
plant "breaker block byte" "^(L\\|${blk:-none}\\|.{60}[0-9a-f]*?)([1-9a-f])" '\g<1>0'
echo "index control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
