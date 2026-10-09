/// Traced.mo: test support. The exchange foundation's `submit` and `approve`, with the same parameters, each call
/// written to the battery's transcript (custody/test/support/Transcript.mo) as the chain judge makes it again.
///
/// Attribution: Thebes Core Team.

import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";

import E "mo:kernel/domain/Encoding";

import T "../../src/ExchangeTypes";
import X "../../src/ExchangeCore";
import K "../../src/ExchangeCanonical";
import TR "../../../custody/test/support/Transcript";

module {
  func bytesOr(b : ?Blob) : Blob { switch (b) { case (?x) x; case null "" } };

  public func xOut(r : X.Result<X.Outcome>) : Text {
    switch (r) { case (#ok(#executed(x))) "x=" # TR.csv(x.effects); case (#ok(#proposed(p))) "p=" # Nat.toText(p.proposal); case (_) "e=" # TR.errName(debug_show(r)) }
  };
  public func xsub(s : X.State, auth : X.Authority, now : Nat64, caller : Principal, c : T.Command, partition : ?Text, justification : Text) : X.Result<X.Outcome> {
    let r = X.submit(s, auth, now, caller, c, partition, justification);
    TR.submitted("exchange", K.registry.current, bytesOr(E.bytesAt(K.registry, K.registry.current, c)), caller, now, justification, xOut(r));
    r
  };
  public func xapp(s : X.State, auth : X.Authority, now : Nat64, checker : Principal, id : Nat) : X.Result<X.Outcome> {
    let r = X.approve(s, auth, now, checker, id);
    TR.approved("exchange", id, checker, now, xOut(r));
    r
  };
}
