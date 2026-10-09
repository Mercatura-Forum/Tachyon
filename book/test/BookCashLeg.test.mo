// BookCashLeg.test.mo: the cash leg in its three shapes (book/SPEC.md §36), by hand. The same DvP row (10 shares of Test
// Issuer A at 85,000, 850,000 of cash) settles against a central bank's reserve ledger, a bank's tokenised deposit
// ledger, and claims bridged to the RTGS; the venue's code is the same for all three. The Python reference book
// (BookCashLeg.verify.sh) replays the commands alone and requires every balance, bridge, earmark and redemption equal and
// the bridged ledger's claims equal to its backing after every command; the regulator's replay refolds the log.
//
// What is proved:
//   * A, reserves: the row settles, 850,000 from account 2 to account 10, final at the fill in central bank money;
//   * B, tokenised deposits: the same row, final at the fill in the bank's money;
//   * C, the bridge: registered once, only with no claim in the book; claims only from the RTGS operator's earmarks (a
//     deposit refused, an earmark by anyone else refused, an RTGS message once); the row settles in claims; a
//     redemption holds the claims, a withdrawal of them refused; the RTGS's failure returns them (both or neither: the
//     backing unmoved); a second redemption settled burns them and lowers the backing; at every checkpoint the claims in
//     the book equal the backing (2,000,000 earmarked, 850,000 transferred out: 1,150,000);
//   * every refusal by name with the book unmoved.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Sha256 "mo:sha2/Sha256";
import DL "mo:kernel/domain/DomainLog";
import X "../../exchange/src/ExchangeCore";
import T "../src/BookTypes";
import B "../src/BookCore";
import TR "../../custody/test/support/Transcript";
import W "support/World";

let w = W.World(true);
let { check; checkpoint; deposit; executes; govern; lim; n; newRun; operator; placed; refusedAs; scheduler; settle; t1; t3; rtgs; depository; tick; reservesL; depositsL; claimsL } = w;

