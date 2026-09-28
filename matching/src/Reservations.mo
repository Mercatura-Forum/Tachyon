/// Reservations.mo - the PURE reservation accounting of the matching engine.
///
/// A reservation is the engine's claim on a trader's FREE capacity (balance ∧ allowance-to-core).
/// The engine holds no custody: the funds stay with the trader until the core pulls them. What the
/// core pulls for one fill is an `icrc2_transfer_from` carrying the ledger's own fee, so it debits
/// the funder `amount + one fee` - PER FILL, once per escrow. The accounting is therefore
/// denominated per escrow, in three terms:
///
///   • a LIVE ORDER reserves its REMAINING NOTIONAL + ONE FEE - the fee of the next escrow it can
///     produce (a bid: limitPrice*remaining + one cash fee; an ask: remaining + one shares fee);
///   • every created-but-unresolved OBLIGATION reserves its OWN EXACT escrow cost - the notional at
///     the clearing price plus one fee, on each side - from the moment its fill is applied until it
///     settles or is voided. The cleared match owes those escrows; until it resolves, the funds it
///     owes are not free for a new order to spend;
///   • every unit reserved is released by exactly ONE event: an order's notional as a fill consumes
///     it or at cancel/kill, an order's margin when the order goes terminal, an obligation's hold
///     when it resolves.
///
/// So reserved(p) = Σ live orders (remaining notional + one fee) + Σ open obligations (exact escrow
/// cost), and a trader with no live order and no open obligation has reserved EXACTLY ZERO. Nothing
/// strands. A K-fill order's K fees are discovered as its fills are applied - each obligation brings
/// its own - which is why one fee at intake is a floor, not an estimate of the whole order's cost.
///
/// The fee a margin and a hold are denominated in is the one the engine read LIVE from the ledger at
/// the order's intake: the fee the order was admitted under. A ledger that raises its fee between
/// intake and escrow leaves a hold short by the difference; that escrow refuses transiently and the
/// drain retries it. The ACCOUNTING stays exact regardless, because every release is the amount that
/// was recorded when it was reserved, never a recomputation against a fee that may since have moved.
///
/// PURE: no awaits, no actor state, no I/O. The actor and the interpreter battery call these same
/// functions over their own maps, so the property battery exercises production code.

import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";

