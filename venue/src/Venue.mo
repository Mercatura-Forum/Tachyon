/// Venue.mo: the venue as one contract: the exchange's foundation (`exchange/`) and the book on it (`book/`), both on
/// certified logs folded into rows in stable memory. A trader's order, cancel and amendment are each one update; the
/// clear of a batch is recorded by the first command of a block after it (or the scheduler's flush), inside that update.
///
/// Authority: the operator, the directors (the four-eyes role), the scheduler and the depository are named at
/// installation; a trader is whoever the exchange's rows hold as an active trader, and acts only for its member's
/// accounts (the book checks the account at every act). Governance and system acts arrive as commands in their frozen
/// bytes; a trader's acts arrive typed. The chain's time of the message is the time every command carries.
///
/// The random end of a call auction (SPEC §8, §9): once an auction's window opens, a timer every second asks the
/// chain's randomness (`raw_rand`) whether this second ends it, with probability one over the seconds left, and ends it
/// for certain at `endTo`: the end is uniform over the window and unknown before the block that ends it. An interruption
/// (§10) ends at the first second after `interruptUntil`. The venue's uncross is an act of the book like the scheduler's.
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
import Map "mo:core/Map";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";
import Time "mo:core/Time";
import Timer "mo:core/Timer";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Auth "mo:kernel/auth/AuthTypes";

import X "../../exchange/src/ExchangeCore";
import XK "../../exchange/src/ExchangeCanonical";
import B "../../book/src/BookCore";
import BK "../../book/src/BookCanonical";
import T "../../book/src/BookTypes";

