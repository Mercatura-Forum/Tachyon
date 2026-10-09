// BookIndexStreams.test.mo: random streams on books with indices (SPEC §26, §27): levels recomputed after every act
// that moves a price, reviews and corporate actions keeping the level by a new divisor, the breaker tripped by the
// stream's own prices and halting every book in the block after, suspensions held to the close and re-armed at the
// seal, among every other command of the book. Every command printed with its outcome for the Python reference
// (BookIndexStreams.verify.sh), which recomputes every factor, divisor, level, path entry and breaker from the commands.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
let { n; printCoverage; seenCount } = w;

w.seed := w.seed ^ Nat64.fromNat(0x1D_0001);
let (commands, replays) = w.indexStreams(0, 3, 1_500);
Debug.print("count: random commands on books with indices, judged by the book and the reference = " # n(commands));
Debug.print("count: books with indices whose log replayed to the same fingerprint = " # n(replays));
printCoverage(["pairs", "clears that traded", "checkpoints", "corporate actions", "breakers tripped", "resumptions", "days sealed"]);
for (f in ["defineIndex", "reviewIndex", "corporateAction", "resume"].vals()) Debug.print("count: executed " # f # " = " # n(seenCount("executed " # f)));
for (e in ["refused ClearNotSubmittable", "refused InvalidTerms", "refused UnknownInstrument"].vals()) Debug.print("count: " # e # " = " # n(seenCount(e)));

if (w.failures > 0) { Debug.print("INDEX STREAMS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("INDEX STREAMS GREEN");
