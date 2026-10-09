// BookGateway.test.mo: the cancel/replace a FIX gateway needs (book/SPEC.md §37), by hand, and the log a gateway's
// reports are reconstructed from. The Python reference book replays the commands; the regulator's replay refolds the
// log; BookGateway.verify.sh also runs `gateway/reconstruct.py`'s rule over this log for account 2 and requires the
// ExecutionReports worked here by hand, in order.
//
// What is proved:
//   * A, a replace: order G1 (a buy of 10 at 850.00) replaced by G2 (30 at 849.90): an amendment that loses priority, the
//     order now found by G2 and no longer by G1; G1 then free for a new order; a replace to a reference the account uses
//     refused, to an empty or a 21-byte one refused, every amendment's refusal still refusing (nothing to amend);
//   * B, the reports: G2 partly filled (10 at 849.90 against a sale of member 2), then filled (20), its AvgPx exactly
//     849.90; order H1 cancelled; the reconstruction from the log gives, for account 2: New G1, New H1, Replaced G2
//     (OrigClOrdID G1), Trade 10 (Partially filled, LeavesQty 20), Trade 20 (Filled), Canceled H1, New G1 (the reference
//     reused), in that order;
//   * every refusal by name with the book unmoved.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import DL "mo:kernel/domain/DomainLog";
import X "../../exchange/src/ExchangeCore";
import T "../src/BookTypes";
import B "../src/BookCore";
import TR "../../custody/test/support/Transcript";
import W "support/World";

let w = W.World(true);
let { check; checkpoint; deposit; executes; lim; n; newRun; placed; refusedAs; scheduler; settle; cash; t1; t3; tick } = w;

let m = newRun(true);
var cases = 0;
func does(who : Principal, c : T.Command, want : [Nat], what : Text) {
  let got = executes(m, who, c, what);
  check(got == want, what # ": " # TR.csv(got) # " wanted " # TR.csv(want));
  cases += 1;
};
func refused(who : Principal, c : T.Command, want : Text, what : Text) { refusedAs(m, who, c, want, what); cases += 1 };
func byRef(ref : Text) : ?Nat { switch (B.orderByRef(m.st, 2, ref)) { case (?(id, _)) ?id; case null null } };

ignore tick();
deposit(m, 2, cash, 50_000_000); deposit(m, 10, w.sharesA, 100);
does(scheduler, #setTrading({ instrument = 1; open = true }), [2, 1], "instrument 1 trading");

// ─── A. the replace ──────────────────────────────────────────────────────────────────────────
ignore tick();
let g = placed(m, lim(2, 1, #buy, 10, 85_000, "G1"));
let h = placed(m, lim(2, 1, #buy, 10, 84_000, "H1"));
settle(m);
refused(t1, #replaceOrder({ order = g; qty = 10; price = 85_000; clientRef = "G9" }), "e:InvalidTerms", "nothing to amend");
refused(t1, #replaceOrder({ order = g; qty = 30; price = 84_990; clientRef = "H1" }), "e:DuplicateClientRef", "a reference the account uses");
refused(t1, #replaceOrder({ order = g; qty = 30; price = 84_990; clientRef = "" }), "e:InvalidTerms", "an empty reference");
refused(t1, #replaceOrder({ order = g; qty = 30; price = 84_990; clientRef = "123456789012345678901" }), "e:InvalidTerms", "a 21-byte reference");
refused(t3, #replaceOrder({ order = g; qty = 30; price = 84_990; clientRef = "G2" }), "e:NotYourOrder", "another member's order");
ignore tick();
does(t1, #replaceOrder({ order = g; qty = 30; price = 84_990; clientRef = "G2" }), [67, g, 0, 30], "A: G1 replaced by G2, 30 at 849.90, its priority lost");
check(byRef("G2") == ?g and byRef("G1") == null, "A: the order answers to G2 only");
settle(m);
checkpoint(m);

// ─── B. fills and a cancel, the reports' events ──────────────────────────────────────────────
ignore tick();
ignore placed(m, lim(10, 1, #sell, 10, 84_990, "S1"));
settle(m);
ignore tick();
ignore placed(m, lim(10, 1, #sell, 20, 84_990, "S2"));
settle(m);
check((switch (B.order(m.st, g)) { case (?o) o.filled == 30 and o.status == #filled; case null false }), "B: G2 filled, 10 then 20");
w.cancel(m, h);
ignore tick();
let g1 = placed(m, lim(2, 1, #buy, 10, 84_000, "G1"));
check(byRef("G1") == ?g1, "B: G1 named a new order");
settle(m);
checkpoint(m);

Debug.print("count: gateway cases computed by hand = " # n(cases));
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));
if (not w.replayed(m)) check(false, "the gateway's book replay");
Debug.print("count: gateway books replayed to their fingerprint = 1");
TR.fingerprint("exchange", X.fingerprint(w.xs));
TR.fingerprint("book", B.fingerprint(m.st));
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the gateway's book log given to the regulator's replay = " # n(logBlocks));
if (w.failures > 0) { Debug.print("GATEWAY FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("GATEWAY GREEN");
