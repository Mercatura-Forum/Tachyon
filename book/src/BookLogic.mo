/// BookLogic.mo: the pure decisions of the book (book/SPEC.md §3, §6). No state, no clock, no await: the core and the
/// battery call these, and the Python reference book implements the same text with its own code.
///
///   collarPrice  a market order's price: on the tick, within the collar around the reference price (§6)
///   onTick       a price on its band's grid
///   auction      one instrument's batch: the clearing price (§3.1), who fills and how much (§3.2), the pairs (§3.3),
///                the fill-or-kill fixpoint (§3.4)
///
/// Attribution: Thebes Core Team.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";

import T "BookTypes";

module {

  // ─── ticks and collars ─────────────────────────────────────────────────────────────────────────────────────────
  public func tickAt(bands : [T.Band], price : Nat) : Nat {
    var t = bands[0].tick;
    for (b in bands.vals()) { if (b.fromPrice <= price) t := b.tick };
    t
  };
  public func onTick(bands : [T.Band], price : Nat) : Bool { price > 0 and price % tickAt(bands, price) == 0 };

  /// A market order's price (§6): a buy at the highest on-tick price at or below reference x (1 + collar); a sell at the
  /// lowest on-tick price at or above reference x (1 - collar), and never below the first tick.
  public func collarPrice(side : T.Side, reference : Nat, collarBps : Nat, bands : [T.Band]) : Nat {
    switch (side) {
      case (#buy) {
        let target = reference * (10_000 + collarBps) / 10_000;
        target - target % tickAt(bands, target)
      };
      case (#sell) {
        let num = reference * (if (collarBps >= 10_000) 0 else (10_000 - collarBps : Nat));
        var target = (num + 9_999) / 10_000;
        if (target == 0) target := 1;
        let t = tickAt(bands, target);
        let up = if (target % t == 0) target else target + (t - target % t);
        if (up == 0) t else up
      };
    }
  };

  // ─── the auction ───────────────────────────────────────────────────────────────────────────────────────────────
  /// One live order as the auction sees it.
  public type Bid = { id : T.OrderId; price : Nat; qty : Nat; prio : Nat64; key : Blob; fok : Bool };
  public type Result = {
    price : ?Nat;
    volume : Nat;
    /// (order, quantity filled), buys then sells, every order with a fill above zero.
    fills : [(T.OrderId, Nat)];
    /// (buy, sell, quantity), every pair at the price.
    pairs : [(T.OrderId, T.OrderId, Nat)];
    /// fill-or-kill orders removed because they could not fill entirely (§3.4)
    killed : [T.OrderId];
  };

  func demand(bids : [Bid], p : Nat) : Nat { var s = 0; for (b in bids.vals()) { if (b.price >= p) s += b.qty }; s };
  func supply(asks : [Bid], p : Nat) : Nat { var s = 0; for (a in asks.vals()) { if (a.price <= p) s += a.qty }; s };

  /// §3.1: among the orders' prices, the one that maximises min(demand, supply); ties to the least imbalance, then the
  /// lower price; null when nothing crosses.
  public func clearingPrice(bids : [Bid], asks : [Bid]) : ?Nat {
    var best : ?(Nat, Nat, Nat) = null;   // (price, executable, imbalance)
    func consider(p : Nat) {
      let d = demand(bids, p); let s = supply(asks, p);
      let ex = Nat.min(d, s);
      if (ex == 0) return;
      let imb = if (d > s) d - s else s - d;
      switch (best) {
        case null best := ?(p, ex, imb);
        case (?(bp, bex, bimb)) {
          if (ex > bex or (ex == bex and (imb < bimb or (imb == bimb and p < bp)))) best := ?(p, ex, imb)
        };
      };
    };
    for (b in bids.vals()) consider(b.price);
    for (a in asks.vals()) consider(a.price);
    switch (best) { case (?(p, _, _)) ?p; case null null }
  };

  func cmpKey(a : Blob, b : Blob) : Order.Order { Blob.compare(a, b) };

  /// §3.2 for the long side: whole price levels from the most aggressive while the volume lasts; at the level where it
  /// runs out, whole priority batches earliest first; in the batch where it runs out, pro rata in lots with the largest
  /// remainders (ties by key). `levels` are the long side's eligible orders, most aggressive first.
  func allocateLong(orders : [Bid], volume : Nat, lot : Nat, moreAggressive : (Nat, Nat) -> Bool) : Map.Map<T.OrderId, Nat> {
    let out = Map.empty<T.OrderId, Nat>();
    // the distinct prices, most aggressive first
    let prices = List.empty<Nat>();
    for (o in orders.vals()) { if (not List.contains(prices, Nat.equal, o.price)) List.add(prices, o.price) };
    let ps = Array.sort<Nat>(List.toArray(prices), func(a, b) { if (moreAggressive(a, b)) #less else if (moreAggressive(b, a)) #greater else #equal });
    var left = volume;
    label levels for (p in ps.vals()) {
      if (left == 0) break levels;
      let level = Array.filter<Bid>(orders, func(o) { o.price == p });
      var total = 0; for (o in level.vals()) total += o.qty;
      if (total <= left) { for (o in level.vals()) Map.add(out, Nat.compare, o.id, o.qty); left -= total; continue levels };
      // the level where the volume runs out: by priority batch
      let prios = List.empty<Nat64>();
      for (o in level.vals()) { if (not List.contains(prios, Nat64.equal, o.prio)) List.add(prios, o.prio) };
      let bs = Array.sort<Nat64>(List.toArray(prios), Nat64.compare);
      label batches for (pr in bs.vals()) {
        if (left == 0) break batches;
        let group = Array.filter<Bid>(level, func(o) { o.prio == pr });
        var g = 0; for (o in group.vals()) g += o.qty;
        if (g <= left) { for (o in group.vals()) Map.add(out, Nat.compare, o.id, o.qty); left -= g; continue batches };
        // pro rata in whole lots
        let leftLots = left / lot;
        let gLots = g / lot;
        var given = 0;
        let rems = List.empty<(Bid, Nat)>();   // (order, remainder of the division)
        for (o in group.vals()) {
          let qLots = o.qty / lot;
          let share = leftLots * qLots / gLots;
          if (share > 0) Map.add(out, Nat.compare, o.id, share * lot);
          given += share;
          List.add(rems, (o, leftLots * qLots % gLots));
        };
        var extra = leftLots - given;
        let order = Array.sort<(Bid, Nat)>(List.toArray(rems), func(a, b) {
          if (a.1 > b.1) #less else if (a.1 < b.1) #greater else cmpKey(a.0.key, b.0.key)
        });
        for ((o, _) in order.vals()) {
          if (extra > 0) {
            let had = switch (Map.get(out, Nat.compare, o.id)) { case (?x) x; case null 0 };
            if (had + lot <= o.qty) { Map.add(out, Nat.compare, o.id, had + lot); extra -= 1 };
          };
        };
        left := 0;
      };
      left := 0;
    };
    out
  };

  func sortForPairs(xs : [(Bid, Nat)], buy : Bool) : [(Bid, Nat)] {
    Array.sort<(Bid, Nat)>(xs, func(a, b) {
      if (a.0.price != b.0.price) { if (buy) (if (a.0.price > b.0.price) #less else #greater) else (if (a.0.price < b.0.price) #less else #greater) }
      else if (a.0.prio != b.0.prio) Nat64.compare(a.0.prio, b.0.prio)
      else cmpKey(a.0.key, b.0.key)
    })
  };

  func once(bids : [Bid], asks : [Bid], lot : Nat) : (?Nat, Nat, Map.Map<T.OrderId, Nat>) {
    let fills = Map.empty<T.OrderId, Nat>();
    switch (clearingPrice(bids, asks)) {
      case null (null, 0, fills);
      case (?p) {
        let eb = Array.filter<Bid>(bids, func(b) { b.price >= p });
        let ea = Array.filter<Bid>(asks, func(a) { a.price <= p });
        var d = 0; for (b in eb.vals()) d += b.qty;
        var s = 0; for (a in ea.vals()) s += a.qty;
        let v = Nat.min(d, s);
        if (d <= s) {
          for (b in eb.vals()) Map.add(fills, Nat.compare, b.id, b.qty);
          for ((id, q) in Map.entries(allocateLong(ea, v, lot, func(x, y) { x < y }))) Map.add(fills, Nat.compare, id, q);
        } else {
          for (a in ea.vals()) Map.add(fills, Nat.compare, a.id, a.qty);
          for ((id, q) in Map.entries(allocateLong(eb, v, lot, func(x, y) { x > y }))) Map.add(fills, Nat.compare, id, q);
        };
        (?p, v, fills)
      };
    }
  };

  /// One instrument's auction over its live orders (§3), with the fill-or-kill fixpoint (§3.4).
  public func auction(bids0 : [Bid], asks0 : [Bid], lot : Nat) : Result {
    var bids = bids0; var asks = asks0;
    let killed = List.empty<T.OrderId>();
    loop {
      let (p, v, fills) = once(bids, asks, lot);
      // a fill-or-kill order that does not fill entirely: remove the latest-priority one (greatest key on a tie)
      var victim : ?Bid = null;
      for (o in Array.concat(bids, asks).vals()) {
        if (o.fok) {
          let got = switch (Map.get(fills, Nat.compare, o.id)) { case (?x) x; case null 0 };
          if (got < o.qty) {
            switch (victim) {
              case null victim := ?o;
              case (?w) { if (o.prio > w.prio or (o.prio == w.prio and Blob.compare(o.key, w.key) == #greater)) victim := ?o };
            };
          };
        };
      };
      switch (victim) {
        case (?w) {
          List.add(killed, w.id);
          bids := Array.filter<Bid>(bids, func(b) { b.id != w.id });
          asks := Array.filter<Bid>(asks, func(a) { a.id != w.id });
        };
        case null {
          // the pairs (§3.3): each side in fill order, matched greedily
          let bf = List.empty<(Bid, Nat)>(); let af = List.empty<(Bid, Nat)>();
          for (b in bids.vals()) { switch (Map.get(fills, Nat.compare, b.id)) { case (?q) { if (q > 0) List.add(bf, (b, q)) }; case null {} } };
          for (a in asks.vals()) { switch (Map.get(fills, Nat.compare, a.id)) { case (?q) { if (q > 0) List.add(af, (a, q)) }; case null {} } };
          let bs = sortForPairs(List.toArray(bf), true);
          let as_ = sortForPairs(List.toArray(af), false);
          let pairs = List.empty<(T.OrderId, T.OrderId, Nat)>();
          var i = 0; var j = 0; var bl = 0; var al = 0;
          while (i < bs.size() and j < as_.size()) {
            if (bl == 0) bl := bs[i].1;
            if (al == 0) al := as_[j].1;
            let q = Nat.min(bl, al);
            List.add(pairs, (bs[i].0.id, as_[j].0.id, q));
            bl -= q; al -= q;
            if (bl == 0) i += 1;
            if (al == 0) j += 1;
          };
          let fl = List.empty<(T.OrderId, Nat)>();
          for ((b, q) in bs.vals()) List.add(fl, (b.id, q));
          for ((a, q) in as_.vals()) List.add(fl, (a.id, q));
          return { price = if (v == 0) null else p; volume = v; fills = List.toArray(fl); pairs = List.toArray(pairs); killed = List.toArray(killed) };
        };
      };
    };
  };
}
