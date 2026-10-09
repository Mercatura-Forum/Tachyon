/// ExchangeLogic.mo: the pure decisions of the exchange's foundation. No state, no clock, no await: the battery, the
/// Python twin and the core all call these, so a decision is reproducible from its inputs alone.
///
///   isinValid     ISO 6166: two letters, nine letters or digits, one check digit (each letter expanded to two digits,
///                 A = 10 ... Z = 35, then the Luhn algorithm over the digits)
///   tableProblem  a tick table's bands start at a price of zero, rise, each tick is above zero, and each band starts
///                 on the previous band's price grid (price-dependent tick tables, as the EGX's 0.001 below 2.00 and
///                 0.01 from 2.00)
///   onTick        a price on its band's grid
///   scheduleProblem  windows covering the whole day without gap or overlap, in order, none `#halted` (a halt is an act)
///   phaseAt       the schedule's phase at a second of a business day; `#closed` on a rest day or a holiday
///   marketTime    the chain's nanoseconds as the market's day and second of the day, by its UTC offset
///
/// Attribution: Thebes Core Team.

import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Int "mo:core/Int";
import Char "mo:core/Char";
import List "mo:core/List";

import Cal "mo:kernel/time/Calendar";

import T "ExchangeTypes";

module {

  // ─── ISIN ──────────────────────────────────────────────────────────────────────────────────────────────────────
  func charValue(c : Char) : ?Nat {
    let n = Nat32.toNat(Char.toNat32(c));
    if (n >= 48 and n <= 57) return ?(n - 48);     // 0-9
    if (n >= 65 and n <= 90) return ?(n - 55);     // A-Z = 10..35
    null
  };

  /// The ISO 6166 check digit of an ISIN's first eleven characters; null when they are not two capital letters and
  /// nine capital letters or digits.
  public func isinCheckDigit(first11 : Text) : ?Nat {
    let digits = List.empty<Nat>();
    var k = 0;
    for (c in first11.chars()) {
      let ?v = charValue(c) else return null;
      if (k < 2 and v < 10) return null;
      if (v >= 10) { List.add(digits, v / 10); List.add(digits, v % 10) } else List.add(digits, v);
      k += 1;
    };
    if (k != 11) return null;
    // Luhn over the digits followed by the check digit: from the rightmost digit of the body, every second digit
    // (starting with that one) is doubled, and a doubled value above 9 has 9 taken off
    var sum = 0;
    var i = List.size(digits);
    var double = true;
    while (i > 0) {
      i -= 1;
      var d = List.at(digits, i);
      if (double) { d *= 2; if (d > 9) d -= 9 };
      sum += d;
      double := not double;
    };
    ?((10 - sum % 10) % 10)
  };

  public func isinValid(isin : Text) : Bool {
    if (isin.size() != T.ISIN_BYTES) return false;
    var first = "";
    var last : ?Char = null;
    var k = 0;
    for (c in isin.chars()) { if (k < 11) first #= Char.toText(c) else last := ?c; k += 1 };
    let ?check = isinCheckDigit(first) else return false;
    let ?l = last else return false;
    charValue(l) == ?check
  };

  // ─── tick tables ───────────────────────────────────────────────────────────────────────────────────────────────
  public func tableProblem(bands : [T.Band]) : ?Text {
    if (bands.size() == 0) return ?"a table has at least one band";
    if (bands.size() > T.MAX_BANDS) return ?("a table has at most " # Nat.toText(T.MAX_BANDS) # " bands");
    if (bands[0].fromPrice != 0) return ?"the first band starts at a price of zero";
    var i = 0;
    while (i < bands.size()) {
      if (bands[i].tick == 0) return ?"a tick is above zero";
      if (i > 0) {
        if (bands[i].fromPrice <= bands[i - 1].fromPrice) return ?"the bands rise";
        if (bands[i].fromPrice % bands[i - 1].tick != 0) return ?"a band starts on the previous band's grid";
      };
      i += 1;
    };
    null
  };

  /// The tick at a price: the tick of the last band starting at or below it.
  public func tickAt(bands : [T.Band], price : Nat) : Nat {
    var t = bands[0].tick;
    for (b in bands.vals()) { if (b.fromPrice <= price) t := b.tick };
    t
  };

  public func onTick(bands : [T.Band], price : Nat) : Bool { price > 0 and price % tickAt(bands, price) == 0 };

  // ─── schedules ─────────────────────────────────────────────────────────────────────────────────────────────────
  public func scheduleProblem(ws : [T.Window]) : ?Text {
    if (ws.size() == 0) return ?"a schedule has at least one window";
    if (ws.size() > T.MAX_WINDOWS) return ?("a schedule has at most " # Nat.toText(T.MAX_WINDOWS) # " windows");
    if (ws[0].startSec != 0) return ?"the first window starts at midnight";
    if (ws[ws.size() - 1].endSec != T.DAY_SECONDS) return ?"the last window ends at midnight";
    var i = 0;
    while (i < ws.size()) {
      if (ws[i].endSec <= ws[i].startSec) return ?"a window ends after it starts";
      if (ws[i].phase == #halted) return ?"a halt is an act, never a scheduled window";
      if (i > 0 and ws[i].startSec != ws[i - 1].endSec) return ?"windows follow one another without gap or overlap";
      i += 1;
    };
    null
  };

  /// The phase the schedule names at `sec` of `day`; a day that is not a business day is closed throughout.
  public func phaseAt(ws : [T.Window], cal : Cal.Calendar, day : T.Day, sec : Nat) : T.Phase {
    if (not Cal.isBusinessDay(cal, day)) return #closed;
    for (w in ws.vals()) { if (sec >= w.startSec and sec < w.endSec) return w.phase };
    #closed
  };

  // ─── the market's clock ────────────────────────────────────────────────────────────────────────────────────────
  public func offsetValid(minutesEast : Int) : Bool { Int.abs(minutesEast) <= T.MAX_OFFSET_MINUTES };

  /// The chain's time (nanoseconds since 1970 UTC) as the market's (day, second of the day).
  public func marketTime(ns : Nat, minutesEast : Int) : (T.Day, Nat) {
    let local : Int = (ns / 1_000_000_000 : Nat) + minutesEast * 60;
    let s = Int.abs(local);   // a market's local time is after 1970 for every offset of at most fourteen hours
    (s / T.DAY_SECONDS, s % T.DAY_SECONDS)
  };
}
