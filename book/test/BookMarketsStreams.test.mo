// BookMarketsStreams.test.mo: random streams on books with fees and market makers that also clear (SPEC §18 to §25):
// fees on pre-funded and clearing parties, the levies paid at cycles, quotes and mass quotes replacing each other,
// fills taking quotes, statements sealed, makers' periods settled with rebates, reconciliations with breaks, among
// every other command of the book. Every command printed with its outcome for the Python reference
// (BookMarketsStreams.verify.sh), which recomputes every fee, hold, statement, presence and rebate from the commands.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
let { n; printCoverage; seenCount } = w;

w.seed := w.seed ^ Nat64.fromNat(0x3A_0001);
let (commands, replays) = w.marketsStreams(0, 3, 1_500);
Debug.print("count: random commands on books with fees and makers, judged by the book and the reference = " # n(commands));
Debug.print("count: books with fees and makers whose log replayed to the same fingerprint = " # n(replays));
printCoverage(["pairs", "clears that traded", "checkpoints", "clearing checkpoints", "cycles paying the levies", "rebates paid"]);
for (f in ["quote", "massQuote", "sealStatements", "settleMakers", "reconcileMember", "settleCycle"].vals()) Debug.print("count: executed " # f # " = " # n(seenCount("executed " # f)));
for (e in ["refused NotAMaker", "refused InsufficientFunds", "refused DuplicateClientRef"].vals()) Debug.print("count: " # e # " = " # n(seenCount(e)));

if (w.failures > 0) { Debug.print("MARKETS STREAMS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("MARKETS STREAMS GREEN");