persistent actor class Venue(init : { operator : Principal; directors : [Principal]; scheduler : Principal; depository : Principal; regulator : Principal }) = this {

  let xs = X.newState();
  let bs = B.newState();
  func dual(permission : Text) : Auth.DualPolicy { { permission; required = 1; eligibleRole = "director"; ttlSeconds = 86_400 } };
  func duals(cat : [Auth.Permission]) : [Auth.DualPolicy] { Array.map<Auth.Permission, Auth.DualPolicy>(Array.filter<Auth.Permission>(cat, func(p) { p.dualByDefault }), func(p) { dual(p.id) }) };
  X.setPolicies(xs, duals(X.catalogue()));
  B.setPolicies(bs, duals(B.catalogue()));

  let schedulerActs : [Text] = ["exchange.segment.advance", "exchange.instrument.reference", "book.instrument.trading", "book.instrument.reference", "book.batch.flush", "book.sweep.endofday", "book.sweep.expire", "book.instrument.phase", "book.auction.uncross", "book.kill.sweep", "book.day.seal"];
  let traderActs : [Text] = ["exchange.account.open", "exchange.account.close", "book.funds.withdraw", "book.order.place", "book.order.cancel", "book.order.amend", "book.order.masscancel", "book.kill.set"];
  let operatorBookActs : [Text] = ["book.instrument.open", "book.instrument.halt", "book.instrument.resume", "book.kill.set", "book.kill.revive", "book.risk.limits"];
  func among(xs_ : [Text], x : Text) : Bool { Array.find<Text>(xs_, func(y) { y == x }) != null };
  func isDirector(p : Principal) : Bool { Array.find<Principal>(init.directors, func(d) { Principal.equal(d, p) }) != null };
  func activeTrader(p : Principal) : ?Nat {
    switch (X.traderByPrincipal(xs, p)) { case (?(_, t)) { if (t.status == #active) ?t.member else null }; case null null }
  };
  func hasGrant(p : Principal, perm : Text) : Bool {
    if (Principal.equal(p, init.operator)) return (Text.startsWith(perm, #text "exchange.") and not among(schedulerActs, perm)) or among(operatorBookActs, perm);
    if (Principal.equal(p, Principal.fromActor(this))) return perm == "book.auction.uncross";
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
  /// An accepted order: its id, status, the price it rests at (a market order's collar), the quantity it shows (an
  /// iceberg's peak; 0 unless live), the caller's own orders it cancelled, and the block that recorded it.
  public type Placed = { #ok : { order : Nat; status : Nat8; price : Nat; shown : Nat; cancelled : [Nat]; block : Nat }; #err : Text };
  /// The order records the account's member and the caller's trader id, as the exchange's rows hold them; the book
  /// checks both again.
  public shared (msg) func place(o : Place) : async Placed {
    let member = switch (X.account(xs, o.account)) { case (?a) a.member; case null 0 };
    let trader = switch (X.traderByPrincipal(xs, msg.caller)) { case (?(id, _)) id; case null 0 };
    switch (B.submit(bs, xs, auth, chainNow(), msg.caller, #placeOrder({ o with member; trader }), null, "")) {
      case (#ok(#executed(x))) #ok({ order = x.effects[1]; status = Nat8.fromNat(x.effects[2]); price = x.effects[3]; shown = x.effects[4]; cancelled = Array.sliceToArray<Nat>(x.effects, 5, x.effects.size()); block = x.block });
      case (#ok(#proposed(_))) #err("Proposed");
      case (#err(e)) #err(debug_show(e));
    }
  };
  public shared (msg) func cancel(order : Nat) : async Text { bOut(B.submit(bs, xs, auth, chainNow(), msg.caller, #cancelOrder({ order }), null, "")) };
  public shared (msg) func amend(order : Nat, qty : Nat, price : Nat) : async Text { bOut(B.submit(bs, xs, auth, chainNow(), msg.caller, #amendOrder({ order; qty; price }), null, "")) };
  /// A trader's kill switch (SPEC §11): its own member (`trader` 0) or one trader of its own member. The member is the
  /// caller's; the book checks the trader is one of it.
  public shared (msg) func kill(trader : Nat, reason : Text) : async Text {
    let member = switch (activeTrader(msg.caller)) { case (?m) m; case null 0 };
    bOut(B.submit(bs, xs, auth, chainNow(), msg.caller, #kill({ member; trader; reason }), null, ""))
  };

  // ─── the random end of call auctions ───────────────────────────────────────────────────────
  transient let ic : actor { raw_rand : () -> async Blob } = actor "aaaaa-aa";
  transient var ending = false;
  /// An instrument whose auction is past its window's end with nothing to trade inside the static band is tried again a
  /// minute on, not every second.
  transient let retryAt = Map.empty<Nat, Nat64>();
  /// Where the next tick's read of the instruments in a call phase starts: past the last one read when a tick read the
  /// most it may, so every instrument in a call phase is reached however many there are.
  transient var callFrom = 0;
  func inWindow(x : T.Instrument, now : Nat64) : Bool {
    if (x.interruptUntil != 0) return now >= x.interruptUntil;
    x.endTo != 0 and now >= x.endFrom
  };
  func endAuctions() : async () {
    if (ending) return;
    let calling = B.inCallPhase(bs, callFrom, B.MAX_CALLING);
    callFrom := if (calling.size() == B.MAX_CALLING) calling[calling.size() - 1].0 + 1 else 0;
    let open = Array.filter<(Nat, T.Instrument)>(calling, func((id, x)) {
      inWindow(x, chainNow()) and (switch (Map.get(retryAt, Nat.compare, id)) { case (?t) chainNow() >= t; case null true })
    });
    if (open.size() == 0) return;
    ending := true;
    let seed = try { Blob.toArray(await ic.raw_rand()) } catch (_) { ending := false; return };
    ending := false;
    for ((id, _) in open.vals()) {
      let now = chainNow();
      switch (B.instrument(bs, id)) {
        case (?x) {
          if ((x.phase == #auction or x.phase == #closingAuction) and inWindow(x, now)) {
            let ends = if (x.interruptUntil != 0 or now >= x.endTo) true else {
              let left = Nat64.toNat((x.endTo - now) / 1_000_000_000) + 1;
              // each instrument's draw: the first four bytes of SHA-256(the block's randomness ‖ the instrument's id)
              let h = Blob.toArray(Sha256.fromArray(#sha256, Array.concat<Nat8>(seed, Array.tabulate<Nat8>(8, func(i) { Nat8.fromNat((id / (256 ** (7 - i : Nat))) % 256) }))));
              let draw = ((Nat8.toNat(h[0]) * 256 + Nat8.toNat(h[1])) * 256 + Nat8.toNat(h[2])) * 256 + Nat8.toNat(h[3]);
              draw % left == 0
            };
            if (ends) {
              let next : T.Phase = if (x.phase == #closingAuction) #tradeAtClose else #continuous;
              switch (B.submit(bs, xs, auth, now, Principal.fromActor(this), #uncross({ instrument = id; next }), null, "the drawn end")) {
                case (#ok(#executed(e))) { if (e.effects.size() == 7 and e.effects[2] == 0 and e.effects[6] != Nat8.toNat(BK.phaseCode(next))) Map.add(retryAt, Nat.compare, id, now + 60_000_000_000) else Map.remove(retryAt, Nat.compare, id) };
                case (_) Map.add(retryAt, Nat.compare, id, now + 60_000_000_000);
              };
            };
          };
        };
        case null {};
      };
    };
  };
  transient let endTimer = Timer.recurringTimer<system>(#seconds 1, endAuctions);

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
  // ─── the public feed, the day's statistics and files (SPEC §13, §15) ──────────────────────────
  /// The most messages one read of the feed returns.
  let FEED_PAGE = 50;
  /// The feed from block `from`: up to `count` messages (at most `FEED_PAGE`), each with its sequence and feed hash; the
  /// feed hash before the first, to chain from; and the head (the next sequence and the last hash). A consumer checks
  /// every hash against the chain over what it received (SPEC §13).
  public query func feed(from : Nat, count : Nat) : async { messages : [(Nat, Blob, Blob)]; previous : ?Blob; next : Nat; head : Blob } {
    let (next, head) = B.feedHeadOf(bs);
    let out = List.empty<(Nat, Blob, Blob)>();
    var previous : ?Blob = null;
    var i = from;
    while (i < next and List.size(out) < Nat.min(count, FEED_PAGE)) {
      switch (B.feedEntry(bs, i)) { case (?e) { if (i == from) previous := ?e.previous; List.add(out, (i, e.message, e.hash)) }; case null {} };
      i += 1;
    };
    { messages = List.toArray(out); previous; next; head }
  };
  /// The feed's head: the next sequence and the last block's feed hash.
  public query func feedHead() : async { next : Nat; head : Blob } { let (next, head) = B.feedHeadOf(bs); { next; head } };
  /// An instrument's statistics for the session since the last seal (SPEC §15).
  public query func sessionStats(id : Nat) : async ?B.Stats { if (B.instrument(bs, id) == null) null else ?B.statsOf(bs, id) };
  /// A sealed day's file (SPEC §15); its SHA-256 is the hash its seal recorded in the log.
  public query func dayFile(day : Nat) : async ?Blob { B.dayFile(bs, day) };

  // ─── the drop copy (SPEC §14), scoped to the caller's member ──────────────────────────────
  /// The caller's member's drop copy from block `from`: its blocks, its own as stored, the others as their public
  /// messages; the block to read from next. An update: a query's caller is not authenticated on this substrate.
  public shared (msg) func dropCopy(from : Nat, count : Nat) : async { #ok : { entries : [(Nat, Bool, Blob)]; next : ?Nat }; #err : Text } {
    let ?member = activeTrader(msg.caller) else return #err("NotATrader");
    #ok(B.dropCopy(bs, member, from, count))
  };

  /// An instrument's row in the book (reference data: its phase, bands, reference, last and closing prices, window).
  public query func instrument(id : Nat) : async ?T.Instrument { B.instrument(bs, id) };
  /// The indicative auction price of an instrument in a call phase (SPEC §9): the price, volume and surplus its uncross
  /// would give now, and whether the price lies within the static band. An update: it walks the crossing orders in stable
  /// memory, which a query may not do on this substrate.
  public func indicative(id : Nat) : async ?{ price : Nat; volume : Nat; surplus : Int; withinBand : Bool } { B.indicative(bs, id) };
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
