/// OfferingCanonical.mo: the bytes of the offering's commands, of its log's events and of the allocation file's
/// chain. Version 1 is frozen from the first deployment: a family's tag is its position, the list append-only.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Cmd "mo:kernel/domain/Command";
import R "mo:kernel/rows/StableRows";
import Sha256 "mo:sha2/Sha256";

import OT "OfferingTypes";

module {

  public func kindCode(k : OT.OrderKind) : Nat8 { switch (k) { case (#cornerstone) 1; case (#bid) 2; case (#retail) 3 } };
  public func kindOf(b : Nat8) : ?OT.OrderKind { switch (b) { case 1 ?#cornerstone; case 2 ?#bid; case 3 ?#retail; case _ null } };
  /// An investor's key within an offering: the first eight bytes of the SHA-256 of its commitment.
  public func investorKey(c : Blob) : Nat { R.getNat(Blob.toArray(Sha256.fromBlob(#sha256, c)), 0, 8) };

  func writeTerms(w : C.Writer, t : OT.Terms) {
    w.text(t.code); w.text(t.name); w.blob(t.issuer); w.blob(t.underwriter); w.nat(t.sharesOffered); w.nat(t.sharesOutstanding);
    w.nat(t.priceLow); w.nat(t.priceHigh); w.nat(t.tick); w.nat(t.lot); w.nat(t.retailBps); w.nat(t.cornerstoneMaxBps); w.nat(t.underwritingBps);
    w.byte(if (t.firmCommitment) 1 else 0); w.nat(t.minSoldBps); w.nat(t.minFloatBps); w.nat(t.minHolders);
    w.nat(t.bookOpen); w.nat(t.bookClose); w.nat(t.retailClose); w.nat(t.listingDay)
  };
  func readTerms(r : C.Reader) : ?OT.Terms {
    let ?code = r.text() else return null; let ?name = r.text() else return null; let ?issuer = r.blob() else return null; let ?underwriter = r.blob() else return null;
    let ?sharesOffered = r.nat() else return null; let ?sharesOutstanding = r.nat() else return null;
    let ?priceLow = r.nat() else return null; let ?priceHigh = r.nat() else return null; let ?tick = r.nat() else return null; let ?lot = r.nat() else return null;
    let ?retailBps = r.nat() else return null; let ?cornerstoneMaxBps = r.nat() else return null; let ?underwritingBps = r.nat() else return null;
    let ?fc = r.byte() else return null; if (fc > 1) return null;
    let ?minSoldBps = r.nat() else return null; let ?minFloatBps = r.nat() else return null; let ?minHolders = r.nat() else return null;
    let ?bookOpen = r.nat() else return null; let ?bookClose = r.nat() else return null; let ?retailClose = r.nat() else return null; let ?listingDay = r.nat() else return null;
    ?{ code; name; issuer; underwriter; sharesOffered; sharesOutstanding; priceLow; priceHigh; tick; lot; retailBps; cornerstoneMaxBps; underwritingBps; firmCommitment = fc == 1; minSoldBps; minFloatBps; minHolders; bookOpen; bookClose; retailClose; listingDay }
  };

  func writeV1(w : C.Writer, c : OT.Command) : Bool {
    switch (c) {
      case (#openOffering(x)) { w.byte(1); writeTerms(w, x.terms); w.nat(x.day) };
      case (#commitCornerstone(x)) { w.byte(2); w.nat(x.offering); w.blob(x.investor); w.nat(x.lots); w.nat(x.day) };
      case (#placeBid(x)) { w.byte(3); w.nat(x.offering); w.blob(x.investor); w.nat(x.price); w.nat(x.lots); w.nat(x.day) };
      case (#withdrawBid(x)) { w.byte(4); w.nat(x.order); w.nat(x.day) };
      case (#subscribeRetail(x)) { w.byte(5); w.nat(x.offering); w.blob(x.investor); w.nat(x.lots); w.nat(x.paid); w.nat(x.day) };
      case (#priceOffering(x)) { w.byte(6); w.nat(x.offering); w.nat(x.price); w.nat(x.day) };
      case (#allocate(x)) { w.byte(7); w.nat(x.offering); w.nat(x.limit) };
      case (#handOff(x)) { w.byte(8); w.nat(x.offering); w.nat(x.day) };
      case (#withdrawOffering(x)) { w.byte(9); w.nat(x.offering); w.text(x.reason); w.nat(x.day) };
    };
    true
  };
  func readV1(r : C.Reader) : ?OT.Command {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?terms = readTerms(r) else return null; let ?day = r.nat() else return null; ?#openOffering({ terms; day }) };
      case 2 { let ?offering = r.nat() else return null; let ?investor = r.blob() else return null; let ?lots = r.nat() else return null; let ?day = r.nat() else return null; ?#commitCornerstone({ offering; investor; lots; day }) };
      case 3 { let ?offering = r.nat() else return null; let ?investor = r.blob() else return null; let ?price = r.nat() else return null; let ?lots = r.nat() else return null; let ?day = r.nat() else return null; ?#placeBid({ offering; investor; price; lots; day }) };
      case 4 { let ?order = r.nat() else return null; let ?day = r.nat() else return null; ?#withdrawBid({ order; day }) };
      case 5 { let ?offering = r.nat() else return null; let ?investor = r.blob() else return null; let ?lots = r.nat() else return null; let ?paid = r.nat() else return null; let ?day = r.nat() else return null; ?#subscribeRetail({ offering; investor; lots; paid; day }) };
      case 6 { let ?offering = r.nat() else return null; let ?price = r.nat() else return null; let ?day = r.nat() else return null; ?#priceOffering({ offering; price; day }) };
      case 7 { let ?offering = r.nat() else return null; let ?limit = r.nat() else return null; ?#allocate({ offering; limit }) };
      case 8 { let ?offering = r.nat() else return null; let ?day = r.nat() else return null; ?#handOff({ offering; day }) };
      case 9 { let ?offering = r.nat() else return null; let ?reason = r.text() else return null; let ?day = r.nat() else return null; ?#withdrawOffering({ offering; reason; day }) };
      case _ null;
    }
  };

  public let registry : E.Registry<OT.Command> = { domainPrefix = "tachyon-offering-command"; current = 1; encoders = [{ version = 1; write = writeV1; read = readV1 }] };
  public func familyOf(c : OT.Command) : Text {
    switch (c) {
      case (#openOffering(_)) "openOffering"; case (#commitCornerstone(_)) "commitCornerstone"; case (#placeBid(_)) "placeBid"; case (#withdrawBid(_)) "withdrawBid";
      case (#subscribeRetail(_)) "subscribeRetail"; case (#priceOffering(_)) "priceOffering"; case (#allocate(_)) "allocate"; case (#handOff(_)) "handOff"; case (#withdrawOffering(_)) "withdrawOffering";
    }
  };

  /// The allocation file as a chain: the head binds the offering, its code and its price; each line binds the one
  /// before it and an order's allocation (the order, its kind, the investor, the lots allocated, the cash due, the
  /// refund); the last binds the underwriter's take-up. Each link is hashed under `tachyon.offering.allocation.v1`.
  public func head(offering : Nat, code : Text, price : Nat) : Blob {
    let w = C.Writer(); w.nat(offering); w.text(code); w.nat(price); C.hashWithDomainBlob(OT.FILE_DOMAIN, w.toBlob())
  };
  public func link(prev : Blob, order : Nat, kind : OT.OrderKind, investor : Blob, lots : Nat, cashDue : Nat, refund : Nat) : Blob {
    let w = C.Writer(); w.blob(prev); w.nat(order); w.byte(kindCode(kind)); w.blob(investor); w.nat(lots); w.nat(cashDue); w.nat(refund); C.hashWithDomainBlob(OT.FILE_DOMAIN, w.toBlob())
  };
  public func tail(prev : Blob, underwriter : Blob, lots : Nat) : Blob {
    let w = C.Writer(); w.blob(prev); w.nat(0); w.blob(underwriter); w.nat(lots); C.hashWithDomainBlob(OT.FILE_DOMAIN, w.toBlob())
  };
  public func zero32() : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })) };

  public type Event = {
    #proposed : Cmd.Proposed;
    #approved : Cmd.Approved;
    #rejected : Cmd.Rejected;
    #expired : Cmd.Expired;
    #executed : { proposal : ?Cmd.ProposalId; version : Nat8; command : OT.Command; effects : OT.Effects };
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
  public let codec : DL.Codec<Event> = { version = 1; supports = func(v : Nat8) : Bool { v == 1 }; domain = "tachyon-offering-log"; write = writeEvent; read = readEvent };
}
