// BookIndex.test.mo: an index and the market-wide circuit breaker (book/SPEC.md §26, §27), by hand. The figures were
// worked from the SPEC's formulas: the capped factors, the divisor, every level through a trade, a dividend, a split and
// two falls; the Python reference book (BookIndex.verify.sh) computes the index again from the commands alone and
// requires every row and the whole path equal; the regulator's replay refolds the log to the book's fingerprint.
//
// The index: instrument 1 (1,000,000 free-float shares at 85,000) and instrument 2 (20,000,000 at 1,995), base 1,000
// points, weights capped at 60%, the breaker at 10% (a halt) and 20% (a suspension to the close).
//
// What is proved:
//   * A, the cap: instrument 1's 68.05% capped at 60% by a factor 704,117,647 (parts per billion); the index starts at
//     its base, 100,000 hundredths;
//   * B, a trade of instrument 2 at 2,050 moves the level to 101,103;
//   * C, a dividend of 5,000 on instrument 1 lowers its reference to 80,000 and the divisor with it: the level stays;
//   * D, a split two for one on instrument 2: prices 998 and 1,025, shares 40,000,000, the level stays;
//   * E, a trade of instrument 1 at 64,000 takes the level to 89,400 (−10.6%): every instrument halted in the block
//     straight after; resumed; a trade at 48,000 takes it to 77,698 (−22.3%): suspended to the close, a resumption
//     refused until the next day's seal re-arms the breaker;
//   * F, a review of the free floats: the factors capped again at the present marks, the level kept by a new divisor;
//   * an action refused while a stop waits on the instrument; every refusal by name with the book unmoved.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Sha256 "mo:sha2/Sha256";
import DL "mo:kernel/domain/DomainLog";
import X "../../exchange/src/ExchangeCore";
import T "../src/BookTypes";
import K "../src/BookCanonical";
import B "../src/BookCore";
import TR "../../custody/test/support/Transcript";
import W "support/World";

