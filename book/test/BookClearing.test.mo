// BookClearing.test.mo: the central counterparty (book/SPEC.md §18 to §21) by hand. Every
// figure below is computed by hand in the comment beside it; the Python reference book (run by
// `BookClearing.verify.sh`) replays the stream from the commands alone with its own code, recounting every margin, the
// CCP's commitment and the custody's held shares from the open orders, and hashes the settlement range from its legs
// with its own Merkle code; the regulator's replay refolds the log and requires the book's fingerprint.
//
// The world: member 1 clears through settlement account 1 (designated accounts 5 and 6; 2 and 3 are its pre-funded
// clients), member 2 through 9 (designated 13 and 14), member 4 through 20; the CCP is member 3's account 18, the
// venue's own cash is account 19. Instrument 1: lot 10, reference 85_000, collar 5%, static band 20%.
//
// What is proved:
//   * the terms, margins, admissions and designations under four eyes; every refusal by name with the book unmoved;
//   * A, novation and a cycle: a clearing buy filled by a clearing sale and a pre-funded sale; net equals gross; the CCP
//     pays the pre-funded seller at the fill; the cycle settles the payer, then the receiver, then delivers;
//   * B, multilateral netting: two members trading both ways settle the difference only; a sale out of unpaid custody;
//   * C, a cash fail rolled with its penalty, a second, and the close-out past the deadline at the collar;
//   * D, a default met through the waterfall in its fixed order, the others' share by the largest remainder;
//   * E, T+2 by the calendar: a holiday and the rest days skipped, two cycles pending at once, delivery against payment
//     of the earlier cycle only;
//   * F, custody composed with the book: the register admits a leg only with its inclusion proof against the
//     book's settlement root, the holders being the linked holders of the leg's accounts; every refusal (no anchor, a
//     changed leg, another index, an unknown root, another ledger, an unlinked account, a leg twice); the register's
//     positions equal to the book's holdings of the linked accounts;
//   * the CCP's cash and custody identities at every checkpoint (World.checkpoint), every leg's inclusion proof.
//
// engine: Region (the row stores and the log live in stable memory).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Nat8 "mo:core/Nat8";
import Auth "mo:kernel/auth/AuthTypes";
import Nat "mo:core/Nat";
import Sha256 "mo:sha2/Sha256";
import DL "mo:kernel/domain/DomainLog";
import MP "mo:kernel/proof/MmrProof";
import X "../../exchange/src/ExchangeCore";
import T "../src/BookTypes";
import B "../src/BookCore";
import TR "../../custody/test/support/Transcript";
import CT "../../custody/src/CustodyTypes";
import Cu "../../custody/src/CustodyCore";
import TCu "../../custody/test/support/Traced";
import W "support/World";

let w = W.World(true);
let { advance; check; checkpoint; day; deposit; depository; executes; govern; lastClear; lim; n; newRun; operator; placed; refusedAs; scheduler; settle;
  sharesA; cash; t1; t3; t5; t6; tick; today } = w;

