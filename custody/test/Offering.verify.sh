#!/usr/bin/env bash
# The offering checks: the ladder and the clearing price, the pricing, every order's allocation, cash due and refund,
# the allocation file's hash chain, the listing gate and the hand-off's proceeds and fee, recomputed by the Python
# twin (integration/offering_twin.py) from the dump alone; then the twin's own controls: six alterations of a copy of
# the dump, one per computation, each of which must turn the twin red.
set -u
cd "$(dirname "$0")/.."
out="$(python3 integration/offering_twin.py "$1")" || { echo "$out"; exit 1; }
echo "$out" | grep -E '^(count:|FAULT)'
echo "$out" | grep -q '^OFFERING TWIN VERIFIED$' || exit 1
rc=0; controls=0
for c in ladder price allocation chain fee slice; do
  tmp="$(mktemp)"
  python3 - "$1" "$tmp" "$c" <<'PY' || { echo "TWIN CONTROL BROKEN: the $c alteration found nothing to alter"; rc=1; rm -f "$tmp"; continue; }
import sys
src, dst, c = sys.argv[1:4]
lines = open(src, encoding="utf-8").read().split("\n"); out = []; done = False
for l in lines:
    f = l.split("|")
    if not done:
        if c == "ladder" and l.startswith("ladder|") and f[2]:
            r = f[2].split(";"); p, n = r[0].split(":"); r[0] = p + ":" + str(int(n) + 1); f[2] = ";".join(r); done = True
        elif c == "price" and l.startswith("priced|1|"):
            e = f[2].split(","); e[1] = str(int(e[1]) + 10); f[2] = ",".join(e); done = True
        elif c == "allocation" and l.startswith("order|") and f[5].split(",")[4] not in ("0",):
            e = f[5].split(","); e[4] = str(int(e[4]) + 1); f[5] = ",".join(e); done = True
        elif c == "chain" and l.startswith("offering|1|"):
            f[3] = ("0" if f[3][0] != "0" else "1") + f[3][1:]; done = True
        elif c == "fee" and l.startswith("handoff|"):
            e = f[2].split(","); e[2] = str(int(e[2]) + 1); f[2] = ",".join(e); done = True
        elif c == "slice" and l.startswith("slice|"):
            e = f[2].split(","); e[2] = str(int(e[2]) + 1); f[2] = ",".join(e); done = True
    out.append("|".join(f))
if not done: sys.exit(1)
open(dst, "w", encoding="utf-8").write("\n".join(out))
PY
  if python3 integration/offering_twin.py "$tmp" > /dev/null 2>&1; then echo "TWIN CONTROL BROKEN: the twin stayed green over an altered $c"; rc=1; else controls=$((controls+1)); fi
  rm -f "$tmp"
done
echo "count: twin controls turned red = $controls"
[ "$rc" -eq 0 ] && [ "$controls" -eq 6 ]
