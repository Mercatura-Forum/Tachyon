/// Traced.mo: test support. The offering's and the custody register's `submit` and `approve`, with the same
/// parameters, each call written to the battery's transcript (`Transcript.mo`) as the chain judge replays it.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";

import E "mo:kernel/domain/Encoding";

import OT "../../src/OfferingTypes";
import Of "../../src/OfferingCore";
import OK "../../src/OfferingCanonical";
import CT "../../src/CustodyTypes";
import Cu "../../src/CustodyCore";
import CK "../../src/CustodyCanonical";
import TR "Transcript";

module {
  func bytesOr(b : ?Blob) : Blob { switch (b) { case (?x) x; case null "" } };

  public func oOut(r : Of.Result<Of.Outcome>) : Text {
    switch (r) { case (#ok(#executed(x))) "x=" # TR.csv(x.effects); case (#ok(#proposed(p))) "p=" # Nat.toText(p.proposal); case (_) "e=" # TR.errName(debug_show(r)) }
  };
  public func cOut(r : Cu.Result<Cu.Outcome>) : Text {
    switch (r) { case (#ok(#executed(x))) "x=" # TR.csv(x.effects); case (#ok(#proposed(p))) "p=" # Nat.toText(p.proposal); case (_) "e=" # TR.errName(debug_show(r)) }
  };
  public func osub(s : Of.State, auth : Of.Authority, now : Nat64, caller : Principal, c : OT.Command, partition : ?Text, justification : Text) : Of.Result<Of.Outcome> {
    let r = Of.submit(s, auth, now, caller, c, partition, justification);
    TR.submitted("offering", OK.registry.current, bytesOr(E.bytesAt(OK.registry, OK.registry.current, c)), caller, now, justification, oOut(r));
    r
  };
  public func oapp(s : Of.State, auth : Of.Authority, now : Nat64, checker : Principal, id : Nat) : Of.Result<Of.Outcome> {
    let r = Of.approve(s, auth, now, checker, id);
    TR.approved("offering", id, checker, now, oOut(r));
    r
  };
  public func csub(s : Cu.State, auth : Cu.Authority, now : Nat64, caller : Principal, c : CT.Command, partition : ?Text, justification : Text) : Cu.Result<Cu.Outcome> {
    let r = Cu.submit(s, auth, now, caller, c, partition, justification);
    TR.submitted("custody", CK.registry.current, bytesOr(E.bytesAt(CK.registry, CK.registry.current, c)), caller, now, justification, cOut(r));
    r
  };
  public func capp(s : Cu.State, auth : Cu.Authority, now : Nat64, checker : Principal, id : Nat) : Cu.Result<Cu.Outcome> {
    let r = Cu.approve(s, auth, now, checker, id);
    TR.approved("custody", id, checker, now, cOut(r));
    r
  };
}
