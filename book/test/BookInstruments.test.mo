// BookInstruments.test.mo: the instrument classes (book/SPEC.md §28 to §32), by hand: bonds with accrued interest under
// each day count, a fund's indicative NAV, warehouse receipts, certificates retired and rights exercised. The figures were
// worked from the SPEC's formulas before the run; the Python reference book (BookInstruments.verify.sh) computes them
// again from the commands alone, with its own date arithmetic, and requires every row, balance, leg and ledger's units
// equal; the regulator's replay refolds the log to the book's fingerprint.
//
// What is proved:
//   * A, bonds: the value date recorded by the scheduler as the calendar's T+1 (2026-03-03), and nothing traded before;
//     10 units of an 18.50% semiannual ACT/365 bond at 98.500% settle 985,000 clean and 23,822 accrued (47 days from
//     2026-01-15); an 11.75% annual 30/360 bond maturing on 31 August, 59,729 (183 days from 2025-08-31); a 20%
//     quarterly ACT/ACT ICMA bond, 1,630 (3 of the 92 days from 2026-02-28, the 31st stepped back to February's end);
//     the buy held the clean value and 95,584 (a period at 31 days a month over 360); the next day refused until its
//     value date is recorded;
//   * B, a fund: its iNAV 12,990.5 is 12,990 half-even; a trade of a basket instrument moves it to 13,100 (13,100.5);
//   * C, receipts: the class refused while units exist; units issued only by a licensed warehouse, traded, and cancelled
//     out of the account presenting them; deposits, withdrawals and loans of them refused; a cancelled receipt's units
//     cannot be sold;
//   * D, certificates: retired by a trader of the holder's member, the units gone, more never offered;
//   * E, rights: traded, exercised in whole new shares by the deadline paying the issuer, refused past it;
//   * every refusal by name with the book unmoved; every ledger's units equal to its balances (the reference).
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
let { advance; check; checkpoint; deposit; executes; govern; lim; n; newRun; operator; placed; refusedAs; scheduler; settle; cash; t1; t3; depository; tick; today } = w;
let { bondL; bond2L; bond3L; fundL; wheatL; carbonL; rightL } = w;

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
func hash(tag : Nat8) : Blob { Sha256.fromArray(#sha256, [tag, 0x4C, 0x31, 0x31]) };
func trade(inst : Nat, qty : Nat, price : Nat, ref : Text) {
  ignore tick();
  ignore placed(m, lim(10, inst, #sell, qty, price, ref # "-s"));
  settle(m);
  ignore tick();
  ignore placed(m, lim(2, inst, #buy, qty, price, ref # "-b"));
  settle(m);
};

ignore tick();
w.openClasses(m);
deposit(m, 2, cash, 50_000_000); deposit(m, 10, cash, 50_000_000);
deposit(m, 10, bondL, 100); deposit(m, 10, bond2L, 100); deposit(m, 10, bond3L, 100);
deposit(m, 10, w.sharesB, 5_000);

// ─── A. bonds ────────────────────────────────────────────────────────────────────────────────
let bond5 : T.Terms = #bond({ couponBps = 1_850; perYear = 2; basis = #act365; maturity = 21_564; settleDays = 1 });   // 2029-01-15
refused(operator, #setTerms({ instrument = 5; terms = #bond({ couponBps = 1_850; perYear = 3; basis = #act365; maturity = 21_564; settleDays = 1 }) }), "e:InvalidTerms", "three coupons a year");
refused(operator, #setTerms({ instrument = 5; terms = #bond({ couponBps = 1_850; perYear = 2; basis = #act365; maturity = 20_514; settleDays = 1 }) }), "e:InvalidTerms", "a maturity not after today");
refused(operator, #setTerms({ instrument = 5; terms = #bond({ couponBps = 10_001; perYear = 2; basis = #act365; maturity = 21_564; settleDays = 1 }) }), "e:InvalidTerms", "a coupon above 100 per cent");
refused(operator, #setTerms({ instrument = 99; terms = bond5 }), "e:UnknownInstrument", "terms for no instrument");
governs(#setTerms({ instrument = 5; terms = bond5 }), [52, 5, 1], "A: an 18.50% semiannual ACT/365 bond");
refused(operator, #setTerms({ instrument = 5; terms = bond5 }), "e:InvalidTerms", "a class set twice");
governs(#setTerms({ instrument = 10; terms = #bond({ couponBps = 1_175; perYear = 1; basis = #thirty360; maturity = 22_157; settleDays = 1 }) }), [52, 10, 1], "A: an 11.75% annual 30/360 bond, 31 August");
governs(#setTerms({ instrument = 11; terms = #bond({ couponBps = 2_000; perYear = 4; basis = #actActIcma; maturity = 21_335; settleDays = 1 }) }), [52, 11, 1], "A: a 20% quarterly ICMA bond, 31 May");
for (i in [5, 10, 11].vals()) does(scheduler, #setTrading({ instrument = i; open = true }), [2, i], "A: bond " # n(i) # " trading");
refused(t3, lim(10, 5, #sell, 10, 98_500, "a-early"), "e:InvalidTerms", "a bond order before its value date");
refused(scheduler, #valueDate({ instrument = 5; day = 20_514 }), "e:InvalidTerms", "a value date the calendar does not give");
refused(scheduler, #valueDate({ instrument = 1; day = 20_515 }), "e:InvalidTerms", "a value date for a share");
for (i in [5, 10, 11].vals()) does(scheduler, #valueDate({ instrument = i; day = 20_515 }), [58, i, 20_515], "A: bond " # n(i) # "'s value date T+1");
checkpoint(m);
// the buy holds the clean value and the most a fill can accrue
let c2 = avail(2, cash);
ignore tick();
ignore placed(m, lim(10, 5, #sell, 10, 98_500, "a5-s"));
settle(m);
ignore tick();
ignore placed(m, lim(2, 5, #buy, 10, 98_500, "a5-b"));
check(c2 - avail(2, cash) == 985_000 + 95_584, "A: the buy holds 985,000 and the bound 95,584: " # n(c2 - avail(2, cash)));
settle(m);
check(c2 - avail(2, cash) == 985_000 + 23_822, "A: 10 units at 98.500% paid 985,000 clean and 23,822 accrued: " # n(c2 - avail(2, cash)));
check(avail(10, cash) == 50_000_000 + 985_000 + 23_822, "A: the seller received both");
check(avail(2, bondL) == 10, "A: the buyer holds 10 units");
let c3 = avail(2, cash);
trade(10, 10, 99_000, "a10");
check(c3 - avail(2, cash) == 990_000 + 59_729, "A: 30/360, 183 days: 59,729 accrued: " # n(c3 - avail(2, cash)));
let c4 = avail(2, cash);
trade(11, 10, 101_250, "a11");
check(c4 - avail(2, cash) == 1_012_500 + 1_630, "A: ICMA, 3 of 92 days: 1,630 accrued: " # n(c4 - avail(2, cash)));
checkpoint(m);

// ─── B. a fund's iNAV ────────────────────────────────────────────────────────────────────────
let basket : [T.Constituent] = [{ instrument = 1; shares = 100 }, { instrument = 2; shares = 2_000 }];
refused(operator, #defineNav({ instrument = 6; units = 0; cash = 500_500; basket }), "e:InvalidTerms", "a creation of no units");
refused(operator, #defineNav({ instrument = 6; units = 1_000; cash = 500_500; basket = [{ instrument = 6; shares = 1 }] }), "e:InvalidTerms", "a fund in its own basket");
refused(operator, #defineNav({ instrument = 6; units = 1_000; cash = 500_500; basket = [{ instrument = 1; shares = 1 }, { instrument = 1; shares = 2 }] }), "e:InvalidTerms", "a basket line twice");
governs(#defineNav({ instrument = 6; units = 1_000; cash = 500_500; basket }), [53, 6, 12_990], "B: 12,990,500 over 1,000 units: 12,990.5, 12,990 half-even");
refused(operator, #defineNav({ instrument = 6; units = 1_000; cash = 500_500; basket }), "e:InvalidTerms", "a fund's iNAV defined twice");
does(scheduler, #setTrading({ instrument = 2; open = true }), [2, 2], "B: instrument 2 trading");
trade(2, 10, 2_050, "b2");
check((switch (B.navOf(m.st, 6)) { case (?v) v.inav == 13_100; case null false }), "B: instrument 2 at 2,050: 13,100.5, 13,100 half-even");
checkpoint(m);

// ─── C. warehouse receipts ───────────────────────────────────────────────────────────────────
deposit(m, 2, wheatL, 100);
refused(operator, #setTerms({ instrument = 7; terms = #receipt({ warehouses = [3, 7] }) }), "e:InvalidTerms", "the receipt class while units exist");
does(t1, #withdraw({ account = 2; member = 1; ledger = wheatL; amount = 100 }), [5, 2, 100], "C: the units taken out");
refused(operator, #setTerms({ instrument = 7; terms = #receipt({ warehouses = [3, 3] }) }), "e:InvalidTerms", "a warehouse twice");
refused(operator, #setTerms({ instrument = 7; terms = #receipt({ warehouses = [] }) }), "e:InvalidTerms", "no warehouse");
governs(#setTerms({ instrument = 7; terms = #receipt({ warehouses = [3, 7] }) }), [52, 7, 2], "C: wheat receipts from warehouses 3 and 7");
refused(depository, #deposit({ account = 2; member = 1; ledger = wheatL; amount = 5; reference = hash(0x01) }), "e:InvalidTerms", "a deposit of a receipt's units");
refused(depository, #borrow({ account = 2; member = 1; instrument = 7; qty = 5; reference = hash(0x02) }), "e:InvalidTerms", "a loan of a receipt's units");
refused(operator, #issueReceipt({ warehouse = 5; instrument = 7; account = 10; member = 2; qty = 50; reference = hash(0x10) }), "e:InvalidTerms", "a warehouse not licensed");
refused(operator, #issueReceipt({ warehouse = 3; instrument = 7; account = 10; member = 1; qty = 50; reference = hash(0x10) }), "e:InvalidTerms", "the account's member");
refused(operator, #issueReceipt({ warehouse = 3; instrument = 8; account = 10; member = 2; qty = 50; reference = hash(0x10) }), "e:InvalidTerms", "a receipt of no receipt instrument");
governs(#issueReceipt({ warehouse = 3; instrument = 7; account = 10; member = 2; qty = 50; reference = hash(0x10) }), [54, 1, 10, 50], "C: receipt 1, 50 tonnes to account 10");
refused(operator, #issueReceipt({ warehouse = 7; instrument = 7; account = 2; member = 1; qty = 30; reference = hash(0x10) }), "e:DuplicateReference", "a warehouse document twice");
governs(#issueReceipt({ warehouse = 7; instrument = 7; account = 2; member = 1; qty = 30; reference = hash(0x11) }), [54, 2, 2, 30], "C: receipt 2, 30 tonnes to account 2");
does(scheduler, #setTrading({ instrument = 7; open = true }), [2, 7], "C: wheat trading");
trade(7, 20, 15_000, "c7");
check(avail(10, wheatL) == 30 and avail(2, wheatL) == 50, "C: 20 tonnes sold to account 2");
refused(operator, #cancelReceipt({ receipt = 1; account = 10; member = 2 }), "e:InsufficientFunds", "a receipt presented by an account without its quantity");
governs(#cancelReceipt({ receipt = 1; account = 2; member = 1 }), [55, 1, 2, 50], "C: receipt 1's goods leave, out of account 2");
refused(operator, #cancelReceipt({ receipt = 1; account = 2; member = 1 }), "e:InvalidTerms", "a receipt cancelled twice");
refused(t1, #withdraw({ account = 2; member = 1; ledger = wheatL; amount = 1 }), "e:InsufficientFunds", "nothing left to withdraw");
refused(t3, #withdraw({ account = 10; member = 2; ledger = wheatL; amount = 1 }), "e:InvalidTerms", "a receipt's units leave only by cancellation");
refused(t1, lim(2, 7, #sell, 1, 15_000, "c-gone"), "e:ShortSaleNotFlagged", "a cancelled receipt's units sold");
check(B.supplyOf(m.st, wheatL) == 30 and avail(10, wheatL) == 30, "C: 30 tonnes in the book, receipt 2's");
checkpoint(m);

// ─── D. certificates ─────────────────────────────────────────────────────────────────────────
refused(operator, #setTerms({ instrument = 8; terms = #certificate({ registry = "\01\02" }) }), "e:InvalidTerms", "a registry of no hash");
governs(#setTerms({ instrument = 8; terms = #certificate({ registry = hash(0x20) }) }), [52, 8, 3], "D: carbon certificates");
deposit(m, 10, carbonL, 100);
refused(t1, #retire({ account = 10; member = 2; trader = 1; instrument = 8; qty = 40; beneficiary = hash(0x21) }), "e:NotYourAccount", "another member's certificates");
refused(t3, #retire({ account = 10; member = 2; trader = 3; instrument = 5; qty = 4; beneficiary = hash(0x21) }), "e:InvalidTerms", "a bond retired");
does(t3, #retire({ account = 10; member = 2; trader = 3; instrument = 8; qty = 40; beneficiary = hash(0x21) }), [56, 1, 40], "D: 40 retired for the beneficiary");
refused(t3, #retire({ account = 10; member = 2; trader = 3; instrument = 8; qty = 61; beneficiary = hash(0x21) }), "e:InsufficientFunds", "more than the account holds");
does(scheduler, #setTrading({ instrument = 8; open = true }), [2, 8], "D: certificates trading");
refused(t3, lim(10, 8, #sell, 61, 2_500, "d-retired"), "e:ShortSaleNotFlagged", "retired certificates offered");
check(B.supplyOf(m.st, carbonL) == 60, "D: 60 in circulation");
checkpoint(m);

// ─── E. rights ───────────────────────────────────────────────────────────────────────────────
let right9 : T.Terms = #right({ underlying = 1; price = 70_000; num = 1; den = 5; deadline = 20_516; issuer = 9; issuerMember = 2 });
refused(operator, #setTerms({ instrument = 9; terms = #right({ underlying = 9; price = 70_000; num = 1; den = 5; deadline = 20_516; issuer = 9; issuerMember = 2 }) }), "e:InvalidTerms", "a right on itself");
refused(operator, #setTerms({ instrument = 9; terms = #right({ underlying = 1; price = 70_000; num = 1; den = 5; deadline = 20_516; issuer = 9; issuerMember = 1 }) }), "e:InvalidTerms", "the issuer account's member");
refused(operator, #setTerms({ instrument = 9; terms = #right({ underlying = 1; price = 70_000; num = 1; den = 5; deadline = 20_516; issuer = 17; issuerMember = 2 }) }), "e:InvalidTerms", "a closed issuer account");
governs(#setTerms({ instrument = 9; terms = right9 }), [52, 9, 4], "E: rights on instrument 1, one new share for five at 70,000 by 2026-03-04");
deposit(m, 2, rightL, 100); deposit(m, 10, rightL, 50);
does(scheduler, #setTrading({ instrument = 9; open = true }), [2, 9], "E: rights trading");
trade(9, 25, 1_200, "e9");
refused(t1, #exercise({ account = 2; member = 1; trader = 1; instrument = 9; qty = 103 }), "e:InvalidTerms", "rights for a part of a share");
refused(t1, #exercise({ account = 2; member = 1; trader = 1; instrument = 9; qty = 130 }), "e:InsufficientFunds", "more rights than held");
let issuerCash = avail(9, cash);
does(t1, #exercise({ account = 2; member = 1; trader = 1; instrument = 9; qty = 120 }), [57, 1, 24, 1_680_000], "E: 120 rights: 24 new shares, 1,680,000 to the issuer");
check(avail(9, cash) == issuerCash + 1_680_000 and avail(2, rightL) == 5, "E: the issuer paid, 5 rights left");
advance(3 * 86_400);
ignore tick();
refused(t1, #exercise({ account = 2; member = 1; trader = 1; instrument = 9; qty = 5 }), "e:InvalidTerms", "an exercise past the deadline");
refused(t1, lim(2, 9, #sell, 5, 1_200, "e-late"), "e:InvalidTerms", "rights offered past the deadline");
// the bonds' value date is the day before's: their orders wait for today's
refused(t3, lim(10, 5, #sell, 10, 98_500, "a-late"), "e:InvalidTerms", "a bond order on a day with no value date recorded");
let vd = 20_518;
check(today() == 20_517, "the next market day: " # n(today()));
does(scheduler, #valueDate({ instrument = 5; day = vd }), [58, 5, vd], "A: bond 5's value date for the day");
ignore placed(m, lim(10, 5, #sell, 10, 98_500, "a-next"));
checkpoint(m);

Debug.print("count: instrument class cases computed by hand = " # n(cases));
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));
if (not w.replayed(m)) check(false, "the classes' book replay");
Debug.print("count: class books replayed to their fingerprint = 1");
TR.fingerprint("exchange", X.fingerprint(w.xs));
TR.fingerprint("book", B.fingerprint(m.st));
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the classes' book log given to the regulator's replay = " # n(logBlocks));
if (w.failures > 0) { Debug.print("INSTRUMENTS FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("INSTRUMENTS GREEN");
