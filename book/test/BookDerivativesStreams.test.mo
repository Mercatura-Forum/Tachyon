// BookDerivativesStreams.test.mo: random streams on books that clear, with a future, a call and a put on an index (SPEC
// §33 to §35): orders from clearing members' accounts within their margin, attestations for the day (now and then stale
// or repeated, refused), daily settlements in slices with trading closed and no cycle cut within a run, expiry on the
// index's level, the variations, premiums and payoffs netted into the clearing's cycles, among every other command of
// the book. Every command printed with its outcome for the Python reference (BookDerivativesStreams.verify.sh), which
// recomputes every median, variation, premium, payoff, margin and position, and the CCP's cash with every run's balance.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
let { n; printCoverage; seenCount } = w;

w.seed := w.seed ^ Nat64.fromNat(0xD7_0001);
let (commands, replays) = w.derivativesStreams(0, 3, 1_500);
Debug.print("count: random commands on books with derivatives, judged by the book and the reference = " # n(commands));
Debug.print("count: books with derivatives whose log replayed to the same fingerprint = " # n(replays));
printCoverage(["pairs", "clears that traded", "checkpoints"]);
for (f in ["attestPrice", "settleDerivatives", "settleCycle", "cutCycle"].vals()) Debug.print("count: executed " # f # " = " # n(seenCount("executed " # f)));
for (e in ["refused InvalidTerms", "refused MarginShort"].vals()) Debug.print("count: " # e # " = " # n(seenCount(e)));

if (w.failures > 0) { Debug.print("DERIVATIVE STREAMS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("DERIVATIVE STREAMS GREEN");
