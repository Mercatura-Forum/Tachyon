#!/usr/bin/env bash
# The off-chain check of the Book battery: the Python reference book replays every stream from the commands alone with
# its own code and requires every outcome, every block of the log, every order and every balance equal.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/reference_book.py" "$1"