w.openClearing();
let m = newRun(true);
var cases = 0;
/// A command under four eyes whose execution has exactly `want` as effects.
func governs(c : T.Command, want : [Nat], what : Text) {
  switch (govern(m, c)) { case (#ok(#executed(x))) { check(x.effects == want, what # ": " # TR.csv(x.effects) # " wanted " # TR.csv(want)); cases += 1 }; case (o) check(false, what # ": " # debug_show(o)) }
};
/// A single act whose execution has exactly `want` as effects.
func does(who : Principal, c : T.Command, want : [Nat], what : Text) {
  let got = executes(m, who, c, what);
  check(got == want, what # ": " # TR.csv(got) # " wanted " # TR.csv(want));
  cases += 1;
};
func refused(who : Principal, c : T.Command, want : Text, what : Text) { refusedAs(m, who, c, want, what); cases += 1 };
func member(x : Nat) : B.ClearingMember { switch (B.clearingMember(m.st, x)) { case (?(_, r)) r; case null { check(false, "clearing member " # n(x)); { member = 0; settlementAccount = 0; creditLine = 0; collateral = 0; fund = 0; fundRequired = 0; imOrders = 0; owedTo = 0; owedBy = 0; debt = 0; fails = 0; peak = 0; status = 0 } } } };
func cashOf(a : Nat) : Nat { B.balance(m.st, a, cash).available };
func sharesOf(a : Nat) : Nat { let b = B.balance(m.st, a, sharesA); b.available + b.held };
func custody(x : Nat) : (Nat, Nat) { let c = B.custodyOf(m.st, x, 1); (c.qty, c.held) };
func obligation(x : Nat, cycle : Nat) : (Nat, Nat) { switch (B.obligationOf(m.st, x, cycle)) { case (?(_, o)) (o.owedTo, o.owedBy); case null (0, 0) } };
func clearing(account : Nat, side : T.Side, qty : Nat, price : Nat, ref : Text) : T.Command { lim(account, 1, side, qty, price, ref) };
func flagged(c : T.Command) : T.Command { switch (c) { case (#placeOrder(x)) #placeOrder({ x with shortSale = true }); case (_) c } };

// ─── the world's funds ───────────────────────────────────────────────────────────────────────
ignore tick();
deposit(m, 1, cash, 50_000_000); deposit(m, 1, sharesA, 1_000);
deposit(m, 9, cash, 50_000_000); deposit(m, 9, sharesA, 1_000);
deposit(m, 2, cash, 10_000_000); deposit(m, 2, sharesA, 500);
deposit(m, 3, cash, 30_000_000);
deposit(m, 20, cash, 10_000_000);
deposit(m, 19, cash, 1_000_000);
deposit(m, 4, cash, 1_000_000);

// ─── the terms, under four eyes ──────────────────────────────────────────────────────────────
let terms : T.Command = #setClearing({ ccpAccount = 18; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 0; penaltyBps = 100; deadlineCycles = 2; fundBps = 2_000; fundFloor = 3_000_000 });
refused(scheduler, #callFund, "e:InvalidTerms", "the fund called before the clearing's terms");
refused(operator, #admitClearing({ member = 1; settlementAccount = 1; creditLine = 0 }), "e:InvalidTerms", "a member admitted before the terms");
refused(operator, #setClearing({ ccpAccount = 18; ccpMember = 2; cashLedger = cash; cycleSecs = 900; cycleDays = 0; penaltyBps = 100; deadlineCycles = 2; fundBps = 2_000; fundFloor = 3_000_000 }), "e:InvalidTerms", "the CCP's account named with another member");
refused(operator, #setClearing({ ccpAccount = 19; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 0; penaltyBps = 100; deadlineCycles = 2; fundBps = 2_000; fundFloor = 3_000_000 }), "e:InvalidTerms", "a CCP account that holds cash");
refused(operator, #setClearing({ ccpAccount = 18; ccpMember = 3; cashLedger = cash; cycleSecs = 0; cycleDays = 0; penaltyBps = 100; deadlineCycles = 2; fundBps = 2_000; fundFloor = 3_000_000 }), "e:InvalidTerms", "a cycle of no length");
refused(operator, #setClearing({ ccpAccount = 18; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 0; penaltyBps = 100; deadlineCycles = 0; fundBps = 2_000; fundFloor = 3_000_000 }), "e:InvalidTerms", "a deadline of no cycle");
governs(terms, [27, 18], "the clearing's terms");
refused(operator, #setClearing({ ccpAccount = 19; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 0; penaltyBps = 100; deadlineCycles = 2; fundBps = 2_000; fundFloor = 3_000_000 }), "e:InvalidTerms", "the CCP's account moved");
governs(#setMargin({ instrument = 1; imBps = 1_000 }), [28, 1, 1_000], "instrument 1's initial margin, 10%");
refused(operator, #setMargin({ instrument = 1; imBps = 0 }), "e:InvalidTerms", "a margin of nothing");
refused(operator, #setMargin({ instrument = 7; imBps = 1_000 }), "e:UnknownInstrument", "a margin on no instrument");
governs(#admitClearing({ member = 1; settlementAccount = 1; creditLine = 5_000_000 }), [29, 1], "member 1 admitted, settling through account 1 with a credit line of 5_000_000");
governs(#admitClearing({ member = 2; settlementAccount = 9; creditLine = 0 }), [29, 2], "member 2 admitted through account 9");
governs(#admitClearing({ member = 4; settlementAccount = 20; creditLine = 0 }), [29, 4], "member 4 admitted through account 20");
refused(operator, #admitClearing({ member = 1; settlementAccount = 1; creditLine = 0 }), "e:InvalidTerms", "a member admitted twice");
refused(operator, #admitClearing({ member = 3; settlementAccount = 19; creditLine = 0 }), "e:InvalidTerms", "the CCP's own member admitted");
refused(operator, #admitClearing({ member = 2; settlementAccount = 1; creditLine = 0 }), "e:InvalidTerms", "a settlement account of another member");
// an account with an open order is designated only once it closes: account 4's buy is placed, then cancelled
ignore tick();
let open4 = placed(m, lim(4, 1, #buy, 10, 85_000, "open-4"));
refused(operator, #designateClearing({ account = 4; member = 1 }), "e:InvalidTerms", "an account with an open order designated");
w.cancel(m, open4);
for ((a, x) in [(5, 1), (6, 1), (13, 2), (14, 2)].vals()) governs(#designateClearing({ account = a; member = x }), [30, a, x], "account " # n(a) # " designated for member " # n(x));
refused(operator, #designateClearing({ account = 5; member = 1 }), "e:InvalidTerms", "an account designated twice");
refused(operator, #designateClearing({ account = 19; member = 3 }), "e:NotClearing", "an account of no clearing member");
refused(operator, #designateClearing({ account = 10; member = 1 }), "e:InvalidTerms", "another member's account designated");
// the venue's skin-in-the-game: 100_000 from its own account 19 (the CCP's member's)
governs(#fundSkin({ account = 19; amount = 100_000 }), [38, 19, 100_000], "the venue's skin-in-the-game");
refused(operator, #fundSkin({ account = 18; amount = 1 }), "e:InvalidTerms", "skin from the CCP's own account");
refused(operator, #fundSkin({ account = 1; amount = 1 }), "e:InvalidTerms", "skin from a member's account");
// collateral: member 1 20_000_000, member 2 2_000_000, each from its settlement account by its own trader
does(t1, #postCollateral({ member = 1; amount = 20_000_000 }), [31, 1, 20_000_000], "member 1's collateral");
does(t3, #postCollateral({ member = 2; amount = 2_000_000 }), [31, 2, 2_000_000], "member 2's collateral");
refused(t3, #postCollateral({ member = 1; amount = 1 }), "e:NotYourAccount", "a trader posting another member's collateral");
refused(t1, #postCollateral({ member = 1; amount = 1_000_000_000 }), "e:InsufficientFunds", "collateral beyond the settlement account's cash");
refused(t5, #postCollateral({ member = 3; amount = 1 }), "e:NotClearing", "the CCP's member posting collateral");
// the CCP's account moves only by clearing
refused(depository, #deposit({ account = 18; member = 3; ledger = cash; amount = 1; reference = w.depRef(800_001) }), "e:InvalidTerms", "a deposit to the CCP's account");
refused(t5, #withdraw({ account = 18; member = 3; ledger = cash; amount = 1 }), "e:InvalidTerms", "a withdrawal from the CCP's account");
refused(t5, lim(18, 1, #buy, 10, 85_000, "ccp-1"), "e:InvalidTerms", "an order on the CCP's account");
// the fund called: three active members, the floor's share ⌈3_000_000 / 3⌉ = 1_000_000 each (no purchases yet)
does(scheduler, #callFund, [36, 3, 1, 1_000_000, 2, 1_000_000, 4, 1_000_000], "the fund's first call");
does(scheduler, #setTrading({ instrument = 1; open = true }), [2, 1], "instrument 1 trading");
refused(t1, clearing(5, #buy, 10, 85_000, "fund-short"), "e:FundShort", "a clearing buy before the fund contribution");
does(t1, #contributeFund({ member = 1; amount = 1_000_000 }), [37, 1, 1_000_000], "member 1's contribution");
does(t3, #contributeFund({ member = 2; amount = 1_000_000 }), [37, 2, 1_000_000], "member 2's contribution");
does(t6, #contributeFund({ member = 4; amount = 1_000_000 }), [37, 4, 1_000_000], "member 4's contribution");
refused(t1, #contributeFund({ member = 1; amount = 1 }), "e:InvalidTerms", "a contribution beyond the requirement");
// the CCP's cash: skin 100_000 + collateral 22_000_000 + funds 3_000_000 = 25_100_000
check(B.ccpCash(m.st) == 25_100_000, "the CCP holds 25_100_000: " # n(B.ccpCash(m.st)));
// entry checks: member 2's buy of 300 at 85_000 needs 2_550_000 initial margin against 2_000_000; member 1's of 360
// is within its margin (3_060_000 of 25_000_000) and beyond the CCP's free 25_100_000 (30_600_000)
refused(t3, clearing(13, #buy, 300, 85_000, "im-short"), "e:MarginShort", "a buy beyond the member's collateral and credit line");
refused(t1, clearing(5, #buy, 360, 85_000, "liq-short"), "e:LiquidityShort", "a buy beyond the CCP's free cash");
refused(t1, clearing(5, #sell, 2_000, 85_000, "too-many"), "e:ShortSaleNotFlagged", "a clearing sale beyond the member's shares, unflagged");
refused(t1, flagged(clearing(5, #sell, 2_000, 85_000, "too-many-f")), "e:InsufficientFunds", "a flagged clearing sale beyond the member's shares");
checkpoint(m);

// ─── A. novation, net equals gross, a cycle (cycle 1) ────────────────────────────────────────
// member 2's clearing sale of 60 pledges 60 of account 9's shares to the CCP; account 2 (pre-funded) sells 40
ignore tick();
let s14 = placed(m, clearing(14, #sell, 60, 85_000, "a-s14"));
check(custody(2) == (60, 60) and sharesOf(9) == 940 and sharesOf(18) == 60, "the sale's 60 shares pledged to the CCP: " # debug_show(custody(2)));
ignore tick();
let s2 = placed(m, lim(2, 1, #sell, 40, 85_000, "a-s2"));
settle(m);
// member 1's clearing buy of 100 at 85_000: value 8_500_000, initial margin 850_000, held by the order, none on account 5
ignore tick();
let b5 = placed(m, clearing(5, #buy, 100, 85_000, "a-b5"));
check(member(1).imOrders == 850_000 and cashOf(5) == 0, "the buy's initial margin is its member's, nothing held on the account");
settle(m);
check(lastClear(m) == [13, 1, 85_000, 100, 2, b5, s14, 60, b5, s2, 40, 0, 0, 0, 0], "A: the clear at 85_000: " # TR.csv(lastClear(m)));
// novation: member 1 owes 5_100_000 + 3_400_000; member 2 is owed 5_100_000; the CCP paid account 2 at the fill
check(obligation(1, 1) == (0, 8_500_000) and obligation(2, 1) == (5_100_000, 0), "A: each member's cycle obligation is the sum of its fills, signed");
check(cashOf(2) == 13_400_000 and sharesOf(2) == 460, "A: the pre-funded seller paid at the fill, final");
check(B.ccpCash(m.st) == 21_700_000 and custody(1) == (100, 0) and custody(2) == (0, 0) and sharesOf(18) == 100, "A: the CCP paid 3_400_000 and holds the 100 shares for member 1");
check(member(1).imOrders == 0, "A: the filled buy's margin released");
let (legsA, _) = B.settlementRoot(m.st);
// the range so far: seven transfers to the CCP (the skin, two collaterals, three contributions, the sale's pledge) and
// the pre-funded fill's two legs
check(legsA == 9, "A: nine legs: " # n(legsA));
does(scheduler, #cutCycle({ cycle = 1; settleDay = 0 }), [33, 1, 0], "A: cycle 1 cut");
refused(scheduler, #cutCycle({ cycle = 2; settleDay = 0 }), "e:InvalidTerms", "a cut before the last cycle settled");
refused(scheduler, #settleCycle({ cycle = 2 }), "e:InvalidTerms", "the open cycle settled");
// the cycle: member 1 pays 8_500_000 from account 1 (50_000_000 - 20_000_000 - 1_000_000 = 29_000_000) and receives its
// 100 shares; member 2 receives 5_100_000; member 4 has nothing
does(scheduler, #settleCycle({ cycle = 1 }), [34, 1, 2, 1, 1, 8_500_000, 2, 3, 5_100_000, 1, 1, 1, 100], "A: cycle 1 settled");
check(cashOf(1) == 20_500_000 and sharesOf(1) == 1_100 and cashOf(9) == 52_100_000 and B.ccpCash(m.st) == 25_100_000 and sharesOf(18) == 0, "A: the net legs moved");
check(member(1).peak == 8_500_000 and member(1).owedBy == 0 and member(2).owedTo == 0, "A: the obligations settled, member 1's largest cycle purchase 8_500_000");
refused(scheduler, #settleCycle({ cycle = 1 }), "e:InvalidTerms", "a cycle settled twice");
checkpoint(m);

// ─── B. multilateral netting (cycle 2) ───────────────────────────────────────────────────────
// member 1 buys 50 at 85_100 from member 2; member 2 buys 30 at 85_100 from member 1, who sells out of the 50 the CCP
// holds for it, not yet paid for
ignore tick();
let bs14 = placed(m, clearing(14, #sell, 50, 85_100, "b-s14"));
settle(m);
ignore tick();
let bb5 = placed(m, clearing(5, #buy, 50, 85_100, "b-b5"));
check(member(1).imOrders == 425_500, "B: initial margin ⌈4_255_000 × 10%⌉ = 425_500");
settle(m);
check(lastClear(m) == [13, 1, 85_100, 50, 1, bb5, bs14, 50, 0, 0, 0, 0], "B: the first fill: " # TR.csv(lastClear(m)));
ignore tick();
let bs6 = placed(m, clearing(6, #sell, 30, 85_100, "b-s6"));
check(custody(1) == (50, 30) and sharesOf(1) == 1_100, "B: the sale pledged out of the custody's 50, nothing from account 1");
settle(m);
ignore tick();
let bb13 = placed(m, clearing(13, #buy, 30, 85_100, "b-b13"));
settle(m);
check(lastClear(m) == [13, 1, 85_100, 30, 1, bb13, bs6, 30, 0, 0, 0, 0], "B: the second fill: " # TR.csv(lastClear(m)));
check(obligation(1, 2) == (2_553_000, 4_255_000) and obligation(2, 2) == (4_255_000, 2_553_000), "B: gross obligations 4_255_000 and 2_553_000 each way");
check(custody(1) == (20, 0) and custody(2) == (30, 0) and sharesOf(18) == 50, "B: the CCP holds 20 for member 1 and 30 for member 2");
checkpoint(m);
refused(scheduler, #cutCycle({ cycle = 2; settleDay = 0 }), "e:CycleNotDue", "a cut before 900 seconds");
advance(900);
does(scheduler, #cutCycle({ cycle = 2; settleDay = 0 }), [33, 2, 0], "B: cycle 2 cut");
// net 4_255_000 - 2_553_000 = 1_702_000 from member 1, to member 2; member 1 receives 20 shares, member 2 30
does(scheduler, #settleCycle({ cycle = 2 }), [34, 2, 2, 1, 1, 1_702_000, 2, 3, 1_702_000, 2, 1, 1, 20, 2, 1, 30], "B: cycle 2 settled at the net");
check(cashOf(1) == 18_798_000 and cashOf(9) == 53_802_000 and sharesOf(1) == 1_120 and sharesOf(9) == 920, "B: 1_702_000 moved each way where 6_808_000 traded");
check(member(2).peak == 2_553_000, "B: member 2's largest cycle purchase");
// the fund called again: member 1's requirement 20% × 8_500_000 = 1_700_000 above the floor's share; the others 1_000_000
does(scheduler, #callFund, [36, 3, 1, 1_700_000, 2, 1_000_000, 4, 1_000_000], "the fund's second call, sized from the fold");
refused(t1, clearing(5, #buy, 10, 85_100, "b-fund"), "e:FundShort", "member 1's buy below its new requirement");
does(t1, #contributeFund({ member = 1; amount = 700_000 }), [37, 1, 700_000], "member 1 tops up");
checkpoint(m);

// ─── C. a cash fail, rolled with its penalty, and the close-out past the deadline (cycles 3 and 4) ───
// member 2 buys 200 at 85_100 from account 2 (pre-funded): value 17_020_000, margin 1_702_000 within its 2_000_000
ignore tick();
let cb13 = placed(m, clearing(13, #buy, 200, 85_100, "c-b13"));
settle(m);
refused(t3, #withdrawCollateral({ member = 2; amount = 1_000_000 }), "e:MarginShort", "collateral withdrawn below the open buy's margin");
refused(t3, #withdrawCollateral({ member = 2; amount = 3_000_000 }), "e:InvalidTerms", "more collateral withdrawn than posted");
ignore tick();
let cs2 = placed(m, lim(2, 1, #sell, 200, 85_100, "c-s2"));
settle(m);
check(lastClear(m) == [13, 1, 85_100, 200, 1, cb13, cs2, 200, 0, 0, 0, 0], "C: the fill: " # TR.csv(lastClear(m)));
check(B.ccpCash(m.st) == 8_780_000 and custody(2) == (200, 0), "C: the CCP paid 17_020_000 at the fill and holds the 200 shares");
// account 9 keeps 53_802_000 - 40_000_000 = 13_802_000, short of 17_020_000
does(t3, #withdraw({ account = 9; member = 2; ledger = cash; amount = 40_000_000 }), [5, 9, 40_000_000], "member 2 takes cash out of its settlement account");
advance(900);
does(scheduler, #cutCycle({ cycle = 3; settleDay = 0 }), [33, 3, 0], "C: cycle 3 cut");
// member 2 fails: 17_020_000 + ⌈1% × 17_020_000⌉ = 17_190_200 rolls; its shares stay with the CCP
does(scheduler, #settleCycle({ cycle = 3 }), [34, 3, 1, 2, 2, 17_190_200, 0], "C: member 2 fails cycle 3");
check(member(2).debt == 17_190_200 and member(2).fails == 1 and custody(2) == (200, 0) and sharesOf(9) == 920, "C: the debt rolled, nothing delivered");
// variation margin: 17_190_200 owed against 200 × 85_100 = 17_020_000 held: 170_200
check(B.variationOf(m.st, member(2)) == 170_200, "C: variation margin 170_200");
// it decides: of 2_000_000 collateral, 100_000 left would not cover it (and no buy is open)
refused(t3, #withdrawCollateral({ member = 2; amount = 1_900_000 }), "e:MarginShort", "collateral withdrawn below the variation margin of a rolled fail");
refused(scheduler, #closeOut({ member = 2; instrument = 1 }), "e:InvalidTerms", "a close-out before the deadline");
refused(scheduler, #closeOut({ member = 1; instrument = 1 }), "e:InvalidTerms", "a close-out of a member that owes nothing");
advance(900);
does(scheduler, #cutCycle({ cycle = 4; settleDay = 0 }), [33, 4, 0], "C: cycle 4 cut");
// a second fail: 17_190_200 + ⌈1% × 17_190_200⌉ = 17_190_200 + 171_902 = 17_362_102
does(scheduler, #settleCycle({ cycle = 4 }), [34, 4, 1, 2, 2, 17_362_102, 0], "C: member 2 fails cycle 4");
check(member(2).fails == 2, "C: two cycles failed: the deadline");
// the close-out: account 3 (pre-funded) bids 200 at 85_100; the reference moves to 70_000, so the CCP's market sale's
// collar is 70_000 × 95% = 66_500, and the batch clears at the lower of the two prices with the most volume: 66_500
ignore tick();
let cb3 = placed(m, lim(3, 1, #buy, 200, 85_100, "c-b3"));
settle(m);
does(scheduler, #setReference({ instrument = 1; price = 70_000 }), [3, 1], "C: the reference at 70_000");
ignore tick();
let co = m.st.nextOrder;
does(scheduler, #closeOut({ member = 2; instrument = 1 }), [35, co, 2, 66_500, 200, 2], "C: the CCP sells member 2's 200 shares at the collar");
check(custody(2) == (200, 200), "C: the close-out holds the custody's shares");
settle(m);
check(lastClear(m) == [13, 1, 66_500, 200, 1, cb3, co, 200, 0, 0, 0, 0], "C: the close-out filled: " # TR.csv(lastClear(m)));
// proceeds 200 × 66_500 = 13_300_000 pay the debt: 17_362_102 - 13_300_000 = 4_062_102 left
check(member(2).debt == 4_062_102 and custody(2) == (0, 0) and B.ccpCash(m.st) == 22_080_000, "C: the proceeds paid the debt");
check(cashOf(3) == 30_000_000 - 13_300_000 and sharesOf(3) == 200, "C: the buyer paid 13_300_000, the difference to its bid returned");
checkpoint(m);

// ─── D. default and the waterfall ────────────────────────────────────────────────────────────
refused(operator, #closeDefault({ member = 2 }), "e:InvalidTerms", "a waterfall for a member not in default");
refused(operator, #declareDefault({ member = 3; reason = "not a clearing member" }), "e:NotClearing", "a default of a member that does not clear");
governs(#declareDefault({ member = 2; reason = "the shortfall left after the close-out" }), [39, 2, 1], "D: member 2 in default, killed (kill 1)");
refused(t3, clearing(13, #buy, 10, 70_000, "d-b13"), "e:Killed", "the defaulter's trader after the kill");
refused(operator, #revive({ kill = 1 }), "e:InvalidTerms", "the kill revived before the waterfall");
// 4_062_102: collateral 2_000_000, fund 1_000_000, skin 100_000 + 170_200 + 171_902 = 442_102, then 620_000 from the
// others' 2_700_000 pro rata: member 1 620_000 × 1_700_000 / 2_700_000 = 390_370 r 1_000_000, member 4 229_629 r 1_700_000;
// the unit left goes to the larger remainder, member 4's: 390_370 and 229_630
governs(#closeDefault({ member = 2 }), [40, 2, 2_000_000, 1_000_000, 442_102, 620_000, 0, 2, 1, 390_370, 4, 229_630], "D: the waterfall in its fixed order");
check(member(2).status == 3 and member(2).debt == 0 and member(2).collateral == 0 and member(1).fund == 1_309_630 and member(4).fund == 770_370, "D: the defaulter closed, the others' funds drawn");
check(B.ccpCash(m.st) == 22_080_000, "D: the waterfall moves claims, not cash");
refused(operator, #closeDefault({ member = 2 }), "e:InvalidTerms", "a waterfall run twice");
checkpoint(m);

// ─── E. T+2 by the calendar (days mode; cycles 5 and 6) ──────────────────────────────────────
governs(#setClearing({ ccpAccount = 18; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 2; penaltyBps = 100; deadlineCycles = 2; fundBps = 2_000; fundFloor = 3_000_000 }), [27, 18], "E: the cycle set to two business days");
does(t1, #contributeFund({ member = 1; amount = 390_370 }), [37, 1, 390_370], "E: member 1's fund back to its requirement");
// Monday 2026-03-02: member 1 buys 10 at 70_000 from account 2
let mon = today();
check(mon == day(2026, 3, 2), "E: Monday 2026-03-02");
ignore tick();
let es2 = placed(m, lim(2, 1, #sell, 10, 70_000, "e-s2"));
settle(m);
ignore tick();
let eb5 = placed(m, clearing(5, #buy, 10, 70_000, "e-b5"));
settle(m);
check(lastClear(m) == [13, 1, 70_000, 10, 1, eb5, es2, 10, 0, 0, 0, 0], "E: Monday's fill");
// T+2 from Monday: Tuesday, then Wednesday the holiday is skipped: Thursday 2026-03-05
refused(scheduler, #cutCycle({ cycle = 5; settleDay = day(2026, 3, 4) }), "e:InvalidTerms", "a settlement day on the holiday");
does(scheduler, #cutCycle({ cycle = 5; settleDay = day(2026, 3, 5) }), [33, 5, day(2026, 3, 5)], "E: Monday's cycle settles Thursday");
refused(scheduler, #cutCycle({ cycle = 6; settleDay = day(2026, 3, 5) }), "e:InvalidTerms", "a second cut on Monday");
refused(scheduler, #settleCycle({ cycle = 5 }), "e:CycleNotDue", "Monday's cycle settled on Monday");
// Tuesday 2026-03-03: member 1 buys 10 more; T+2 from Tuesday: Thursday, then Friday and Saturday rest: Sunday 2026-03-08
advance(86_400);
ignore tick();
let es2b = placed(m, lim(2, 1, #sell, 10, 70_000, "e-s2b"));
settle(m);
ignore tick();
let eb5b = placed(m, clearing(5, #buy, 10, 70_000, "e-b5b"));
settle(m);
check(lastClear(m) == [13, 1, 70_000, 10, 1, eb5b, es2b, 10, 0, 0, 0, 0], "E: Tuesday's fill");
does(scheduler, #cutCycle({ cycle = 6; settleDay = day(2026, 3, 8) }), [33, 6, day(2026, 3, 8)], "E: Tuesday's cycle settles Sunday");
check(custody(1) == (20, 0), "E: two cycles pending, the CCP holds 20 for member 1");
// Thursday: cycle 5 settles; member 1 pays 700_000 and receives 10 shares only: the other 10 are cycle 6's, unpaid
advance(2 * 86_400);
does(scheduler, #settleCycle({ cycle = 5 }), [34, 5, 1, 1, 1, 700_000, 1, 1, 1, 10], "E: Thursday settles Monday's cycle, delivering against its payment only");
refused(scheduler, #settleCycle({ cycle = 6 }), "e:CycleNotDue", "Tuesday's cycle on Thursday");
check(custody(1) == (10, 0), "E: Tuesday's 10 shares stay with the CCP");
// Sunday 2026-03-08
advance(3 * 86_400);
check(today() == day(2026, 3, 8), "E: Sunday");
does(scheduler, #settleCycle({ cycle = 6 }), [34, 6, 1, 1, 1, 700_000, 1, 1, 1, 10], "E: Sunday settles Tuesday's cycle");
check(custody(1) == (0, 0), "E: everything delivered");
checkpoint(m);

// ─── G. a second default, its loss inside its own fund: the order of the layers decides (cycle 7) ─────────
// member 4 clears through its account 20; the venue's skin topped up to 500_000; member 4's fund back to 1_000_000
governs(#fundSkin({ account = 19; amount = 500_000 }), [38, 19, 500_000], "G: the skin topped up");
does(t6, #contributeFund({ member = 4; amount = 229_630 }), [37, 4, 229_630], "G: member 4's fund back to its requirement");
does(t6, #postCollateral({ member = 4; amount = 700_000 }), [31, 4, 700_000], "G: member 4's collateral");
governs(#designateClearing({ account = 20; member = 4 }), [30, 20, 4], "G: account 20 designated");
// member 4 buys 100 at 70_000 from account 2: margin 700_000, exactly its collateral
ignore tick();
let gs2 = placed(m, lim(2, 1, #sell, 100, 70_000, "g-s2"));
settle(m);
ignore tick();
let gb20 = placed(m, clearing(20, #buy, 100, 70_000, "g-b20"));
settle(m);
check(lastClear(m) == [13, 1, 70_000, 100, 1, gb20, gs2, 100, 0, 0, 0, 0], "G: the fill");
// account 20 keeps 10_000_000 - 1_000_000 - 229_630 - 700_000 - 2_000_000 = 6_070_370, short of 7_000_000
does(t6, #withdraw({ account = 20; member = 4; ledger = cash; amount = 2_000_000 }), [5, 20, 2_000_000], "G: member 4 takes cash out");
// Sunday's cycle settles two business days on: Monday, Tuesday 2026-03-10
does(scheduler, #cutCycle({ cycle = 7; settleDay = day(2026, 3, 10) }), [33, 7, day(2026, 3, 10)], "G: Sunday's cycle settles Tuesday");
advance(2 * 86_400);
// member 4 fails: 7_000_000 + 1% = 7_070_000
does(scheduler, #settleCycle({ cycle = 7 }), [34, 7, 1, 4, 2, 7_070_000, 0], "G: member 4 fails");
governs(#declareDefault({ member = 4; reason = "a fail it cannot pay" }), [39, 4, 2], "G: member 4 in default (kill 2)");
// the close-out: account 3 bids 100 at 70_000; the reference at 60_000, so the collar is 57_000 and the batch clears there
ignore tick();
let gb3 = placed(m, lim(3, 1, #buy, 100, 70_000, "g-b3"));
settle(m);
does(scheduler, #setReference({ instrument = 1; price = 60_000 }), [3, 1], "G: the reference at 60_000");
ignore tick();
let gco = m.st.nextOrder;
does(scheduler, #closeOut({ member = 4; instrument = 1 }), [35, gco, 2, 57_000, 100, 4], "G: the CCP sells member 4's 100 shares");
settle(m);
check(lastClear(m) == [13, 1, 57_000, 100, 1, gb3, gco, 100, 0, 0, 0, 0], "G: the close-out filled");
check(member(4).debt == 1_370_000, "G: 7_070_000 - 5_700_000 = 1_370_000 left");
// the waterfall: collateral 700_000, then 670_000 of its own fund of 1_000_000; the skin and the others untouched
governs(#closeDefault({ member = 4 }), [40, 4, 700_000, 670_000, 0, 0, 0, 1, 1, 0], "G: the loss met inside the defaulter's own fund");
check(member(4).collateral == 330_000 and member(4).status == 3 and member(1).fund == 1_700_000, "G: what the defaulter had beyond its loss stays its collateral");
checkpoint(m);

// ─── F. custody composed with the book: legs admitted only with their proof ─────────────────────
let cauth : Cu.Authority = {
  hasGrant = func(p : Principal, perm : Text) : Bool {
    if (w.peq(p, operator)) Text.startsWith(perm, #text "custody.") else if (w.peq(p, w.director1) or w.peq(p, w.director2)) (perm == "command.approve" or perm == "command.reject") else false
  };
  holdsRole = w.holdsRole;
};
let cs = Cu.newState();
let custodyDuals = Array.map<Auth.Permission, Auth.DualPolicy>(Array.filter<Auth.Permission>(Cu.catalogue(), func(p) { p.dualByDefault }), func(p) { w.dual(p.id) });
Cu.setPolicies(cs, custodyDuals);
let anchor : Cu.Anchor = func(k : Nat) : ?Blob { B.settlementRootAt(m.st, k) };
var custodyCases = 0;
func csubmit(c : CT.Command) : Cu.Result<Cu.Outcome> { ignore tick(); TCu.csubWith(cs, cauth, anchor, w.now, operator, c, null, "clearing") };
func cgovern(c : CT.Command, what : Text) {
  switch (csubmit(c)) {
    case (#ok(#proposed(p))) { ignore tick(); switch (TCu.capp(cs, cauth, w.now, w.director1, p.proposal)) { case (#ok(#executed(_))) { custodyCases += 1 }; case (o) check(false, what # " approved: " # debug_show(o)) } };
    case (o) check(false, what # " proposed: " # debug_show(o));
  }
};
func crefused(r : Cu.Result<Cu.Outcome>, want : Text, what : Text) {
  let fp0 = Cu.fingerprint(cs);
  check(TCu.cOut(r) == want, what # ": " # TCu.cOut(r) # " wanted " # want);
  check(Cu.fingerprint(cs) == fp0, what # ": the register unmoved");
  custodyCases += 1;
};
// the holders: 1 the issuer's side outside the venue; 2 to 6 the venue's accounts 1, 2, 3, 9 and the CCP's 18
let linked : [(Nat, Nat)] = [(1, 2), (2, 3), (3, 4), (9, 5), (18, 6)];
for (h in Nat.range(1, 7)) cgovern(#registerHolder({ holder = h; commit = w.bytes(0x60 + h, 32); account = Principal.fromBlob(w.bytes(0x70 + h, 10)) }), "holder " # n(h));
cgovern(#registerAsset({ code = "SHRA"; name = "Test Issuer A ordinary shares"; ledger = sharesA; cashLedger = cash; issuedSupply = 1_000_000; issuer = 1 }), "the asset");
for ((a, h) in linked.vals()) { if (a != 18) cgovern(#linkAccount({ account = a; holder = h }), "account " # n(a) # " linked") };
crefused(csubmit(#linkAccount({ account = 1; holder = 3 })), "e=AccountLinked", "an account linked twice");
// the depository's deliveries into the venue: what the battery deposited in instrument 1's shares
for ((rid, a, h, units) in [(1, 1, 2, 1_000), (2, 9, 5, 1_000), (3, 2, 3, 500)].vals()) {
  switch (csubmit(#recordSettlement({ asset = 1; receipt = { kind = #delivery; id = rid; block = 0; hash = Sha256.fromArray(#sha256, [Nat8.fromNat(rid)]) }; from = 1; to = h; units; day = today() }))) {
    case (#ok(#executed(_))) custodyCases += 1; case (o) check(false, "the deposit into account " # n(a) # ": " # debug_show(o));
  };
};
let (legCount, _) = B.settlementRoot(m.st);
func legAt(i : Nat) : B.Leg { switch (B.legOf(m.st, i)) { case (?l) l; case null { check(false, "leg " # n(i)); { kind = 0; ledger = cash; from = 0; to = 0; units = 0; block = 0 } } } };
func admit(i : Nat, k : Nat, l : B.Leg) : CT.Command {
  let proof = switch (B.settlementProofAt(m.st, i, k)) { case (?p) p.proof; case null { check(false, "a proof of leg " # n(i) # " at " # n(k)); { siblings = []; peakIndex = 0; peaks = [] } } };
  #admitLeg({ asset = 1; index = i; legs = k; leg = l; proof; day = today() })
};
var firstShares = legCount; var firstCash = legCount;
for (i in Nat.range(0, legCount)) { let l = legAt(i); if (w.peq(l.ledger, sharesA) and firstShares == legCount) firstShares := i; if (w.peq(l.ledger, cash) and firstCash == legCount) firstCash := i };
let l0 = legAt(firstShares);
check(l0.kind == 3 and l0.from == 9 and l0.to == 18 and l0.units == 60, "the first shares leg is A's pledge of 60 from account 9 to the CCP");
// the refusals, each leaving the register unmoved
// the register alone, not composed with the book: untraced, since the judge's actor always composes the two (a refusal
// writes nothing, so the transcript the judge replays is unchanged by it)
crefused(Cu.submit(cs, cauth, w.now, operator, admit(firstShares, legCount, l0), null, "clearing"), "e=RootUnknown", "a leg where the register is not composed with the book");
crefused(csubmit(admit(firstShares, legCount, l0)), "e=AccountNotLinked", "a leg into the CCP's account before it is linked");
cgovern(#linkAccount({ account = 18; holder = 6 }), "the CCP's account linked");
crefused(csubmit(switch (admit(firstShares, legCount, l0)) { case (#admitLeg(x)) #admitLeg({ x with leg = { l0 with units = 61 } }); case (c) c }), "e=ProofRefused", "a leg whose units were changed");
crefused(csubmit(switch (admit(firstShares, legCount, l0)) { case (#admitLeg(x)) #admitLeg({ x with index = firstShares + 1 }); case (c) c }), "e=ProofRefused", "a proof given for another index");
crefused(csubmit(switch (admit(firstShares, legCount, l0)) { case (#admitLeg(x)) #admitLeg({ x with legs = legCount + 1 }); case (c) c }), "e=RootUnknown", "a root of more legs than the book holds");
crefused(csubmit(switch (admit(firstShares, legCount, l0)) { case (#admitLeg(x)) #admitLeg({ x with legs = firstShares + 2 }); case (c) c }), "e=ProofRefused", "a proof against the root of another count");
crefused(csubmit(admit(firstCash, legCount, legAt(firstCash))), "e=InvalidTerms", "a cash leg against the shares' register");
// every shares leg admitted in the range's order, half against the root when the leg was the last, half against today's
var admitted = 0;
for (i in Nat.range(0, legCount)) {
  let l = legAt(i);
  if (w.peq(l.ledger, sharesA)) {
    switch (csubmit(admit(i, if (admitted % 2 == 0) i + 1 else legCount, l))) {
      case (#ok(#executed(x))) { admitted += 1; Debug.print("CL|" # n(i) # "|" # n(x.effects[1]) # "|" # n(x.effects[2]) # "|" # n(x.effects[3])) };
      case (o) check(false, "leg " # n(i) # " admitted: " # debug_show(o));
    };
  };
};
crefused(csubmit(admit(firstShares, legCount, l0)), "e=ReceiptRecorded", "a leg admitted twice");
// the register's positions are the book's holdings of the linked accounts, the issuer holding the rest
for ((a, h) in linked.vals()) {
  check(Cu.position(cs, 1, h) == sharesOf(a), "holder " # n(h) # " holds account " # n(a) # "'s shares: " # n(Cu.position(cs, 1, h)) # " against " # n(sharesOf(a)));
  Debug.print("CP|" # n(a) # "|" # n(Cu.position(cs, 1, h)));
};
check(Cu.position(cs, 1, 1) == 1_000_000 - 2_500, "the issuer's side holds what was not delivered into the venue");
let cfresh = Cu.newStateOver(cs.log);
Cu.setPolicies(cfresh, custodyDuals);
let crep = Cu.replay(cfresh);
check(crep.faults.size() == 0 and Cu.fingerprint(cfresh) == Cu.fingerprint(cs), "the register's log replays to its fingerprint");
Debug.print("count: legs of the settlement range admitted into custody with their proofs = " # n(admitted));
Debug.print("count: custody cases = " # n(custodyCases));

// ─── the settlement range: every leg's proof against the root; a proof against the wrong leg or root fails ─────
let (legs, root) = B.settlementRoot(m.st);
var proved = 0;
for (i in Nat.range(0, legs)) {
  switch (B.settlementProof(m.st, i)) {
    case (?p) {
      if (MP.verify(B.legRows.encode(p.leg), i, p.proof, root)) proved += 1 else check(false, "leg " # n(i) # " proves");
      if (i + 1 < legs) { switch (B.legOf(m.st, i + 1)) { case (?other) check(not MP.verify(B.legRows.encode(other), i, p.proof, root), "control: leg " # n(i + 1) # " does not prove at " # n(i)); case null {} } };
      check(not MP.verify(B.legRows.encode(p.leg), i, p.proof, Sha256.fromArray(#sha256, [0])), "control: a wrong root refuses leg " # n(i));
    };
    case null check(false, "leg " # n(i) # " has a proof");
  };
};
Debug.print("count: settlement legs proved against the range's root = " # n(proved));
Debug.print("count: clearing cases computed by hand = " # n(cases));
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));
if (not w.replayed(m)) check(false, "the clearing book's replay");
Debug.print("count: clearing books replayed to their fingerprint = 1");
TR.fingerprint("exchange", X.fingerprint(w.xs));
TR.fingerprint("book", B.fingerprint(m.st));
TR.fingerprint("custody", Cu.fingerprint(cs));
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the clearing book's log given to the regulator's replay = " # n(logBlocks));
// the drop copies (SPEC §14) of the three clearing members and the CCP's member: the regulator's replay requires each to
// be exactly the member's blocks, the clearing's acts among them
var dropEntries = 0;
for (mem in [1, 2, 3, 4].vals()) {
  var from = 0;
  label pages loop {
    let page = B.dropCopy(m.st, mem, from, 7);
    for ((blk, own, bytes) in page.entries.vals()) { w.line("D|" # n(mem) # "|" # n(blk) # "|" # (if own "1" else "0") # "|" # TR.hex(Sha256.fromBlob(#sha256, bytes))); dropEntries += 1 };
    switch (page.next) { case (?nx) from := nx; case null break pages };
  };
};
Debug.print("count: drop-copy entries of the clearing members = " # n(dropEntries));
if (w.failures > 0) { Debug.print("CLEARING FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("CLEARING GREEN");
