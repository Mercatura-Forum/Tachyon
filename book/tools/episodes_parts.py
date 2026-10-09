#!/usr/bin/env python3
"""episodes_parts.py: writes book/test/BookEpisodesNN.test.mo (and its .verify.sh), the 10,000 random episodes of the
book's acceptance in parts. Each part is its own process: a WASI battery is one message, so the heap it allocates is never
collected; with the feed's visible book digested after every act, 840 episodes of twenty commands outgrew a
process's capped memory, so the 10,080 episodes run as 24 parts of 420. Every part is the same program with its own part
number (it seeds the generator); the reference and the feed's consumer check every part's log.

    python3 book/tools/episodes_parts.py        (rewrites the parts; the committed files must equal its output)

Attribution: Thebes Core Team.
"""
import os

PARTS, PER, STEPS = 24, 420, 20
HERE = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.join(HERE, "..", "test")

MO = '''// BookEpisodes{k:02d}.test.mo: part {k} of {parts} of the book's random episodes (written by book/tools/episodes_parts.py).
// {per} episodes of {steps} random commands, each from an empty book on one long-lived book: after an episode the
// accounts with open orders cancel them all. Every command is printed with its outcome for the Python reference
// (BookEpisodes{k:02d}.verify.sh), which replays the part from the commands alone. With the other parts: {total} episodes.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
w.seed := w.seed ^ Nat64.fromNat(0xE9_0000 + {k});
let commands = w.episodes({per}, {steps}, 60);
Debug.print("count: episodes of random commands judged by the book and the reference = " # Nat.toText(w.seenCount("episodes")));
Debug.print("count: random commands in the episodes = " # Nat.toText(commands));
w.printCoverage(["pairs", "clears that traded", "stops triggered", "orders cancelled at a clear", "uncrossed books checked", "checkpoints", "continuous trades checked within the bands", "trades at close", "volatility interruptions", "uncrosses", "uncrosses that traded", "uncrosses equal to their indicative price", "feed digests printed"]);
if (w.failures > 0) {{ Debug.print("BOOK EPISODES {k:02d} FAILED: " # Nat.toText(w.failures)); assert false }} else Debug.print("BOOK EPISODES {k:02d} GREEN");
'''
VERIFY = '''#!/usr/bin/env bash
# The off-chain checks of a Book battery: the Python reference book replays every stream from the commands alone with
# its own code and requires every outcome, every block of the log, every order and every balance equal; the feed's
# consumer holds the visible book from the public feed alone and requires it equal to the book's after every act.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$here/integration/reference_book.py" "$1"
python3 "$here/integration/feed_book.py" "$1"
'''

for k in range(1, PARTS + 1):
    with open(os.path.join(TEST, f"BookEpisodes{k:02d}.test.mo"), "w") as f:
        f.write(MO.format(k=k, parts=PARTS, per=PER, steps=STEPS, total=PARTS * PER))
    v = os.path.join(TEST, f"BookEpisodes{k:02d}.verify.sh")
    with open(v, "w") as f:
        f.write(VERIFY)
    os.chmod(v, 0o755)
print(f"{PARTS} parts of {PER} episodes: {PARTS * PER} episodes")
