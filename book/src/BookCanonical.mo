/// BookCanonical.mo: the bytes of the book's commands and of its log's events. Version 1 is frozen from the first
/// deployment: a family's tag is its position in `BookTypes.Command`; every closed vocabulary's byte is listed here and
/// never renumbered; a byte the build does not know decodes to nothing.
///
/// Attribution: Thebes Core Team.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Cmd "mo:kernel/domain/Command";

import T "BookTypes";

module {

  public func sideCode(s : T.Side) : Nat8 { switch (s) { case (#buy) 1; case (#sell) 2 } };
  public func sideOf(c : Nat8) : ?T.Side { switch (c) { case 1 ?#buy; case 2 ?#sell; case _ null } };
  public func kindCode(k : T.Kind) : Nat8 { switch (k) { case (#limit) 1; case (#market) 2; case (#ioc) 3; case (#fok) 4; case (#stop) 5; case (#stopLimit) 6; case (#trailingStop) 7 } };
  public func kindOf(c : Nat8) : ?T.Kind { switch (c) { case 1 ?#limit; case 2 ?#market; case 3 ?#ioc; case 4 ?#fok; case 5 ?#stop; case 6 ?#stopLimit; case 7 ?#trailingStop; case _ null } };
  public func validityCode(v : T.Validity) : Nat8 { switch (v) { case (#day) 1; case (#gtc) 2; case (#gtd) 3 } };
  public func validityOf(c : Nat8) : ?T.Validity { switch (c) { case 1 ?#day; case 2 ?#gtc; case 3 ?#gtd; case _ null } };
  public func selfTradeCode(x : T.SelfTrade) : Nat8 { switch (x) { case (#cancelIncoming) 1; case (#cancelResting) 2; case (#cancelBoth) 3 } };
  public func selfTradeOf(c : Nat8) : ?T.SelfTrade { switch (c) { case 1 ?#cancelIncoming; case 2 ?#cancelResting; case 3 ?#cancelBoth; case _ null } };
  public func capacityCode(x : T.Capacity) : Nat8 { switch (x) { case (#agency) 1; case (#principal) 2 } };
  public func capacityOf(c : Nat8) : ?T.Capacity { switch (c) { case 1 ?#agency; case 2 ?#principal; case _ null } };
  public func statusCode(s : T.Status) : Nat8 { switch (s) { case (#waiting) 1; case (#live) 2; case (#filled) 3; case (#cancelled) 4 } };
  public func statusOf(c : Nat8) : ?T.Status { switch (c) { case 1 ?#waiting; case 2 ?#live; case 3 ?#filled; case 4 ?#cancelled; case _ null } };

  func writeBands(w : C.Writer, bs : [T.Band]) { w.len16(bs.size()); for (b in bs.vals()) { w.nat(b.fromPrice); w.nat(b.tick) } };
  func readBands(r : C.Reader) : ?[T.Band] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Band>();
    var i = 0;
    while (i < n) { let ?fromPrice = r.nat() else return null; let ?tick = r.nat() else return null; List.add(out, { fromPrice; tick }); i += 1 };
    ?List.toArray(out)
  };

  func writeV1(w : C.Writer, c : T.Command) : Bool {
    switch (c) {
      case (#openInstrument(x)) { w.byte(1); w.nat(x.instrument); w.principal(x.assetLedger); w.principal(x.cashLedger); w.nat(x.lot); w.nat(x.referencePrice); writeBands(w, x.bands); w.nat(x.collarBps) };
      case (#setTrading(x)) { w.byte(2); w.nat(x.instrument); w.bool(x.open) };
      case (#setReference(x)) { w.byte(3); w.nat(x.instrument); w.nat(x.price) };
      case (#deposit(x)) { w.byte(4); w.nat(x.account); w.principal(x.ledger); w.nat(x.amount); w.blob(x.reference) };
      case (#withdraw(x)) { w.byte(5); w.nat(x.account); w.principal(x.ledger); w.nat(x.amount) };
      case (#placeOrder(x)) {
        w.byte(6); w.nat(x.account); w.nat(x.instrument); w.byte(sideCode(x.side)); w.byte(kindCode(x.kind)); w.nat(x.qty); w.nat(x.price); w.nat(x.stopPrice); w.nat(x.peak);
        w.byte(validityCode(x.validity)); w.nat(x.gtdDay); w.byte(selfTradeCode(x.selfTrade)); w.byte(capacityCode(x.capacity)); w.bool(x.shortSale); w.text(x.clientRef); w.nat(x.oco); w.nat(x.trail)
      };
      case (#cancelOrder(x)) { w.byte(7); w.nat(x.order) };
      case (#amendOrder(x)) { w.byte(8); w.nat(x.order); w.nat(x.qty); w.nat(x.price) };
      case (#massCancel(x)) { w.byte(9); w.nat(x.account); w.nat(x.limit) };
      case (#flush) { w.byte(10) };
      case (#endOfDay(x)) { w.byte(11); w.nat(x.limit) };
      case (#expireGtd(x)) { w.byte(12); w.nat(x.day); w.nat(x.limit) };
      case (#clear(x)) { w.byte(13); w.nat64(x.time) };
    };
    true
  };
  func readV1(r : C.Reader) : ?T.Command {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 {
        let ?instrument = r.nat() else return null; let ?assetLedger = r.principal() else return null; let ?cashLedger = r.principal() else return null;
        let ?lot = r.nat() else return null; let ?referencePrice = r.nat() else return null; let ?bands = readBands(r) else return null; let ?collarBps = r.nat() else return null;
        ?#openInstrument({ instrument; assetLedger; cashLedger; lot; referencePrice; bands; collarBps })
      };
      case 2 { let ?instrument = r.nat() else return null; let ?open = r.bool() else return null; ?#setTrading({ instrument; open }) };
      case 3 { let ?instrument = r.nat() else return null; let ?price = r.nat() else return null; ?#setReference({ instrument; price }) };
      case 4 { let ?account = r.nat() else return null; let ?ledger = r.principal() else return null; let ?amount = r.nat() else return null; let ?reference = r.blob() else return null; ?#deposit({ account; ledger; amount; reference }) };
      case 5 { let ?account = r.nat() else return null; let ?ledger = r.principal() else return null; let ?amount = r.nat() else return null; ?#withdraw({ account; ledger; amount }) };
      case 6 {
        let ?account = r.nat() else return null; let ?instrument = r.nat() else return null; let ?sc = r.byte() else return null; let ?side = sideOf(sc) else return null;
        let ?kc = r.byte() else return null; let ?kind = kindOf(kc) else return null; let ?qty = r.nat() else return null; let ?price = r.nat() else return null;
        let ?stopPrice = r.nat() else return null; let ?peak = r.nat() else return null; let ?vc = r.byte() else return null; let ?validity = validityOf(vc) else return null;
        let ?gtdDay = r.nat() else return null; let ?tc = r.byte() else return null; let ?selfTrade = selfTradeOf(tc) else return null;
        let ?cc = r.byte() else return null; let ?capacity = capacityOf(cc) else return null; let ?shortSale = r.bool() else return null;
        let ?clientRef = r.text() else return null; let ?oco = r.nat() else return null; let ?trail = r.nat() else return null;
        ?#placeOrder({ account; instrument; side; kind; qty; price; stopPrice; peak; validity; gtdDay; selfTrade; capacity; shortSale; clientRef; oco; trail })
      };
      case 7 { let ?order = r.nat() else return null; ?#cancelOrder({ order }) };
      case 8 { let ?order = r.nat() else return null; let ?qty = r.nat() else return null; let ?price = r.nat() else return null; ?#amendOrder({ order; qty; price }) };
      case 9 { let ?account = r.nat() else return null; let ?limit = r.nat() else return null; ?#massCancel({ account; limit }) };
      case 10 ?#flush;
      case 11 { let ?limit = r.nat() else return null; ?#endOfDay({ limit }) };
      case 12 { let ?day = r.nat() else return null; let ?limit = r.nat() else return null; ?#expireGtd({ day; limit }) };
      case 13 { let ?time = r.nat64() else return null; ?#clear({ time }) };
      case _ null;
    }
  };

  public let registry : E.Registry<T.Command> = { domainPrefix = "tachyon-book-command"; current = 1; encoders = [{ version = 1; write = writeV1; read = readV1 }] };

  public let families : [Text] = ["openInstrument", "setTrading", "setReference", "deposit", "withdraw", "placeOrder", "cancelOrder", "amendOrder", "massCancel", "flush", "endOfDay", "expireGtd", "clear"];
  public func familyOf(c : T.Command) : Text {
    switch (c) {
      case (#openInstrument(_)) "openInstrument"; case (#setTrading(_)) "setTrading"; case (#setReference(_)) "setReference"; case (#deposit(_)) "deposit";
      case (#withdraw(_)) "withdraw"; case (#placeOrder(_)) "placeOrder"; case (#cancelOrder(_)) "cancelOrder"; case (#amendOrder(_)) "amendOrder";
      case (#massCancel(_)) "massCancel"; case (#flush) "flush"; case (#endOfDay(_)) "endOfDay"; case (#expireGtd(_)) "expireGtd"; case (#clear(_)) "clear";
    }
  };

  /// The order's key (§3.2): SHA-256 under the book's domain of its account, side, price, quantity and client reference.
  public func orderKey(account : Nat, side : T.Side, price : Nat, qty : Nat, clientRef : Text) : Blob {
    let w = C.Writer(); w.nat(account); w.byte(sideCode(side)); w.nat(price); w.nat(qty); w.text(clientRef);
    C.hashWithDomainBlob("tachyon.book.order-key.v1", w.toBlob())
  };

  public type Event = {
    #proposed : Cmd.Proposed;
    #approved : Cmd.Approved;
    #rejected : Cmd.Rejected;
    #expired : Cmd.Expired;
    #executed : { proposal : ?Cmd.ProposalId; version : Nat8; command : T.Command; effects : T.Effects };
  };
  func writeEvent(w : C.Writer, e : Event) {
    switch (e) {
      case (#proposed(p)) { w.byte(1); Cmd.writeProposed(w, p) };
      case (#approved(a)) { w.byte(2); Cmd.writeApproved(w, a) };
      case (#rejected(x)) { w.byte(3); Cmd.writeRejected(w, x) };
      case (#expired(x)) { w.byte(4); Cmd.writeExpired(w, x) };
      case (#executed(x)) { w.byte(5); w.optNat(x.proposal); w.byte(x.version); switch (E.bytesAt(registry, x.version, x.command)) { case (?b) w.blob(b); case null w.blob("") }; w.nats(x.effects) };
    }
  };
  func readEvent(r : C.Reader) : ?Event {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?p = Cmd.readProposed(r) else return null; ?#proposed(p) };
      case 2 { let ?a = Cmd.readApproved(r) else return null; ?#approved(a) };
      case 3 { let ?x = Cmd.readRejected(r) else return null; ?#rejected(x) };
      case 4 { let ?x = Cmd.readExpired(r) else return null; ?#expired(x) };
      case 5 {
        let ?proposal = r.optNat() else return null; let ?version = r.byte() else return null; let ?bytes = r.blob() else return null;
        let ?command = E.readAt(registry, version, C.Reader(Blob.toArray(bytes))) else return null; let ?effects = r.nats() else return null;
        ?#executed({ proposal; version; command; effects })
      };
      case _ null;
    }
  };
  public let codec : DL.Codec<Event> = { version = 1; supports = func(v : Nat8) : Bool { v == 1 }; domain = "tachyon-book-log"; write = writeEvent; read = readEvent };
}
