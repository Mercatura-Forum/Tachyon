/// BookFeed.mo: the public feed (SPEC §13): one message for every block of the book's log, written from the block
/// alone, naming no account, member, trader, client reference or caller; and the feed's hash chain.
///
/// Attribution: Thebes Core Team.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Sha256 "mo:sha2/Sha256";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";

import T "BookTypes";
import K "BookCanonical";

module {
  public let VERSION : Nat8 = 1;
  public let DOMAIN = "thebes.book.feed.v1";
  /// The feed hash before block 0: 32 zero bytes.
  public func genesis() : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })) };

  /// A list of nats written as the feed writes counts: its length (two bytes) then each.
  func list(w : C.Writer, xs : [Nat]) { w.nats(xs) };
  func slice(e : [Nat], from : Nat, n : Nat) : [Nat] { Array.tabulate<Nat>(n, func(i) { e[from + i] }) };

  /// The message of block `b` (SPEC §13).
  public func message(b : DL.Block<K.Event>) : Blob {
    let w = C.Writer();
    w.byte(VERSION); w.nat(b.index); w.nat64(b.timestamp);
    switch (b.event) {
      case (#executed(x)) body(w, x.command, x.effects);
      case (_) w.byte(0);
    };
    w.toBlob()
  };

  func body(w : C.Writer, c : T.Command, e : [Nat]) {
    switch (c) {
      case (#openInstrument(x)) {
        w.byte(1); w.nat(x.instrument); w.nat(x.lot); w.nat(x.referencePrice);
        w.len16(x.bands.size()); for (band in x.bands.vals()) { w.nat(band.fromPrice); w.nat(band.tick) };
        w.nat(x.collarBps); w.nat(x.staticBps); w.nat(x.dynamicBps); w.nat(x.interruptSecs);
      };
      case (#setTrading(x)) { w.byte(2); w.nat(x.instrument); w.bool(x.open) };
      case (#setReference(x)) { w.byte(3); w.nat(x.instrument); w.nat(x.price) };
      // effects: [6, order, status, price, shown, cancelled own orders...]
      case (#placeOrder(x)) {
        let own = slice(e, 5, e.size() - 5);
        if (e[2] == Nat8.toNat(K.statusCode(#live))) {
          w.byte(4); w.nat(e[1]); w.nat(x.instrument); w.byte(if (x.side == #buy) 1 else 2); w.nat(e[3]); w.nat(e[4]); list(w, own);
        } else if (own.size() > 0) { w.byte(5); list(w, own) }   // cancelled with the resting: only the resting were shown
        else w.byte(0);                                          // a stop waits hidden
      };
      case (#cancelOrder(x)) { w.byte(5); list(w, [x.order]) };
      // effects: [8, order, priority kept, shown]; shown 0: a waiting stop, hidden
      case (#amendOrder(x)) {
        if (e[3] == 0) w.byte(0) else { w.byte(6); w.nat(x.order); w.nat(x.price); w.nat(e[3]); w.bool(e[2] == 1) };
      };
      // a replacement is an amendment to the feed (its new reference is the member's, never public)
      case (#replaceOrder(x)) {
        if (e[3] == 0) w.byte(0) else { w.byte(6); w.nat(x.order); w.nat(x.price); w.nat(e[3]); w.bool(e[2] == 1) };
      };
      // effects: [tag, count, orders...]
      case (#massCancel(_)) { w.byte(5); list(w, slice(e, 2, e[1])) };
      case (#endOfDay(_)) { w.byte(5); list(w, slice(e, 2, e[1])) };
      case (#expireGtd(_)) { w.byte(5); list(w, slice(e, 2, e[1])) };
      // effects: [19, kill, count, orders...]
      case (#killSweep(_)) { w.byte(5); list(w, slice(e, 3, e[2])) };
      case (#clear(_)) { w.byte(7); clearBody(w, e) };
      case (#setPhase(x)) { w.byte(8); w.nat(x.instrument); w.byte(K.phaseCode(x.phase)); w.nat64(x.endFrom); w.nat64(x.endTo); w.text("") };
      case (#halt(x)) { w.byte(8); w.nat(x.instrument); w.byte(K.phaseCode(#halted)); w.nat64(0); w.nat64(0); w.text(x.reason) };
      case (#resume(x)) { w.byte(8); w.nat(x.instrument); w.byte(K.phaseCode(#auction)); w.nat64(0); w.nat64(0); w.text("") };
      // effects: [15, instrument, price, volume, pairs, (b, s, q)..., cancelled, orders..., shown, (o, n)..., phase after]
      case (#uncross(x)) {
        w.byte(9); w.nat(x.instrument);
        let next = instrumentBody(w, e, 2, false);
        w.byte(Nat8.fromNat(e[next]));
      };
      // effects: [22, day, rows, the file's hash, one byte an effect]
      case (#sealDay(_)) { w.byte(10); w.nat(e[1]); w.nat(e[2]); w.bytes(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(e[3 + i]) })) };
      // effects: [35, order, status, price, shown, member]: the CCP's close-out order, added as any sale is (SPEC §20)
      case (#closeOut(x)) { w.byte(4); w.nat(e[1]); w.nat(x.instrument); w.byte(2); w.nat(e[3]); w.nat(e[4]); list(w, []) };
      // effects: [45 or 46, quotes, per quote: instrument, cancelled, orders..., then each side's order, status, price,
      // shown]: a maker's quotes (SPEC §25), each its cancelled orders and the sides it adds
      case (#quote(_) or #massQuote(_)) {
        w.byte(11);
        let n = e[1]; w.len16(n);
        var p = 2;
        for (_ in Nat.range(0, n)) {
          w.nat(e[p]); let nc = e[p + 1]; list(w, slice(e, p + 2, nc)); p += 2 + nc;
          let adds = Array.filter<Nat>([0, 1], func(k) { e[p + 4 * k + 1] == Nat8.toNat(K.statusCode(#live)) });
          w.len16(adds.size());
          for (k in adds.vals()) { w.nat(e[p + 4 * k]); w.byte(if (k == 0) 1 else 2); w.nat(e[p + 4 * k + 2]); w.nat(e[p + 4 * k + 3]) };
          p += 8;
        };
      };
      // effects: [51, index, level, kind, halted, instruments...]: the market-wide breaker (SPEC §27), every instrument it
      // halted in this block
      case (#tripBreaker(_)) { w.byte(12); w.nat(e[1]); w.nat(e[2]); w.byte(Nat8.fromNat(e[3])); list(w, slice(e, 5, e[4])) };
      // private: funds, kills, limits, insider lists, securities loans, clearing members' terms, margins and obligations,
      // fee schedules, statements, reconciliations, makers' registrations and periods, an instrument's class terms, funds'
      // baskets, receipts, retirements, exercises and value dates (an iNAV and a bond's terms are read through the venue), attestations, and
      // derivatives' settlements (positions are their members'; the settlement prices are read through the venue), and the
      // cash bridge's earmarks and redemptions
      case (#deposit(_) or #withdraw(_) or #flush or #kill(_) or #revive(_) or #setLimits(_) or #setBlackout(_) or #liftBlackout(_) or #borrow(_) or #returnBorrow(_)
        or #setClearing(_) or #setMargin(_) or #admitClearing(_) or #designateClearing(_) or #postCollateral(_) or #withdrawCollateral(_) or #cutCycle(_)
        or #settleCycle(_) or #callFund or #contributeFund(_) or #fundSkin(_) or #declareDefault(_) or #closeDefault(_)
        or #setFeeSchedule(_) or #sealStatements(_) or #reconcileMember(_) or #registerMaker(_) or #settleMakers(_)
        or #defineIndex(_) or #reviewIndex(_) or #corporateAction(_)
        or #setTerms(_) or #defineNav(_) or #issueReceipt(_) or #cancelReceipt(_) or #retire(_) or #exercise(_) or #valueDate(_)
        or #setAttestors(_) or #attestPrice(_) or #settleDerivatives(_)
        or #registerBridge(_) or #earmark(_) or #redeem(_) or #rtgsSettle(_) or #rtgsReject(_)) w.byte(0);
    }
  };

  /// A clear's effects: [13, then per instrument: instrument, price, volume, pairs, (b, s, q)..., cancelled, orders...,
  /// triggered, (o, side, price, shown)..., shown, (o, n)..., interrupted].
  func clearBody(w : C.Writer, e : [Nat]) {
    var k = 1; var n = 0;
    while (k < e.size()) { k := skipInstrument(e, k); n += 1 };
    w.len16(n);
    k := 1;
    while (k < e.size()) {
      w.nat(e[k]);
      let after = instrumentBody(w, e, k + 1, true);
      w.bool(e[after] == 1);
      k := after + 1;
    };
  };
  /// Writes price, volume, pairs, removed, (revealed when `triggers`), shown from effects at `at`; returns the index
  /// after them.
  func instrumentBody(w : C.Writer, e : [Nat], at : Nat, triggers : Bool) : Nat {
    w.nat(e[at]); w.nat(e[at + 1]);
    let np = e[at + 2];
    w.len16(np);
    var p = at + 3;
    for (_ in Nat.range(0, np)) { w.nat(e[p]); w.nat(e[p + 1]); w.nat(e[p + 2]); p += 3 };
    let nc = e[p]; list(w, slice(e, p + 1, nc)); p += 1 + nc;
    if (triggers) {
      let nt = e[p]; w.len16(nt); p += 1;
      for (_ in Nat.range(0, nt)) { w.nat(e[p]); w.byte(Nat8.fromNat(e[p + 1])); w.nat(e[p + 2]); w.nat(e[p + 3]); p += 4 };
    };
    let ns = e[p]; w.len16(ns); p += 1;
    for (_ in Nat.range(0, ns)) { w.nat(e[p]); w.nat(e[p + 1]); p += 2 };
    p
  };
  func skipInstrument(e : [Nat], k : Nat) : Nat {
    let np = e[k + 3];
    var p = k + 4 + 3 * np;
    p += 1 + e[p];          // cancelled
    p += 1 + 4 * e[p];      // triggered
    p += 1 + 2 * e[p];      // shown
    p + 1                   // interrupted
  };

  /// The feed hash of a block: SHA-256 over the domain, the previous block's feed hash and the message (SPEC §13).
  public func chain(previous : Blob, message : Blob) : Blob {
    let w = C.Writer(); w.text(DOMAIN); w.blobRaw(previous); w.blobRaw(message);
    Sha256.fromArray(#sha256, w.toArray())
  };
}
