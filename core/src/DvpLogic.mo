/// DvpLogic.mo - the PURE decision core of the DvP state machine.
///
/// Every function here is referentially transparent (no awaits, no state, no I/O) so it
/// can be exhaustively unit-tested under `mops test --mode interpreter` with no replica.
/// DvpCore.mo calls these for the error-prone arithmetic and gating; the test battery
/// drives the same functions plus a pure mock-ledger simulation. Keeping the conservation
/// arithmetic and the lifecycle gates in one tested place is what closes agenda F.

import T "DvpTypes";

module {

  // ── Conservation arithmetic (INV-DVP-1) ────────────────────────────────────────────
  // Net amount delivered to a recipient after the ledger's outbound fee. The recipient
  // bears the outbound fee; the core's per-leg balance returns to exactly 0
  // (escrowed = net + fee). Rejects the dust case where the fee would eat the whole leg.
  public func netAfterFee(escrowed : Nat, fee : Nat) : Result_<Nat> {
    if (escrowed <= fee) return #err("amount (" # natT(escrowed) # ") <= ledger fee (" # natT(fee) # ")");
    let net : Nat = escrowed - fee;
    // Guard against any arithmetic slip: net + fee must reconstruct escrowed exactly.
    if (net + fee != escrowed) return #err("conservation arithmetic violated");
    #ok(net);
  };

  // A leg amount must strictly exceed the ledger fee to be both deliverable AND refundable.
  public func legAmountValid(amount : Nat, fee : Nat) : Bool { amount > fee };

  // ── Idempotent created_at_time allocation (INV-DVP-5 substrate) ──────────────────────
  // Strictly-monotonic step: unique per call (even when `now` is identical across calls in
  // one block), never more than (#same-instant allocations) ahead of real time.
  public func nextCat(cursor : Nat64, now : Nat64) : Nat64 {
    if (now > cursor) now else cursor + 1;
  };

  // ── Lifecycle gates ──────────────────────────────────────────────────────────────────
  // Funding is allowed only on an Open trade within the funding window.
  public func canFund(status : T.TradeStatus, now : Nat64, deadline : Nat64) : Result_<()> {
    switch (status) {
      case (#Open) { if (now > deadline) #err("past funding deadline") else #ok(()) };
      case (#Funded) #err("trade already fully escrowed");
      case (#Settled) #err("trade already settled");
      case (#Aborted) #err("trade aborted");
    };
  };

  // DvP gate (INV-DVP-2): settlement may proceed only when BOTH legs are escrowed.
  public func canSettle(status : T.TradeStatus, aEscrowed : Bool, bEscrowed : Bool) : Result_<()> {
    switch (status) {
      case (#Funded) {
        if (aEscrowed and bEscrowed) #ok(()) else #err("DvP gate: both legs must be escrowed");
      };
      case (#Open) #err("trade not fully escrowed - DvP gate closed");
      case (#Settled) #err("already settled");
      case (#Aborted) #err("trade aborted");
    };
  };

  // Reclaim is allowed only on an Open trade after the deadline (never on Funded/terminal).
  public func canReclaim(status : T.TradeStatus, now : Nat64, deadline : Nat64) : Result_<()> {
    switch (status) {
      case (#Open) { if (now <= deadline) #err("funding deadline not reached") else #ok(()) };
      case (#Funded) #err("both legs escrowed - settles, not reclaims");
      case (#Settled) #err("settled - cannot reclaim (INV-DVP-3)");
      case (#Aborted) #err("already aborted");
    };
  };

  // ── Delivery gates (one leg, free of payment) ──────────────────────────────────────────
  // The maker funds an Open delivery within its window.
  public func canFundDelivery(status : T.DeliveryStatus, now : Nat64, deadline : Nat64) : Result_<()> {
    switch (status) {
      case (#Open) { if (now > deadline) #err("past funding deadline") else #ok(()) };
      case (#Escrowed) #err("delivery already escrowed");
      case (#Delivered) #err("delivery already delivered");
      case (#Reclaimed) #err("delivery reclaimed");
    };
  };
  // The taker accepts an escrowed delivery within its window; acceptance is what opens the gate.
  public func canAccept(status : T.DeliveryStatus, escrowed : Bool, now : Nat64, deadline : Nat64) : Result_<()> {
    switch (status) {
      case (#Escrowed) { if (not escrowed) #err("delivery gate: the leg must be escrowed") else if (now > deadline) #err("past the deadline - the maker reclaims") else #ok(()) };
      case (#Open) #err("delivery not escrowed - nothing to accept");
      case (#Delivered) #err("already delivered");
      case (#Reclaimed) #err("delivery reclaimed");
    };
  };
  // The payout fires only for an escrowed and accepted delivery (INV-DEL-2).
  public func canDeliver(status : T.DeliveryStatus, escrowed : Bool, accepted : Bool) : Result_<()> {
    switch (status) {
      case (#Escrowed) { if (escrowed and accepted) #ok(()) else #err("delivery gate: escrowed and accepted") };
      case (#Open) #err("delivery not escrowed");
      case (#Delivered) #err("already delivered");
      case (#Reclaimed) #err("delivery reclaimed");
    };
  };
  // Reclaim is allowed after the deadline on a delivery the taker has not accepted.
  public func canReclaimDelivery(status : T.DeliveryStatus, accepted : Bool, now : Nat64, deadline : Nat64) : Result_<()> {
    switch (status) {
      case (#Open or #Escrowed) {
        if (accepted) #err("accepted - this delivery delivers, it cannot be reclaimed")
        else if (now <= deadline) #err("deadline not reached")
        else #ok(())
      };
      case (#Delivered) #err("delivered - cannot reclaim (INV-DEL-3)");
      case (#Reclaimed) #err("already reclaimed");
    };
  };
  public func isDeliveryTerminal(status : T.DeliveryStatus) : Bool {
    switch (status) { case (#Delivered) true; case (#Reclaimed) true; case (_) false };
  };

  // ── Terminal-state predicates ──────────────────────────────────────────────────────────
  public func isTerminal(status : T.TradeStatus) : Bool {
    switch (status) { case (#Settled) true; case (#Aborted) true; case (_) false };
  };

  // INV-DVP-3: a single leg may be resolved to AT MOST ONE of {paid, refunded}.
  public func legSingleResolution(payout : ?Nat, refund : ?Nat) : Bool {
    not (payout != null and refund != null);
  };

  // ── helpers ────────────────────────────────────────────────────────────────────────────
  public type Result_<T_> = { #ok : T_; #err : Text };

  func natT(n : Nat) : Text {
    if (n == 0) return "0";
    var x = n;
    var s = "";
    let d = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];
    while (x > 0) { s := d[x % 10] # s; x := x / 10 };
    s;
  };
};
