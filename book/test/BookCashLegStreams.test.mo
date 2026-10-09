// BookCashLegStreams.test.mo: random streams on books with the three cash legs (SPEC §36): orders settling in reserves,
// tokenised deposits and claims bridged to the RTGS among every other command of the book; earmarks, redemptions, the
// RTGS settling and rejecting them, many refused. Every command printed with its outcome for the Python reference
// (BookCashLegStreams.verify.sh), which holds the claims in the book equal to their backing after every command.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import W "support/World";

let w = W.World(false);
let { n; printCoverage; seenCount } = w;

w.seed := w.seed ^ Nat64.fromNat(0xCA_0001);
let (commands, replays) = w.cashStreams(0, 3, 1_500);
Debug.print("count: random commands on books with the cash legs, judged by the book and the reference = " # n(commands));
Debug.print("count: books with the cash legs whose log replayed to the same fingerprint = " # n(replays));
printCoverage(["pairs", "clears that traded", "checkpoints"]);
for (f in ["earmark", "redeem", "rtgsSettle", "rtgsReject"].vals()) Debug.print("count: executed " # f # " = " # n(seenCount("executed " # f)));
for (e in ["refused InvalidTerms", "refused InsufficientFunds", "refused DuplicateReference"].vals()) Debug.print("count: " # e # " = " # n(seenCount(e)));

if (w.failures > 0) { Debug.print("CASH LEG STREAMS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("CASH LEG STREAMS GREEN");
