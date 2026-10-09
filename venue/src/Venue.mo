/// Venue.mo: the venue as one contract: the exchange's foundation (`exchange/`) and the book on it (`book/`), both on
/// certified logs folded into rows in stable memory. A trader's order, cancel and amendment are each one update; the
/// clear of a batch is recorded by the first command of a block after it (or the scheduler's flush), inside that update.
///
/// Authority: the operator, the directors (the four-eyes role), the scheduler and the depository are named at
/// installation; a trader is whoever the exchange's rows hold as an active trader, and acts only for its member's
/// accounts (the book checks the account at every act). Governance and system acts arrive as commands in their frozen
/// bytes; a trader's acts arrive typed. The chain's time of the message is the time every command carries.
///
/// Reads that name an account or an order are updates scoped to the caller's member: a query's caller is not
/// authenticated on this substrate. The counters are public.
///
/// Attribution: Thebes Core Team.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Time "mo:core/Time";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Auth "mo:kernel/auth/AuthTypes";

import X "../../exchange/src/ExchangeCore";
import XK "../../exchange/src/ExchangeCanonical";
import B "../../book/src/BookCore";
import BK "../../book/src/BookCanonical";
import T "../../book/src/BookTypes";

persistent actor class Venue(init : { operator : Principal; directors : [Principal]; scheduler : Principal; depository : Principal; regulator : Principal }) {

  let xs = X.newState();
  let bs = B.newState();
  func dual(permission : Text) : Auth.DualPolicy { { permission; required = 1; eligibleRole = "director"; ttlSeconds = 86_400 } };
  func duals(cat : [Auth.Permission]) : [Auth.DualPolicy] { Array.map<Auth.Permission, Auth.DualPolicy>(Array.filter<Auth.Permission>(cat, func(p) { p.dualByDefault }), func(p) { dual(p.id) }) };
  X.setPolicies(xs, duals(X.catalogue()));
  B.setPolicies(bs, duals(B.catalogue()));

  let schedulerActs : [Text] = ["exchange.segment.advance", "exchange.instrument.reference", "book.instrument.trading", "book.instrument.reference", "book.batch.flush", "book.sweep.endofday", "book.sweep.expire"];
  let traderActs : [Text] = ["exchange.account.open", "exchange.account.close", "book.funds.withdraw", "book.order.place", "book.order.cancel", "book.order.amend", "book.order.masscancel"];
  func among(xs_ : [Text], x : Text) : Bool { Array.find<Text>(xs_, func(y) { y == x }) != null };
  func isDirector(p : Principal) : Bool { Array.find<Principal>(init.directors, func(d) { Principal.equal(d, p) }) != null };
  func activeTrader(p : Principal) : ?Nat {
    switch (X.traderByPrincipal(xs, p)) { case (?(_, t)) { if (t.status == #active) ?t.member else null }; case null null }
  };
  func hasGrant(p : Principal, perm : Text) : Bool {
    if (Principal.equal(p, init.operator)) return (Text.startsWith(perm, #text "exchange.") and not among(schedulerActs, perm)) or perm == "book.instrument.open";
    if (Principal.equal(p, init.scheduler)) return among(schedulerActs, perm);
    if (isDirector(p)) return perm == "command.approve" or perm == "command.reject";
    if (Principal.equal(p, init.depository)) return perm == "book.funds.deposit";
    activeTrader(p) != null and among(traderActs, perm)
  };
  func holdsRole(p : Principal, role : Text) : Bool { role == "director" and isDirector(p) };
  transient let auth : B.Authority = { hasGrant; holdsRole };

  func chainNow() : Nat64 { Nat64.fromIntWrap(Time.now()) };
  func csv(xs_ : [Nat]) : Text { var o = ""; for (x in xs_.vals()) o := o # (if (o == "") "" else ",") # Nat.toText(x); o };
  func errText(e : Text) : Text { "e=" # e };
  func xOut(r : X.Result<X.Outcome>) : Text {
    switch (r) { case (#ok(#executed(x))) "x=" # csv(x.effects); case (#ok(#proposed(p))) "p=" # Nat.toText(p.proposal); case (#err(e)) errText(debug_show(e)) }
  };
  func bOut(r : B.Result<B.Outcome>) : Text {
    switch (r) { case (#ok(#executed(x))) "x=" # csv(x.effects); case (#ok(#proposed(p))) "p=" # Nat.toText(p.proposal); case (#err(e)) errText(debug_show(e)) }
  };

  // ─── governance and system acts, in the commands' frozen bytes ─────────────────────────────
  public shared (msg) func exchange(version : Nat8, command : Blob, justification : Text) : async Text {
    let ?c = E.readAt(XK.registry, version, C.Reader(Blob.toArray(command))) else return errText("Undecodable");
    xOut(X.submit(xs, auth, chainNow(), msg.caller, c, null, justification))
  };
  public shared (msg) func exchangeApprove(proposal : Nat) : async Text { xOut(X.approve(xs, auth, chainNow(), msg.caller, proposal)) };
  public shared (msg) func book(version : Nat8, command : Blob, justification : Text) : async Text {
    let ?c = E.readAt(BK.registry, version, C.Reader(Blob.toArray(command))) else return errText("Undecodable");
    bOut(B.submit(bs, xs, auth, chainNow(), msg.caller, c, null, justification))
  };
  public shared (msg) func bookApprove(proposal : Nat) : async Text { bOut(B.approve(bs, xs, auth, chainNow(), msg.caller, proposal)) };

  // ─── a trader's acts, typed: one update each ──────────────────────────────────────────────
  public type Place = {
    account : Nat; instrument : Nat; side : T.Side; kind : T.Kind; qty : Nat; price : Nat; stopPrice : Nat; peak : Nat;
    validity : T.Validity; gtdDay : Nat; selfTrade : T.SelfTrade; capacity : T.Capacity; shortSale : Bool; clientRef : Text; oco : Nat; trail : Nat;
  };
  public type Placed = { #ok : { order : Nat; status : Nat8; cancelled : [Nat]; block : Nat }; #err : Text };
  public shared (msg) func place(o : Place) : async Placed {
    switch (B.submit(bs, xs, auth, chainNow(), msg.caller, #placeOrder(o), null, "")) {
      case (#ok(#executed(x))) #ok({ order = x.effects[1]; status = Nat8.fromNat(x.effects[2]); cancelled = Array.sliceToArray<Nat>(x.effects, 3, x.effects.size()); block = x.block });
      case (#ok(#proposed(_))) #err("Proposed");
      case (#err(e)) #err(debug_show(e));
    }
  };
  public shared (msg) func cancel(order : Nat) : async Text { bOut(B.submit(bs, xs, auth, chainNow(), msg.caller, #cancelOrder({ order }), null, "")) };
  public shared (msg) func amend(order : Nat, qty : Nat, price : Nat) : async Text { bOut(B.submit(bs, xs, auth, chainNow(), msg.caller, #amendOrder({ order; qty; price }), null, "")) };

  // ─── reads scoped to the caller's member (updates) ─────────────────────────────────────────
  func ownsAccount(p : Principal, account : Nat) : Bool {
    switch (activeTrader(p), X.account(xs, account)) { case (?m, ?a) a.member == m; case (_) false }
  };
  public shared (msg) func myOrder(id : Nat) : async ?T.Order {
    switch (B.order(bs, id)) { case (?o) { if (ownsAccount(msg.caller, o.account)) ?o else null }; case null null }
  };
  public shared (msg) func myBalance(account : Nat, ledger : Principal) : async ?T.Balance {
    if (ownsAccount(msg.caller, account)) ?B.balance(bs, account, ledger) else null
  };

  // ─── the regulator's copy of the book's log ───────────────────────────────────────────────
  /// The book's certified log as stored, `count` blocks from `from` (at most 500), for the regulator named at
  /// installation, who rebuilds the book from it alone (`book/integration/regulator_replay.py`) and compares the
  /// fingerprint with `fingerprints`.
  public shared (msg) func bookLog(from : Nat, count : Nat) : async { #ok : { blocks : [Blob]; length : Nat }; #err : Text } {
    if (not Principal.equal(msg.caller, init.regulator)) return #err("NotTheRegulator");
    let n = DL.length(bs.log);
    let out = List.empty<Blob>();
    var i = from;
    let stop = Nat.min(n, from + Nat.min(count, 500));
    while (i < stop) { switch (DL.rawBlock(bs.log, i)) { case (?b) List.add(out, b); case null {} }; i += 1 };
    #ok({ blocks = List.toArray(out); length = n })
  };

  // ─── public counters and the fingerprints ─────────────────────────────────────────────────
  public query func counts() : async { orders : Nat; bookBlocks : Nat; exchangeBlocks : Nat } {
    { orders = bs.nextOrder - 1; bookBlocks = B.counts(bs).blocks; exchangeBlocks = X.counts(xs).blocks }
  };
  public func exchangeFingerprint() : async Blob { X.fingerprint(xs) };
  /// The book's fingerprint in slices of at most 5,000 rows a call (a large book cannot be fingerprinted in one message):
  /// call again while it answers `#more`; a block appended meanwhile starts the run again.
  transient var bookRun : ?B.FingerprintRun = null;
  public func fingerprintBook(rows : Nat) : async { #more : Nat; #done : Blob } {
    let run = switch (bookRun) { case (?r) r; case null { let r = B.startFingerprint(bs); bookRun := ?r; r } };
    switch (B.stepFingerprint(bs, run, Nat.min(rows, 5_000))) {
      case (#done(h)) { bookRun := null; #done(h) };
      case (#more(p)) #more(p);
      case (#restart) { bookRun := ?B.startFingerprint(bs); #more(0) };
    }
  };
}
