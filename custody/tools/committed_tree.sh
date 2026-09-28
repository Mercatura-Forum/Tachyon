#!/usr/bin/env bash
# The committed tree, and nothing else, in a scratch directory: `git archive HEAD` of this repository, the kernel
# submodule archived at the commit git records, the resolved packages copied in. Every gate builds from this, so what
# is proved is what is committed.
#   custody/tools/committed_tree.sh <out-dir>
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"
rm -rf "$out"; mkdir -p "$out"
git -C "$root" archive HEAD | tar -x -C "$out"
mkdir -p "$out/vendor/thebes-kernel"
if git -C "$root" ls-tree HEAD vendor/thebes-kernel | grep -q '^160000'; then
  # the kernel as a submodule: archived at the commit git records
  pin="$(git -C "$root" ls-tree HEAD vendor/thebes-kernel | awk '{print $3}')"
  git -C "$root/vendor/thebes-kernel" archive "$pin" | tar -x -C "$out/vendor/thebes-kernel"
else
  # the kernel placed by the reader (vendor/thebes-kernel/README.md names the commit): a git checkout of it, at that
  # commit, archived at that commit; anything else is refused
  # the commit as the committed README names it (a checkout placed there replaces the file in the working tree)
  pin="$(git -C "$root" show HEAD:vendor/thebes-kernel/README.md 2>/dev/null | grep -o 'commit `[0-9a-f]*`' | grep -o '[0-9a-f]\{7,\}')"
  [ -n "$pin" ] || { echo "vendor/thebes-kernel/README.md names no commit"; exit 1; }
  here="$(git -C "$root/vendor/thebes-kernel" rev-parse HEAD 2>/dev/null || true)"
  case "$here" in "$pin"*) ;; *) echo "vendor/thebes-kernel is not a checkout of the kernel at $pin (found: ${here:-none})"; exit 1 ;; esac
  git -C "$root/vendor/thebes-kernel" archive "$pin" | tar -x -C "$out/vendor/thebes-kernel"
fi
cp -r "$root/.mops" "$out/.mops"
echo "$out: tachyon $(git -C "$root" rev-parse --short HEAD), kernel $(echo "$pin" | cut -c1-7)"
