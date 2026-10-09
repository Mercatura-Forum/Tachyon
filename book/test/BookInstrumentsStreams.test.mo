// BookInstrumentsStreams.test.mo: random streams on books with the instrument classes (SPEC §28 to §32), half of them
// clearing: orders on bonds, a fund, wheat receipts, certificates and rights among every other command of the book; bonds'
// value dates, accrued interest settled pre-funded and novated under every day count; receipts issued and cancelled,
// certificates retired, rights exercised, most of them refused on one rule or another. Every command printed with its
// outcome for the Python reference (BookInstrumentsStreams.verify.sh), which recomputes every accrual with its own date
// arithmetic, and every ledger's units in the book.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
let { n; printCoverage; seenCount } = w;

w.seed := w.seed ^ Nat64.fromNat(0xC5_0001);
let (commands, replays) = w.classesStreams(0, 4, 1_200);
Debug.print("count: random commands on books with the instrument classes, judged by the book and the reference = " # n(commands));
Debug.print("count: books with the classes whose log replayed to the same fingerprint = " # n(replays));
printCoverage(["pairs", "clears that traded", "checkpoints"]);
for (f in ["valueDate", "issueReceipt", "cancelReceipt", "retire", "exercise", "settleCycle"].vals()) Debug.print("count: executed " # f # " = " # n(seenCount("executed " # f)));
for (e in ["refused InvalidTerms", "refused InsufficientFunds", "refused NotYourAccount"].vals()) Debug.print("count: " # e # " = " # n(seenCount(e)));

if (w.failures > 0) { Debug.print("INSTRUMENT STREAMS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("INSTRUMENT STREAMS GREEN");
