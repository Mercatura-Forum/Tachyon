#!/usr/bin/env bash
# The off-chain checks of the derivatives battery: the Python reference book replays the commands alone, computing every
# attested median, variation, premium, payoff, margin and position again; the feed's consumer holds the visible book from
# the public feed alone; the regulator's replay refolds the certified log and requires the book's fingerprint.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
# the derivative rows are compared, not merely present: a reference that compared none fails here
out="$(python3 "$here/integration/reference_book.py" "$1")" || { echo "$out"; exit 1; }; echo "$out"
echo "$out" | grep -Eq '^reference: [1-9][0-9]* derivative rows \(settlement states, attestations, positions\) compared' || { echo "reference: no derivative row compared"; exit 1; }
python3 "$here/integration/feed_book.py" "$1"
python3 "$here/integration/regulator_replay.py" "$1"
