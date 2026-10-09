#!/usr/bin/env bash
# The controls of the gateway battery's off-chain checks (SPEC §37): faults planted in a copy of a green BookGateway log,
# each of a class a check claims to catch. For the reference: a replacement to a reference the account uses, logged as
# executed; a refused replacement to a reference nobody uses; a refused 21-byte reference shortened to 20 bytes. For the
# regulator's replay: a byte of the replacement's stored block. For the reports rebuilt from the log alone: the
# replacement's block gone, the second fill's block gone. Each check must be green on the unaltered log first and red on
# every planted copy. A plant that finds no line, or changes nothing, is CONTROL BROKEN.
#   book/tools/gateway_control.sh <BookGateway log>
set -u
log="$1"; here="$(cd "$(dirname "$0")/.." && pwd)"; work="$(mktemp -d)"
ref="$here/integration/reference_book.py"; reg="$here/integration/regulator_replay.py"; hand="$here/../gateway/hand_reports.py"
for c in "$ref" "$reg" "$hand"; do python3 "$c" "$log" > /dev/null || { echo "STOP: $(basename "$c") is red on the unaltered log"; exit 1; }; done
red=0; total=0
plant() {
  total=$((total+1)); out="$work/$total.log"; check="$2"
  python3 - "$log" "$out" "$3" "$4" <<'PY'
import re, sys
src, dst, pat, rep = sys.argv[1:5]
lines = open(src).read().split("\n")
for i, l in enumerate(lines):
    if re.search(pat, l):
        if rep == "DROP":
            del lines[i]
        else:
            lines[i] = re.sub(pat, rep, l, count=1)
        open(dst, "w").write("\n".join(lines)); sys.exit(0)
sys.exit(3)
PY
  rc=$?
  if [ $rc -ne 0 ]; then echo "$1: CONTROL BROKEN (no line matches $3)"; return; fi
  if cmp -s "$log" "$out"; then echo "$1: CONTROL BROKEN (the plant changed nothing)"; return; fi
  if python3 "$check" "$out" > /dev/null 2>&1; then echo "$1: GREEN UNDER FAULT"; else echo "$1: RED"; red=$((red+1)); fi
}
plant "a used reference executed" "$ref" '(k=replaceOrder;order=1;qty=30;price=84990;ref=)G2(\|x:67)' '\g<1>H1\g<2>'
plant "an unused reference refused" "$ref" '(k=replaceOrder;order=1;qty=30;price=84990;ref=)H1(\|e:DuplicateClientRef)' '\g<1>H7\g<2>'
plant "a 20-byte reference refused" "$ref" '(ref=)123456789012345678901(\|e:InvalidTerms)' '\g<1>12345678901234567890\g<2>'
plant "the replacement's block byte" "$reg" '^(L\|13\|.{60}[0-9a-f]*?)([1-9a-f])' '\g<1>0'
plant "the replacement's block gone" "$hand" '^L\|13\|' 'DROP'
plant "the second fill's block gone" "$hand" '^L\|18\|' 'DROP'
echo "gateway control: $red of $total planted faults refused"
[ "$red" -eq "$total" ] && [ "$total" -gt 0 ]
