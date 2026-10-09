#!/usr/bin/env bash
# The gateway's checks without a chain: QuickFIX/J's conformance sessions (FIX 4.4; FIX 5.0 SP2 over FIXT.1.1) through
# `gateway.Gateway` with a stand-in venue
# (test/standin.py), then each planted fault, which must turn it RED. The engine is fetched and pinned by
# conformance/fetch.sh into $QFJ_DIR.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="${QFJ_DIR:-$HOME/.cache/thebes-quickfixj-2.3.1}"
"$here/conformance/fetch.sh" "$dir" > /dev/null || { echo "FAILED: the conformance engine"; exit 1; }
fail=0
python3 "$here/test/framing.py" || { echo "FAILED: framing"; fail=$((fail+1)); }
for v in 4.4 5.0sp2; do
  timeout 600 python3 "$here/test/standin.py" "$dir" --version $v || { echo "FAILED: the conformance session, FIX $v"; fail=$((fail+1)); }
done
red=0; total=0
for run in "4.4 drop-leaves" "4.4 resend-without-possdup" "5.0sp2 drop-leaves" "5.0sp2 resend-without-possdup"; do
  set -- $run; total=$((total+1))
  if timeout 900 python3 "$here/test/standin.py" "$dir" --version "$1" --plant "$2" > /dev/null 2>&1; then echo "FIX $1 $2: GREEN UNDER FAULT"; else echo "FIX $1 $2: RED"; red=$((red+1)); fi
done
echo "count: planted faults the conformance refused = $red"
[ "$red" -eq "$total" ] || fail=$((fail+1))
echo "tests: framing + 2 sessions + $total controls, failed: $fail"
[ "$fail" -eq 0 ]
