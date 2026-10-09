/// ExchangeCanonical.mo: the bytes of the exchange foundation's commands and of its log's events. Version 1 is frozen
/// from the first deployment: a family's tag is its position in `ExchangeTypes.Command`, and a closed vocabulary's
/// byte is listed here and never renumbered; a byte the build does not know decodes to nothing (a decode fault), never
/// to a default.
///
/// Attribution: Thebes Core Team.

import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Cmd "mo:kernel/domain/Command";

import T "ExchangeTypes";

module {

  // ─── closed vocabularies ───────────────────────────────────────────────────────────────────────────────────────
  public func memberStatusCode(s : T.MemberStatus) : Nat8 { switch (s) { case (#active) 1; case (#suspended) 2; case (#expelled) 3 } };
  public func memberStatusOf(c : Nat8) : ?T.MemberStatus { switch (c) { case 1 ?#active; case 2 ?#suspended; case 3 ?#expelled; case _ null } };
  public func traderStatusCode(s : T.TraderStatus) : Nat8 { switch (s) { case (#active) 1; case (#revoked) 2 } };
  public func traderStatusOf(c : Nat8) : ?T.TraderStatus { switch (c) { case 1 ?#active; case 2 ?#revoked; case _ null } };
  public func accountKindCode(k : T.AccountKind) : Nat8 { switch (k) { case (#house) 1; case (#client) 2 } };
  public func accountKindOf(c : Nat8) : ?T.AccountKind { switch (c) { case 1 ?#house; case 2 ?#client; case _ null } };
  public func accountStatusCode(s : T.AccountStatus) : Nat8 { switch (s) { case (#open) 1; case (#closed) 2 } };
  public func accountStatusOf(c : Nat8) : ?T.AccountStatus { switch (c) { case 1 ?#open; case 2 ?#closed; case _ null } };
  public func phaseCode(p : T.Phase) : Nat8 {
    switch (p) { case (#closed) 1; case (#preOpen) 2; case (#openingAuction) 3; case (#continuous) 4; case (#closingAuction) 5; case (#tradeAtClose) 6; case (#halted) 7 }
  };
  public func phaseOf(c : Nat8) : ?T.Phase {
    switch (c) { case 1 ?#closed; case 2 ?#preOpen; case 3 ?#openingAuction; case 4 ?#continuous; case 5 ?#closingAuction; case 6 ?#tradeAtClose; case 7 ?#halted; case _ null }
  };
  public func instrumentStatusCode(s : T.InstrumentStatus) : Nat8 { switch (s) { case (#listed) 1; case (#suspended) 2; case (#delisted) 3 } };
  public func instrumentStatusOf(c : Nat8) : ?T.InstrumentStatus { switch (c) { case 1 ?#listed; case 2 ?#suspended; case 3 ?#delisted; case _ null } };

  // ─── composite fields ──────────────────────────────────────────────────────────────────────────────────────────
  func writeWindows(w : C.Writer, ws : [T.Window]) { w.len16(ws.size()); for (x in ws.vals()) { w.byte(phaseCode(x.phase)); w.nat(x.startSec); w.nat(x.endSec) } };
  func readWindows(r : C.Reader) : ?[T.Window] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Window>();
    var i = 0;
    while (i < n) { let ?pc = r.byte() else return null; let ?phase = phaseOf(pc) else return null; let ?startSec = r.nat() else return null; let ?endSec = r.nat() else return null; List.add(out, { phase; startSec; endSec }); i += 1 };
    ?List.toArray(out)
  };
  func writeBands(w : C.Writer, bs : [T.Band]) { w.len16(bs.size()); for (b in bs.vals()) { w.nat(b.fromPrice); w.nat(b.tick) } };
  func readBands(r : C.Reader) : ?[T.Band] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Band>();
    var i = 0;
    while (i < n) { let ?fromPrice = r.nat() else return null; let ?tick = r.nat() else return null; List.add(out, { fromPrice; tick }); i += 1 };
    ?List.toArray(out)
  };
  /// A signed number: one sign byte (0 for zero or above, 1 below zero), then the magnitude.
  public func writeInt(w : C.Writer, x : Int) { w.byte(if (x < 0) 1 else 0); w.nat(Int.abs(x)) };
  public func readInt(r : C.Reader) : ?Int {
    let ?sign = r.byte() else return null;
    let ?m = r.nat() else return null;
    switch (sign) { case 0 ?(m : Int); case 1 { if (m == 0) null else ?(-(m : Int)) }; case _ null }
  };

  // ─── the commands, version 1 ───────────────────────────────────────────────────────────────────────────────────
  func writeV1(w : C.Writer, c : T.Command) : Bool {
    switch (c) {
      case (#admitMember(x)) { w.byte(1); w.text(x.code); w.text(x.name); w.bool(x.marketMaker); w.bool(x.clearing); w.nat(x.day) };
      case (#setMemberStatus(x)) { w.byte(2); w.nat(x.member); w.byte(memberStatusCode(x.status)); w.text(x.reason) };
      case (#registerTrader(x)) { w.byte(3); w.nat(x.member); w.principal(x.principal) };
      case (#revokeTrader(x)) { w.byte(4); w.nat(x.trader); w.text(x.reason) };
      case (#grantTradingRight(x)) { w.byte(5); w.nat(x.trader); w.nat(x.segment) };
      case (#withdrawTradingRight(x)) { w.byte(6); w.nat(x.trader); w.nat(x.segment) };
      case (#openAccount(x)) { w.byte(7); w.nat(x.member); w.byte(accountKindCode(x.kind)); w.blob(x.client) };
      case (#closeAccount(x)) { w.byte(8); w.nat(x.account); w.text(x.reason) };
      case (#defineSegment(x)) { w.byte(9); w.text(x.code); w.text(x.name); writeWindows(w, x.windows) };
      case (#setSchedule(x)) { w.byte(10); w.nat(x.segment); writeWindows(w, x.windows) };
      case (#setRestDays(x)) { w.byte(11); w.nats(x.days) };
      case (#declareHoliday(x)) { w.byte(12); w.nat(x.day); w.text(x.reason) };
      case (#defineTickTable(x)) { w.byte(13); writeBands(w, x.bands) };
      case (#listInstrument(x)) {
        w.byte(14); w.text(x.isin); w.text(x.name); w.nat(x.segment); w.text(x.currency); w.principal(x.assetLedger); w.principal(x.cashLedger);
        w.nat(x.tickTable); w.nat(x.lot); w.nat(x.referencePrice); w.nat(x.day)
      };
      case (#setInstrumentStatus(x)) { w.byte(15); w.nat(x.instrument); w.byte(instrumentStatusCode(x.status)); w.text(x.reason) };
      case (#setLot(x)) { w.byte(16); w.nat(x.instrument); w.nat(x.lot) };
      case (#setReferencePrice(x)) { w.byte(17); w.nat(x.instrument); w.nat(x.price); w.nat(x.day) };
      case (#advancePhase(x)) { w.byte(18); w.nat(x.segment); w.nat(x.day); w.nat(x.sec) };
      case (#setUtcOffset(x)) { w.byte(19); writeInt(w, x.minutesEast) };
    };
    true
  };
  func readV1(r : C.Reader) : ?T.Command {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?code = r.text() else return null; let ?name = r.text() else return null; let ?marketMaker = r.bool() else return null; let ?clearing = r.bool() else return null; let ?day = r.nat() else return null; ?#admitMember({ code; name; marketMaker; clearing; day }) };
      case 2 { let ?member = r.nat() else return null; let ?sc = r.byte() else return null; let ?status = memberStatusOf(sc) else return null; let ?reason = r.text() else return null; ?#setMemberStatus({ member; status; reason }) };
      case 3 { let ?member = r.nat() else return null; let ?principal = r.principal() else return null; ?#registerTrader({ member; principal }) };
      case 4 { let ?trader = r.nat() else return null; let ?reason = r.text() else return null; ?#revokeTrader({ trader; reason }) };
      case 5 { let ?trader = r.nat() else return null; let ?segment = r.nat() else return null; ?#grantTradingRight({ trader; segment }) };
      case 6 { let ?trader = r.nat() else return null; let ?segment = r.nat() else return null; ?#withdrawTradingRight({ trader; segment }) };
      case 7 { let ?member = r.nat() else return null; let ?kc = r.byte() else return null; let ?kind = accountKindOf(kc) else return null; let ?client = r.blob() else return null; ?#openAccount({ member; kind; client }) };
      case 8 { let ?account = r.nat() else return null; let ?reason = r.text() else return null; ?#closeAccount({ account; reason }) };
      case 9 { let ?code = r.text() else return null; let ?name = r.text() else return null; let ?windows = readWindows(r) else return null; ?#defineSegment({ code; name; windows }) };
      case 10 { let ?segment = r.nat() else return null; let ?windows = readWindows(r) else return null; ?#setSchedule({ segment; windows }) };
      case 11 { let ?days = r.nats() else return null; ?#setRestDays({ days }) };
      case 12 { let ?day = r.nat() else return null; let ?reason = r.text() else return null; ?#declareHoliday({ day; reason }) };
      case 13 { let ?bands = readBands(r) else return null; ?#defineTickTable({ bands }) };
      case 14 {
        let ?isin = r.text() else return null; let ?name = r.text() else return null; let ?segment = r.nat() else return null; let ?currency = r.text() else return null;
        let ?assetLedger = r.principal() else return null; let ?cashLedger = r.principal() else return null; let ?tickTable = r.nat() else return null;
        let ?lot = r.nat() else return null; let ?referencePrice = r.nat() else return null; let ?day = r.nat() else return null;
        ?#listInstrument({ isin; name; segment; currency; assetLedger; cashLedger; tickTable; lot; referencePrice; day })
      };
      case 15 { let ?instrument = r.nat() else return null; let ?sc = r.byte() else return null; let ?status = instrumentStatusOf(sc) else return null; let ?reason = r.text() else return null; ?#setInstrumentStatus({ instrument; status; reason }) };
      case 16 { let ?instrument = r.nat() else return null; let ?lot = r.nat() else return null; ?#setLot({ instrument; lot }) };
      case 17 { let ?instrument = r.nat() else return null; let ?price = r.nat() else return null; let ?day = r.nat() else return null; ?#setReferencePrice({ instrument; price; day }) };
      case 18 { let ?segment = r.nat() else return null; let ?day = r.nat() else return null; let ?sec = r.nat() else return null; ?#advancePhase({ segment; day; sec }) };
      case 19 { let ?minutesEast = readInt(r) else return null; ?#setUtcOffset({ minutesEast }) };
      case _ null;
    }
  };

  public let registry : E.Registry<T.Command> = { domainPrefix = "tachyon-exchange-command"; current = 1; encoders = [{ version = 1; write = writeV1; read = readV1 }] };

  /// The family list, in tag order. Append only.
  public let families : [Text] = [
    "admitMember", "setMemberStatus", "registerTrader", "revokeTrader", "grantTradingRight", "withdrawTradingRight", "openAccount", "closeAccount",
    "defineSegment", "setSchedule", "setRestDays", "declareHoliday", "defineTickTable", "listInstrument", "setInstrumentStatus", "setLot",
    "setReferencePrice", "advancePhase", "setUtcOffset",
  ];
  public func familyOf(c : T.Command) : Text {
    switch (c) {
      case (#admitMember(_)) "admitMember"; case (#setMemberStatus(_)) "setMemberStatus"; case (#registerTrader(_)) "registerTrader"; case (#revokeTrader(_)) "revokeTrader";
      case (#grantTradingRight(_)) "grantTradingRight"; case (#withdrawTradingRight(_)) "withdrawTradingRight"; case (#openAccount(_)) "openAccount"; case (#closeAccount(_)) "closeAccount";
      case (#defineSegment(_)) "defineSegment"; case (#setSchedule(_)) "setSchedule"; case (#setRestDays(_)) "setRestDays"; case (#declareHoliday(_)) "declareHoliday";
      case (#defineTickTable(_)) "defineTickTable"; case (#listInstrument(_)) "listInstrument"; case (#setInstrumentStatus(_)) "setInstrumentStatus"; case (#setLot(_)) "setLot";
      case (#setReferencePrice(_)) "setReferencePrice"; case (#advancePhase(_)) "advancePhase"; case (#setUtcOffset(_)) "setUtcOffset";
    }
  };

  // ─── the log's events ──────────────────────────────────────────────────────────────────────────────────────────
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
  public let codec : DL.Codec<Event> = { version = 1; supports = func(v : Nat8) : Bool { v == 1 }; domain = "tachyon-exchange-log"; write = writeEvent; read = readEvent };
}
