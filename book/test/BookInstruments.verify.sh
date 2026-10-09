#!/usr/bin/env bash
# The off-chain checks of the instruments battery: the Python reference book replays the commands alone, computing every
# accrual (with its own date arithmetic), iNAV, receipt, retirement, entitlement and ledger's units again; the feed's
# consumer holds the visible book from the public feed alone; the regulator's replay
# refolds the certified log and requires the book's fingerprint.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
# the class rows are compared, not merely present: a reference that compared none fails here
out="$(python3 "$here/integration/reference_book.py" "$1")" || { echo "$out"; exit 1; }; echo "$out"
echo "$out" | grep -Eq '^reference: [1-9][0-9]* class rows \(terms, iNAVs and path, receipts, retirements, entitlements\) compared' || { echo "reference: no class row compared"; exit 1; }
python3 "$here/integration/feed_book.py" "$1"
python3 "$here/integration/regulator_replay.py" "$1"
