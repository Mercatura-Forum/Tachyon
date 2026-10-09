// BookEpisodes12.test.mo: part 12 of 24 of the book's random episodes (written by book/tools/episodes_parts.py).
// 420 episodes of 20 random commands, each from an empty book on one long-lived book: after an episode the
// accounts with open orders cancel them all. Every command is printed with its outcome for the Python reference
// (BookEpisodes12.verify.sh), which replays the part from the commands alone. With the other parts: 10080 episodes.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
w.seed := w.seed ^ Nat64.fromNat(0xE9_0000 + 12);
let commands = w.episodes(420, 20, 60);
Debug.print("count: episodes of random commands judged by the book and the reference = " # Nat.toText(w.seenCount("episodes")));
Debug.print("count: random commands in the episodes = " # Nat.toText(commands));
w.printCoverage(["pairs", "clears that traded", "stops triggered", "orders cancelled at a clear", "uncrossed books checked", "checkpoints", "continuous trades checked within the bands", "trades at close", "volatility interruptions", "uncrosses", "uncrosses that traded", "uncrosses equal to their indicative price", "feed digests printed"]);
if (w.failures > 0) { Debug.print("BOOK EPISODES 12 FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("BOOK EPISODES 12 GREEN");
