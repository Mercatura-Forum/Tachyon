/// Traced.mo: test support. The desk's `submit` and `approve`, each call written to the battery's transcript
/// (custody/test/support/Transcript.mo) as the chain judge makes it again.
///
/// Attribution: Thebes Core Team.

import Nat "mo:core/Nat";

import E "mo:kernel/domain/Encoding";

import T "../../src/SurvTypes";
import S "../../src/SurvCore";
import K "../../src/SurvCanonical";
import B "../../../book/src/BookCore";
import X "../../../exchange/src/ExchangeCore";
import TR "../../../custody/test/support/Transcript";

module {
  func bytesOr(b : ?Blob) : Blob { switch (b) { case (?x) x; case null "" } };
  public func sOut(r : S.Result<S.Outcome>) : Text {
    switch (r) { case (#ok(#executed(x))) "x=" # TR.csv(x.effects); case (#ok(#proposed(p))) "p=" # Nat.toText(p.proposal); case (_) "e=" # TR.errName(debug_show(r)) }
  };
  public func ssub(s : S.State, book : B.State, xs : X.State, auth : S.Authority, now : Nat64, caller : Principal, c : T.Command, justification : Text) : S.Result<S.Outcome> {
    let r = S.submit(s, book, xs, auth, now, caller, c, null, justification);
    TR.submitted("surveillance", K.registry.current, bytesOr(E.bytesAt(K.registry, K.registry.current, c)), caller, now, justification, sOut(r));
    r
  };
  public func sapp(s : S.State, book : B.State, xs : X.State, auth : S.Authority, now : Nat64, checker : Principal, id : Nat) : S.Result<S.Outcome> {
    let r = S.approve(s, book, xs, auth, now, checker, id);
    TR.approved("surveillance", id, checker, now, sOut(r));
    r
  };
}
