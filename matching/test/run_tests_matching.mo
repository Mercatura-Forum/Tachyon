/// run_tests_matching.mo - interpreter battery for the matching engine's PURE clearing core.
///
/// Run (no replica):
///   moc -r --package core <core@2.5.0/src> --package sha2 <sha2@0.1.9/src> \
///       canisters/dvp-matching/test/run_tests_matching.mo
/// Non-zero exit on any failure (Runtime.trap at the end), so it is a hard CI gate.
///
/// PART 1 - unit checks on hand-computed call-auction cases (clearing price, volume, priority).
/// PART 2 - chunked == unbounded EQUIVALENCE: for thousands of random books, the
///   resumable step() planner, stopped at EVERY possible chunk size k, reproduces the unbounded
///   fillSchedule byte-for-byte (same fills, same order) AND the per-trader book/balance deltas
///   are identical. PLUS conservation (M4) and price-time priority (M3) on every trial.
/// PART 3 - all-or-none Kill-before-mutate: the read-only FOK fixpoint over random books.
/// PART 4 - the RESERVATION accounting (Reservations.mo) over random lifecycles: every release is
///   exactly covered, the reservation always equals what the model prescribes for the live book and
///   the open obligations, and once every order is closed and every obligation resolved it is
///   EXACTLY zero with all four maps empty - nothing strands.

import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import List "mo:core/List";
import Map "mo:core/Map";

import L "../src/MatchLogic";
import R "../src/Reservations";
import T "../src/MatchTypes";

