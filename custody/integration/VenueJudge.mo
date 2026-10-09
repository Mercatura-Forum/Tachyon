/// VenueJudge.mo: the test composition the chain judge installs (`custody/integration/chain_judge.py`): the offering,
/// the custody register, the exchange's foundation and the book on it, composed as their batteries compose them, so that a battery's transcript can be made again on a
/// chain, call by call. It is a test actor and never the product's front.
///
/// Each chain signer the judge uses stands for one of the battery's roles (a principal the battery acted as). The actor
/// admits a call only from a signer it was installed with, and passes the domain the role's principal and the clock
/// the transcript carries, so the domains' logs on the chain are the battery's byte for byte: the judge compares the
/// fingerprints, the log's tip included. The roles' grants and the dual policies are the battery's, given at
/// installation; four eyes is the core's own rule.
///
/// `fingerprints` and `replayCheck` are updates: a fold over stable memory in a query is refused on this substrate.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";

import Of "../src/OfferingCore";
import OK "../src/OfferingCanonical";
import Cu "../src/CustodyCore";
import CK "../src/CustodyCanonical";
import TC "../test/support/Traced";
import X "../../exchange/src/ExchangeCore";
import XK "../../exchange/src/ExchangeCanonical";
import XTC "../../exchange/test/support/Traced";
import Bk "../../book/src/BookCore";
import BK "../../book/src/BookCanonical";
import BTC "../../book/test/support/Traced";
import Sv "../../surveillance/src/SurvCore";
import SvK "../../surveillance/src/SurvCanonical";
import SvT "../../surveillance/test/support/Traced";