let w = W.World(true);
let { advance; check; checkpoint; deposit; executes; govern; lim; n; newRun; operator; placed; refusedAs; scheduler; settle; sharesA; sharesB; cash; tick; today } = w;

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
func level() : Nat { switch (B.indexRowOf(m.st, 1)) { case (?x) x.level; case null 0 } };
func phaseOf(i : Nat) : ?T.Phase { switch (B.instrument(m.st, i)) { case (?x) ?x.phase; case null null } };
/// The family of the log's block `back` from its end (1 the last).
func familyFromEnd(back : Nat) : Text {
  switch (DL.get(m.st.log, K.codec, DL.length(m.st.log) - back)) { case (?b) { switch (b.event) { case (#executed(x)) K.familyOf(x.command); case (_) "other" } }; case null "none" }
};
let actionRef = Sha256.fromArray(#sha256, [0x43, 0x41]);

ignore tick();
deposit(m, 2, cash, 500_000_000); deposit(m, 2, sharesA, 1_000); deposit(m, 2, sharesB, 10_000);
deposit(m, 10, cash, 500_000_000); deposit(m, 10, sharesA, 1_000); deposit(m, 10, sharesB, 10_000);

// ─── A. the index defined, its cap ───────────────────────────────────────────────────────────
let cs : [T.Constituent] = [{ instrument = 1; shares = 1_000_000 }, { instrument = 2; shares = 20_000_000 }];
refused(operator, #defineIndex({ index = 1; base = 1_000; capBps = 4_000; haltBps = 1_000; suspendBps = 2_000; constituents = cs }), "e:InvalidTerms", "a cap two constituents cannot meet");
refused(operator, #defineIndex({ index = 1; base = 1_000; capBps = 6_000; haltBps = 1_000; suspendBps = 1_000; constituents = cs }), "e:InvalidTerms", "a suspension not above the halt");
refused(operator, #defineIndex({ index = 9; base = 1_000; capBps = 6_000; haltBps = 1_000; suspendBps = 2_000; constituents = cs }), "e:InvalidTerms", "an index beyond eight");
refused(operator, #defineIndex({ index = 1; base = 1_000; capBps = 6_000; haltBps = 1_000; suspendBps = 2_000; constituents = [{ instrument = 4; shares = 1 }] }), "e:UnknownInstrument", "a constituent the book does not trade");
refused(scheduler, #tripBreaker({ index = 1 }), "a:NoGrant", "the breaker submitted");
// 85,000 × 1,000,000 against 1,995 × 20,000,000: 68.05% capped at 60%: 60 × 39.9e9 / (85e9 × 40) = 0.704117647
governs(#defineIndex({ index = 1; base = 1_000; capBps = 6_000; haltBps = 1_000; suspendBps = 2_000; constituents = cs }), [48, 1, 100_000], "A: the index at its base, 1,000.00");
switch (B.constituentsOf(m.st, 1)) {
  case (rows) check(rows.size() == 2 and rows[0].1.factor == 704_117_647 and rows[1].1.factor == 1_000_000_000, "A: instrument 1 capped, instrument 2 not");
};
check(switch (B.indexRowOf(m.st, 1)) { case (?x) x.divisor == 997_499_999_950_000_000_000_000_000_000_000; case null false }, "A: the divisor M × 10^18 / 100,000");

// ─── B. a trade moves the level ──────────────────────────────────────────────────────────────
does(scheduler, #setTrading({ instrument = 2; open = true }), [2, 2], "B: instrument 2 trading");
ignore tick();
ignore placed(m, lim(10, 2, #sell, 10, 2_050, "b-s"));
settle(m);
ignore tick();
ignore placed(m, lim(2, 2, #buy, 10, 2_050, "b-b"));
settle(m);
check(level() == 101_103, "B: the level at instrument 2's 2,050: " # n(level()));

// ─── C. a dividend: the divisor follows, the level stays ─────────────────────────────────────
refused(operator, #corporateAction({ instrument = 2; action = #dividend({ amount = 5 }); reference = actionRef }), "e:InvalidTerms", "an action on an instrument trading");
refused(operator, #corporateAction({ instrument = 1; action = #dividend({ amount = 85_000 }); reference = actionRef }), "e:InvalidTerms", "a dividend at the price");
governs(#corporateAction({ instrument = 1; action = #dividend({ amount = 5_000 }); reference = actionRef }), [50, 1, 80_000, 1], "C: the dividend, the reference at 80,000");
check(level() == 101_103 and (switch (B.indexRowOf(m.st, 1)) { case (?x) x.divisor == 962_675_803_487_532_516_344_717_763_073_301; case null false }), "C: the level unmoved, the divisor set again");

// ─── D. a split: prices halved, shares doubled, the level stays ──────────────────────────────
// a stop waiting on instrument 2 is an open order: the action is refused until it is cancelled
let waiting = placed(m, w.order(2, 2, #buy, #stopLimit, 5, 2_100, 2_100, 0, #gtc, 0, #cancelResting, "d-stop", 0));
does(scheduler, #setTrading({ instrument = 2; open = false }), [2, 2], "D: instrument 2 closed");
refused(operator, #corporateAction({ instrument = 2; action = #split({ num = 2; den = 1 }); reference = actionRef }), "e:InvalidTerms", "an action under a waiting stop");
w.cancel(m, waiting);
governs(#corporateAction({ instrument = 2; action = #split({ num = 2; den = 1 }); reference = actionRef }), [50, 2, 998, 1], "D: two for one: the reference 1,995 → 997.5 → 998 half-even");
check((switch (B.instrument(m.st, 2)) { case (?i) i.lastPrice == 1_025; case null false }) and level() == 101_103, "D: the last price 1,025, the level unmoved");
check((switch (B.constituentsOf(m.st, 1)) { case (rows) rows[1].1.shares == 40_000_000 }), "D: 40,000,000 shares");
checkpoint(m);

// ─── E. the breaker ──────────────────────────────────────────────────────────────────────────
does(scheduler, #setTrading({ instrument = 1; open = true }), [2, 1], "E: instrument 1 trading");
does(scheduler, #setTrading({ instrument = 2; open = true }), [2, 2], "E: instrument 2 trading");
ignore tick();
ignore placed(m, lim(10, 1, #sell, 10, 64_000, "e-s"));
settle(m);
ignore tick();
ignore placed(m, lim(2, 1, #buy, 10, 64_000, "e-b"));
settle(m);
// 89,400 is 10.6% below the reference 100,000: the clear, then the breaker, then the flush that recorded them
check(level() == 89_400, "E: the level at 64,000: " # n(level()));
check(familyFromEnd(3) == "clear" and familyFromEnd(2) == "tripBreaker" and familyFromEnd(1) == "flush", "E: the breaker in the block straight after the clear");
check(phaseOf(1) == ?#halted and phaseOf(2) == ?#halted, "E: every instrument halted");
governs(#resume({ instrument = 1 }), [17, 1], "E: instrument 1 resumed (a halt, not a suspension)");
governs(#resume({ instrument = 2 }), [17, 2], "E: instrument 2 resumed");
does(scheduler, #setReference({ instrument = 1; price = 60_000 }), [3, 1], "E: instrument 1's reference at 60,000");
ignore tick();
ignore placed(m, lim(10, 1, #sell, 10, 48_000, "e-s2"));
ignore placed(m, lim(2, 1, #buy, 10, 48_000, "e-b2"));
ignore tick();
ignore executes(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "E: the auction uncrossed at 48,000");
// 77,698 is 22.3% below: suspended to the close in the block straight after the uncross
check(level() == 77_698, "E: the level at 48,000: " # n(level()));
check(familyFromEnd(2) == "uncross" and familyFromEnd(1) == "tripBreaker", "E: the suspension straight after the uncross");
check(phaseOf(1) == ?#halted and phaseOf(2) == ?#halted, "E: every instrument halted again");
refused(operator, #resume({ instrument = 1 }), "e:InvalidTerms", "a resumption before the close");
checkpoint(m);
// the next market day: the seal re-arms the breaker at the close's level; a resumption is accepted
advance(86_400);
ignore tick();
ignore executes(m, scheduler, #sealDay({ day = today() }), "E: the next day sealed");
check((switch (B.indexRowOf(m.st, 1)) { case (?x) x.reference == 77_698 and x.tripped == 0; case null false }), "E: the breaker re-armed at 77,698");
governs(#resume({ instrument = 1 }), [17, 1], "E: instrument 1 resumed the next day");
checkpoint(m);

// ─── F. a review: new free floats, the factors capped again, the level kept by a new divisor ──
refused(operator, #reviewIndex({ index = 1; constituents = [{ instrument = 2; shares = 30_000_000 }] }), "e:InvalidTerms", "a review of other constituents");
refused(operator, #reviewIndex({ index = 2; constituents = cs }), "e:InvalidTerms", "a review of no index");
let divisorBefore = switch (B.indexRowOf(m.st, 1)) { case (?x) x.divisor; case null 0 };
governs(#reviewIndex({ index = 1; constituents = [{ instrument = 1; shares = 1_000_000 }, { instrument = 2; shares = 30_000_000 }] }), [49, 1, 77_698], "F: the review, the level 777.0 kept");
check(level() == 77_698 and (switch (B.indexRowOf(m.st, 1)) { case (?x) x.divisor != divisorBefore; case null false }), "F: the level unmoved, the divisor set again");
check((switch (B.constituentsOf(m.st, 1)) { case (rows) rows[1].1.shares == 30_000_000 }), "F: 30,000,000 shares");
checkpoint(m);

Debug.print("count: index cases computed by hand = " # n(cases));
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));
if (not w.replayed(m)) check(false, "the index book's replay");
Debug.print("count: index books replayed to their fingerprint = 1");
TR.fingerprint("exchange", X.fingerprint(w.xs));
TR.fingerprint("book", B.fingerprint(m.st));
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the index book's log given to the regulator's replay = " # n(logBlocks));
if (w.failures > 0) { Debug.print("INDEX FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("INDEX GREEN");
