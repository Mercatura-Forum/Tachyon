#!/usr/bin/env bash
# The controls of the surveillance oracle: faults planted in a copy of a green battery log, each of a class the oracle
# claims to catch: an alert the desk raised removed, an alert's evidence altered, a sealed report's hash altered, a block
# of the book's log removed. The oracle must be green on the unaltered log and red on every planted copy; a plant that
# finds no line or changes nothing is CONTROL BROKEN.
#   surveillance/tools/oracle_control.sh <battery log>
set -u
log="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"; work="$(mktemp -d)"
oracle="$here/integration/surveillance_replay.py"
python3 "$oracle" "$log" > /dev/null || { echo "STOP: the oracle is red on the unaltered log"; exit 1; }
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
  if python3 "$oracle" "$out" > /dev/null; then echo "$1: GREEN UNDER FAULT"; else echo "$1: RED"; red=$((red+1)); fi
}
plant "alert removed" '^SA\|3\|.*$' 'SA-removed'
plant "evidence altered" '^(SA\|1\|1\|[0-9]+\|1\|[0-9a-f]+\|\|[0-9]+\|[0-9]+\|)10\|' '\g<1>20|'
plant "report hash altered" '^(SR\|[0-9]+\|[0-9]+\|)[0-9]' '\g<1>a'
plant "book block removed" '^L\|40\|.*$' 'L-removed'
echo "oracle control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