persistent actor class VenueJudge(init : {
  roles : [{ signer : Principal; role : Principal }];
  grants : [{ role : Principal; prefixes : [Text]; exact : [Text] }];
  eligibleRole : Text;
  holders : [Principal];
  offeringDuals : [Text];
  custodyDuals : [Text];
  exchangeDuals : [Text];
  bookDuals : [Text];
  survDuals : [Text];
  ttlSeconds : Nat;
}) {

  let os = Of.newState();
  let cs = Cu.newState();
  let xs = X.newState();
  let bs = Bk.newState();
  let ss = Sv.newState();
  func duals(ps : [Text]) : [{ permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat }] {
    Array.map<Text, { permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat }>(ps, func(permission) { { permission; required = 1; eligibleRole = init.eligibleRole; ttlSeconds = init.ttlSeconds } })
  };
  Of.setPolicies(os, duals(init.offeringDuals));
  Cu.setPolicies(cs, duals(init.custodyDuals));
  X.setPolicies(xs, duals(init.exchangeDuals));
  Bk.setPolicies(bs, duals(init.bookDuals));
  Sv.setPolicies(ss, duals(init.survDuals));

  func hasGrant(p : Principal, perm : Text) : Bool {
    for (g in init.grants.vals()) {
      if (Principal.equal(g.role, p)) {
        for (x in g.exact.vals()) { if (x == perm) return true };
        for (x in g.prefixes.vals()) { if (Text.startsWith(perm, #text x)) return true };
      };
    };
    false
  };
  func holdsRole(p : Principal, role : Text) : Bool { role == init.eligibleRole and Array.find<Principal>(init.holders, func(h) { Principal.equal(h, p) }) != null };
  transient let auth : Of.Authority = { hasGrant; holdsRole };
  func roleOf(signer : Principal) : ?Principal {
    for (r in init.roles.vals()) { if (Principal.equal(r.signer, signer)) return ?r.role };
    null
  };

  public shared (msg) func submit(domain : Text, version : Nat8, command : Blob, justification : Text, now : Nat64) : async Text {
    let ?role = roleOf(msg.caller) else return "e=UnknownSigner";
    let r = C.Reader(Blob.toArray(command));
    switch (domain) {
      case "offering" { let ?c = E.readAt(OK.registry, version, r) else return "e=Undecodable"; TC.oOut(Of.submit(os, auth, now, role, c, null, justification)) };
      // the register composed with the book: a leg is admitted against the book's settlement root (SPEC §19)
      case "custody" { let ?c = E.readAt(CK.registry, version, r) else return "e=Undecodable"; TC.cOut(Cu.submitWith(cs, auth, func(n : Nat) : ?Blob { Bk.settlementRootAt(bs, n) }, now, role, c, null, justification)) };
      case "exchange" { let ?c = E.readAt(XK.registry, version, r) else return "e=Undecodable"; XTC.xOut(X.submit(xs, auth, now, role, c, null, justification)) };
      case "book" { let ?c = E.readAt(BK.registry, version, r) else return "e=Undecodable"; BTC.bOut(Bk.submit(bs, xs, auth, now, role, c, null, justification)) };
      case "surveillance" { let ?c = E.readAt(SvK.registry, version, r) else return "e=Undecodable"; SvT.sOut(Sv.submit(ss, bs, xs, auth, now, role, c, null, justification)) };
      case _ "e=UnknownDomain";
    }
  };
  public shared (msg) func approve(domain : Text, proposal : Nat, now : Nat64) : async Text {
    let ?role = roleOf(msg.caller) else return "e=UnknownSigner";
    switch (domain) {
      case "offering" TC.oOut(Of.approve(os, auth, now, role, proposal));
      case "custody" TC.cOut(Cu.approve(cs, auth, now, role, proposal));
      case "exchange" XTC.xOut(X.approve(xs, auth, now, role, proposal));
      case "book" BTC.bOut(Bk.approve(bs, xs, auth, now, role, proposal));
      case "surveillance" SvT.sOut(Sv.approve(ss, bs, xs, auth, now, role, proposal));
      case _ "e=UnknownDomain";
    }
  };
  public func fingerprints() : async [(Text, Blob)] { [("offering", Of.fingerprint(os)), ("custody", Cu.fingerprint(cs)), ("exchange", X.fingerprint(xs)), ("book", Bk.fingerprint(bs)), ("surveillance", Sv.fingerprint(ss))] };
  public func replayCheck() : async Text {
    let o2 = Of.newStateOver(os.log); Of.setPolicies(o2, duals(init.offeringDuals));
    let orp = Of.replay(o2);
    let c2 = Cu.newStateOver(cs.log); Cu.setPolicies(c2, duals(init.custodyDuals));
    let crp = Cu.replay(c2);
    if (orp.faults.size() > 0 or Of.fingerprint(o2) != Of.fingerprint(os)) return "fault|offering|" # debug_show(orp.faults);
    if (crp.faults.size() > 0 or Cu.fingerprint(c2) != Cu.fingerprint(cs)) return "fault|custody|" # debug_show(crp.faults);
    let x2 = X.newStateOver(xs.log); X.setPolicies(x2, duals(init.exchangeDuals));
    let xrp = X.replay(x2);
    if (xrp.faults.size() > 0 or X.fingerprint(x2) != X.fingerprint(xs)) return "fault|exchange|" # debug_show(xrp.faults);
    let b2 = Bk.newStateOver(bs.log); Bk.setPolicies(b2, duals(init.bookDuals));
    let brp = Bk.replay(b2);
    if (brp.faults.size() > 0 or Bk.fingerprint(b2) != Bk.fingerprint(bs)) return "fault|book|" # debug_show(brp.faults);
    let s2 = Sv.newStateOver(ss.log); Sv.setPolicies(s2, duals(init.survDuals));
    let srp = Sv.replay(s2, bs, xs);
    if (srp.faults.size() > 0 or Sv.fingerprint(s2) != Sv.fingerprint(ss)) return "fault|surveillance|" # debug_show(srp.faults);
    "ok|" # Nat.toText(orp.blocks) # "," # Nat.toText(crp.blocks) # "," # Nat.toText(xrp.blocks) # "," # Nat.toText(brp.blocks) # "," # Nat.toText(srp.blocks)
  };
  public query func counts() : async { offeringBlocks : Nat; custodyBlocks : Nat; exchangeBlocks : Nat; bookBlocks : Nat } { { offeringBlocks = Of.counts(os).blocks; custodyBlocks = Cu.counts(cs).blocks; exchangeBlocks = X.counts(xs).blocks; bookBlocks = Bk.counts(bs).blocks } };
}
