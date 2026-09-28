/// OfferingMath.mo: the offering's arithmetic as declared computations, reproduced by
/// `custody/integration/offering_twin.py`.

module {

  public let BPS : Nat = 10_000;

  /// A share of a total in basis points, floored.
  public func bpsOf(total : Nat, bps : Nat) : Nat { total * bps / BPS };

  /// A fee in basis points of an amount, rounded half up to the piastre, once.
  public func feeHalfUp(amount : Nat, bps : Nat) : Nat { let n = amount * bps; let q = n / BPS; if (2 * (n % BPS) >= BPS) q + 1 else q };

  /// Pro rata by cumulative rounding: an order of `lots` after `before` lots of the same tranche's demand, in a
  /// tranche of `supply` lots against `demand`, gets the difference of the two floors. Every order is within one lot
  /// of its exact share, and the orders of the tranche together get exactly `supply` (the floors telescope).
  public func cumulativeShare(before : Nat, lots : Nat, supply : Nat, demand : Nat) : Nat {
    if (demand == 0) return 0;
    if (supply >= demand) return lots;
    ((before + lots) * supply / demand) - (before * supply / demand : Nat) : Nat
  };

  /// The tranches after pricing: each filled up to its size from its demand; a tranche's unfilled lots go to the
  /// other when the other is oversubscribed; what neither takes is unsold.
  public func tranches(instLots : Nat, retailLots : Nat, instDemand : Nat, retailDemand : Nat) : { inst : Nat; retail : Nat; unsold : Nat } {
    let instFill = if (instDemand < instLots) instDemand else instLots;
    let retailFill = if (retailDemand < retailLots) retailDemand else retailLots;
    let spareInst = instLots - instFill : Nat;
    let spareRetail = retailLots - retailFill : Nat;
    let moreInst = instDemand - instFill : Nat;
    let moreRetail = retailDemand - retailFill : Nat;
    let toInst = if (spareRetail < moreInst) spareRetail else moreInst;
    let toRetail = if (spareInst < moreRetail) spareInst else moreRetail;
    let inst = instFill + toInst;
    let retail = retailFill + toRetail;
    { inst; retail; unsold = instLots + retailLots - inst - retail : Nat }
  };

  public func checkArithmetic() : Bool {
    feeHalfUp(1_000_000, 250) == 25_000 and feeHalfUp(3, 5_000) == 2 and feeHalfUp(1, 4_999) == 0
    and cumulativeShare(0, 3, 10, 30) == 1 and cumulativeShare(3, 3, 10, 30) == 1 and cumulativeShare(0, 1, 2, 3) == 0 and cumulativeShare(1, 1, 2, 3) == 1 and cumulativeShare(2, 1, 2, 3) == 1
    and cumulativeShare(0, 7, 10, 5) == 7
    and tranches(90, 10, 200, 4) == { inst = 96; retail = 4; unsold = 0 }
    and tranches(90, 10, 50, 30) == { inst = 50; retail = 30; unsold = 20 }
    and tranches(90, 10, 60, 5) == { inst = 60; retail = 5; unsold = 35 }
  };
}
