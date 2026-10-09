#!/usr/bin/env bash
# The off-chain checks of the clearing battery: the Python reference book replays the stream from the commands alone,
# recounting margins, the CCP's commitment and the custody's held shares from the open orders and hashing the settlement
# range from its legs; the feed's consumer holds the visible book from the public feed alone; the regulator's replay
# refolds the certified log and requires the book's fingerprint.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/reference_book.py" "$1"
python3 "$here/integration/feed_book.py" "$1"
python3 "$here/integration/regulator_replay.py" "$1"
