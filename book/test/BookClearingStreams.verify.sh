#!/usr/bin/env bash
# The off-chain checks of the clearing streams: the Python reference book replays every stream from the commands alone,
# recounting margins, the CCP's commitment and the custody's held shares from the open orders, checking the CCP's cash
# and custody identities after every command, and hashing the settlement range from its legs; the feed's consumer holds
# the visible book from the public feed alone.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/reference_book.py" "$1"
python3 "$here/integration/feed_book.py" "$1"
