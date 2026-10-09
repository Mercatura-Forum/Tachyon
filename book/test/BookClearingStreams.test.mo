// BookClearingStreams.test.mo: random streams on fresh books that clear (SPEC §18 to §21): clearing and pre-funded
// orders, collateral, the fund, cycles cut and settled, fails, close-outs, defaults and their waterfalls, among every
// other command of the book. Every command printed with its outcome for the Python reference (BookClearingStreams.verify.sh),
// which recounts margins, the CCP's commitment and the custody's held shares from the open orders, checks the CCP's
// cash and custody identities after every command, and hashes the settlement range from its legs.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import K "../src/BookCanonical";
import W "support/World";

let w = W.World(false);
let { n; printCoverage; seenCount } = w;

w.seed := w.seed ^ Nat64.fromNat(0xC1EA_0001);
let (commands, replays) = w.clearingStreams(0, 3, 1_500);
Debug.print("count: random commands on books that clear, judged by the book and the reference = " # n(commands));
Debug.print("count: books that clear whose log replayed to the same fingerprint = " # n(replays));
printCoverage(["pairs", "clears that traded", "checkpoints", "clearing checkpoints", "settlement proofs verified", "cycle fails"]);
for (f in ["postCollateral", "withdrawCollateral", "callFund", "contributeFund", "cutCycle", "settleCycle", "closeOut", "declareDefault", "closeDefault"].vals()) Debug.print("count: executed " # f # " = " # n(seenCount("executed " # f)));
for (e in ["refused FundShort", "refused MarginShort", "refused LiquidityShort", "refused CycleNotDue", "refused NotClearing"].vals()) Debug.print("count: " # e # " = " # n(seenCount(e)));
ignore K.families;

if (w.failures > 0) { Debug.print("CLEARING STREAMS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("CLEARING STREAMS GREEN");
