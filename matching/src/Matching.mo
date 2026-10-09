/// Matching.mo - frequent batch-auction CLOB matching engine (DvP P3).
///
/// A NEW persistent actor that ORCHESTRATES three PROVEN, UNCHANGED primitives - it re-implements
/// neither escrow nor settlement:
///   • shares ledger (ICRC-1/2 IndexedLedger)   • cash ledger (ICRC-1/2 IndexedLedger CBDC)
///   • the DvP atomic-swap core (settlement, both-or-neither - byte-frozen lifecycle, the frozen lifecycle)
///
/// Model (decided): frequent batch auction, single uniform clearing price p* per window
/// (Budish-Cramton-Shim). Escrow-on-submit = ICRC-2 approve-to-core + an engine-side RESERVATION
/// (no engine custody). Each cleared (buyer,seller,p*,qty) → a SETTLEMENT OBLIGATION that settles as
/// a DvP trade between seller=maker and buyer=taker through the UNCHANGED core.
///
/// The crux: the clear is `Prim.performanceCounter(0)`-gated against MATCH_INSTR_BUDGET
/// (mirror CLMM SWAP_INSTR_BUDGET); on budget exhaustion mid-clear it applies the bounded fill slice
/// atomically, saves a PendingClear, and a Timer resumes next round - plan-then-apply via the PURE,
/// read-only MatchLogic planner (Oisy plan-then-apply / Kill-before-mutate), with the partial
/// remainder re-enqueued at PRESERVED price-time priority (original id). Unbounded batch size AND
/// per-chunk atomicity AND zero dependence on an operator size cap.

import Prim "mo:⛔";
import Map "mo:core/Map";
import List "mo:core/List";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Principal "mo:core/Principal";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";

import ICRC "ICRC";
import L "MatchLogic";
import T "MatchTypes";

