#!/usr/bin/env bash
# The custody register's off-chain check: the positions refolded, every entitlement, file and reconciliation
# recomputed by the Python twin (custody/integration/custody_twin.py), which must print CUSTODY TWIN VERIFIED.
set -u
cd "$(dirname "$0")/.."
out="$(python3 integration/custody_twin.py "$1")" || { echo "$out"; exit 1; }
echo "$out" | grep -E '^(count:|FAULT)'
echo "$out" | grep -q '^CUSTODY TWIN VERIFIED$' && echo "$out" | grep -Eq '^count: [^=]+ = [1-9][0-9]*$'