module {

  /// The amounts one obligation holds - its exact escrow cost on each side.
  public type Amounts = { cash : Nat; shares : Nat };

  /// The four maps the accounting lives in. `cash` and `shares` are the engine's UNCHANGED
  /// reservation state (the totals `reservationOf` reports); `margin` and `hold` are the additive
  /// state this accounting adds, which is what makes every release exact rather than recomputed.
  public type Ledger = {
    cash : Map.Map<Principal, Nat>;    // owner -> reserved cash
    shares : Map.Map<Principal, Nat>;  // owner -> reserved shares
    margin : Map.Map<Nat, Nat>;        // orderId -> the one-fee margin a LIVE order holds
    hold : Map.Map<Nat, Amounts>;      // obligation seq -> the escrow cost it holds until it resolves
  };

  /// A release that exceeded what was reserved. (0,0) is exact; anything else is an accounting
  /// DRIFT. By the construction of the transitions below it is unreachable - every release is an
  /// amount this module itself recorded - and the property battery proves that over random
  /// lifecycles. The actor logs a non-exact drift to its no-stranding invariant log rather than
  /// trapping, so a discrepancy turns the oracle red instead of being lost in a clamped subtraction.
  public type Drift = { cash : Nat; shares : Nat };
  public let exact : Drift = { cash = 0; shares = 0 };
  public func isExact(d : Drift) : Bool { d.cash == 0 and d.shares == 0 };

  public func empty() : Ledger {
    {
      cash = Map.empty<Principal, Nat>();
      shares = Map.empty<Principal, Nat>();
      margin = Map.empty<Nat, Nat>();
      hold = Map.empty<Nat, Amounts>();
    }
  };

  func get(m : Map.Map<Principal, Nat>, k : Principal) : Nat {
    switch (Map.get(m, Principal.compare, k)) { case (?v) v; case null 0 }
  };
  func credit(m : Map.Map<Principal, Nat>, k : Principal, d : Nat) {
    if (d > 0) Map.add(m, Principal.compare, k, get(m, k) + d);
  };
  /// Debit `d`, clamped at zero, and return the SHORTFALL - 0 when the reservation covered it.
  /// A zero entry is deleted so an owner with nothing reserved holds no key.
  func debit(m : Map.Map<Principal, Nat>, k : Principal, d : Nat) : Nat {
    let cur = get(m, k);
    if (d >= cur) { ignore Map.delete(m, Principal.compare, k); d - cur } else { Map.add(m, Principal.compare, k, cur - d); 0 };
  };

  public func reservedCash(l : Ledger, p : Principal) : Nat { get(l.cash, p) };
  public func reservedShares(l : Ledger, p : Principal) : Nat { get(l.shares, p) };
  /// The fee margin a live order holds; 0 for an order that holds none (terminal, or one admitted
  /// before this accounting existed - see `closeOrder`).
  public func marginOf(l : Ledger, orderId : Nat) : Nat {
    switch (Map.get(l.margin, Nat.compare, orderId)) { case (?v) v; case null 0 };
  };
  public func holdOf(l : Ledger, seq : Nat) : ?Amounts { Map.get(l.hold, Nat.compare, seq) };

  // ── Intake ──────────────────────────────────────────────────────────────────────────────────
  /// What an ask must have free on the shares ledger: the shares it sells, plus the one fee its
  /// escrow costs. (The accounting this replaces reserved `qty` alone, so an ask approved for
  /// exactly `qty` was admitted and its escrow then refused on allowance - the order was never
  /// fundable and the engine had said it was.)
  public func askNeed(qty : Nat, sharesFee : Nat) : Nat { qty + sharesFee };
  /// What a bid must have free on the cash ledger: the notional at its own limit price - the most
  /// any fill of it can cost - plus the one fee its escrow costs.
  public func bidNeed(limitPrice : Nat, qty : Nat, cashFee : Nat) : Nat { limitPrice * qty + cashFee };

  /// Reserve an accepted ask: its qty and its margin. Call AFTER the order exists (the margin is
  /// keyed by order id) and with no await in between, so intake is atomic.
  public func openAsk(l : Ledger, owner : Principal, orderId : Nat, qty : Nat, sharesFee : Nat) {
    credit(l.shares, owner, askNeed(qty, sharesFee));
    if (sharesFee > 0) Map.add(l.margin, Nat.compare, orderId, sharesFee);
  };
  /// Reserve an accepted bid: its notional at the limit price, and its margin.
  public func openBid(l : Ledger, owner : Principal, orderId : Nat, limitPrice : Nat, qty : Nat, cashFee : Nat) {
    credit(l.cash, owner, bidNeed(limitPrice, qty, cashFee));
    if (cashFee > 0) Map.add(l.margin, Nat.compare, orderId, cashFee);
  };

  // ── A fill ──────────────────────────────────────────────────────────────────────────────────
  /// One applied fill, as one transfer of the reservation from the orders to the obligation: the
  /// notional the fill consumed leaves each side's order reservation (the bid's at its LIMIT price,
  /// which is what intake reserved), the obligation takes up its own exact escrow cost on both
  /// sides, and an order left with no remaining qty releases its margin - it can produce no further
  /// escrow, so it needs no further fee.
  ///
  /// The obligation's hold is credited BEFORE a margin is released so the release is always covered
  /// by construction; the two are simultaneous in effect (no await can interleave a caller).
  ///
  /// `buyerDone`/`sellerDone` are the post-fill remainders being zero. An order whose margin was
  /// never recorded (one admitted before this accounting) contributes a zero fee to the hold and
  /// releases nothing - the fill is accounted exactly as the old code accounted it, and the
  /// difference stays visible as residue rather than being invented here.
  public func fill(
    l : Ledger,
    seq : Nat,
    buyer : Principal,
    seller : Principal,
    buyId : Nat,
    sellId : Nat,
    bidLimit : Nat,
    price : Nat,
    qty : Nat,
    buyerDone : Bool,
    sellerDone : Bool,
  ) : Drift {
    let bidFee = marginOf(l, buyId);
    let askFee = marginOf(l, sellId);
    var shortCash = 0;
    var shortShares = 0;

    // the notional this fill consumed leaves the orders
    shortCash += debit(l.cash, buyer, bidLimit * qty);
    shortShares += debit(l.shares, seller, qty);

    // the obligation takes up the escrows it now owes: notional at the CLEARING price + one fee a side
    let h : Amounts = { cash = price * qty + bidFee; shares = qty + askFee };
    credit(l.cash, buyer, h.cash);
    credit(l.shares, seller, h.shares);
    Map.add(l.hold, Nat.compare, seq, h);

    // an order with nothing remaining can produce no further escrow: its margin goes back
    if (buyerDone) {
      shortCash += debit(l.cash, buyer, bidFee);
      ignore Map.delete(l.margin, Nat.compare, buyId);
    };
    if (sellerDone) {
      shortShares += debit(l.shares, seller, askFee);
      ignore Map.delete(l.margin, Nat.compare, sellId);
    };
    { cash = shortCash; shares = shortShares };
  };

  // ── A terminal order (cancel, all-or-none kill) ──────────────────────────────────────────────
  /// An order that will never fill again releases its remaining notional AND its fee margin: it can
  /// produce no escrow, so it holds nothing. (The accounting this replaces released the notional
  /// alone and left the margin reserved for the life of the engine - the strand.)
  public func closeOrder(l : Ledger, owner : Principal, orderId : Nat, isBid : Bool, remainingNotional : Nat) : Drift {
    let fee = marginOf(l, orderId);
    ignore Map.delete(l.margin, Nat.compare, orderId);
    if (isBid) { { cash = debit(l.cash, owner, remainingNotional + fee); shares = 0 } } else {
      { cash = 0; shares = debit(l.shares, owner, remainingNotional + fee) };
    };
  };

  // ── A terminal obligation (settled through the core, or voided) ──────────────────────────────
  /// A resolved obligation releases exactly what it held - the amounts recorded when its fill was
  /// applied, never a recomputation. Idempotent: the record is TAKEN, so an idempotent re-drive, a
  /// void after a refusal, or two callers racing the same seq release it once and only once. An
  /// obligation that holds nothing (resolved already, or created before this accounting) releases
  /// nothing.
  public func resolveObligation(l : Ledger, seq : Nat, buyer : Principal, seller : Principal) : Drift {
    switch (Map.take(l.hold, Nat.compare, seq)) {
      case null exact;
      case (?h) { { cash = debit(l.cash, buyer, h.cash); shares = debit(l.shares, seller, h.shares) } };
    };
  };
};
