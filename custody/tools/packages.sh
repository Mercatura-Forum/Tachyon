#!/usr/bin/env bash
# Emits the moc --package flags for the custody module: the mops dependencies (absolute paths, so the runner may
# work from any directory) plus the Thebes kernel, vendored as a git submodule at the commit git records.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRCS="$(cd "$ROOT" && mops sources 2>/dev/null | sed "s#--package \([^ ]*\) \.mops/#--package \1 $ROOT/.mops/#g")"
echo "$SRCS --package kernel $ROOT/vendor/thebes-kernel/src"
