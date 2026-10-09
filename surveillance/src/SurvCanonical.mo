/// SurvCanonical.mo: the bytes of the desk's commands and of its log's events. Version 1; a family's tag is its position
/// in `SurvTypes.Command`, from 1; a byte the build does not know decodes to nothing.
///
/// Attribution: Thebes Core Team.

import Blob "mo:core/Blob";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Cmd "mo:kernel/domain/Command";

import T "SurvTypes";

module {
  public let families : [Text] = ["scan", "setParams", "openCase", "noteCase", "closeCase", "reportCase", "sealReport"];
  public func familyOf(c : T.Command) : Text {
    switch (c) {
      case (#scan(_)) "scan"; case (#setParams(_)) "setParams"; case (#openCase(_)) "openCase"; case (#noteCase(_)) "noteCase";
      case (#closeCase(_)) "closeCase"; case (#reportCase(_)) "reportCase"; case (#sealReport(_)) "sealReport";
    }
  };
  func writeParams(w : C.Writer, p : T.Params) {
    for (v in [p.paintCount, p.paintSecs, p.stuffCount, p.stuffSecs, p.spoofQty, p.spoofSecs, p.markShare, p.markBps, p.positionLevel].vals()) w.nat(v);
  };
  func writeV1(w : C.Writer, c : T.Command) : Bool {
    switch (c) {
      case (#scan(x)) { w.byte(1); w.nat(x.limit) };
      case (#setParams(x)) { w.byte(2); writeParams(w, x) };
      case (#openCase(x)) { w.byte(3); w.nat(x.alert) };
      case (#noteCase(x)) { w.byte(4); w.nat(x.caseId); w.text(x.note) };
      case (#closeCase(x)) { w.byte(5); w.nat(x.caseId); w.text(x.reason) };
      case (#reportCase(x)) { w.byte(6); w.nat(x.caseId); w.text(x.summary) };
      case (#sealReport(x)) { w.byte(7); w.nat(x.day) };
    };
    true
  };
  func readV1(r : C.Reader) : ?T.Command {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?limit = r.nat() else return null; ?#scan({ limit }) };
      case 2 {
        let ?paintCount = r.nat() else return null; let ?paintSecs = r.nat() else return null; let ?stuffCount = r.nat() else return null;
        let ?stuffSecs = r.nat() else return null; let ?spoofQty = r.nat() else return null; let ?spoofSecs = r.nat() else return null;
        let ?markShare = r.nat() else return null; let ?markBps = r.nat() else return null; let ?positionLevel = r.nat() else return null;
        ?#setParams({ paintCount; paintSecs; stuffCount; stuffSecs; spoofQty; spoofSecs; markShare; markBps; positionLevel })
      };
      case 3 { let ?alert = r.nat() else return null; ?#openCase({ alert }) };
      case 4 { let ?caseId = r.nat() else return null; let ?note = r.text() else return null; ?#noteCase({ caseId; note }) };
      case 5 { let ?caseId = r.nat() else return null; let ?reason = r.text() else return null; ?#closeCase({ caseId; reason }) };
      case 6 { let ?caseId = r.nat() else return null; let ?summary = r.text() else return null; ?#reportCase({ caseId; summary }) };
      case 7 { let ?day = r.nat() else return null; ?#sealReport({ day }) };
      case _ null;
    }
  };

  public let registry : E.Registry<T.Command> = { domainPrefix = "tachyon-surveillance-command"; current = 1; encoders = [{ version = 1; write = writeV1; read = readV1 }] };

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
      case 1 { let ?x = Cmd.readProposed(r) else return null; ?#proposed(x) };
      case 2 { let ?x = Cmd.readApproved(r) else return null; ?#approved(x) };
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
  public let codec : DL.Codec<Event> = { version = 1; supports = func(v : Nat8) : Bool { v == 1 }; domain = "tachyon-surveillance-log"; write = writeEvent; read = readEvent };
}
