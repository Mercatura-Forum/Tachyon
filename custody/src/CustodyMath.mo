/// CustodyMath.mo: the entitlements as declared computations, reproduced by `custody/integration/custody_twin.py`.

import CT "CustodyTypes";

module {

  public let BPS : Nat = 10_000;

  /// A ratio applied to a position: the whole units, floored, and the fraction's numerator over the denominator
  /// (the units the fraction would be, times the denominator: exact, never a decimal).
  public func ratio(units : Nat, numerator : Nat, denominator : Nat) : { whole : Nat; fractionNumerator : Nat } {
    let product = units * numerator;
    { whole = product / denominator; fractionNumerator = product % denominator }
  };

  /// Cash in lieu of a fraction: the fraction of a unit times the price, one exact fraction floored (the holder is
  /// never paid a micro the fraction does not earn).
  public func cashInLieu(fractionNumerator : Nat, denominator : Nat, priceMicro : Nat) : Nat { fractionNumerator * priceMicro / denominator };

  /// A holder's entitlement under an action's terms, from its units at the record date.
  public func entitlement(kind : CT.Kind, units : Nat) : { cashDue : Nat; unitsDue : Nat; rights : Nat; fractionUnits : Nat } {
    switch (kind) {
      case (#cashDividend(d)) { { cashDue = units * d.perUnitMicro; unitsDue = 0; rights = 0; fractionUnits = 0 } };
      case (#split(s)) { let r = ratio(units, s.numerator, s.denominator); { cashDue = cashInLieu(r.fractionNumerator, s.denominator, s.cashInLieuMicro); unitsDue = r.whole; rights = 0; fractionUnits = r.fractionNumerator } };
      case (#bonus(b)) { let r = ratio(units, b.numerator, b.denominator); { cashDue = cashInLieu(r.fractionNumerator, b.denominator, b.cashInLieuMicro); unitsDue = r.whole; rights = 0; fractionUnits = r.fractionNumerator } };
      case (#rights(rg)) { let r = ratio(units, rg.numerator, rg.denominator); { cashDue = 0; unitsDue = 0; rights = r.whole; fractionUnits = r.fractionNumerator } };
      case (#redemption(rd)) { let r = ratio(units, rd.ratioBps, BPS); { cashDue = r.whole * rd.pricePerUnitMicro; unitsDue = r.whole; rights = 0; fractionUnits = r.fractionNumerator } };
    }
  };

  /// The subscription a holder pays for the rights it takes.
  public func subscription(rightsTaken : Nat, priceMicro : Nat) : Nat { rightsTaken * priceMicro };

  public func checkArithmetic() : Bool {
    ratio(7, 3, 2) == { whole = 10; fractionNumerator = 1 } and cashInLieu(1, 2, 1_000) == 500
    and entitlement(#cashDividend({ perUnitMicro = 250 }), 40) == { cashDue = 10_000; unitsDue = 0; rights = 0; fractionUnits = 0 }
    and entitlement(#split({ numerator = 3; denominator = 2; cashInLieuMicro = 1_000 }), 7) == { cashDue = 500; unitsDue = 10; rights = 0; fractionUnits = 1 }
    and entitlement(#bonus({ numerator = 1; denominator = 10; cashInLieuMicro = 900 }), 25) == { cashDue = 450; unitsDue = 2; rights = 0; fractionUnits = 5 }
    and entitlement(#rights({ numerator = 1; denominator = 4; subscriptionPriceMicro = 5; subscriptionDeadline = 0 }), 10) == { cashDue = 0; unitsDue = 0; rights = 2; fractionUnits = 2 }
    and entitlement(#redemption({ ratioBps = 2_500; pricePerUnitMicro = 3 }), 10) == { cashDue = 6; unitsDue = 2; rights = 0; fractionUnits = 5_000 }
    and subscription(3, 5) == 15
  };
}
