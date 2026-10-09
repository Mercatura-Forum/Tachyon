/// CustodyCanonical.mo: the bytes of the custody module's commands, of its log's events, of an entitlement file
/// and of a reconciliation. Version 1 is frozen from the first deployment.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Cmd "mo:kernel/domain/Command";

import CT "CustodyTypes";

module {

  public func kindCode(k : CT.Kind) : Nat8 { switch (k) { case (#cashDividend(_)) 1; case (#split(_)) 2; case (#bonus(_)) 3; case (#rights(_)) 4; case (#redemption(_)) 5 } };
  public func writeKind(w : C.Writer, k : CT.Kind) {
    w.byte(kindCode(k));
    switch (k) {
      case (#cashDividend(d)) w.nat(d.perUnitMicro);
      case (#split(s)) { w.nat(s.numerator); w.nat(s.denominator); w.nat(s.cashInLieuMicro) };
      case (#bonus(b)) { w.nat(b.numerator); w.nat(b.denominator); w.nat(b.cashInLieuMicro) };
      case (#rights(r)) { w.nat(r.numerator); w.nat(r.denominator); w.nat(r.subscriptionPriceMicro); w.nat(r.subscriptionDeadline) };
      case (#redemption(r)) { w.nat(r.ratioBps); w.nat(r.pricePerUnitMicro) };
    }
  };
  public func readKind(r : C.Reader) : ?CT.Kind {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?perUnitMicro = r.nat() else return null; ?#cashDividend({ perUnitMicro }) };
      case 2 { let ?numerator = r.nat() else return null; let ?denominator = r.nat() else return null; let ?cashInLieuMicro = r.nat() else return null; ?#split({ numerator; denominator; cashInLieuMicro }) };
      case 3 { let ?numerator = r.nat() else return null; let ?denominator = r.nat() else return null; let ?cashInLieuMicro = r.nat() else return null; ?#bonus({ numerator; denominator; cashInLieuMicro }) };
      case 4 { let ?numerator = r.nat() else return null; let ?denominator = r.nat() else return null; let ?subscriptionPriceMicro = r.nat() else return null; let ?subscriptionDeadline = r.nat() else return null; ?#rights({ numerator; denominator; subscriptionPriceMicro; subscriptionDeadline }) };
      case 5 { let ?ratioBps = r.nat() else return null; let ?pricePerUnitMicro = r.nat() else return null; ?#redemption({ ratioBps; pricePerUnitMicro }) };
      case _ null;
    }
  };
  public func receiptKindCode(k : CT.ReceiptKind) : Nat8 { switch (k) { case (#trade) 1; case (#delivery) 2; case (#issuance) 3; case (#redemption) 4; case (#fillLeg) 5; case (#cycleLeg) 6; case (#transferLeg) 7 } };
  public func receiptKindOf(c : Nat8) : ?CT.ReceiptKind { switch (c) { case 1 ?#trade; case 2 ?#delivery; case 3 ?#issuance; case 4 ?#redemption; case 5 ?#fillLeg; case 6 ?#cycleLeg; case 7 ?#transferLeg; case _ null } };
  public func stateCode(s : CT.ActionState) : Nat8 { switch (s) { case (#announced) 1; case (#struck) 2; case (#paid) 3; case (#cancelled) 4 } };
  public func stateOf(c : Nat8) : ?CT.ActionState { switch (c) { case 1 ?#announced; case 2 ?#struck; case 3 ?#paid; case 4 ?#cancelled; case _ null } };

  func writeV1(w : C.Writer, c : CT.Command) : Bool {
    switch (c) {
      case (#registerHolder(x)) { w.byte(1); w.nat(x.holder); w.blob(x.commit); w.principal(x.account) };
      case (#registerAsset(x)) { w.byte(2); w.text(x.code); w.text(x.name); w.principal(x.ledger); w.principal(x.cashLedger); w.nat(x.issuedSupply); w.nat(x.issuer) };
      case (#recordSettlement(x)) { w.byte(3); w.nat(x.asset); w.byte(receiptKindCode(x.receipt.kind)); w.nat(x.receipt.id); w.nat(x.receipt.block); w.blob(x.receipt.hash); w.nat(x.from); w.nat(x.to); w.nat(x.units); w.nat(x.day) };
      case (#reconcile(x)) { w.byte(4); w.nat(x.asset); w.nat(x.day); w.nat(x.ledgerBlock); w.len16(x.balances.size()); for ((h, u) in x.balances.vals()) { w.nat(h); w.nat(u) } };
      case (#announceAction(x)) { w.byte(5); w.nat(x.asset); writeKind(w, x.kind); w.nat(x.recordDate); w.nat(x.exDate); w.nat(x.paymentDate); w.blob(x.source) };
      case (#cancelAction(x)) { w.byte(6); w.nat(x.action); w.nat(x.day); w.text(x.reason) };
      case (#strikeRecordDate(x)) { w.byte(7); w.nat(x.action); w.nat(x.limit) };
      case (#subscribeRights(x)) { w.byte(8); w.nat(x.action); w.nat(x.holder); w.nat(x.rights); w.nat(x.day) };
      case (#pay(x)) { w.byte(9); w.nat(x.action); w.nat(x.day); w.nat(x.limit) };
      case (#certifyEntitlementFile(x)) { w.byte(10); w.nat(x.action); w.nat(x.day) };
      case (#linkAccount(x)) { w.byte(11); w.nat(x.account); w.nat(x.holder) };
      case (#admitLeg(x)) {
        w.byte(12); w.nat(x.asset); w.nat(x.index); w.nat(x.legs);
        w.nat(x.leg.kind); w.principal(x.leg.ledger); w.nat(x.leg.from); w.nat(x.leg.to); w.nat(x.leg.units); w.nat(x.leg.block);
        w.len16(x.proof.siblings.size()); for (h in x.proof.siblings.vals()) w.blob(h);
        w.nat(x.proof.peakIndex); w.len16(x.proof.peaks.size()); for (h in x.proof.peaks.vals()) w.blob(h);
        w.nat(x.day)
      };
    };
    true
  };
  /// A list of hashes as `admitLeg` writes it: its length (two bytes), then each as a blob.
  func hashes(r : C.Reader) : ?[Blob] {
    let ?n = r.len16() else return null;
    let out = List.empty<Blob>();
    for (_ in Nat.range(0, n)) { let ?h = r.blob() else return null; List.add(out, h) };
    ?List.toArray(out)
  };
  func readV1(r : C.Reader) : ?CT.Command {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?holder = r.nat() else return null; let ?commit = r.blob() else return null; let ?account = r.principal() else return null; ?#registerHolder({ holder; commit; account }) };
      case 2 { let ?code = r.text() else return null; let ?name = r.text() else return null; let ?ledger = r.principal() else return null; let ?cashLedger = r.principal() else return null; let ?issuedSupply = r.nat() else return null; let ?issuer = r.nat() else return null; ?#registerAsset({ code; name; ledger; cashLedger; issuedSupply; issuer }) };
      case 3 {
        let ?asset = r.nat() else return null; let ?kc = r.byte() else return null; let ?kind = receiptKindOf(kc) else return null; let ?id = r.nat() else return null; let ?block = r.nat() else return null; let ?hash = r.blob() else return null;
        let ?from = r.nat() else return null; let ?to = r.nat() else return null; let ?units = r.nat() else return null; let ?day = r.nat() else return null;
        ?#recordSettlement({ asset; receipt = { kind; id; block; hash }; from; to; units; day })
      };
      case 4 {
        let ?asset = r.nat() else return null; let ?day = r.nat() else return null; let ?ledgerBlock = r.nat() else return null; let ?n = r.len16() else return null;
        var i = 0; let out = List.empty<(Nat, Nat)>();
        while (i < n) { let ?h = r.nat() else return null; let ?u = r.nat() else return null; List.add(out, (h, u)); i += 1 };
        ?#reconcile({ asset; day; ledgerBlock; balances = List.toArray(out) })
      };
      case 5 { let ?asset = r.nat() else return null; let ?kind = readKind(r) else return null; let ?recordDate = r.nat() else return null; let ?exDate = r.nat() else return null; let ?paymentDate = r.nat() else return null; let ?source = r.blob() else return null; ?#announceAction({ asset; kind; recordDate; exDate; paymentDate; source }) };
      case 6 { let ?action = r.nat() else return null; let ?day = r.nat() else return null; let ?reason = r.text() else return null; ?#cancelAction({ action; day; reason }) };
      case 7 { let ?action = r.nat() else return null; let ?limit = r.nat() else return null; ?#strikeRecordDate({ action; limit }) };
      case 8 { let ?action = r.nat() else return null; let ?holder = r.nat() else return null; let ?rights = r.nat() else return null; let ?day = r.nat() else return null; ?#subscribeRights({ action; holder; rights; day }) };
      case 9 { let ?action = r.nat() else return null; let ?day = r.nat() else return null; let ?limit = r.nat() else return null; ?#pay({ action; day; limit }) };
      case 10 { let ?action = r.nat() else return null; let ?day = r.nat() else return null; ?#certifyEntitlementFile({ action; day }) };
      case 11 { let ?account = r.nat() else return null; let ?holder = r.nat() else return null; ?#linkAccount({ account; holder }) };
      case 12 {
        let ?asset = r.nat() else return null; let ?index = r.nat() else return null; let ?legs = r.nat() else return null;
        let ?kind = r.nat() else return null; let ?ledger = r.principal() else return null; let ?from = r.nat() else return null; let ?to = r.nat() else return null;
        let ?units = r.nat() else return null; let ?block = r.nat() else return null;
        let ?siblings = hashes(r) else return null; let ?peakIndex = r.nat() else return null; let ?peaks = hashes(r) else return null; let ?day = r.nat() else return null;
        ?#admitLeg({ asset; index; legs; leg = { kind; ledger; from; to; units; block }; proof = { siblings; peakIndex; peaks }; day })
      };
      case _ null;
    }
  };

  public let registry : E.Registry<CT.Command> = { domainPrefix = "tachyon-custody-command"; current = 1; encoders = [{ version = 1; write = writeV1; read = readV1 }] };
  public func familyOf(c : CT.Command) : Text {
    switch (c) { case (#registerHolder(_)) "registerHolder"; case (#registerAsset(_)) "registerAsset"; case (#recordSettlement(_)) "recordSettlement"; case (#reconcile(_)) "reconcile"; case (#announceAction(_)) "announceAction"; case (#cancelAction(_)) "cancelAction"; case (#strikeRecordDate(_)) "strikeRecordDate"; case (#subscribeRights(_)) "subscribeRights"; case (#pay(_)) "pay"; case (#certifyEntitlementFile(_)) "certifyEntitlementFile"; case (#linkAccount(_)) "linkAccount"; case (#admitLeg(_)) "admitLeg" }
  };

  /// The entitlement file's bytes: the action, its asset and kind, the record and payment dates, then every
  /// entitlement in holder order (holder, units at record, cash due, cash payable, units due, units taken, rights,
  /// rights taken, fraction); hashed under `tachyon.custody.entitlements.v1`.
  public type FileLine = { holder : Nat; unitsAtRecord : Nat; cashDue : Nat; cashPayable : Nat; unitsDue : Nat; unitsTaken : Nat; rights : Nat; rightsTaken : Nat; fractionUnits : Nat };
  public func fileBytes(action : Nat, asset : Nat, kind : CT.Kind, recordDate : Nat, paymentDate : Nat, lines : [FileLine]) : Blob {
    let w = C.Writer();
    w.nat(action); w.nat(asset); writeKind(w, kind); w.nat(recordDate); w.nat(paymentDate); w.nat(lines.size());
    for (l in lines.vals()) { w.nat(l.holder); w.nat(l.unitsAtRecord); w.nat(l.cashDue); w.nat(l.cashPayable); w.nat(l.unitsDue); w.nat(l.unitsTaken); w.nat(l.rights); w.nat(l.rightsTaken); w.nat(l.fractionUnits) };
    w.toBlob()
  };
  public func fileHash(bytes : Blob) : Blob { C.hashWithDomainBlob(CT.FILE_DOMAIN, bytes) };
  /// A reconciliation's bytes: the asset, the day, the ledger block, then every holder in order with its position
  /// and the ledger's balance; hashed under `tachyon.custody.reconciliation.v1`.
  public func reconciliationBytes(asset : Nat, day : Nat, ledgerBlock : Nat, rows : [(Nat, Nat, Nat)]) : Blob {
    let w = C.Writer();
    w.nat(asset); w.nat(day); w.nat(ledgerBlock); w.nat(rows.size());
    for ((h, p, b) in rows.vals()) { w.nat(h); w.nat(p); w.nat(b) };
    w.toBlob()
  };
  public func reconciliationHash(bytes : Blob) : Blob { C.hashWithDomainBlob(CT.RECONCILIATION_DOMAIN, bytes) };

  public type Event = {
    #proposed : Cmd.Proposed;
    #approved : Cmd.Approved;
    #rejected : Cmd.Rejected;
    #expired : Cmd.Expired;
    #executed : { proposal : ?Cmd.ProposalId; version : Nat8; command : CT.Command; effects : CT.Effects };
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
  public let codec : DL.Codec<Event> = { version = 1; supports = func(v : Nat8) : Bool { v == 1 }; domain = "tachyon-custody-log"; write = writeEvent; read = readEvent };
}
