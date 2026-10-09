// BookEpisodes10.test.mo: part 10 of 12 of the book's random episodes (written by book/tools/episodes_parts.py).
// 840 episodes of 20 random commands, each from an empty book on one long-lived book: after an episode the
// accounts with open orders cancel them all. Every command is printed with its outcome for the Python reference
// (BookEpisodes10.verify.sh), which replays the part from the commands alone. With the other parts: 10080 episodes.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
w.seed := w.seed ^ Nat64.fromNat(0xE9_0000 + 10);
let commands = w.episodes(840, 20, 60);
Debug.print("count: episodes of random commands judged by the book and the reference = " # Nat.toText(w.seenCount("episodes")));
Debug.print("count: random commands in the episodes = " # Nat.toText(commands));
w.printCoverage(["pairs", "clears that traded", "stops triggered", "orders cancelled at a clear", "uncrossed books checked", "checkpoints"]);
if (w.failures > 0) { Debug.print("BOOK EPISODES 10 FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("BOOK EPISODES 10 GREEN");
