#!/usr/bin/env bash
# The off-chain check of the surveillance battery: the desk's rules written again in Python, applied to every book log
# the battery printed, requiring every alert, its evidence and every report's hash equal to the desk's.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/surveillance_replay.py" "$1"
