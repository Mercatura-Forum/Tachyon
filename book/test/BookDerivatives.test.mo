// BookDerivatives.test.mo: attested prices, futures and options on an index (book/SPEC.md §33 to §35), by hand. The
// figures were worked from the SPEC's formulas before the run; the Python reference book (BookDerivatives.verify.sh)
// computes every variation, premium, payoff, margin and position again from the commands alone and requires them equal;
// the regulator's replay refolds the log to the book's fingerprint.
//
// The contracts: on index 1 (instruments 1 and 2, 1,000.00), multiplier 10, expiring three market days after today:
// 12 a future (10% initial margin), 13 a call at 1,000.00 and 14 a put at 900.00 (writer's margin a 15%, b 10%). Member
// 1 trades on its clearing account 5, member 2 on its account 13.
//
// What is proved:
//   * A, a future's fill: 4 contracts at 1,005.00 against the mark 1,000.00 (the reference price): the buyer owes 20,000
//     and the seller is owed it in the cycle at once; each position holds 400,000 of margin; open interest balanced;
//   * B, attested prices: the daily price the median of three (1,010.00 of 1,010.00, 1,012.00 and 1,009.00); a price for
//     another day, another attestor's number, a second price refused; the settlement refused before the third, and
//     while trading; in slices of one position, trading not reopened within the run; the long owed 40,000, margins
//     404,000;
//   * C, options: a call's premium 50,000 and its writer's margin 350,000 (2 × 10 × (25.00 + 15% × 1,000.00)); a put's
//     premium 54,000 and its writer's 324,000 (out of the money by 100.00: a × the index less it 50.00, b × the strike
//     90.00 the floor, b × the index would be 100.00); a writer's order refused counting the positions' margin; the call
//     marked at its attested 26.50, the writer's margin 353,000;
//   * D, expiry at the index's 1,011.03 (instrument 2 traded at 2,050): the future's last variation 4,120, the call
//     paying 22,060, the put nothing; every position closed, every margin released; the contract refused afterwards;
//   * E, the cycle: member 1 pays 57,820 net (20,000 + 50,000 + 54,000 owed against 40,000 + 4,120 + 22,060 owed to it),
//     member 2 is paid it, the CCP flat;
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
let { advance; check; checkpoint; deposit; executes; govern; lim; n; newRun; operator; placed; refusedAs; scheduler; settle; cash; t1; t3; at1; at2; at3; tick; today } = w;

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
func owed(member : Nat) : (Nat, Nat) { switch (B.clearingMember(m.st, member)) { case (?(_, r)) (r.owedTo, r.owedBy); case null (0, 0) } };
func pos(account : Nat, inst : Nat) : (Bool, Nat, Nat, Nat) { switch (B.positionOf(m.st, account, inst)) { case (?(_, p)) (p.long, p.qty, p.mark, p.im); case null (false, 0, 0, 0) } };
func cross(inst : Nat, qty : Nat, price : Nat, ref : Text) {
  ignore tick();
  ignore placed(m, lim(13, inst, #sell, qty, price, ref # "-s"));
  settle(m);
  ignore tick();
  ignore placed(m, lim(5, inst, #buy, qty, price, ref # "-b"));
  settle(m);
};

ignore tick();
let expiry = w.openDerivatives(m);
let day0 = today();
check(expiry == day0 + 3, "the contracts expire three days on");

// ─── A. a future's fill ──────────────────────────────────────────────────────────────────────
refused(operator, #setTerms({ instrument = 12; terms = #future({ index = 1; multiplier = 10; expiry; imBps = 1_000 }) }), "e:InvalidTerms", "a class set twice");
refused(t1, lim(2, 12, #buy, 1, 100_000, "a-prefunded"), "e:InvalidTerms", "a future on a pre-funded account");
refused(t1, #placeOrder({ account = 5; instrument = 12; side = #sell; kind = #limit; qty = 1; price = 100_000; stopPrice = 0; peak = 0; validity = #gtc; gtdDay = 0; selfTrade = #cancelResting;
  capacity = #agency; shortSale = true; clientRef = "a-short"; oco = 0; trail = 0; member = 1; trader = w.traderIdOf(t1) }), "e:InvalidTerms", "a future flagged a short sale");
refused(t3, lim(13, 12, #sell, 100, 100_000, "a-big"), "e:MarginShort", "100 contracts beyond the collateral");
cross(12, 4, 100_500, "a");
check(owed(1) == (0, 20_000) and owed(2) == (20_000, 0), "A: the buyer owes 20,000, the seller is owed it");
check(pos(5, 12) == (true, 4, 100_000, 400_000) and pos(13, 12) == (false, 4, 100_000, 400_000), "A: long and short 4 at 1,000.00, 400,000 each");
check(B.memberImOf(m.st, 1) == 400_000 and B.memberImOf(m.st, 2) == 400_000, "A: the members' positions' margin");
checkpoint(m);

// ─── B. attested prices and the daily settlement ─────────────────────────────────────────────
refused(operator, #setAttestors({ attestors = [at1, at2] }), "e:InvalidTerms", "two attestors");
refused(at1, #attestPrice({ attestor = 1; instrument = 12; day = day0 - 1; price = 101_000 }), "e:InvalidTerms", "a stale price");
refused(at2, #attestPrice({ attestor = 1; instrument = 12; day = day0; price = 101_000 }), "e:InvalidTerms", "another attestor's number");
refused(at1, #attestPrice({ attestor = 1; instrument = 1; day = day0; price = 101_000 }), "e:InvalidTerms", "a price for a share");
does(at1, #attestPrice({ attestor = 1; instrument = 12; day = day0; price = 101_000 }), [60, 12, day0, 1, 0], "B: the first price");
refused(at1, #attestPrice({ attestor = 1; instrument = 12; day = day0; price = 101_100 }), "e:InvalidTerms", "a second price from one attestor");
does(at2, #attestPrice({ attestor = 2; instrument = 12; day = day0; price = 101_200 }), [60, 12, day0, 2, 0], "B: the second price");
does(scheduler, #setTrading({ instrument = 12; open = false }), [2, 12], "B: the future closed for the day");
refused(scheduler, #settleDerivatives({ instrument = 12; day = day0; limit = 500 }), "e:InvalidTerms", "a settlement before the third price");
does(at3, #attestPrice({ attestor = 3; instrument = 12; day = day0; price = 100_900 }), [60, 12, day0, 3, 101_000], "B: the third price: the median 1,010.00");
refused(scheduler, #settleDerivatives({ instrument = 12; day = day0 + 1; limit = 500 }), "e:InvalidTerms", "a settlement for another day");
does(scheduler, #settleDerivatives({ instrument = 12; day = day0; limit = 1 }), [61, 12, day0, 101_000, 0, 1, 5, 1, 40_000, 0], "B: the first slice: the long owed 40,000");
refused(scheduler, #setTrading({ instrument = 12; open = true }), "e:InvalidTerms", "trading reopened within a run");
refused(scheduler, #cutCycle({ cycle = 1; settleDay = 0 }), "e:InvalidTerms", "a cycle cut within a run");
// a checkpoint within the run: the contract's state carries the run's balance (40,000 owed, nothing charged yet)
check((switch (B.derivOf(m.st, 12)) { case (?d) d.runTo == 40_000 and d.runBy == 0 and d.runDay == day0; case null false }), "B: the run's balance kept");
checkpoint(m);
does(scheduler, #settleDerivatives({ instrument = 12; day = day0; limit = 1 }), [61, 12, day0, 101_000, 1, 1, 13, 2, 0, 40_000], "B: the last slice: the short owes 40,000");
refused(scheduler, #settleDerivatives({ instrument = 12; day = day0; limit = 1 }), "e:InvalidTerms", "a day settled twice");
check(pos(5, 12) == (true, 4, 101_000, 404_000) and owed(1) == (40_000, 20_000), "B: marked at 1,010.00, margin 404,000");
checkpoint(m);

// ─── C. options ──────────────────────────────────────────────────────────────────────────────
cross(13, 2, 2_500, "c-call");
check(owed(1) == (40_000, 70_000) and owed(2) == (70_000, 40_000), "C: the call's premium 50,000");
check(pos(5, 13) == (true, 2, 2_500, 50_000) and pos(13, 13) == (false, 2, 2_500, 350_000), "C: the holder's 50,000, the writer's 350,000");
cross(14, 3, 1_800, "c-put");
check(owed(1) == (40_000, 124_000), "C: the put's premium 54,000");
check(pos(13, 14) == (false, 3, 1_800, 324_000), "C: the put writer's 324,000, the floor on the strike");
// the positions' margin counts: 6 more calls (1,050,000) fit 2,000,000 of collateral alone, not beside 1,078,000
refused(t3, lim(13, 13, #sell, 6, 2_500, "c-margin"), "e:MarginShort", "a writer's order beyond the collateral with the positions' margin");
for ((a, p) in [(at1, 2_600), (at2, 2_700), (at3, 2_650)].vals()) ignore executes(m, a, #attestPrice({ attestor = if (a == at1) 1 else if (a == at2) 2 else 3; instrument = 13; day = day0; price = p }), "C: the call's prices");
does(scheduler, #setTrading({ instrument = 13; open = false }), [2, 13], "C: the call closed for the day");
does(scheduler, #settleDerivatives({ instrument = 13; day = day0; limit = 500 }), [61, 13, day0, 2_650, 1, 2, 5, 1, 0, 0, 13, 2, 0, 0], "C: the call marked at 26.50, no cash");
check(pos(13, 13) == (false, 2, 2_650, 353_000) and pos(5, 13) == (true, 2, 2_650, 53_000), "C: the writer's margin 353,000");
check(B.memberImOf(m.st, 1) == 404_000 + 53_000 + 54_000 and B.memberImOf(m.st, 2) == 404_000 + 353_000 + 324_000, "C: the members' positions' margin");
checkpoint(m);

// ─── D. expiry at the index's level ──────────────────────────────────────────────────────────
deposit(m, 2, cash, 50_000_000); deposit(m, 10, w.sharesB, 100);
does(scheduler, #setTrading({ instrument = 2; open = true }), [2, 2], "D: instrument 2 trading");
ignore tick();
ignore placed(m, lim(10, 2, #sell, 10, 2_050, "d-s"));
settle(m);
ignore tick();
ignore placed(m, lim(2, 2, #buy, 10, 2_050, "d-b"));
settle(m);
check((switch (B.indexRowOf(m.st, 1)) { case (?x) x.level; case null 0 }) == 101_103, "D: the index at 1,011.03");
advance(3 * 86_400);
ignore tick();
check(today() == expiry, "D: the expiry day");
does(scheduler, #setTrading({ instrument = 14; open = false }), [2, 14], "D: the put closed (the future and the call closed since their daily settlement)");
does(scheduler, #settleDerivatives({ instrument = 12; day = expiry; limit = 500 }), [61, 12, expiry, 101_103, 1, 2, 5, 1, 4_120, 0, 13, 2, 0, 4_120], "D: the future's last variation 4,120");
does(scheduler, #settleDerivatives({ instrument = 13; day = expiry; limit = 500 }), [61, 13, expiry, 101_103, 1, 2, 5, 1, 22_060, 0, 13, 2, 0, 22_060], "D: the call pays 11.03 × 2 × 10");
does(scheduler, #settleDerivatives({ instrument = 14; day = expiry; limit = 500 }), [61, 14, expiry, 101_103, 1, 2, 5, 1, 0, 0, 13, 2, 0, 0], "D: the put expires worthless");
check(pos(5, 12).1 == 0 and pos(13, 13).1 == 0 and pos(13, 14).1 == 0, "D: every position closed");
check(B.memberImOf(m.st, 1) == 0 and B.memberImOf(m.st, 2) == 0, "D: every margin released");
refused(t1, lim(5, 12, #buy, 1, 100_000, "d-late"), "e:InvalidTerms", "a contract after its expiry");
refused(scheduler, #settleDerivatives({ instrument = 12; day = expiry; limit = 500 }), "e:InvalidTerms", "an expired contract settled again");
checkpoint(m);

// ─── E. the cycle ────────────────────────────────────────────────────────────────────────────
check(owed(1) == (66_180, 124_000) and owed(2) == (124_000, 66_180), "E: member 1 owes 57,820 net, member 2 is owed it");
let c1 = B.balance(m.st, 1, cash).available; let c9 = B.balance(m.st, 9, cash).available;
ignore executes(m, scheduler, #cutCycle({ cycle = 1; settleDay = 0 }), "E: the cycle cut");
ignore executes(m, scheduler, #settleCycle({ cycle = 1 }), "E: the cycle settled");
check(c1 - B.balance(m.st, 1, cash).available == 57_820 and B.balance(m.st, 9, cash).available - c9 == 57_820, "E: 57,820 from member 1's account to member 2's");
check(owed(1) == (0, 0) and owed(2) == (0, 0), "E: nothing owed after the cycle");
checkpoint(m);

Debug.print("count: derivative cases computed by hand = " # n(cases));
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));
if (not w.replayed(m)) check(false, "the derivatives' book replay");
Debug.print("count: derivative books replayed to their fingerprint = 1");
TR.fingerprint("exchange", X.fingerprint(w.xs));
TR.fingerprint("book", B.fingerprint(m.st));
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the derivatives' book log given to the regulator's replay = " # n(logBlocks));
if (w.failures > 0) { Debug.print("DERIVATIVES FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("DERIVATIVES GREEN");
