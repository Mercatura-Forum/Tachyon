#!/usr/bin/env bash
# The off-chain checks of the main Book battery: the Python reference book replays every stream from the commands alone
# and requires every outcome, block, order and balance equal; the regulator's replay rebuilds the book from its
# certified log alone and requires every recorded effect and the book's fingerprint; the feed's consumer holds the visible
# book from the public feed alone and requires it equal to the book's after every act.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/reference_book.py" "$1"
python3 "$here/integration/feed_book.py" "$1"
python3 "$here/integration/regulator_replay.py" "$1"
