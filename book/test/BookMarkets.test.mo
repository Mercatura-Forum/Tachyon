// BookMarkets.test.mo: fees, statements, member reconciliation and market makers (book/SPEC.md §22 to §25), by hand.
// Every figure below is computed by hand in the comment beside it; the Python reference book (BookMarkets.verify.sh)
// replays the stream from the commands alone with its own code: the fees half-even with their largest-remainder split,
// the buys' holds, every statement's hash chain, every reconciliation's hash, every maker's presence and session accrued
// from the block times, the rebates; the regulator's replay refolds the log to the book's fingerprint.
//
// The world: the levies' accounts are the venue member's 21 (the exchange's), 22 (the depository's), 23 (the
// regulator's); member 1 is a market maker, member 2 is not. Instrument 1: lot 10, reference 85_000; instrument 2:
// lot 1, reference 1_995, tick 1 below 2_000 and 10 from it.
//
// What is proved:
//   * A, a fill's fee on each side: 200 ppm of 8_500_000 is 1_700, split 1_063 / 425 / 212 by the largest remainder
//     (the tie to the first levy); the buy held its value, its fee rounded up and a unit a lot, and gets 10 back;
//   * B, half-even: 598.5 is charged 598 (half-up would charge 599), split 299 / 179 / 120;
//   * C, statements sealed with every member's lines, the hash chain the reference's; D, a member's attestation with a
//     break found and recorded;
//   * E, makers: registration only for a member admitted as a maker; quotes replace atomically (a refusal leaves the
//     live quote); a fill taking the bid below the minimum is a gap in presence; a mass quote; presence and the session
//     accrued from the block times, the obligation met on one instrument and not the other, the rebate half-even;
//   * F, a clearing party's fee owed in the cycle and the levies paid by the CCP at the cycle;
//   * every refusal by name with the book unmoved; the fee schedules' rules.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Sha256 "mo:sha2/Sha256";
import DL "mo:kernel/domain/DomainLog";
import X "../../exchange/src/ExchangeCore";
import T "../src/BookTypes";
import B "../src/BookCore";
import TR "../../custody/test/support/Transcript";
import W "support/World";

let w = W.World(true);
let { advance; check; checkpoint; deposit; executes; govern; lastClear; lim; n; newRun; operator; placed; refusedAs; scheduler; settle;
  sharesA; sharesB; cash; t1; t3; tick; today } = w;

w.openLevies();
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
func cashOf(a : Nat) : Nat { let b = B.balance(m.st, a, cash); b.available + b.held };
func avail(a : Nat) : Nat { B.balance(m.st, a, cash).available };
func quote(account : Nat, inst : Nat, bid : Nat, ask : Nat, qty : Nat, ref : Text) : T.Command {
  #quote({ account; member = w.memberOf(account); trader = w.traderIdOf(w.traderOf(account)); side = { instrument = inst; bidPrice = bid; askPrice = ask; qty; ref } })
};

// ─── the world's funds ───────────────────────────────────────────────────────────────────────
ignore tick();
deposit(m, 2, cash, 50_000_000); deposit(m, 2, sharesA, 1_000); deposit(m, 2, sharesB, 10_000);
deposit(m, 3, cash, 50_000_000); deposit(m, 3, sharesA, 500); deposit(m, 3, sharesB, 40_000);
deposit(m, 10, cash, 50_000_000); deposit(m, 10, sharesA, 1_000); deposit(m, 10, sharesB, 10_000);
deposit(m, 11, cash, 20_000_000); deposit(m, 11, sharesB, 5_000);