let m = newRun(true);
var cases = 0;
func governs(c : T.Command, want : [Nat], what : Text) {
  switch (govern(m, c)) { case (#ok(#executed(x))) { check(x.effects == want, what # ": " # TR.csv(x.effects) # " wanted " # TR.csv(want)); cases += 1 }; case (o) check(false, what # ": " # debug_show(o)) }
};
func does(who : Principal, c : T.Command, want : [Nat], what : Text) {
  let got = executes(m, who, c, what);
  check(got == want, what # ": " # TR.csv(got) # " wanted " # TR.csv(want));
  cases += 1;
};
func refused(who : Principal, c : T.Command, want : Text, what : Text) { refusedAs(m, who, c, want, what); cases += 1 };
func avail(account : Nat, l : Principal) : Nat { B.balance(m.st, account, l).available };
func held(account : Nat, l : Principal) : Nat { B.balance(m.st, account, l).held };
func msg(tag : Nat8) : Blob { Sha256.fromArray(#sha256, [tag, 0x52, 0x54, 0x47, 0x53]) };
func row(inst : Nat, ref : Text) {
  ignore tick();
  ignore placed(m, lim(10, inst, #sell, 10, 85_000, ref # "-s"));
  settle(m);
  ignore tick();
  ignore placed(m, lim(2, inst, #buy, 10, 85_000, ref # "-b"));
  settle(m);
};
func backing() : Nat { switch (B.bridgeOf(m.st, claimsL)) { case (?(_, b)) b.backing; case null 0 } };

ignore tick();
let legs = w.openCashLegs(m);
let (ia, ib, ic) = (legs[0], legs[1], legs[2]);
deposit(m, 10, w.sharesA, 30);
for (i in legs.vals()) does(scheduler, #setTrading({ instrument = i; open = true }), [2, i], "instrument " # n(i) # " trading");

// ─── A. reserves ─────────────────────────────────────────────────────────────────────────────
deposit(m, 2, reservesL, 1_000_000);
row(ia, "a");
check(avail(2, reservesL) == 150_000 and avail(10, reservesL) == 850_000 and avail(2, w.sharesA) == 10, "A: 850,000 of reserves for 10 shares, at the fill");

// ─── B. tokenised deposits ───────────────────────────────────────────────────────────────────
deposit(m, 2, depositsL, 1_000_000);
row(ib, "b");
check(avail(2, depositsL) == 150_000 and avail(10, depositsL) == 850_000 and avail(2, w.sharesA) == 20, "B: 850,000 of the bank's deposits for 10 shares, at the fill");
checkpoint(m);

// ─── C. the bridge to the RTGS ───────────────────────────────────────────────────────────────
refused(operator, #registerBridge({ ledger = reservesL; rtgs }), "e:InvalidTerms", "a ledger with units in the book bridged");
governs(#registerBridge({ ledger = claimsL; rtgs }), [62, 1], "C: the claims' bridge");
refused(operator, #registerBridge({ ledger = claimsL; rtgs }), "e:InvalidTerms", "a ledger bridged twice");
governs(#registerBridge({ ledger = w.claims2L; rtgs = w.rtgs2 }), [62, 2], "C: a second bridge, another RTGS");
refused(w.rtgs2, #earmark({ ledger = claimsL; account = 2; member = 1; amount = 2_000_000; reference = msg(0x10) }), "e:InvalidTerms", "an earmark by another bridge's RTGS");
refused(depository, #deposit({ account = 2; member = 1; ledger = claimsL; amount = 5; reference = msg(0x01) }), "e:InvalidTerms", "claims deposited");
refused(operator, #earmark({ ledger = claimsL; account = 2; member = 1; amount = 2_000_000; reference = msg(0x10) }), "a:NoGrant", "an earmark by the operator");
refused(rtgs, #earmark({ ledger = reservesL; account = 2; member = 1; amount = 2_000_000; reference = msg(0x10) }), "e:InvalidTerms", "an earmark on a ledger not bridged");
refused(rtgs, #earmark({ ledger = claimsL; account = 2; member = 2; amount = 2_000_000; reference = msg(0x10) }), "e:InvalidTerms", "the account's member");
does(rtgs, #earmark({ ledger = claimsL; account = 2; member = 1; amount = 2_000_000; reference = msg(0x10) }), [63, 1, 2, 2_000_000], "C: 2,000,000 earmarked, as many claims to account 2");
refused(rtgs, #earmark({ ledger = claimsL; account = 2; member = 1; amount = 1; reference = msg(0x10) }), "e:DuplicateReference", "an RTGS message twice");
check(B.supplyOf(m.st, claimsL) == 2_000_000 and backing() == 2_000_000, "C: the claims are the backing");
row(ic, "c");
check(avail(2, claimsL) == 1_150_000 and avail(10, claimsL) == 850_000 and avail(2, w.sharesA) == 30, "C: 850,000 of claims for 10 shares, at the fill");
checkpoint(m);
refused(t1, #redeem({ account = 10; member = 2; trader = 1; ledger = claimsL; amount = 1 }), "e:NotYourAccount", "another member's claims redeemed");
refused(t3, #redeem({ account = 10; member = 2; trader = 3; ledger = claimsL; amount = 850_001 }), "e:InsufficientFunds", "more than the account holds");
refused(t3, #redeem({ account = 10; member = 2; trader = 3; ledger = reservesL; amount = 1 }), "e:InvalidTerms", "reserves redeemed through the bridge");
does(t3, #redeem({ account = 10; member = 2; trader = 3; ledger = claimsL; amount = 850_000 }), [64, 1, 850_000], "C: 850,000 redeemed, held");
check(avail(10, claimsL) == 0 and held(10, claimsL) == 850_000, "C: the claims held");
refused(t3, #withdraw({ account = 10; member = 2; ledger = claimsL; amount = 1 }), "e:InsufficientFunds", "nothing free to withdraw");
refused(operator, #rtgsReject({ redemption = 1; reference = msg(0x20) }), "a:NoGrant", "the RTGS's answer from the operator");
// failure injection: the RTGS cannot move the cash; both or neither: the claims come back, the backing is unmoved
does(rtgs, #rtgsReject({ redemption = 1; reference = msg(0x20) }), [66, 1, 850_000], "C: the RTGS's transfer failed: the claims returned");
check(avail(10, claimsL) == 850_000 and held(10, claimsL) == 0 and backing() == 2_000_000 and B.supplyOf(m.st, claimsL) == 2_000_000, "C: both or neither");
refused(rtgs, #rtgsSettle({ redemption = 1; reference = msg(0x21) }), "e:InvalidTerms", "a rejected redemption settled");
refused(t3, #withdraw({ account = 10; member = 2; ledger = claimsL; amount = 1 }), "e:InvalidTerms", "claims withdrawn");
does(t3, #redeem({ account = 10; member = 2; trader = 3; ledger = claimsL; amount = 850_000 }), [64, 2, 850_000], "C: redeemed again");
checkpoint(m);
does(rtgs, #rtgsSettle({ redemption = 2; reference = msg(0x22) }), [65, 2, 850_000], "C: the RTGS transferred 850,000 out of the earmark: the claims burned");
refused(rtgs, #rtgsSettle({ redemption = 2; reference = msg(0x23) }), "e:InvalidTerms", "a redemption settled twice");
check(avail(10, claimsL) == 0 and held(10, claimsL) == 0 and backing() == 1_150_000 and B.supplyOf(m.st, claimsL) == 1_150_000, "C: 1,150,000 of claims, 1,150,000 of backing");
checkpoint(m);

Debug.print("count: cash leg cases computed by hand = " # n(cases));
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));
if (not w.replayed(m)) check(false, "the cash legs' book replay");
Debug.print("count: cash leg books replayed to their fingerprint = 1");
TR.fingerprint("exchange", X.fingerprint(w.xs));
TR.fingerprint("book", B.fingerprint(m.st));
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the cash legs' book log given to the regulator's replay = " # n(logBlocks));
if (w.failures > 0) { Debug.print("CASH LEG FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("CASH LEG GREEN");