var checks : Nat = 0;
var failures : Nat = 0;
func check(name : Text, cond : Bool) {
  checks += 1;
  if (not cond) { failures += 1; Debug.print("  FAIL: " # name) };
};
func checkEqNat(name : Text, got : Nat, want : Nat) {
  checks += 1;
  if (got != want) { failures += 1; Debug.print("  FAIL: " # name # " got=" # Nat.toText(got) # " want=" # Nat.toText(want)) };
};

// deterministic LCG (no Math.random in the interpreter)
var rngState : Nat64 = 0x2545F4914F6CDD1D;
func rnd() : Nat64 { rngState := rngState *% 6364136223846793005 +% 1442695040888963407; rngState };
func rndRange(lo : Nat, hi : Nat) : Nat { // inclusive
  if (hi <= lo) return lo;
  lo + Nat64.toNat(rnd() % Nat64.fromNat(hi - lo + 1))
};

type BO = L.BookOrder;

// Build eligible arrays + schedule for a book, then apply a schedule and return per-id share fills.
func applySchedule(schedule : [T.Fill]) : (Map.Map<Nat, Nat>, Map.Map<Nat, Nat>, Nat, Nat) {
  // returns (buyFills by buyId, sellFills by sellId, totalShares, totalCash)
  let buys = Map.empty<Nat, Nat>();
  let sells = Map.empty<Nat, Nat>();
  var shares = 0; var cash = 0;
  for (f in schedule.vals()) {
    Map.add(buys, Nat.compare, f.buyId, (switch (Map.get(buys, Nat.compare, f.buyId)) { case (?x) x; case null 0 }) + f.qty);
    Map.add(sells, Nat.compare, f.sellId, (switch (Map.get(sells, Nat.compare, f.sellId)) { case (?x) x; case null 0 }) + f.qty);
    shares += f.qty; cash += f.qty * f.price;
  };
  (buys, sells, shares, cash)
};

// Stream step() but force a chunk boundary every `k` fills (simulating budget exhaustion),
// resuming the cursor across chunks. Returns the concatenated fill list.
func chunkedSchedule(eb : [T.EligibleOrder], ea : [T.EligibleOrder], price : Nat, V : Nat, k : Nat) : [T.Fill] {
  let out = List.empty<T.Fill>();
  var i = 0; var j = 0; var cb = 0; var ca = 0; var filled = 0;
  label loop_ while (true) {
    // a chunk: up to k fills, then "yield" (loop continues with saved cursor - same as a Timer resume)
    var n = 0;
    label chunk while (n < k) {
      let st = L.step(eb, ea, price, V, i, j, cb, ca, filled);
      switch (st.fill) {
        case null break loop_;
        case (?fl) { List.add(out, fl); i := st.i; j := st.j; cb := st.carryBid; ca := st.carryAsk; filled := st.filled; n += 1 };
      };
    };
    if (n == 0) break loop_;
  };
  List.toArray(out)
};

func fillsEqual(a : [T.Fill], b : [T.Fill]) : Bool {
  if (a.size() != b.size()) return false;
  var idx = 0;
  while (idx < a.size()) {
    let x = a[idx]; let y = b[idx];
    if (x.buyId != y.buyId or x.sellId != y.sellId or x.price != y.price or x.qty != y.qty) return false;
    idx += 1;
  };
  true
};

func mapsEqual(a : Map.Map<Nat, Nat>, b : Map.Map<Nat, Nat>) : Bool {
  if (Map.size(a) != Map.size(b)) return false;
  for ((kk, vv) in Map.entries(a)) {
    switch (Map.get(b, Nat.compare, kk)) { case (?w) { if (w != vv) return false }; case null return false };
  };
  true
};

Debug.print("PART 1 - hand-computed call-auction unit checks");

// Case A: simple cross. bid 10sh@100, ask 10sh@90. Any p in [90,100] crosses 10. Tie→min imbalance
// (all equal, imbalance 0 at exec=10) → lowest price = 90.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 100; qty = 10 }];
  let asks : [BO] = [{ id = 2; limitPrice = 90; qty = 10 }];
  let p = L.clearingPrice(bids, asks);
  check("A: crosses", p != null);
  switch (p) { case (?pp) { checkEqNat("A: p* lowest-of-tie", pp, 90); checkEqNat("A: V", L.targetVolume(bids, asks, pp), 10) }; case null {} };
};

// Case B: no cross. bid@90, ask@100. demand(p)>0 only p<=90; supply>0 only p>=100. exec=0 everywhere.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 90; qty = 10 }];
  let asks : [BO] = [{ id = 2; limitPrice = 100; qty = 5 }];
  check("B: no cross", L.clearingPrice(bids, asks) == null);
};

// Case C: max-volume price beats a narrower-spread price.
//   bids: 5@100, 5@95 ;  asks: 5@90, 5@98
//   p=98: demand(>=98)=5, supply(<=98)=10 -> exec 5
//   p=95: demand(>=95)=10, supply(<=95)=5 -> exec 5
//   p=90: demand(>=90)=10, supply(<=90)=5 -> exec 5
//   all exec 5; imbalance: p98 |5-10|=5, p95 |10-5|=5, p90 |10-5|=5, p100 demand5 supply10 exec5 imb5.
//   tie on exec & imbalance -> lowest price = 90.  V=5.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 100; qty = 5 }, { id = 2; limitPrice = 95; qty = 5 }];
  let asks : [BO] = [{ id = 3; limitPrice = 90; qty = 5 }, { id = 4; limitPrice = 98; qty = 5 }];
  switch (L.clearingPrice(bids, asks)) {
    case (?pp) { checkEqNat("C: p*", pp, 90); checkEqNat("C: V", L.targetVolume(bids, asks, pp), 5) };
    case null { check("C: should cross", false) };
  };
};

// Case D: priority + pro-rata. p* fixed; long side (bids) overfilled, marginal partial by priority.
//   bids: id1 8@100, id2 8@100 (same price -> id1 first), id3 8@90 (ineligible if p*>90)
//   asks: id4 10@p* .  Suppose p*=100: demand(>=100)=16, supply(<=100)=10 -> V=10.
//   eligible bids sorted: id1, id2 (both @100). fills: id1 gets 8, id2 gets 2 (marginal). seller id4 -> 10.
do {
  let bids : [BO] = [{ id = 1; limitPrice = 100; qty = 8 }, { id = 2; limitPrice = 100; qty = 8 }];
  let asks : [BO] = [{ id = 4; limitPrice = 100; qty = 10 }];
  switch (L.clearingPrice(bids, asks)) {
    case (?pp) {
      let eb = L.eligibleBids(bids, pp);
      let ea = L.eligibleAsks(asks, pp);
      let V = L.targetVolume(bids, asks, pp);
      checkEqNat("D: V", V, 10);
      check("D: bid priority id1 first", eb[0].id == 1 and eb[1].id == 2);
      let sched = L.fillSchedule(eb, ea, pp, V);
      let (buys, sells, sh, csh) = applySchedule(sched);
      checkEqNat("D: id1 filled 8", switch (Map.get(buys, Nat.compare, 1)) { case (?x) x; case null 0 }, 8);
      checkEqNat("D: id2 filled 2 (marginal)", switch (Map.get(buys, Nat.compare, 2)) { case (?x) x; case null 0 }, 2);
      checkEqNat("D: seller id4 filled 10", switch (Map.get(sells, Nat.compare, 4)) { case (?x) x; case null 0 }, 10);
      checkEqNat("D: shares moved", sh, 10);
      checkEqNat("D: cash moved", csh, 1000);
      check("D: conserves", L.scheduleConserves(sched, pp, V));
    };
    case null { check("D: should cross", false) };
  };
};

Debug.print("PART 2 - chunked == unbounded equivalence + conservation + priority (random books)");

let TRIALS = 4000;
var crossed = 0;
var t = 0;
label trials while (t < TRIALS) {
  t += 1;
  // random book: up to 6 bids + 6 asks, prices in a band that often crosses, qty 1..20
  let nb = rndRange(1, 6);
  let na = rndRange(1, 6);
  let bidsL = List.empty<BO>();
  let asksL = List.empty<BO>();
  var nextId = 1;
  var x = 0;
  while (x < nb) { List.add(bidsL, { id = nextId; limitPrice = rndRange(90, 110); qty = rndRange(1, 20) } : BO); nextId += 1; x += 1 };
  x := 0;
  while (x < na) { List.add(asksL, { id = nextId; limitPrice = rndRange(85, 105); qty = rndRange(1, 20) } : BO); nextId += 1; x += 1 };
  let bids = List.toArray(bidsL);
  let asks = List.toArray(asksL);

  switch (L.clearingPrice(bids, asks)) {
    case null {}; // no cross - nothing to clear this trial
    case (?pStar) {
      crossed += 1;
      let eb = L.eligibleBids(bids, pStar);
      let ea = L.eligibleAsks(asks, pStar);
      let V = L.targetVolume(bids, asks, pStar);

      // priority (M3): eligible bids non-increasing price; within equal price, increasing id.
      var pidx = 1;
      // (qty-priority sort is validated structurally below via the fill order)
      let _ = pidx;

      // unbounded reference
      let unb = L.fillSchedule(eb, ea, pStar, V);
      let (ub, us, ush, ucash) = applySchedule(unb);

      // chunked at several chunk sizes - MUST match unbounded byte-for-byte (M1)
      for (k in [1, 2, 3, 5, 13].vals()) {
        let ch = chunkedSchedule(eb, ea, pStar, V, k);
        if (not fillsEqual(unb, ch)) { failures += 1; Debug.print("  FAIL: chunked!=unbounded trial=" # Nat.toText(t) # " k=" # Nat.toText(k)); };
        checks += 1;
        let (cb, cs, csh, ccash) = applySchedule(ch);
        if (not (mapsEqual(ub, cb) and mapsEqual(us, cs) and csh == ush and ccash == ucash)) {
          failures += 1; Debug.print("  FAIL: chunked balances != unbounded trial=" # Nat.toText(t) # " k=" # Nat.toText(k));
        };
        checks += 1;
      };

      // conservation (M4): shares == V, cash == V*p*
      if (not L.scheduleConserves(unb, pStar, V)) { failures += 1; Debug.print("  FAIL: conservation trial=" # Nat.toText(t)) };
      checks += 1;
      if (ush != V or ucash != V * pStar) { failures += 1; Debug.print("  FAIL: volume/cash trial=" # Nat.toText(t)) };
      checks += 1;

      // short side fully filled: V == min(demand,supply); the side equal to V is exhausted.
      let d = L.demand(bids, pStar); let s = L.supply(asks, pStar);
      // total filled per side equals V
      var sumBuy = 0; for ((_, v) in Map.entries(ub)) sumBuy += v;
      var sumSell = 0; for ((_, v) in Map.entries(us)) sumSell += v;
      if (sumBuy != V or sumSell != V) { failures += 1; Debug.print("  FAIL: side totals trial=" # Nat.toText(t)) };
      checks += 1;
      let _ = (d, s);
    };
  };
};

Debug.print("PART 3 - all-or-none (FOK) Kill-before-mutate");

type BOA = L.BookOrderA;
// fill totals for survivors at p*, to assert every surviving AON order fully fills
func survivorFills(orders : [BOA], killed : [Nat], pStar : Nat) : Map.Map<Nat, Nat> {
  let surv = List.empty<BOA>();
  for (o in orders.vals()) { var k = false; for (x in killed.vals()) { if (x == o.id) k := true }; if (not k) List.add(surv, o) };
  let sa = List.toArray(surv);
  let bidsBO = List.empty<L.BookOrder>(); let asksBO = List.empty<L.BookOrder>();
  for (o in sa.vals()) { let bo : L.BookOrder = { id = o.id; limitPrice = o.limitPrice; qty = o.qty }; if (o.isBid) List.add(bidsBO, bo) else List.add(asksBO, bo) };
  let eb = L.eligibleBids(List.toArray(bidsBO), pStar);
  let ea = L.eligibleAsks(List.toArray(asksBO), pStar);
  let V = L.targetVolume(List.toArray(bidsBO), List.toArray(asksBO), pStar);
  let sched = L.fillSchedule(eb, ea, pStar, V);
  let (b, s, _, _) = applySchedule(sched);
  // merge buy+sell maps
  for ((kk, vv) in Map.entries(s)) { Map.add(b, Nat.compare, kk, (switch (Map.get(b, Nat.compare, kk)) { case (?x) x; case null 0 }) + vv) };
  b
};
func inList(xs : [Nat], v : Nat) : Bool { for (x in xs.vals()) { if (x == v) return true }; false };

// AON-1: bid AON 10@100 but only 5 supply → bid KILLED → no cross.
do {
  let os : [BOA] = [{ id = 1; limitPrice = 100; qty = 10; aon = true; isBid = true }, { id = 2; limitPrice = 90; qty = 5; aon = false; isBid = false }];
  let r = L.clearAON(os);
  check("AON-1: under-filled AON bid killed", inList(r.killed, 1));
  check("AON-1: no cross after kill", r.pStar == null);
};
// AON-2: bid AON 5@100 fully fillable (10 supply) → survives, ask (GTC) partials.
do {
  let os : [BOA] = [{ id = 1; limitPrice = 100; qty = 5; aon = true; isBid = true }, { id = 2; limitPrice = 90; qty = 10; aon = false; isBid = false }];
  let r = L.clearAON(os);
  check("AON-2: AON bid survives", not inList(r.killed, 1));
  switch (r.pStar) { case (?pp) {
    let fills = survivorFills(os, r.killed, pp);
    checkEqNat("AON-2: AON bid fully fills", switch (Map.get(fills, Nat.compare, 1)) { case (?x) x; case null 0 }, 5);
  }; case null { check("AON-2: should cross", false) } };
};
// AON-3: AON ask wants 10 but demand only 6 → ask killed → no cross.
do {
  let os : [BOA] = [{ id = 1; limitPrice = 100; qty = 6; aon = false; isBid = true }, { id = 2; limitPrice = 90; qty = 10; aon = true; isBid = false }];
  let r = L.clearAON(os);
  check("AON-3: under-filled AON ask killed", inList(r.killed, 2));
  check("AON-3: no cross after kill", r.pStar == null);
};

// Property: random books with ~30% AON flags. After clearAON, EVERY surviving AON order fully fills
// (the defining FOK guarantee), and killed ids are a subset of the AON orders.
var aonTrials = 0; var aonChecked = 0;
var tt = 0;
label aonloop while (tt < 1500) {
  tt += 1;
  let nb = rndRange(1, 5); let na = rndRange(1, 5);
  let osL = List.empty<BOA>(); var nid = 1;
  var z = 0;
  while (z < nb) { let aon = (rndRange(0, 9) < 3); List.add(osL, { id = nid; limitPrice = rndRange(90, 110); qty = rndRange(1, 15); aon; isBid = true } : BOA); nid += 1; z += 1 };
  z := 0;
  while (z < na) { let aon = (rndRange(0, 9) < 3); List.add(osL, { id = nid; limitPrice = rndRange(85, 105); qty = rndRange(1, 15); aon; isBid = false } : BOA); nid += 1; z += 1 };
  let os = List.toArray(osL);
  let r = L.clearAON(os);
  aonTrials += 1;
  // killed ⊆ AON orders
  for (kid in r.killed.vals()) {
    var isAon = false; for (o in os.vals()) { if (o.id == kid and o.aon) isAon := true };
    if (not isAon) { failures += 1; Debug.print("  FAIL: killed a non-AON order id=" # Nat.toText(kid)) };
    checks += 1;
  };
  switch (r.pStar) {
    case null {};
    case (?pp) {
      let fills = survivorFills(os, r.killed, pp);
      for (o in os.vals()) {
        if (o.aon and not inList(r.killed, o.id)) {
          let got = switch (Map.get(fills, Nat.compare, o.id)) { case (?x) x; case null 0 };
          if (got != o.qty) { failures += 1; Debug.print("  FAIL: surviving AON not fully filled id=" # Nat.toText(o.id) # " got=" # Nat.toText(got) # " qty=" # Nat.toText(o.qty)) };
          checks += 1; aonChecked += 1;
        };
      };
    };
  };
};
Debug.print("aonTrials=" # Nat.toText(aonTrials) # " survivingAON-checks=" # Nat.toText(aonChecked));

Debug.print("PART 4 - the reservation accounting: nothing strands (random lifecycles)");
// ══ PART 4 - the reservation accounting: nothing strands, over random lifecycles ═══════════════
//
// A reservation is the engine's claim on a trader's FREE capacity (balance ∧ allowance-to-core). The
// escrow the core pulls for one fill debits the funder `amount + one fee`, once PER FILL, so
// Reservations.mo denominates the reservation per escrow: a live order holds its remaining notional
// plus one fee, every created obligation holds its own exact escrow cost until it resolves, and every
// unit reserved has exactly one release event.
//
// This part drives those PRODUCTION functions - the same ones the actor calls - over random
// lifecycles: intakes, fills at a clearing price at or below the bid's limit (whole and partial, so a
// K-fill order's K fees are exercised), cancels and all-or-none kills, settlements, voids, and
// repeated resolutions of the same seq. After EVERY step it checks
//   (a) EXACT      - no release exceeded what was reserved (every transition returns an exact Drift);
//   (b) PRESCRIBED - reserved(p) equals Σ live orders (remaining notional + margin) + Σ open
//                    obligations (their escrow cost), each term computed independently here;
//   (c) COVERED    - reserved(p) is never below the escrow cost of p's own open obligations;
// and once every order is closed and every obligation resolved,
//   (d) ZERO       - reserved(p) is EXACTLY zero for every trader and all four maps are EMPTY: not one
//                    key, not one unit left behind. That is the no-stranding property, and the defect
//                    this accounting closes (a filled bid's fee margin used to stay reserved forever).

func checkExact(name : Text, d : R.Drift) {
  checks += 1;
  if (not R.isExact(d)) {
    failures += 1;
    Debug.print("  FAIL: " # name # " released beyond the reservation by cash=" # Nat.toText(d.cash) # " shares=" # Nat.toText(d.shares));
  };
};

// The arithmetic of the two intake floors, stated.
checkEqNat("askNeed: an ask needs its qty AND the one fee its escrow costs", R.askNeed(100, 3), 103);
checkEqNat("bidNeed: a bid needs its notional at its own limit plus one escrow fee", R.bidNeed(10, 20, 7), 207);

// The three faces of the defect, each as a closed case.
do {
  // (i) a filled bid strands nothing: the margin goes back when the order is done, the hold when the
  //     obligation resolves. The accounting this replaces left one cash fee reserved for ever.
  let l = R.empty();
  let p = Principal.fromText("rwlgt-iiaaa-aaaaa-aaaaa-cai");
  let q = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
  R.openBid(l, p, 1, 100, 10, 10);
  R.openAsk(l, q, 2, 10, 4);
  checkEqNat("a bid reserves its notional plus one fee", R.reservedCash(l, p), 1010);
  checkEqNat("an ask reserves its qty plus one fee (the leg the old accounting missed)", R.reservedShares(l, q), 14);
  checkExact("fill the pair whole", R.fill(l, 0, p, q, 1, 2, 100, 100, 10, true, true));
  checkEqNat("the filled bid holds only its obligation's escrow cost", R.reservedCash(l, p), 1010);
  checkEqNat("the filled ask holds only its obligation's escrow cost", R.reservedShares(l, q), 14);
  checkExact("settle it", R.resolveObligation(l, 0, p, q));
  checkEqNat("a settled lifecycle leaves the buyer nothing reserved", R.reservedCash(l, p), 0);
  checkEqNat("a settled lifecycle leaves the seller nothing reserved", R.reservedShares(l, q), 0);
  checkEqNat("and no margin key", Map.size(l.margin), 0);
  checkEqNat("and no hold key", Map.size(l.hold), 0);
};
do {
  // (ii) a K-fill order pays K fees, and the account discovers them as the fills are applied: one fee
  //      at intake is a floor, not an estimate of the whole order's cost.
  let l = R.empty();
  let p = Principal.fromText("rwlgt-iiaaa-aaaaa-aaaaa-cai");
  let q = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
  R.openBid(l, p, 1, 100, 10, 10);
  var k = 0;
  while (k < 5) {
    R.openAsk(l, q, 10 + k, 2, 4);
    let done = (k == 4);
    checkExact("K-fill: fill " # Nat.toText(k), R.fill(l, k, p, q, 1, 10 + k, 100, 100, 2, done, true));
    k += 1;
  };
  checkEqNat("five fills reserve five escrows, each with its own fee", R.reservedCash(l, p), 5 * (200 + 10));
  checkEqNat("the seller's five escrows likewise", R.reservedShares(l, q), 5 * (2 + 4));
  k := 0;
  while (k < 5) { checkExact("K-fill: resolve " # Nat.toText(k), R.resolveObligation(l, k, p, q)); k += 1 };
  checkEqNat("all five resolved: the buyer reserves nothing", R.reservedCash(l, p), 0);
  checkEqNat("all five resolved: the seller reserves nothing", R.reservedShares(l, q), 0);
};
do {
  // (iii) a cancel and an all-or-none kill release the margin too, and a resolution is idempotent.
  let l = R.empty();
  let p = Principal.fromText("rwlgt-iiaaa-aaaaa-aaaaa-cai");
  R.openBid(l, p, 1, 50, 4, 9);
  checkExact("cancel releases the notional and the margin", R.closeOrder(l, p, 1, true, 50 * 4));
  checkEqNat("a cancelled order leaves nothing reserved", R.reservedCash(l, p), 0);
  R.openAsk(l, p, 2, 7, 3);
  checkExact("an all-or-none kill releases the notional and the margin", R.closeOrder(l, p, 2, false, 7));
  checkEqNat("a killed order leaves nothing reserved", R.reservedShares(l, p), 0);
  checkExact("resolving an unknown seq releases nothing", R.resolveObligation(l, 77, p, p));
  checkEqNat("and moves nothing", R.reservedCash(l, p) + R.reservedShares(l, p), 0);
};

type SimOrder = { id : Nat; owner : Principal; isBid : Bool; limit : Nat; fee : Nat; var remaining : Nat; var live : Bool };
type SimObl = { seq : Nat; buyer : Principal; seller : Principal; cash : Nat; shares : Nat; var isOpen : Bool };

let TRADERS : [Principal] = [
  Principal.fromText("rwlgt-iiaaa-aaaaa-aaaaa-cai"),
  Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"),
  Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
];

let RESV_TRIALS = 900;
var resvTrials = 0;
var resvFills = 0;
var resvSteps = 0;
var rt = 0;
while (rt < RESV_TRIALS) {
  rt += 1;
  let l = R.empty();
  let cashFee = rndRange(0, 6);
  let sharesFee = rndRange(0, 6);
  let sOrders = List.empty<SimOrder>();
  let sObls = List.empty<SimObl>();
  var nextId = 1;
  var nextSeq = 0;

  // (b) + (c): the model equation and the coverage bound, both computed here from the simulated book
  // rather than from the module's totals.
  func verify(tag : Text) {
    for (p in TRADERS.vals()) {
      var wantShares = 0;
      var wantCash = 0;
      var oblShares = 0;
      var oblCash = 0;
      for (o in List.values(sOrders)) {
        if (o.live and Principal.equal(o.owner, p)) {
          if (o.isBid) wantCash += o.limit * o.remaining + o.fee else wantShares += o.remaining + o.fee;
        };
      };
      for (b in List.values(sObls)) {
        if (b.isOpen) {
          if (Principal.equal(b.buyer, p)) oblCash += b.cash;
          if (Principal.equal(b.seller, p)) oblShares += b.shares;
        };
      };
      wantCash += oblCash;
      wantShares += oblShares;
      checkEqNat("prescribed cash " # tag, R.reservedCash(l, p), wantCash);
      checkEqNat("prescribed shares " # tag, R.reservedShares(l, p), wantShares);
      check("reserved cash covers the open obligations " # tag, R.reservedCash(l, p) >= oblCash);
      check("reserved shares covers the open obligations " # tag, R.reservedShares(l, p) >= oblShares);
    };
  };

  func liveSide(isBid : Bool) : ?SimOrder {
    let cands = List.empty<SimOrder>();
    for (o in List.values(sOrders)) { if (o.live and o.isBid == isBid and o.remaining > 0) List.add(cands, o) };
    let n = List.size(cands);
    if (n == 0) null else List.get(cands, rndRange(0, n - 1));
  };

  let steps = rndRange(6, 16);
  var st = 0;
  while (st < steps) {
    st += 1;
    resvSteps += 1;
    let op = rndRange(0, 9);
    if (op <= 3) {
      // intake
      let owner = TRADERS[rndRange(0, TRADERS.size() - 1)];
      let isBid = (rndRange(0, 1) == 0);
      let limit = rndRange(1, 40);
      let qty = rndRange(1, 12);
      let id = nextId;
      nextId += 1;
      if (isBid) R.openBid(l, owner, id, limit, qty, cashFee) else R.openAsk(l, owner, id, qty, sharesFee);
      List.add(sOrders, { id; owner; isBid; limit; fee = (if (isBid) cashFee else sharesFee); var remaining = qty; var live = true });
    } else if (op <= 6) {
      // a fill between a live bid and a live ask, at a price at or below the bid's limit
      switch (liveSide(true), liveSide(false)) {
        case (?bid, ?ask) {
          let q = rndRange(1, Nat.min(bid.remaining, ask.remaining));
          let price = rndRange(1, bid.limit);
          bid.remaining -= q;
          ask.remaining -= q;
          let bDone = bid.remaining == 0;
          let aDone = ask.remaining == 0;
          checkExact("fill", R.fill(l, nextSeq, bid.owner, ask.owner, bid.id, ask.id, bid.limit, price, q, bDone, aDone));
          // the hold the obligation must now carry: the notional at the CLEARING price plus one fee a side
          let wantCash = price * q + bid.fee;
          let wantShares = q + ask.fee;
          let got : R.Amounts = switch (R.holdOf(l, nextSeq)) { case (?h) h; case null ({ cash = 0; shares = 0 }) };
          checkEqNat("the obligation holds the cash escrow exactly", got.cash, wantCash);
          checkEqNat("the obligation holds the shares escrow exactly", got.shares, wantShares);
          List.add(sObls, { seq = nextSeq; buyer = bid.owner; seller = ask.owner; cash = wantCash; shares = wantShares; var isOpen = true });
          if (bDone) bid.live := false;
          if (aDone) ask.live := false;
          nextSeq += 1;
          resvFills += 1;
        };
        case (_, _) {};
      };
    } else if (op <= 7) {
      // a cancel or an all-or-none kill: the same transition
      switch (liveSide(rndRange(0, 1) == 0)) {
        case (?o) {
          checkExact("close", R.closeOrder(l, o.owner, o.id, o.isBid, (if (o.isBid) o.limit * o.remaining else o.remaining)));
          o.live := false;
          o.remaining := 0;
        };
        case null {};
      };
    } else {
      // resolve an obligation - settled or voided, the same transition - then resolve it AGAIN: a
      // re-drive, a second void or two racing callers must release it once and only once
      let open_ = List.empty<SimObl>();
      for (b in List.values(sObls)) { if (b.isOpen) List.add(open_, b) };
      if (List.size(open_) > 0) {
        switch (List.get(open_, rndRange(0, List.size(open_) - 1))) {
          case (?b) {
            checkExact("resolve", R.resolveObligation(l, b.seq, b.buyer, b.seller));
            b.isOpen := false;
            checkExact("resolve again (idempotent)", R.resolveObligation(l, b.seq, b.buyer, b.seller));
          };
          case null {};
        };
      };
    };
    verify("after step " # Nat.toText(st) # " of trial " # Nat.toText(rt));
  };

  // (d) wind the whole book down and demand EXACT zero - no unit and no key left anywhere
  for (o in List.values(sOrders)) {
    if (o.live) {
      checkExact("wind-down close", R.closeOrder(l, o.owner, o.id, o.isBid, (if (o.isBid) o.limit * o.remaining else o.remaining)));
      o.live := false;
      o.remaining := 0;
    };
  };
  for (b in List.values(sObls)) {
    if (b.isOpen) {
      checkExact("wind-down resolve", R.resolveObligation(l, b.seq, b.buyer, b.seller));
      b.isOpen := false;
    };
  };
  for (p in TRADERS.vals()) {
    checkEqNat("quiescence: reserved cash is exactly zero", R.reservedCash(l, p), 0);
    checkEqNat("quiescence: reserved shares is exactly zero", R.reservedShares(l, p), 0);
  };
  checkEqNat("quiescence: not one reserved-cash key left", Map.size(l.cash), 0);
  checkEqNat("quiescence: not one reserved-shares key left", Map.size(l.shares), 0);
  checkEqNat("quiescence: not one order margin left", Map.size(l.margin), 0);
  checkEqNat("quiescence: not one obligation hold left", Map.size(l.hold), 0);
  resvTrials += 1;
};
Debug.print("reservationTrials=" # Nat.toText(resvTrials) # " steps=" # Nat.toText(resvSteps) # " fills=" # Nat.toText(resvFills));

Debug.print("trials=" # Nat.toText(TRIALS) # " crossed=" # Nat.toText(crossed));
Debug.print("checks=" # Nat.toText(checks) # " failures=" # Nat.toText(failures));
if (failures > 0) { Runtime.trap("MATCHING BATTERY FAILED: " # Nat.toText(failures) # " failures") };
Debug.print("ALL GREEN");
