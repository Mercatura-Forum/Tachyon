/// Traced.mo: test support. The book's `submit` and `approve`, with the same parameters, each call written to the
/// battery's transcript (custody/test/support/Transcript.mo) as the chain judge makes it again.
///
/// Attribution: Thebes Core Team.

import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";

import E "mo:kernel/domain/Encoding";

import T "../../src/BookTypes";
import B "../../src/BookCore";
import K "../../src/BookCanonical";
import X "../../../exchange/src/ExchangeCore";
import TR "../../../custody/test/support/Transcript";

module {
  func bytesOr(b : ?Blob) : Blob { switch (b) { case (?x) x; case null "" } };

  public func bOut(r : B.Result<B.Outcome>) : Text {
    switch (r) { case (#ok(#executed(x))) "x=" # TR.csv(x.effects); case (#ok(#proposed(p))) "p=" # Nat.toText(p.proposal); case (_) "e=" # TR.errName(debug_show(r)) }
  };
  public func bsub(s : B.State, xs : X.State, auth : B.Authority, now : Nat64, caller : Principal, c : T.Command, partition : ?Text, justification : Text) : B.Result<B.Outcome> {
    let r = B.submit(s, xs, auth, now, caller, c, partition, justification);
    TR.submitted("book", K.registry.current, bytesOr(E.bytesAt(K.registry, K.registry.current, c)), caller, now, justification, bOut(r));
    r
  };
  public func bapp(s : B.State, xs : X.State, auth : B.Authority, now : Nat64, checker : Principal, id : Nat) : B.Result<B.Outcome> {
    let r = B.approve(s, xs, auth, now, checker, id);
    TR.approved("book", id, checker, now, bOut(r));
    r
  };
}