// ─── fee schedules, under four eyes ──────────────────────────────────────────────────────────
refused(operator, #setFeeSchedule({ instrument = 1; levies = [{ account = 17; ppm = 100 }] }), "e:AccountClosed", "a levy to a closed account");
refused(operator, #setFeeSchedule({ instrument = 1; levies = [{ account = 21; ppm = 0 }] }), "e:InvalidTerms", "a levy of no rate");
refused(operator, #setFeeSchedule({ instrument = 1; levies = [{ account = 21; ppm = 100_001 }] }), "e:InvalidTerms", "fees above 10 per cent a side");
refused(operator, #setFeeSchedule({ instrument = 1; levies = [{ account = 99; ppm = 100 }] }), "e:UnknownAccount", "a levy to no account");
refused(operator, #setFeeSchedule({ instrument = 1; levies = [{ account = 21; ppm = 100 }, { account = 21; ppm = 100 }] }), "e:InvalidTerms", "a levy's account twice");
refused(operator, #setFeeSchedule({ instrument = 1; levies = [] }), "e:InvalidTerms", "a schedule of no levy");
governs(#setFeeSchedule({ instrument = 1; levies = [{ account = 21; ppm = 125 }, { account = 22; ppm = 50 }, { account = 23; ppm = 25 }] }), [41, 1, 3], "instrument 1's fees: 125 + 50 + 25 ppm a side");
governs(#setFeeSchedule({ instrument = 2; levies = [{ account = 21; ppm = 100 }, { account = 22; ppm = 60 }, { account = 23; ppm = 40 }] }), [41, 2, 3], "instrument 2's fees: 100 + 60 + 40 ppm a side");
does(scheduler, #setTrading({ instrument = 1; open = true }), [2, 1], "instrument 1 trading");
does(scheduler, #setTrading({ instrument = 2; open = true }), [2, 2], "instrument 2 trading");
// a buy open on instrument 1: its schedule may not change under it
ignore tick();
let openBuy = placed(m, lim(2, 1, #buy, 10, 80_000, "open-buy"));
refused(operator, #setFeeSchedule({ instrument = 1; levies = [{ account = 21; ppm = 10 }] }), "e:InvalidTerms", "a schedule changed under an open buy");
w.cancel(m, openBuy);
checkpoint(m);

// ─── A. a fill's fees (instrument 1) ─────────────────────────────────────────────────────────
ignore tick();
let sA = placed(m, lim(10, 1, #sell, 100, 85_000, "a-s"));
settle(m);
ignore tick();
let cash2 = avail(2);
let bA = placed(m, lim(2, 1, #buy, 100, 85_000, "a-b"));
// the hold: 8_500_000, the fee on it rounded up (1_700 exactly), a unit a lot (100 / 10 = 10): 8_501_710
check(cash2 - avail(2) == 8_501_710, "A: the buy holds 8_501_710: " # n(cash2 - avail(2)));
settle(m);
check(lastClear(m) == [13, 1, 85_000, 100, 1, bA, sA, 100, 0, 0, 0, 0], "A: the fill");
// each side pays 1_700: 1_063 to the exchange (the tie of remainders to the first levy), 425, 212
check(avail(2) == cash2 - 8_500_000 - 1_700 and cashOf(10) == 50_000_000 + 8_500_000 - 1_700, "A: the buyer paid its value and fee, 10 back; the seller its fee from its proceeds");
check(cashOf(21) == 2 * 1_063 and cashOf(22) == 2 * 425 and cashOf(23) == 2 * 212, "A: the levies: 2_126, 850, 424");
check(B.feeTotalOf(m.st, 1, 1) == 1_700 and B.feeTotalOf(m.st, 2, 1) == 1_700, "A: each member's fees on instrument 1");

// ─── B. half-even (instrument 2) ─────────────────────────────────────────────────────────────
ignore tick();
let sB = placed(m, lim(11, 2, #sell, 1_500, 1_995, "b-s"));
settle(m);
ignore tick();
let cash2b = avail(2);
let bB = placed(m, lim(2, 2, #buy, 1_500, 1_995, "b-b"));
// 2_992_500 × 200 ppm = 598.5: held rounded up (599) with a unit a lot (1_500): 2_994_599
check(cash2b - avail(2) == 2_994_599, "B: the buy holds 2_994_599");
settle(m);
check(lastClear(m) == [13, 2, 1_995, 1_500, 1, bB, sB, 1_500, 0, 0, 0, 0], "B: the fill");
// charged half-even: 598 (599 half-up); split 299, 179.4, 119.6 → 299, 179, 119, the unit left to the largest remainder (23's)
check(avail(2) == cash2b - 2_992_500 - 598, "B: the buyer's fee 598, half-even");
check(cashOf(11) == 20_000_000 + 2_992_500 - 598, "B: the seller's fee 598");
check(cashOf(21) == 2_126 + 2 * 299 and cashOf(22) == 850 + 2 * 179 and cashOf(23) == 424 + 2 * 120, "B: the split 299 / 179 / 120 each side");
checkpoint(m);

// ─── C. statements ───────────────────────────────────────────────────────────────────────────
// member 1 bought twice, member 2 sold twice: two lines each; member 1's row was made first (A's buy)
let day0 = today();
does(scheduler, #sealStatements({ day = day0 }), [42, day0, 2, 1, 2, 2, 2], "C: the day's statements sealed");
refused(scheduler, #sealStatements({ day = day0 }), "e:InvalidTerms", "a day sealed twice");
refused(scheduler, #sealStatements({ day = day0 + 1 }), "e:InvalidTerms", "a day other than the market day");
// the seal's hash is the reference's own chain over the same lines (BookMarkets.verify.sh)
switch (B.statementSealOf(m.st, 1, day0)) {
  case (?seal) check(seal.lines == 2 and B.statementOf(m.st, 1).lines == 0, "C: member 1's two lines sealed, its next statement empty");
  case null check(false, "C: member 1's seal");
};

// ─── D. a member's reconciliation ────────────────────────────────────────────────────────────
// account 10 holds 800_161 of its cash for an open buy (800_000, its fee rounded up 160, a unit a lot): what is compared
// is all it holds, available and held
ignore tick();
ignore placed(m, lim(10, 1, #buy, 10, 80_000, "d-b"));
check(B.balance(m.st, 10, cash).held == 800_161, "D: account 10 holds 800_161 for its open buy");
// member 2 attests account 10's cash (58_498_300) and shares (900), right, and account 11's cash 22_992_500, where the
// book holds 22_991_902: one break
does(t3, #reconcileMember({ member = 2; day = day0; balances = [{ account = 10; ledger = cash; amount = 58_498_300 }, { account = 10; ledger = sharesA; amount = 900 },
  { account = 11; ledger = cash; amount = 22_992_500 }] }), [43, 1, 2, 1], "D: two matches and the planted break");
refused(t1, #reconcileMember({ member = 2; day = day0; balances = [{ account = 10; ledger = cash; amount = 1 }] }), "e:NotYourAccount", "another member's attestation");
refused(t3, #reconcileMember({ member = 2; day = day0; balances = [{ account = 2; ledger = cash; amount = 1 }] }), "e:NotYourAccount", "an account of another member attested");
refused(t3, #reconcileMember({ member = 2; day = day0 + 1; balances = [{ account = 10; ledger = cash; amount = 1 }] }), "e:InvalidTerms", "a day to come");
checkpoint(m);

// ─── E. market makers ────────────────────────────────────────────────────────────────────────
refused(operator, #registerMaker({ member = 2; instrument = 2; maxSpreadBps = 100; minQty = 50; presenceBps = 5_000; rebateBps = 2_000 }), "e:NotAMaker", "a member the exchange did not admit as a maker");
governs(#registerMaker({ member = 1; instrument = 2; maxSpreadBps = 100; minQty = 50; presenceBps = 5_000; rebateBps = 2_000 }), [44, 1], "E: member 1 for instrument 2: 1% spread, 50 a side, half the session, 20% of its fees back");
let tR2 = w.now;
governs(#registerMaker({ member = 1; instrument = 1; maxSpreadBps = 50; minQty = 10; presenceBps = 5_000; rebateBps = 1_000 }), [44, 2], "E: member 1 for instrument 1");
let tR1 = w.now;
refused(operator, #registerMaker({ member = 1; instrument = 2; maxSpreadBps = 100; minQty = 50; presenceBps = 5_000; rebateBps = 2_000 }), "e:InvalidTerms", "a maker registered twice");
refused(t3, quote(11, 2, 1_990, 2_000, 100, "nm"), "e:NotAMaker", "a quote by a member that is no maker");
refused(t1, quote(3, 2, 2_000, 1_990, 100, "x1"), "e:InvalidPrice", "a bid above the ask");
refused(t1, quote(3, 2, 1_990, 2_000, 30_000, "x2"), "e:InsufficientFunds", "a quote beyond the account's cash");
ignore tick();
let tQ1 = w.now;
let e1 = executes(m, t1, quote(3, 2, 1_990, 2_000, 100, "q1"), "E: the first quote");
let (bid1, ask1) = (e1[4], e1[8]);
check(e1 == [45, 1, 2, 0, bid1, 2, 1_990, 100, ask1, 2, 2_000, 100], "E: the quote's two sides live: " # TR.csv(e1));
// refused for its funds: the live quote stays, the book unmoved
refused(t1, quote(3, 2, 1_990, 2_000, 30_000, "x3"), "e:InsufficientFunds", "a replacement beyond the funds leaves the live quote");
check(w.status(m, bid1) == ?#live and w.status(m, ask1) == ?#live, "E: the refused replacement left both sides live");
// ten minutes on, account 11 sells 60 into the bid: 40 left, below the 50: a gap in presence from that clear
advance(600);
ignore tick();
ignore placed(m, lim(11, 2, #sell, 60, 1_990, "e-s"));
settle(m);
let tF = w.now;
// the maker's fee on its 60 at 1_990: 119_400 × 200 ppm = 23.88, charged 24
check(B.feeTotalOf(m.st, 1, 2) == 598 + 24, "E: member 1's fees on instrument 2: 598 + 24");
// five minutes on, the quote replaced: the bid's 40 and the ask cancelled, both new sides live
advance(300);
ignore tick();
let tQ2 = w.now;
let e2 = executes(m, t1, quote(3, 2, 1_990, 2_000, 100, "q2"), "E: the quote replaced");
check(e2 == [45, 1, 2, 2, bid1, ask1, e2[6], 2, 1_990, 100, e2[10], 2, 2_000, 100], "E: the replacement: " # TR.csv(e2));
// five minutes on, a quote too wide: 100 apart, 2_000_000 > 100 × 3_900: not present from it
advance(300);
ignore tick();
let tW = w.now;
ignore executes(m, t1, quote(3, 2, 1_900, 2_000, 100, "w1"), "E: a quote too wide");
// a minute on, a large quote on instrument 1 from account 2, then its replacement, which account 2 can afford only with
// what the first holds released: 25_490_127 held, about 13_015_000 left, 25_493_128 needed
advance(60);
ignore tick();
let tB1 = w.now;
ignore executes(m, t1, quote(2, 1, 84_950, 85_050, 300, "big1"), "E: a large quote");
ignore tick();
ignore executes(m, t1, quote(2, 1, 84_960, 85_050, 300, "big2"), "E: its replacement, afforded by what it releases");
// a minute on, a mass quote: instrument 2 again (a spread of 15: 300_000 ≤ 100 × 3_985) and instrument 1 on account 3,
// which cancels the large quote's two sides on account 2
advance(60);
ignore tick();
let e3 = executes(m, t1, #massQuote({ account = 3; member = 1; trader = w.traderIdOf(t1); sides = [{ instrument = 2; bidPrice = 1_985; askPrice = 2_000; qty = 100; ref = "m2" },
  { instrument = 1; bidPrice = 84_950; askPrice = 85_050; qty = 10; ref = "m1" }] }), "E: the mass quote");
let tM = w.now;
check(e3.size() == 26 and e3[0] == 46 and e3[1] == 2 and e3[2] == 2 and e3[3] == 2 and e3[14] == 1 and e3[15] == 2, "E: the mass quote: " # TR.csv(e3));
advance(300);
ignore tick();
let tEnd = w.now;
// presence by hand: instrument 2 present from the first quote to the clear that took its bid below 50, from the
// replacement to the quote too wide, and from the mass quote to the end; instrument 1 present from the large quote
// to the end (its replacements live in the same blocks); each session from its registration (trading continuously)
let p2 = Nat64.toNat(tF - tQ1) + Nat64.toNat(tW - tQ2) + Nat64.toNat(tEnd - tM);
let s2 = Nat64.toNat(tEnd - tR2);
let p1 = Nat64.toNat(tEnd - tB1);
let s1 = Nat64.toNat(tEnd - tR1);
check(p2 * 10_000 >= 5_000 * s2 and p1 * 10_000 < 5_000 * s1, "E: instrument 2's obligation met, instrument 1's not");
// the rebate: 20% of 622 = 124.4, half-even 124, from the exchange's account to account 3
does(scheduler, #settleMakers({ day = day0 }), [47, day0, 2, 1, 2, p2, s2, 1, 124, 1, 1, p1, s1, 0, 0], "E: the makers' period: presence, session, met, rebate");
refused(scheduler, #settleMakers({ day = day0 }), "e:InvalidTerms", "the makers' day settled twice");
checkpoint(m);

// ─── F. a clearing party's fee, owed in the cycle, the levies paid at it ─────────────────────
ignore tick();
deposit(m, 9, cash, 30_000_000); deposit(m, 19, cash, 5_000_000);
governs(#setClearing({ ccpAccount = 18; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 0; penaltyBps = 100; deadlineCycles = 2; fundBps = 500; fundFloor = 1_000_000 }), [27, 18], "F: the clearing's terms");
governs(#setMargin({ instrument = 1; imBps = 1_000 }), [28, 1, 1_000], "F: instrument 1's margin");
governs(#admitClearing({ member = 2; settlementAccount = 9; creditLine = 0 }), [29, 2], "F: member 2 clears");
governs(#designateClearing({ account = 14; member = 2 }), [30, 14, 2], "F: account 14 designated");
governs(#fundSkin({ account = 19; amount = 5_000_000 }), [38, 19, 5_000_000], "F: the skin");
does(t3, #postCollateral({ member = 2; amount = 10_000_000 }), [31, 2, 10_000_000], "F: member 2's collateral");
does(scheduler, #callFund, [36, 1, 2, 1_000_000], "F: the fund's call");
does(t3, #contributeFund({ member = 2; amount = 1_000_000 }), [37, 2, 1_000_000], "F: member 2's contribution");
ignore tick();
let sF = placed(m, lim(2, 1, #sell, 100, 85_000, "f-s"));
settle(m);
ignore tick();
let bF = placed(m, lim(14, 1, #buy, 100, 85_000, "f-b"));
settle(m);
check(lastClear(m) == [13, 1, 85_000, 100, 1, bF, sF, 100, 0, 0, 0, 0], "F: the fill");
// member 2 owes the value and its fee, 8_501_700; the CCP owes the levies the buyer's fee
check(B.payableTotal(m.st) == 1_700, "F: the levies owed 1_700 by the CCP");
does(scheduler, #cutCycle({ cycle = 1; settleDay = 0 }), [33, 1, 0], "F: cycle 1 cut");
does(scheduler, #settleCycle({ cycle = 1 }), [34, 1, 1, 2, 1, 8_501_700, 1, 2, 1, 100, 3, 21, 1_063, 22, 425, 23, 212], "F: member 2 pays the value and fee; the CCP pays the levies; 100 shares delivered");
check(B.payableTotal(m.st) == 0, "F: nothing owed to the levies");
checkpoint(m);

Debug.print("count: markets cases computed by hand = " # n(cases));
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));
if (not w.replayed(m)) check(false, "the markets book's replay");
Debug.print("count: markets books replayed to their fingerprint = 1");
TR.fingerprint("exchange", X.fingerprint(w.xs));
TR.fingerprint("book", B.fingerprint(m.st));
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the markets book's log given to the regulator's replay = " # n(logBlocks));
var dropEntries = 0;
for (mem in [1, 2, 3].vals()) {
  var from = 0;
  label pages loop {
    let page = B.dropCopy(m.st, mem, from, 7);
    for ((blk, own, bytes) in page.entries.vals()) { w.line("D|" # n(mem) # "|" # n(blk) # "|" # (if own "1" else "0") # "|" # TR.hex(Sha256.fromBlob(#sha256, bytes))); dropEntries += 1 };
    switch (page.next) { case (?nx) from := nx; case null break pages };
  };
};
Debug.print("count: drop-copy entries of the members = " # n(dropEntries));
if (w.failures > 0) { Debug.print("MARKETS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("MARKETS GREEN");
