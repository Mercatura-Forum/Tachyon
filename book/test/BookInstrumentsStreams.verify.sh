#!/usr/bin/env bash
# The off-chain checks of the random instrument-class streams: the Python reference book replays the commands alone,
# computing every accrual with its own date arithmetic, every iNAV, receipt, retirement, entitlement and ledger's units
# again; the feed's consumer holds the visible book from the public feed alone. (The streams' logs replay to
# their fingerprints inside the battery; the regulator's replay of a printed log is the hand battery's.)
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
# the class rows are compared, not merely present: a reference that compared none fails here
out="$(python3 "$here/integration/reference_book.py" "$1")" || { echo "$out"; exit 1; }; echo "$out"
echo "$out" | grep -Eq '^reference: [1-9][0-9]* class rows \(terms, iNAVs and path, receipts, retirements, entitlements\) compared' || { echo "reference: no class row compared"; exit 1; }
# the streams settle accrued interest (legs of kind 6) and subscriptions (kind 7): streams that settled none fail here
echo "$out" | grep -Eq '^reference: settlement legs by kind .*\b6:[1-9][0-9]*, 7:[1-9]' || { echo "reference: no accrued interest or subscription settled"; exit 1; }
python3 "$here/integration/feed_book.py" "$1"
