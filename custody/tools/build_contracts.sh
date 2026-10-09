#!/usr/bin/env bash
# build_contracts.sh: the private line's contracts built for a Thebes chain: the venue (`venue/src/Venue.mo`) and the
# judge's test actor (`custody/integration/VenueJudge.mo`), from the tree at <tree> (a committed tree copied by
# committed_tree.sh) into <out>, each with its sha256.
#
#   custody/tools/build_contracts.sh <tree> <out>
#
# Legacy (classical) persistence is required: the substrate carries stable memory, and only stable memory, to the new
# module on an in-place upgrade. A module built with moc's default (enhanced orthogonal persistence) keeps its state in
# main memory and comes back from an upgrade empty: every row and every log gone.
#
# Attribution: Thebes Core Team.
set -euo pipefail
tree="$(cd "$1" && pwd)"; out="$2"
MOC="${MOC:-$HOME/.cache/mops/moc/1.4.1/moc}"
mkdir -p "$out"
cd "$tree"
S="$(custody/tools/packages.sh)"
for src in venue/src/Venue.mo custody/integration/VenueJudge.mo; do
  name="$(basename "$src" .mo)"
  "$MOC" --legacy-persistence $S -o "$out/$name.wasm" "$src" 2> "$out/$name.build.log" || { cat "$out/$name.build.log"; exit 1; }
  echo "$(sha256sum "$out/$name.wasm" | cut -c1-64)  $name.wasm  (moc --legacy-persistence, $(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo "tree $tree"))"
done
