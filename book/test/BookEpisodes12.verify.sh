#!/usr/bin/env bash
# The off-chain checks of a Book battery: the Python reference book replays every stream from the commands alone with
# its own code and requires every outcome, every block of the log, every order and every balance equal; the feed's
# consumer holds the visible book from the public feed alone and requires it equal to the book's after every act.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/reference_book.py" "$1"
python3 "$here/integration/feed_book.py" "$1"
