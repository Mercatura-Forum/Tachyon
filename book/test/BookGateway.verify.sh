#!/usr/bin/env bash
# The off-chain checks of the gateway battery: the Python reference book replays the commands alone; the feed's consumer
# holds the visible book from the public feed alone; the regulator's replay refolds the certified log; and the gateway's
# rule (`gateway/orderlog.py`, `gateway/er.py`) gives, from this log alone, the ExecutionReports of account 2 worked by
# hand in BookGateway.test.mo, in order.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/reference_book.py" "$1"
python3 "$here/integration/feed_book.py" "$1"
python3 "$here/integration/regulator_replay.py" "$1"
python3 "$here/../gateway/hand_reports.py" "$1"
