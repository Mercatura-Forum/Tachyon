#!/usr/bin/env bash
# The twin's own control: a dumped figure altered by one in a copy of the battery's log must turn the twin red; a
# twin that stays green over an altered figure checks nothing. Three alterations: an entitlement's cash due, a
# holder's position, an action's file hash.
#   custody/tools/twin_control.sh <battery log>
set -u
cd "$(dirname "$0")/.."
rc=0
alter() {  # <src> <dst> <line prefix> <field index> [text]
  python3 - "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import sys
src, dst, prefix, field, text = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
lines = open(src).read().split("\n"); done = False; out = []
for l in lines:
    if not done and l.startswith(prefix + "|") and l.split("|")[field] not in ("", "0"):
        f = l.split("|"); f[field] = (text if text else str(int(f[field]) + 1)); l = "|".join(f); done = True
    out.append(l)
assert done, "no %s line to alter" % prefix
open(dst, "w").write("\n".join(out))
PY
}
for kind in "entitlement:4:" "holder:2:" "action:9:deadbeef"; do
  IFS=: read -r prefix field text <<<"$kind"
  tmp="$(mktemp)"
  alter "$1" "$tmp" "$prefix" "$field" "$text"
  if python3 integration/custody_twin.py "$tmp" > /dev/null 2>&1; then echo "TWIN CONTROL BROKEN: the twin stayed green over an altered $prefix figure"; rc=1; else echo "TWIN CONTROL GREEN: the twin went red over an altered $prefix figure"; fi
  rm -f "$tmp"
done
exit $rc
