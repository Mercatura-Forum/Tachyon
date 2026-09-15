/// run_tests_delivery.mo - interpreter battery for the delivery free of payment (one leg).
///
/// Run with the moc interpreter (no replica):
///   moc -r --package core <core/src> --package sha2 <sha2/src> test/run_tests_delivery.mo
/// Exit code is non-zero on any failed check (Runtime.trap), so it is a hard CI gate.
///
/// PART 1 - DvpLogic delivery gates: funding, acceptance, the payout gate (escrow AND acceptance),
///   reclaim, terminal predicates; each bound to an exact expected verdict.
/// PART 2 - property simulation (N >= 10_000): the same pure ledger mock as the trade battery and
///   the SAME idempotent payout/refund algorithm the core uses on a delivery's single leg, with
///   randomized amounts, lifecycle paths (accepted and delivered, unaccepted and reclaimed, never
///   escrowed and closed) and injected ledger failures (clean-transient AND lost-reply-after-commit).
///   Asserts conservation, exactly-once payout or refund, and no-stranding on EVERY trial; the leg
///   never moves without the acceptance.

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Map "mo:core/Map";

import L "../src/DvpLogic";

var checks : Nat = 0;
var failures : Nat = 0;
func check(name : Text, cond : Bool) {
  checks += 1;
  if (not cond) { failures += 1; Debug.print("  FAIL: " # name) };
};
func checkEqNat(name : Text, got : Nat, want : Nat) {
  checks += 1;
  if (got != want) { failures += 1; Debug.print("  FAIL: " # name # " got=" # Nat.toText(got) # " want=" # Nat.toText(want)) };
};
func isOk<X>(r : L.Result_<X>) : Bool { switch (r) { case (#ok(_)) true; case (#err(_)) false } };
func isErr<X>(r : L.Result_<X>) : Bool { not isOk(r) };

type Ledger = {
  bal : Map.Map<Text, Nat>;
  fee : Nat;
  var burned : Nat;
  dedup : Map.Map<Nat64, Nat>;
  var nextIdx : Nat;
};
func newLedger(fee : Nat) : Ledger { { bal = Map.empty<Text, Nat>(); fee; var burned = 0; dedup = Map.empty<Nat64, Nat>(); var nextIdx = 1 } };
func bget(lg : Ledger, a : Text) : Nat { switch (Map.get(lg.bal, Text.compare, a)) { case (?b) b; case null 0 } };
func bset(lg : Ledger, a : Text, v : Nat) { if (v == 0) ignore Map.delete(lg.bal, Text.compare, a) else Map.add(lg.bal, Text.compare, a, v) };
func credit(lg : Ledger, a : Text, v : Nat) { if (v > 0) bset(lg, a, bget(lg, a) + v) };
func totalSupply(lg : Ledger) : Nat { var s = lg.burned; for ((_, v) in Map.entries(lg.bal)) { s += v }; s };

type TxResult = { #Ok : Nat; #Duplicate : Nat; #InsufficientFunds; #TransientNoCommit; #TransientLostReply : Nat };
func transfer(lg : Ledger, from : Text, to : Text, amount : Nat, cat : Nat64, fail : { #none; #clean; #lost }) : TxResult {
  switch (Map.get(lg.dedup, Nat64.compare, cat)) { case (?idx) { return #Duplicate(idx) }; case null {} };
  let total = amount + lg.fee;
  if (bget(lg, from) < total) return #InsufficientFunds;
  switch (fail) {
    case (#clean) { #TransientNoCommit };
    case (_) {
      bset(lg, from, bget(lg, from) - total);
      credit(lg, to, amount);
      lg.burned += lg.fee;
      let idx = lg.nextIdx; lg.nextIdx += 1;
      Map.add(lg.dedup, Nat64.compare, cat, idx);
      switch (fail) { case (#lost) { #TransientLostReply(idx) }; case (_) { #Ok(idx) } };
    };
  };
};

var rng : Nat64 = 9_017_236_559_137_331_009;
func rnd() : Nat64 {
  var x = rng;
  x := x ^ (x << 13);
  x := x ^ (x >> 7);
  x := x ^ (x << 17);
  rng := x;
  x;
};
func rndRange(lo : Nat, hi : Nat) : Nat { lo + Nat64.toNat(rnd() % Nat64.fromNat(hi - lo + 1)) };
func injFail() : { #none; #clean; #lost } { let r = rnd() % 100; if (r < 60) #none else if (r < 85) #clean else #lost };
func unwrap(r : L.Result_<Nat>) : Nat { switch (r) { case (#ok(n)) n; case (#err(e)) Runtime.trap("unwrap err: " # e) } };

// ── PART 1: the gates ─────────────────────────────────────────────────────────────────
Debug.print("PART 1 - delivery gates");
check("fund Open in-window", isOk(L.canFundDelivery(#Open, 100, 200)));
check("fund Open past-deadline rejects", isErr(L.canFundDelivery(#Open, 300, 200)));
check("fund Escrowed rejects", isErr(L.canFundDelivery(#Escrowed, 100, 200)));
check("fund Delivered rejects", isErr(L.canFundDelivery(#Delivered, 100, 200)));
check("fund Reclaimed rejects", isErr(L.canFundDelivery(#Reclaimed, 100, 200)));
check("accept Escrowed in-window", isOk(L.canAccept(#Escrowed, true, 100, 200)));
check("accept Escrowed past-deadline rejects", isErr(L.canAccept(#Escrowed, true, 300, 200)));
check("accept Escrowed without the escrow rejects", isErr(L.canAccept(#Escrowed, false, 100, 200)));
check("accept Open rejects (nothing to accept)", isErr(L.canAccept(#Open, false, 100, 200)));
check("accept Delivered rejects", isErr(L.canAccept(#Delivered, true, 100, 200)));
check("accept Reclaimed rejects", isErr(L.canAccept(#Reclaimed, true, 100, 200)));
check("deliver Escrowed+accepted ok", isOk(L.canDeliver(#Escrowed, true, true)));
check("deliver Escrowed unaccepted rejects (the gate)", isErr(L.canDeliver(#Escrowed, true, false)));
check("deliver Escrowed without escrow rejects", isErr(L.canDeliver(#Escrowed, false, true)));
check("deliver Open rejects", isErr(L.canDeliver(#Open, false, false)));
check("deliver Reclaimed rejects (INV-DEL-3)", isErr(L.canDeliver(#Reclaimed, true, true)));
check("reclaim Escrowed unaccepted past-deadline ok", isOk(L.canReclaimDelivery(#Escrowed, false, 300, 200)));
check("reclaim Open unescrowed past-deadline ok", isOk(L.canReclaimDelivery(#Open, false, 300, 200)));
check("reclaim pre-deadline rejects", isErr(L.canReclaimDelivery(#Escrowed, false, 100, 200)));
check("reclaim accepted rejects (it delivers)", isErr(L.canReclaimDelivery(#Escrowed, true, 300, 200)));
check("reclaim Delivered rejects (INV-DEL-3)", isErr(L.canReclaimDelivery(#Delivered, true, 300, 200)));
check("reclaim Reclaimed rejects", isErr(L.canReclaimDelivery(#Reclaimed, false, 300, 200)));
check("terminal Delivered", L.isDeliveryTerminal(#Delivered));
check("terminal Reclaimed", L.isDeliveryTerminal(#Reclaimed));
check("terminal Escrowed false", not L.isDeliveryTerminal(#Escrowed));
check("terminal Open false", not L.isDeliveryTerminal(#Open));

// ── PART 2: property simulation ───────────────────────────────────────────────────────
Debug.print("PART 2 - property simulation (N=10000 randomized deliveries)");
var trial = 0;
let N = 10_000;
var catCursor : Nat64 = 1_000_000;
var clock : Nat64 = 1_000_000;
var delivered = 0; var reclaimed = 0; var closed = 0;
while (trial < N) {
  let fee = rndRange(0, 5);
  let lg = newLedger(fee);
  let amount = rndRange(fee + 1, fee + 5000);
  let maker = "maker"; let taker = "taker"; let core = "core";
  credit(lg, maker, amount + fee + rndRange(0, 100));
  let total0 = totalSupply(lg);
  let maker0 = bget(lg, maker);
  let path = rnd() % 10;   // 0: never escrowed and closed; 1, 2: reclaimed unaccepted; else accepted and delivered
  if (path == 0) {
    // the maker never funded: the delivery closes past the deadline with nothing moved
    check("unescrowed: reclaim past the deadline is allowed", isOk(L.canReclaimDelivery(#Open, false, 300, 200)));
    checkEqNat("unescrowed: maker untouched", bget(lg, maker), maker0);
    closed += 1;
  } else {
    catCursor := L.nextCat(catCursor, clock); clock += 1;
    switch (transfer(lg, maker, core, amount, catCursor, #none)) { case (#Ok(_)) {}; case (_) Runtime.trap("escrow setup failed") };
    checkEqNat("escrow: core holds the leg", bget(lg, core), amount);
    // the gate: without the acceptance, no payout is planned at all
    check("gate: no payout without the acceptance", isErr(L.canDeliver(#Escrowed, true, false)));
    if (path <= 2) {
      var ref : ?Nat = null; var catR : ?Nat64 = null; var guard = 0;
      while (ref == null and guard < 80) {
        guard += 1;
        let c = switch (catR) { case (?cc) cc; case null { catCursor := L.nextCat(catCursor, clock); clock += 1; catR := ?catCursor; catCursor } };
        switch (transfer(lg, core, maker, unwrap(L.netAfterFee(amount, lg.fee)), c, injFail())) {
          case (#Ok(i) or #Duplicate(i) or #TransientLostReply(i)) { ref := ?i }; case (_) {};
        };
      };
      check("reclaim converged", ref != null);
      checkEqNat("reclaim: maker restored minus 2 fees", bget(lg, maker), maker0 - 2 * lg.fee);
      reclaimed += 1;
    } else {
      check("accept: allowed on the escrowed leg in the window", isOk(L.canAccept(#Escrowed, true, 100, 200)));
      var pay : ?Nat = null; var catP : ?Nat64 = null; var guard = 0;
      while (pay == null and guard < 80) {
        guard += 1;
        let c = switch (catP) { case (?cc) cc; case null { catCursor := L.nextCat(catCursor, clock); clock += 1; catP := ?catCursor; catCursor } };
        switch (transfer(lg, core, taker, unwrap(L.netAfterFee(amount, lg.fee)), c, injFail())) {
          case (#Ok(i) or #Duplicate(i) or #TransientLostReply(i)) { pay := ?i }; case (_) {};
        };
      };
      check("deliver converged", pay != null);
      checkEqNat("deliver: taker got the leg net fee", bget(lg, taker), amount - lg.fee);
      checkEqNat("deliver: maker paid the leg and the escrow fee", bget(lg, maker), maker0 - amount - lg.fee);
      delivered += 1;
    };
  };
  checkEqNat("conservation: supply", totalSupply(lg), total0);
  checkEqNat("no-stranding: core == 0", bget(lg, core), 0);
  trial += 1;
};
check("every path taken", delivered > 0 and reclaimed > 0 and closed > 0);
Debug.print("delivered=" # Nat.toText(delivered) # " reclaimed=" # Nat.toText(reclaimed) # " closed=" # Nat.toText(closed));

// exactly-once: the same created_at_time replayed is a Duplicate that moves nothing
do {
  let lg = newLedger(10);
  credit(lg, "core", 1000);
  let cat : Nat64 = 9_999_999;
  let r1 = transfer(lg, "core", "taker", 500, cat, #none);
  let r2 = transfer(lg, "core", "taker", 500, cat, #none);
  check("idempotent: first is Ok", switch (r1) { case (#Ok(_)) true; case (_) false });
  check("idempotent: replay is Duplicate", switch (r2) { case (#Duplicate(_)) true; case (_) false });
  checkEqNat("idempotent: taker credited once (500)", bget(lg, "taker"), 500);
  checkEqNat("idempotent: core debited once (510)", bget(lg, "core"), 490);
};

Debug.print("checks=" # Nat.toText(checks) # " failures=" # Nat.toText(failures));
if (failures > 0) { Runtime.trap("BATTERY RED: " # Nat.toText(failures) # " failed checks") } else { Debug.print("BATTERY GREEN: all " # Nat.toText(checks) # " checks passed") };