shared (install) persistent actor class Matching(cfg : {
  sharesLedger : Principal;
  cashLedger : Principal;
  dvpCore : Principal;
  instrBudget : ?Nat64;        // per-chunk instruction budget; null => 20 B
  maxFillsPerChunk : ?Nat;     // egypt-side per-chunk fill cap; null => production default (1000)
  listingRegistry : ?Principal; // P4-D: issuer-listing gate. null => no gate (M1-M5 reference behaviour).
}) = self {

  // The installer (the controller that installed or upgraded this engine): the only principal that names the
  // clearing agent and sets the lot. On an upgrade it is the upgrade's caller, as in the core.
  transient let installer : Principal = install.caller;

  // ── Config (the proven primitives this engine orchestrates) ───────────────────────────────
  let sharesLedger : Principal = cfg.sharesLedger;
  let cashLedger : Principal = cfg.cashLedger;
  let dvpCore : Principal = cfg.dvpCore;
  let listingRegistry : ?Principal = cfg.listingRegistry;  // P4-D issuer-listing gate (optional)

  // ── Interfaces the engine calls (P4) ────────────────────────────────────────────────────────
  // The DvP core's additive authorized-relayer settlement entrypoint. The engine is the
  // controller-set relayer; settleMatchFor pays the asset leg → buyer and the cash leg → seller
  // DIRECTLY from the core's both-or-neither atomic swap, with NO trader action at settle.
  type TradeStatus = { #Open; #Funded; #Settled; #Aborted };
  type SettleResult = {
    tradeId : Nat; status : TradeStatus; legAPaid : Bool; legBPaid : Bool;
    legAPayoutAmount : Nat; legBPayoutAmount : Nat; note : Text;
  };
  type DvpCoreIface = actor {
    settleMatchFor : (args : {
      matchSeq : Nat; maker : Principal; taker : Principal;
      assetLedger : Principal; assetAmount : Nat; cashLedger : Principal; cashAmount : Nat;
      deadlineSecs : Nat;
    }) -> async Result.Result<SettleResult, Text>;
  };
  func dvpCoreActor() : DvpCoreIface { actor (Principal.toText(dvpCore)) };

  // The issuer-listing registry. Only a registered+funded (shares,cash) pair is
  // tradeable; a query the engine consults at order intake when a registry is configured.
  type ListingRegistryIface = actor {
    isPairTradeable : (shares : Principal, cash : Principal) -> async Bool;
  };

  // A chunk ends when EITHER bound trips (after >= 1 fill of progress):
  //  • MATCH_INSTR_BUDGET - `Prim.performanceCounter(0)` instruction budget (mirror CLMM
  //    SWAP_INSTR_BUDGET); this is the bound on the target chain.
  //  • MAX_FILLS_PER_CHUNK - a deterministic fills-per-chunk cap. THIS is the operative bound on
  //    the EGYPT engine, whose `ic0.performance_counter` returns the block timestamp_ns (constant
  //    within a message - host.rs:2652), so the instruction-budget term never fires here. Bounding
  //    by fill count keeps each chunk's work well under the engine's per-message bound regardless of
  //    crossing depth.
  // Both are configurable so a test instance can force chunking with a feasible order count; the
  // chunking/resume logic is byte-identical for ALL chunk sizes (proven by the pure battery).
  let MATCH_INSTR_BUDGET : Nat64 = switch (cfg.instrBudget) { case (?b) b; case null 20_000_000_000 };
  let MAX_FILLS_PER_CHUNK : Nat = switch (cfg.maxFillsPerChunk) { case (?n) n; case null 1000 };

  // ── State ──────────────────────────────────────────────────────────────────────────────────
  var nextOrderId : Nat = 1;
  var currentWindow : Nat = 0;          // open window - new submits land here
  let orders = Map.empty<Nat, T.Order>();
  let obligations = List.empty<T.Obligation>();
  var nextObligationSeq : Nat = 0;
  let pendingClears = Map.empty<Nat, T.PendingClear>();   // window -> resumable clear state
  let chunkCounts = Map.empty<Nat, Nat>();                // window -> chunk-messages used

  // engine-side reservations (the escrow accounting - no custody)
  let reservedShares = Map.empty<Principal, Nat>();       // by seller owner
  let reservedCash = Map.empty<Principal, Nat>();         // by buyer owner

  // diagnostic invariant log (M4 no-stranding ANOMALIES; asserted EMPTY in tests; never traps)
  let invLog = List.empty<Text>();
  // normal-event audit log for FOK kills (a kill is expected behaviour, NOT an anomaly)
  let killLog = List.empty<Text>();

  // ── The fixes of AU-01 to AU-05 and AU-08 ────────────────────────────────────────────────────────────────
  // The principal that closes and clears windows (AU-04): set by the installer; until it is set, only the installer.
  var clearingAgent : ?Principal = null;
  // The lot (AU-08): every quantity a whole number of lots, the lot above the asset ledger's fee, every limit price
  // times the lot above the cash ledger's fee, so every fill settles. 0 = not configured: no order is accepted.
  var lotSize : Nat = 0;
  var assetFeeAtLot : Nat = 0;
  var cashFeeAtLot : Nat = 0;
  // A bid's cash still reserved, by order id (AU-02): limit x quantity + fee at intake, released exactly by
  // L.bidRelease. A bid accepted before these fixes has no entry and is released as before (limit x remaining).
  let bidReserve = Map.empty<Nat, Nat>();
  // Each owner's live limits per side, limit -> count of live orders at it (AU-03): the owner's best opposite
  // limit is the map's least ask or greatest bid, read in O(log n).
  let liveBidLimits = Map.empty<Principal, Map.Map<Nat, Nat>>();
  let liveAskLimits = Map.empty<Principal, Map.Map<Nat, Nat>>();
  // A window's obligations in emission order (bounded settlement, AU-05), the settlement cursor per window, and the
  // obligations the core refused, with its reason (a refused obligation is recorded, never re-driven for ever).
  let obligationsByWindow = Map.empty<Nat, List.List<Nat>>();
  let settleCursor = Map.empty<Nat, Nat>();
  let refusedObligations = Map.empty<Nat, Text>();
  // Set once the indexes above cover every order and obligation made before them (the first postupgrade).
  var indexesBuilt : Bool = false;
  let MAX_PAGE : Nat = 500;

  transient let selfPrincipal = Principal.fromActor(self);

  func now64() : Nat64 { Nat64.fromNat(Int.abs(Time.now())) };
  func requireAuth(caller : Principal) { if (Principal.isAnonymous(caller)) Runtime.trap("anonymous principal not allowed") };
  func sharesL() : ICRC.Ledger { actor (Principal.toText(sharesLedger)) };
  func cashL() : ICRC.Ledger { actor (Principal.toText(cashLedger)) };

  func getN(m : Map.Map<Principal, Nat>, k : Principal) : Nat { switch (Map.get(m, Principal.compare, k)) { case (?v) v; case null 0 } };
  func addN(m : Map.Map<Principal, Nat>, k : Principal, d : Nat) { Map.add(m, Principal.compare, k, getN(m, k) + d) };
  func subN(m : Map.Map<Principal, Nat>, k : Principal, d : Nat) {
    let cur = getN(m, k);
    let nv : Nat = if (d >= cur) 0 else cur - d;
    if (nv == 0) ignore Map.delete(m, Principal.compare, k) else Map.add(m, Principal.compare, k, nv);
  };
  func cidN(m : Map.Map<Nat, Nat>, k : Nat) : Nat { switch (Map.get(m, Nat.compare, k)) { case (?v) v; case null 0 } };

  func logInv(msg : Text) { List.add(invLog, msg) };
  func memNat(xs : [Nat], v : Nat) : Bool { for (x in xs.vals()) { if (x == v) return true }; false };

  func isAgent(c : Principal) : Bool {
    switch (clearingAgent) { case (?a) Principal.equal(c, a) or Principal.equal(c, installer); case null Principal.equal(c, installer) }
  };

  func limitsOf(side : T.Side) : Map.Map<Principal, Map.Map<Nat, Nat>> { switch (side) { case (#buy) liveBidLimits; case (#sell) liveAskLimits } };

  func indexLive(o : T.Order) {
    let byOwner = limitsOf(o.side);
    let m = switch (Map.get(byOwner, Principal.compare, o.owner)) { case (?m) m; case null { let m = Map.empty<Nat, Nat>(); Map.add(byOwner, Principal.compare, o.owner, m); m } };
    Map.add(m, Nat.compare, o.limitPrice, cidN(m, o.limitPrice) + 1);
  };

  func unindexLive(o : T.Order) {
    let byOwner = limitsOf(o.side);
    switch (Map.get(byOwner, Principal.compare, o.owner)) {
      case null {};
      case (?m) {
        let n = cidN(m, o.limitPrice);
        if (n <= 1) ignore Map.delete(m, Nat.compare, o.limitPrice) else Map.add(m, Nat.compare, o.limitPrice, n - 1);
        if (Map.isEmpty(m)) ignore Map.delete(byOwner, Principal.compare, o.owner);
      };
    };
  };

  // The owner's best live limit on the side opposite to `side`.
  func bestOpposite(owner : Principal, side : T.Side) : ?Nat {
    switch (side) {
      case (#buy) switch (Map.get(liveAskLimits, Principal.compare, owner)) { case (?m) switch (Map.minEntry(m)) { case (?(p, _)) ?p; case null null }; case null null };
      case (#sell) switch (Map.get(liveBidLimits, Principal.compare, owner)) { case (?m) switch (Map.maxEntry(m)) { case (?(p, _)) ?p; case null null }; case null null };
    }
  };

  // Release what a bid holds for `fill` units filled with `remainingAfter` left (0 when the order ends: its last
  // fill, a cancel or a kill), exactly (AU-02).
  func releaseBid(o : T.Order, fill : Nat, remainingAfter : Nat) {
    switch (Map.get(bidReserve, Nat.compare, o.id)) {
      case (?held) {
        let (rel, left) = L.bidRelease(held, o.limitPrice, fill, remainingAfter);
        subN(reservedCash, o.owner, rel);
        if (left == 0) ignore Map.delete(bidReserve, Nat.compare, o.id) else Map.add(bidReserve, Nat.compare, o.id, left);
      };
      // accepted before the fixes: released as it was reserved then
      case null subN(reservedCash, o.owner, o.limitPrice * (if (remainingAfter == 0 and fill == 0) o.remaining else fill));
    };
  };

  // Kill an all-or-none (FOK) order that could not fully fill: release its reservation, mark it
  // Cancelled, zero its remaining. NO fill is ever applied (Kill-before-mutate, M2). Other orders
  // are untouched (the kill decision came from the read-only clearAON fixpoint).
  func killOrder(id : Nat) {
    switch (Map.get(orders, Nat.compare, id)) {
      case null {};
      case (?o) {
        switch (o.side) {
          case (#sell) subN(reservedShares, o.owner, o.remaining);
          case (#buy) releaseBid(o, 0, 0);
        };
        unindexLive(o);
        o.status := #Cancelled;
        o.remaining := 0;
        List.add(killLog, "FOK-KILL order " # Nat.toText(id) # " (could not fully fill at clearing price)");
      };
    };
  };

  // ── A. Intake - escrow-on-submit via ICRC-2 approve + engine reservation ────────────────────
  // Verifies the order is FUNDABLE: the trader's free (balance ∧ allowance-to-core) covers the
  // order's funding need, then RESERVES that capacity so the same funds are never matched twice.
  public shared ({ caller }) func submitOrder(args : { side : T.Side; limitPrice : Nat; qty : Nat; allOrNone : Bool }) : async Result.Result<T.SubmitResult, Text> {
    requireAuth(caller);
    if (args.qty == 0) return #err("qty must be > 0");
    if (args.limitPrice == 0) return #err("limitPrice must be > 0");
    switch (L.lotRefusal(args.qty, args.limitPrice, lotSize, assetFeeAtLot, cashFeeAtLot)) { case (?why) return #err(why); case null {} };

    // P4-D listing gate: when a registry is configured, this engine's (shares,cash) pair must be a
    // registered+funded listing or no order is accepted. null registry => no gate (M1-M5 behaviour).
    switch (listingRegistry) {
      case (?reg) {
        let registry : ListingRegistryIface = actor (Principal.toText(reg));
        let ok = try { await registry.isPairTradeable(sharesLedger, cashLedger) } catch (_) { return #err("listing registry unreachable") };
        if (not ok) return #err("this market (shares/cash pair) is not a registered, funded listing");
      };
      case null {};
    };

    switch (args.side) {
      case (#sell) {
        // need `qty` shares; check free balance ∧ free allowance(owner -> core) on the shares ledger
        let bal = try { await sharesL().icrc1_balance_of({ owner = caller; subaccount = null }) } catch (_) { return #err("shares ledger unreachable") };
        let alw = try { (await sharesL().icrc2_allowance({ account = { owner = caller; subaccount = null }; spender = { owner = dvpCore; subaccount = null } })).allowance } catch (_) { return #err("shares allowance read failed") };
        let reserved = getN(reservedShares, caller);
        if (bal < reserved + args.qty) return #err("insufficient free shares: balance " # Nat.toText(bal) # " reserved " # Nat.toText(reserved) # " need " # Nat.toText(args.qty));
        if (alw < reserved + args.qty) return #err("insufficient shares allowance to DvP core: " # Nat.toText(alw) # " (approve the core for >= " # Nat.toText(reserved + args.qty) # ")");
        // the last check, after every await (AU-03): no window holds two orders of one owner that can fill each other
        if (L.crossesOwn(#sell, args.limitPrice, bestOpposite(caller, #sell))) return #err("self-trade prevented: this sell would cross your own live buy");
        addN(reservedShares, caller, args.qty);
        let o = makeOrder(caller, #sell, args.limitPrice, args.qty, args.allOrNone);
        #ok({ orderId = o.id; status = o.status; reservedShares = args.qty; reservedCash = 0; note = "ask resting in window " # Nat.toText(currentWindow) });
      };
      case (#buy) {
        // need limitPrice*qty cash (+ one escrow fee margin); check free balance ∧ allowance on cash
        let fee = try { await cashL().icrc1_fee() } catch (_) { return #err("cash ledger unreachable") };
        let need = args.limitPrice * args.qty + fee;
        let bal = try { await cashL().icrc1_balance_of({ owner = caller; subaccount = null }) } catch (_) { return #err("cash ledger unreachable") };
        let alw = try { (await cashL().icrc2_allowance({ account = { owner = caller; subaccount = null }; spender = { owner = dvpCore; subaccount = null } })).allowance } catch (_) { return #err("cash allowance read failed") };
        let reserved = getN(reservedCash, caller);
        if (bal < reserved + need) return #err("insufficient free cash: balance " # Nat.toText(bal) # " reserved " # Nat.toText(reserved) # " need " # Nat.toText(need));
        if (alw < reserved + need) return #err("insufficient cash allowance to DvP core: " # Nat.toText(alw) # " (approve the core for >= " # Nat.toText(reserved + need) # ")");
        if (L.crossesOwn(#buy, args.limitPrice, bestOpposite(caller, #buy))) return #err("self-trade prevented: this buy would cross your own live sell");
        addN(reservedCash, caller, need);
        let o = makeOrder(caller, #buy, args.limitPrice, args.qty, args.allOrNone);
        Map.add(bidReserve, Nat.compare, o.id, need);
        #ok({ orderId = o.id; status = o.status; reservedShares = 0; reservedCash = need; note = "bid resting in window " # Nat.toText(currentWindow) });
      };
    };
  };

  func makeOrder(owner : Principal, side : T.Side, limitPrice : Nat, qty : Nat, allOrNone : Bool) : T.Order {
    let id = nextOrderId; nextOrderId += 1;
    let o : T.Order = {
      id; owner; side; limitPrice; qty; var remaining = qty;
      window = currentWindow; allOrNone; var status = #Open; createdAt = now64();
    };
    Map.add(orders, Nat.compare, id, o);
    indexLive(o);
    o
  };

  // cancel: owner-only; only a resting order in the OPEN window (never one being cleared); releases reservation.
  public shared ({ caller }) func cancelOrder(id : Nat) : async Result.Result<Text, Text> {
    requireAuth(caller);
    let o = switch (Map.get(orders, Nat.compare, id)) { case (?x) x; case null return #err("no such order") };
    if (not Principal.equal(o.owner, caller)) return #err("only the owner may cancel");
    if (o.window != currentWindow) return #err("order is in a closed/clearing window - cannot cancel");
    switch (o.status) { case (#Open or #PartiallyFilled) {}; case (_) return #err("order is not cancellable") };
    // release the remaining reservation
    switch (o.side) {
      case (#sell) subN(reservedShares, o.owner, o.remaining);
      case (#buy) releaseBid(o, 0, 0);
    };
    unindexLive(o);
    o.status := #Cancelled;
    o.remaining := 0;
    #ok("cancelled; reservation released");
  };

  // ── B+C. Clear the open window: compute p*, then chunked plan-then-apply under the budget ────
  public shared ({ caller }) func clearWindow() : async Result.Result<T.ClearResult, Text> {
    requireAuth(caller);
    if (not isAgent(caller)) return #err("only the clearing agent closes and clears a window");
    let w = currentWindow;
    switch (Map.get(pendingClears, Nat.compare, w)) { case (?_) return #err("window already being cleared"); case null {} };

    // snapshot the resting orders of window w (read-only projection for the pure clearing math)
    let allL = List.empty<L.BookOrderA>();
    for ((_, o) in Map.entries(orders)) {
      if (o.window == w and o.remaining > 0 and (o.status == #Open or o.status == #PartiallyFilled)) {
        List.add(allL, { id = o.id; limitPrice = o.limitPrice; qty = o.remaining; aon = o.allOrNone; isBid = (o.side == #buy) });
      };
    };
    let allA = List.toArray(allL);

    // close window w - new submits now land in w+1 (orders arriving during the chunking gap, M3)
    currentWindow += 1;

    // Kill-before-mutate (M2): the read-only AON fixpoint computes p* over SURVIVORS + the KILL set
    // WITHOUT touching any book. The rejected FOK orders are then killed (reservation released, status
    // Cancelled): no fill is ever applied for a FOK that cannot fully fill.
    let aon = L.clearAON(allA);
    for (vid in aon.killed.vals()) killOrder(vid);

    switch (aon.pStar) {
      case null {
        reenqueue(w);  // no cross - all (surviving) rest forward to the now-open window, original ids preserved
        #ok({ window = w; clearingPrice = null; targetVolume = 0; fillsThisCall = 0; totalFilled = 0; complete = true; chunks = 0; note = "no cross this window" });
      };
      case (?pStar) {
        // survivors = snapshot minus killed FOK orders
        let survivors = Array.filter<L.BookOrderA>(allA, func o = not memNat(aon.killed, o.id));
        let bidsS = Array.map<L.BookOrderA, L.BookOrder>(Array.filter<L.BookOrderA>(survivors, func o = o.isBid), func o = { id = o.id; limitPrice = o.limitPrice; qty = o.qty });
        let asksS = Array.map<L.BookOrderA, L.BookOrder>(Array.filter<L.BookOrderA>(survivors, func o = not o.isBid), func o = { id = o.id; limitPrice = o.limitPrice; qty = o.qty });
        let eb = L.eligibleBids(bidsS, pStar);
        let ea = L.eligibleAsks(asksS, pStar);
        let V = L.targetVolume(bidsS, asksS, pStar);
        let pc : T.PendingClear = {
          window = w; clearingPrice = pStar; eligBids = eb; eligAsks = ea; targetVolume = V;
          var i = 0; var j = 0; var carryBid = 0; var carryAsk = 0; var filled = 0; createdAt = now64();
        };
        Map.add(pendingClears, Nat.compare, w, pc);
        Map.add(chunkCounts, Nat.compare, w, 0);
        #ok(driveChunk<system>(w, pc));
      };
    };
  };

  // Resume a chunked clear (public so a test can drive chunks deterministically; the Timer also
  // calls it for autonomous resume). Idempotent and safe: it only advances the FIXED schedule.
  public shared ({ caller }) func continueClear(window : Nat) : async Result.Result<T.ClearResult, Text> {
    if (not (Principal.equal(caller, selfPrincipal) or isAgent(caller))) return #err("only the clearing agent or the engine's own timer resumes a clear");
    switch (Map.get(pendingClears, Nat.compare, window)) {
      case null #err("no pending clear for window " # Nat.toText(window));
      case (?pc) #ok(driveChunk<system>(window, pc));
    };
  };

  // Run ONE chunk (perf-counter-gated), apply its bounded fill slice atomically, then either
  // finalize (re-enqueue remainders) or arm a Timer to resume next round.
  func driveChunk<system>(w : Nat, pc : T.PendingClear) : T.ClearResult {
    let start = Prim.performanceCounter(0);
    var n = 0;
    var complete = false;
    // Budget is checked AFTER applying each fill so every chunk makes >= 1 fill of progress -
    // a pathologically small budget can never livelock (it just yields one fill per chunk).
    label loop_ while (true) {
      let st = L.step(pc.eligBids, pc.eligAsks, pc.clearingPrice, pc.targetVolume, pc.i, pc.j, pc.carryBid, pc.carryAsk, pc.filled);
      switch (st.fill) {
        case null { complete := true; break loop_ };
        case (?fl) {
          applyFill(pc, fl);                 // atomic book mutation + reservation release + obligation
          pc.i := st.i; pc.j := st.j; pc.carryBid := st.carryBid; pc.carryAsk := st.carryAsk; pc.filled := st.filled;
          n += 1;
        };
      };
      // fill-count bound (operative): fills/chunk cap. Instruction bound: the budget. Either ends the chunk.
      if (n >= MAX_FILLS_PER_CHUNK or Prim.performanceCounter(0) - start > MATCH_INSTR_BUDGET) { complete := false; break loop_ };
    };
    Map.add(chunkCounts, Nat.compare, w, cidN(chunkCounts, w) + 1);
    if (complete) {
      finalizeClear(pc);
    } else {
      ignore Timer.setTimer<system>(#seconds 0, func() : async () { ignore await continueClear(w) });
    };
    {
      window = w; clearingPrice = ?pc.clearingPrice; targetVolume = pc.targetVolume;
      fillsThisCall = n; totalFilled = pc.filled; complete; chunks = cidN(chunkCounts, w);
      note = if (complete) "clear complete" else "budget exhausted - Timer resumes (chunk " # Nat.toText(cidN(chunkCounts, w)) # ")";
    };
  };

  // Apply one micro-fill: mutate the book, release the consumed reservation, emit the obligation.
  // Synchronous (no await) ⇒ deterministic, no interleaving ⇒ a chunk's slice is all-or-nothing.
  func applyFill(pc : T.PendingClear, fl : T.Fill) {
    let buy = switch (Map.get(orders, Nat.compare, fl.buyId)) { case (?o) o; case null { logInv("applyFill: missing buy " # Nat.toText(fl.buyId)); return } };
    let sell = switch (Map.get(orders, Nat.compare, fl.sellId)) { case (?o) o; case null { logInv("applyFill: missing sell " # Nat.toText(fl.sellId)); return } };
    if (buy.remaining < fl.qty or sell.remaining < fl.qty) { logInv("applyFill: overfill guard buy=" # Nat.toText(fl.buyId) # " sell=" # Nat.toText(fl.sellId)); return };
    buy.remaining -= fl.qty;
    sell.remaining -= fl.qty;
    releaseBid(buy, fl.qty, buy.remaining);                    // exactly what the bid held for this fill (AU-02)
    subN(reservedShares, sell.owner, fl.qty);
    buy.status := (if (buy.remaining == 0) #Filled else #PartiallyFilled);
    sell.status := (if (sell.remaining == 0) #Filled else #PartiallyFilled);
    if (buy.remaining == 0) unindexLive(buy);
    if (sell.remaining == 0) unindexLive(sell);
    let ob : T.Obligation = {
      seq = nextObligationSeq; window = pc.window;
      buyId = fl.buyId; sellId = fl.sellId; buyer = buy.owner; seller = sell.owner;
      price = pc.clearingPrice; qty = fl.qty; var dvpTradeId = null; var settled = false;
    };
    List.add(obligations, ob);
    windowObligations(pc.window, ob.seq);
    nextObligationSeq += 1;
  };

  // Finalize a completed clear: re-enqueue every not-fully-filled order of window w into the now-open
  // window, PRESERVING its original id (price-time priority) - M3.
  func finalizeClear(pc : T.PendingClear) {
    reenqueue(pc.window);
    ignore Map.delete(pendingClears, Nat.compare, pc.window);
  };

  // Re-enqueue all resting (Open/PartiallyFilled, remaining>0) orders of window w into currentWindow,
  // keeping their original id. New gap-arrivals already hold LARGER ids ⇒ within equal price the
  // remainder still sorts ahead (its earlier time) but never JUMPS the queue - priority preserved.
  func reenqueue(w : Nat) {
    let movers = List.empty<T.Order>();
    for ((_, o) in Map.entries(orders)) {
      if (o.window == w and o.remaining > 0 and (o.status == #Open or o.status == #PartiallyFilled)) List.add(movers, o);
    };
    for (o in List.values(movers)) {
      let moved : T.Order = {
        id = o.id; owner = o.owner; side = o.side; limitPrice = o.limitPrice; qty = o.qty;
        var remaining = o.remaining; window = currentWindow; allOrNone = o.allOrNone;
        var status = o.status; createdAt = o.createdAt;
      };
      Map.add(orders, Nat.compare, o.id, moved);
    };
  };

  // ── D. Settlement linkage. The engine links an obligation to its DvP trade only from the core's own reply to
  // `settleMatchFor` (settleOneObligation below). The former `recordSettlement`, which let any authenticated caller
  // mark any obligation settled under any trade id and so stop its settlement for ever (AU-01), is removed.

  func windowObligations(w : Nat, seq : Nat) {
    let l = switch (Map.get(obligationsByWindow, Nat.compare, w)) { case (?l) l; case null { let l = List.empty<Nat>(); Map.add(obligationsByWindow, Nat.compare, w, l); l } };
    List.add(l, seq);
  };

  func obligationAt(seq : Nat) : ?T.Obligation { if (seq < List.size(obligations)) ?List.at(obligations, seq) else null };

  // ── B (P4): autonomous atomic settlement - drive a cleared obligation through the core's additive
  // authorized-relayer entrypoint. The engine (as the controller-set relayer) calls settleMatchFor;
  // the core escrows shares from the seller + cash from the buyer (both pre-approved the core at
  // intake) and pays shares→buyer + cash→seller, both-or-neither, in one block, NO trader action.
  // Idempotent end-to-end: the core keys on the obligation `seq`, so a re-call re-drives the SAME
  // trade and never double-settles.
  // The engine's own `settled` flag is never trusted to skip the core: the core keys a matched settlement on the
  // obligation's sequence and pays nothing twice (INV-DVP-5), so asking it again for a settled obligation returns
  // the same trade, and an obligation whose flag was set by anything but the core's reply (AU-01, on an engine that
  // ran the removed `recordSettlement`) is settled for real.
  // An `async*` helper, run inline in the message that calls it (AU-09). A private `async` function is a message to the
  // engine itself; on a chain where nested asynchrony is not active, the calling message takes the helper's reply as
  // its own and its continuation does not run, so `settleMatched` would return the helper's text without moving its
  // cursor or arming the next timer, and the window would stop settling after its first obligation.
  func settleOneObligation(ob : T.Obligation, deadlineSecs : Nat) : async* Result.Result<Text, Text> {
    let cashAmount = ob.price * ob.qty;
    let r = try {
      await dvpCoreActor().settleMatchFor({
        matchSeq = ob.seq; maker = ob.seller; taker = ob.buyer;
        assetLedger = sharesLedger; assetAmount = ob.qty;
        cashLedger; cashAmount; deadlineSecs;
      })
    } catch (_) { return #err("settleMatchFor call to DvP core trapped/unreachable") };
    switch (r) {
      case (#ok(res)) {
        // record the linkage regardless (the trade now exists); mark settled only when the core
        // confirms the atomic swap committed (status Settled ⇒ both legs paid).
        ob.dvpTradeId := ?res.tradeId;
        if (res.status == #Settled) {
          ob.settled := true;
          #ok("obligation " # Nat.toText(ob.seq) # " SETTLED via DvP trade " # Nat.toText(res.tradeId) # " (" # res.note # ")");
        } else {
          #err("obligation " # Nat.toText(ob.seq) # " not yet settled - DvP trade " # Nat.toText(res.tradeId) # ": " # res.note);
        };
      };
      case (#err(e)) {
        Map.add(refusedObligations, Nat.compare, ob.seq, e);
        #err("core rejected settleMatchFor for obligation " # Nat.toText(ob.seq) # ": " # e)
      };
    };
  };

  // Settle ONE obligation by seq (authenticated; settlement of a cleared match is deterministic and
  // safe to trigger by anyone - the obligation's parties/price/qty are immutable).
  public shared ({ caller }) func settleObligation(seq : Nat, deadlineSecs : Nat) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (deadlineSecs == 0) return #err("deadlineSecs must be > 0");
    switch (obligationAt(seq)) { case (?ob) await* settleOneObligation(ob, deadlineSecs); case null #err("no such obligation seq " # Nat.toText(seq)) };
  };

  // Autonomous batch settle of a window: one obligation a message (a message drives at most one settlement on
  // Thebes), the next armed by a timer, from a cursor over the window's own obligations (AU-05: no scan of every
  // obligation). An obligation the core refuses is recorded with the core's reason and the cursor moves past it, so
  // a refusal can never re-arm the timer on the same obligation for ever; `settleObligation` re-drives one by hand.
  public shared ({ caller }) func settleMatched(window : Nat, deadlineSecs : Nat) : async Result.Result<{ settledThisCall : Bool; remaining : Nat; note : Text }, Text> {
    requireAuth(caller);
    if (deadlineSecs == 0) return #err("deadlineSecs must be > 0");
    let l = switch (Map.get(obligationsByWindow, Nat.compare, window)) { case (?l) l; case null return #ok({ settledThisCall = false; remaining = 0; note = "no obligations in window " # Nat.toText(window) }) };
    var k = cidN(settleCursor, window);
    // skip what is already settled or refused
    label skip while (k < List.size(l)) {
      let seq = List.at(l, k);
      switch (obligationAt(seq)) { case (?ob) { if (not ob.settled and not Map.containsKey(refusedObligations, Nat.compare, seq)) break skip }; case null {} };
      k += 1;
    };
    Map.add(settleCursor, Nat.compare, window, k);
    if (k >= List.size(l)) return #ok({ settledThisCall = false; remaining = 0; note = "no unsettled obligations in window " # Nat.toText(window) });
    let ob = switch (obligationAt(List.at(l, k))) { case (?o) o; case null Runtime.trap("window index names a missing obligation") };
    let r = await* settleOneObligation(ob, deadlineSecs);
    // the cursor moves past a settled or a refused obligation; one left pending (a ledger that did not answer) is
    // tried again by the next message
    if (ob.settled or Map.containsKey(refusedObligations, Nat.compare, ob.seq)) Map.add(settleCursor, Nat.compare, window, k + 1);
    let rem : Nat = List.size(l) - cidN(settleCursor, window);
    if (rem > 0) ignore Timer.setTimer<system>(#seconds 0, func() : async () { ignore await settleMatched(window, deadlineSecs) });
    let note = switch (r) { case (#ok(n)) n; case (#err(e)) e };
    let ok = switch (r) { case (#ok(_)) true; case (#err(_)) false };
    #ok({ settledThisCall = ok; remaining = rem; note });
  };

  // ── The installer's settings ──────────────────────────────────────────────────────────────────────────
  public shared ({ caller }) func setClearingAgent(agent : Principal) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not Principal.equal(caller, installer)) return #err("only the installer names the clearing agent");
    clearingAgent := ?agent;
    #ok("clearing agent set to " # Principal.toText(agent))
  };

  // The lot, checked against both ledgers' fees as they are now (AU-08).
  public shared ({ caller }) func setLotSize(lot : Nat) : async Result.Result<Text, Text> {
    requireAuth(caller);
    if (not Principal.equal(caller, installer)) return #err("only the installer sets the lot");
    let fa = try { await sharesL().icrc1_fee() } catch (_) { return #err("shares ledger unreachable") };
    let fc = try { await cashL().icrc1_fee() } catch (_) { return #err("cash ledger unreachable") };
    if (lot <= fa) return #err("the lot must exceed the shares ledger fee (" # Nat.toText(fa) # ")");
    lotSize := lot; assetFeeAtLot := fa; cashFeeAtLot := fc;
    #ok("lot " # Nat.toText(lot) # " (shares fee " # Nat.toText(fa) # ", cash fee " # Nat.toText(fc) # ")")
  };

  // ── Queries ──────────────────────────────────────────────────────────────────────────────────
  public query func config() : async { sharesLedger : Principal; cashLedger : Principal; dvpCore : Principal; matchingEngine : Principal; budget : Nat64; maxFillsPerChunk : Nat; listingRegistry : ?Principal } {
    { sharesLedger; cashLedger; dvpCore; matchingEngine = selfPrincipal; budget = MATCH_INSTR_BUDGET; maxFillsPerChunk = MAX_FILLS_PER_CHUNK; listingRegistry };
  };
  public query func enginePrincipal() : async Principal { selfPrincipal };
  public query func getCurrentWindow() : async Nat { currentWindow };
  // An order is read by its owner or by the clearing agent (AU-05). Every read scoped to its caller is an update call:
  // the Thebes node binary takes a query's caller from the request's unsigned `sender` field, so a query cannot
  // establish who is asking and a scope checked inside one does not restrict anything. An update's caller is the
  // signer of its ingress message.
  public shared ({ caller }) func getOrder(id : Nat) : async ?T.OrderView {
    switch (Map.get(orders, Nat.compare, id)) { case (?o) { if (Principal.equal(o.owner, caller) or isAgent(caller)) ?T.orderView(o) else null }; case null null }
  };
  public query func orderCount() : async Nat { if (nextOrderId == 0) 0 else nextOrderId - 1 };
  public query func obligationCount() : async Nat { List.size(obligations) };

  // Pages for the clearing agent (the venue's operator and the regulator's reader): at most MAX_PAGE rows a page.
  public shared ({ caller }) func ordersPage(fromId : Nat, limit : Nat) : async Result.Result<[T.OrderView], Text> {
    if (not isAgent(caller)) return #err("only the clearing agent reads every order");
    let out = List.empty<T.OrderView>();
    var id = Nat.max(fromId, 1);
    let stop = Nat.min(nextOrderId, id + Nat.min(limit, MAX_PAGE));
    while (id < stop) { switch (Map.get(orders, Nat.compare, id)) { case (?o) List.add(out, T.orderView(o)); case null {} }; id += 1 };
    #ok(List.toArray(out))
  };
  public shared ({ caller }) func obligationsPage(fromSeq : Nat, limit : Nat) : async Result.Result<[T.ObligationView], Text> {
    if (not isAgent(caller)) return #err("only the clearing agent reads every obligation");
    let out = List.empty<T.ObligationView>();
    var k = fromSeq;
    let stop = Nat.min(List.size(obligations), fromSeq + Nat.min(limit, MAX_PAGE));
    while (k < stop) { List.add(out, T.obligationView(List.at(obligations, k))); k += 1 };
    #ok(List.toArray(out))
  };
  public shared ({ caller }) func refusedObligation(seq : Nat) : async ?Text {
    if (not isAgent(caller)) return null;
    Map.get(refusedObligations, Nat.compare, seq)
  };
  public query func lot() : async { lot : Nat; assetFee : Nat; cashFee : Nat } { { lot = lotSize; assetFee = assetFeeAtLot; cashFee = cashFeeAtLot } };
  public query func clearingAgentPrincipal() : async ?Principal { clearingAgent };

  public query func pendingClearStatus(w : Nat) : async ?{ window : Nat; clearingPrice : Nat; targetVolume : Nat; filled : Nat; i : Nat; j : Nat; chunks : Nat } {
    switch (Map.get(pendingClears, Nat.compare, w)) {
      case (?pc) ?{ window = pc.window; clearingPrice = pc.clearingPrice; targetVolume = pc.targetVolume; filled = pc.filled; i = pc.i; j = pc.j; chunks = cidN(chunkCounts, w) };
      case null null;
    };
  };
  // A reservation is read by its owner or by the clearing agent (AU-05).
  public shared ({ caller }) func reservationOf(p : Principal) : async ?{ shares : Nat; cash : Nat } {
    if (not (Principal.equal(caller, p) or isAgent(caller))) return null;
    ?{ shares = getN(reservedShares, p); cash = getN(reservedCash, p) }
  };
  // chunk-messages used to clear window w (persists after finalize) - proof of K>=2 chunking (M5).
  public query func chunksUsed(w : Nat) : async Nat { cidN(chunkCounts, w) };
  public shared ({ caller }) func invariantLog() : async [Text] { if (isAgent(caller)) List.toArray(invLog) else [] };
  public shared ({ caller }) func killLogPage(from : Nat, limit : Nat) : async [Text] {
    if (not isAgent(caller)) return [];
    let out = List.empty<Text>();
    var k = from;
    let stop = Nat.min(List.size(killLog), from + Nat.min(limit, MAX_PAGE));
    while (k < stop) { List.add(out, List.at(killLog, k)); k += 1 };
    List.toArray(out)
  };

  // Obligations as text for byte comparison across runs ("buyId>sellId@price:qty;"), a page at a time.
  public shared ({ caller }) func obligationSummaryPage(fromSeq : Nat, limit : Nat) : async Text {
    if (not isAgent(caller)) return "";
    var s = "";
    var k = fromSeq;
    let stop = Nat.min(List.size(obligations), fromSeq + Nat.min(limit, MAX_PAGE));
    while (k < stop) { let b = List.at(obligations, k); s #= Nat.toText(b.buyId) # ">" # Nat.toText(b.sellId) # "@" # Nat.toText(b.price) # ":" # Nat.toText(b.qty) # ";"; k += 1 };
    s
  };

  // The indexes the fixes added cover the orders and obligations made before them: built once, at the first
  // upgrade to this code. Bounded by the book that exists at that moment.
  system func postupgrade() {
    if (indexesBuilt) return;
    for ((_, o) in Map.entries(orders)) {
      if (o.remaining > 0 and (o.status == #Open or o.status == #PartiallyFilled)) indexLive(o);
    };
    for (ob in List.values(obligations)) windowObligations(ob.window, ob.seq);
    indexesBuilt := true;
  };
};
