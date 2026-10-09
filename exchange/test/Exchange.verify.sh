#!/usr/bin/env bash
# The off-chain check of the Exchange battery: the Python twin recomputes every phase, ISIN and tick decision from
# the battery's dump with its own code.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/exchange_twin.py" "$1"
