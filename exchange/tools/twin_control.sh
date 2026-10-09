#!/usr/bin/env bash
# The twin's control: three faults planted in a copy of a green battery log, each of a class the twin claims to
# catch (a scheduler outcome, an ISIN verdict, a tick verdict); the twin must go red on every one, and green on the
# unaltered log first. A planted fault that changes nothing (the pattern not found) is CONTROL BROKEN.
#   exchange/tools/twin_control.sh <battery log>
set -u
log="$1"; twin="$(cd "$(dirname "$0")/.." && pwd)/integration/exchange_twin.py"; work="$(mktemp -d)"
python3 "$twin" "$log" > /dev/null || { echo "STOP: the twin is red on the unaltered log"; exit 1; }
red=0; total=0
plant() {  # name, python expression replacing one line
  total=$((total+1)); out="$work/$1.log"
  python3 - "$log" "$out" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
lines = open(src).read().split("\n")
for i, l in enumerate(lines):
    if l.startswith(old):
        lines[i] = new + l[len(old):] if new.startswith("dump:") else new
        open(dst, "w").write("\n".join(lines)); sys.exit(0)
sys.exit(3)
PY
  rc=$?
  if [ $rc -ne 0 ]; then echo "$1: CONTROL BROKEN (no line starts with $2)"; return; fi
  if cmp -s "$log" "$out"; then echo "$1: CONTROL BROKEN (the plant changed nothing)"; return; fi
  if python3 "$twin" "$out" > /dev/null; then echo "$1: GREEN UNDER FAULT"; else echo "$1: RED"; red=$((red+1)); fi
}
first_adv="$(grep -m1 '^dump:advance|1|.*|1>2$' "$log")"
plant "phase" "$first_adv" "${first_adv%1>2}1>4"
plant "isin" "dump:isin|XS0TESTA0015|0" "dump:isin|XS0TESTA0015|1"
plant "tick" "dump:tick|2005|0" "dump:tick|2005|1"
echo "twin control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
