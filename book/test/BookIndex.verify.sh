#!/usr/bin/env bash
# The off-chain checks of the index battery: the Python reference book replays the commands alone, computing every
# capped factor, divisor, level and breaker again and requiring every index row and the whole path equal; the feed's
# consumer holds the visible book (the breaker's halts in it) from the public feed alone; the regulator's replay
# refolds the certified log and requires the book's fingerprint.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
# the index rows and the path are compared, not merely present: a reference that compared none fails here
out="$(python3 "$here/integration/reference_book.py" "$1")" || { echo "$out"; exit 1; }; echo "$out"
echo "$out" | grep -Eq '^reference: [1-9][0-9]* index rows and [1-9][0-9]* path levels compared' || { echo "reference: no index row compared"; exit 1; }
python3 "$here/integration/feed_book.py" "$1"
python3 "$here/integration/regulator_replay.py" "$1"
