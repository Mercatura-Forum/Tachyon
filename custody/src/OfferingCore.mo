/// OfferingCore.mo: an initial public offering as commands on a certified log, folded into fixed-width rows: the
/// offering with its terms and its running figures, the orders (cornerstone commitments, institutional bids, retail
/// applications), the book's price ladder; pricing against the book, the allocation swept in slices with its file
/// chained by hash, the hand-off to the listing behind its gate. A replay of the log onto a fresh state reproduces
/// every row.
///
/// Authorisation inputs are parameters: who holds a role and who holds a permission are answered by the contract
/// that composes this core over its grant rows.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import Fold "mo:kernel/domain/Fold";
import Cmd "mo:kernel/domain/Command";
import Auth "mo:kernel/auth/AuthTypes";
import Perm "mo:kernel/auth/Permissions";
import MC "mo:kernel/auth/MakerChecker";
import RS "mo:kernel/rows/RowStore";
import Page "mo:kernel/rows/Page";
import R "mo:kernel/rows/StableRows";

import OT "OfferingTypes";
import K "OfferingCanonical";
import M "OfferingMath";

module {

  public type Error = { #offering : OT.Error; #auth : Auth.Error; #encoding : Text };
  public type Result<A> = Result.Result<A, Error>;

  // ═══════════════════════════════════════════════════════
  //  THE PERMISSION CATALOGUE
  // ═══════════════════════════════════════════════════════

  /// The offering's terms, a cornerstone's commitment, the price, the hand-off and a withdrawal bind the issuer, the
  /// underwriter and every investor: dual. A bid and its withdrawal are the bookrunner recording what an investor
  /// sent, and a retail application is the investor's own act paid in full: single, the reason recorded. The
  /// allocation is a sweep whose every figure the price and the orders already determine: single.
  public func catalogue() : Perm.Catalogue { [
    Perm.p("offering.open", "offering", #create, #command("openOffering"), false, false, true),
    Perm.p("offering.cornerstone.commit", "order", #create, #command("commitCornerstone"), false, false, true),
    Perm.p("offering.bid.place", "order", #create, #command("placeBid"), false, false, false),
    Perm.p("offering.bid.withdraw", "order", #close, #command("withdrawBid"), false, false, false),
    Perm.p("offering.retail.subscribe", "order", #create, #command("subscribeRetail"), false, false, false),
    Perm.p("offering.price", "offering", #approve, #command("priceOffering"), false, false, true),
    Perm.p("offering.allocate", "offering", #update, #command("allocate"), false, false, false),
    Perm.p("offering.handoff", "offering", #approve, #command("handOff"), false, false, true),
    Perm.p("offering.withdraw", "offering", #close, #command("withdrawOffering"), false, false, true),
    Perm.p("command.approve", "command", #approve, #method("approve"), false, false, false),
    Perm.p("command.reject", "command", #reject, #method("reject"), false, false, false),
  ] };
  public func singleActs() : [(Text, Text)] { [
    ("offering.bid.place", "records an institutional investor's bid as the bookrunner received it, within the range and the book's days, one live bid per investor; the price is set later under four eyes"),
    ("offering.bid.withdraw", "withdraws a live bid while the book is open, as the investor instructed; the bid leaves the book and the ladder"),
    ("offering.retail.subscribe", "records a retail investor's application paid in full at the top of the range, once per investor and within the retail days; the refund is computed at allocation"),
    ("offering.allocate", "allocates the next slice of orders by the declared rule; the price, the tranches and every order were fixed before, and the caller chooses nothing"),
  ] };
  public let commandNames : [Text] = ["openOffering", "commitCornerstone", "placeBid", "withdrawBid", "subscribeRetail", "priceOffering", "allocate", "handOff", "withdrawOffering"];
  public let methodNames : [Text] = ["approve", "reject"];
  public func permissionOf(c : OT.Command) : Auth.Permission {
    switch (Perm.byCommand(catalogue(), K.familyOf(c))) { case (?p) p; case null Runtime.trap("catalogue: no permission guards " # K.familyOf(c)) }
  };

  // ═══════════════════════════════════════════════════════
  //  THE ROWS
  // ═══════════════════════════════════════════════════════

  func padded(b : R.Buf, width : Nat) : Blob { while (b.size() < width) R.putByte(b, 0); R.done(b, width) };
  let MAXK : Nat = 0xFFFF_FFFF_FFFF_FFFF;

  /// An offering: its terms and its running figures. `cornerLots`, `retailDemand` and `retailPaid` grow with the
  /// orders; `bidDemand`, `bidsAlloc`, `retailAlloc`, `underwriterLots` and `unsold` are fixed at pricing; the cursor,
  /// the cumulative demands, `allocatedLots`, `holders`, `cashDue`, `refunds` and `chain` are the allocation's.
  public type OfferingRow = {
    terms : OT.Terms; state : Nat; price : Nat; cornerLots : Nat; retailDemand : Nat; retailPaid : Nat; bidDemand : Nat; bidsAlloc : Nat; retailAlloc : Nat;
    unsold : Nat; underwriterLots : Nat; cursor : Nat; cumBid : Nat; cumRetail : Nat; allocatedLots : Nat; orders : Nat; holders : Nat; cashDue : Nat; refunds : Nat; chain : Blob;
  };
  public let TERMS_BYTES = 203;      // code 12, name 48, issuer 32, underwriter 32, six numbers 8 each, three rates 2 each, firm 1, two rates 2 each, minHolders 4, four days 4 each
  public let FIGURES_BYTES = 161;    // state 1, fifteen numbers 8 each, orders 4, holders 4, chain 32
  public let OFFERING_ROW_BYTES = 368;
  func putTerms(b : R.Buf, t : OT.Terms) {
    R.putText(b, t.code, OT.CODE_BYTES); R.putText(b, t.name, OT.NAME_BYTES); R.putBlob(b, t.issuer, 32); R.putBlob(b, t.underwriter, 32);
    R.putNat(b, t.sharesOffered, 8); R.putNat(b, t.sharesOutstanding, 8); R.putNat(b, t.priceLow, 8); R.putNat(b, t.priceHigh, 8); R.putNat(b, t.tick, 8); R.putNat(b, t.lot, 8);
    R.putNat(b, t.retailBps, 2); R.putNat(b, t.cornerstoneMaxBps, 2); R.putNat(b, t.underwritingBps, 2); R.putBool(b, t.firmCommitment); R.putNat(b, t.minSoldBps, 2); R.putNat(b, t.minFloatBps, 2); R.putNat(b, t.minHolders, 4);
    R.putNat(b, t.bookOpen, 4); R.putNat(b, t.bookClose, 4); R.putNat(b, t.retailClose, 4); R.putNat(b, t.listingDay, 4)
  };
  func getTerms(a : [Nat8]) : OT.Terms {
    { code = R.getText(a, 0, 12); name = R.getText(a, 12, 48); issuer = R.getBlob(a, 60, 32); underwriter = R.getBlob(a, 92, 32);
      sharesOffered = R.getNat(a, 124, 8); sharesOutstanding = R.getNat(a, 132, 8); priceLow = R.getNat(a, 140, 8); priceHigh = R.getNat(a, 148, 8); tick = R.getNat(a, 156, 8); lot = R.getNat(a, 164, 8);
      retailBps = R.getNat(a, 172, 2); cornerstoneMaxBps = R.getNat(a, 174, 2); underwritingBps = R.getNat(a, 176, 2); firmCommitment = R.getBool(a, 178); minSoldBps = R.getNat(a, 179, 2); minFloatBps = R.getNat(a, 181, 2); minHolders = R.getNat(a, 183, 4);
      bookOpen = R.getNat(a, 187, 4); bookClose = R.getNat(a, 191, 4); retailClose = R.getNat(a, 195, 4); listingDay = R.getNat(a, 199, 4) }
  };
  public let offerings : RS.Decl<OfferingRow> = {
    table = "offerings"; idBytes = 8; rowBytes = OFFERING_ROW_BYTES;
    encode = func(x : OfferingRow) : Blob {
      let b = R.buf(); putTerms(b, x.terms);
      R.putNat(b, x.state, 1);
      for (v in [x.price, x.cornerLots, x.retailDemand, x.retailPaid, x.bidDemand, x.bidsAlloc, x.retailAlloc, x.unsold, x.underwriterLots, x.cursor, x.cumBid, x.cumRetail, x.allocatedLots, x.cashDue, x.refunds].vals()) R.putNat(b, v, 8);
      R.putNat(b, x.orders, 4); R.putNat(b, x.holders, 4); R.putBlob(b, x.chain, 32);
      padded(b, OFFERING_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : OfferingRow {
      let f = func(k : Nat) : Nat { R.getNat(a, 204 + 8 * k, 8) };
      { terms = getTerms(a); state = R.getNat(a, 203, 1); price = f(0); cornerLots = f(1); retailDemand = f(2); retailPaid = f(3); bidDemand = f(4); bidsAlloc = f(5); retailAlloc = f(6); unsold = f(7); underwriterLots = f(8);
        cursor = f(9); cumBid = f(10); cumRetail = f(11); allocatedLots = f(12); cashDue = f(13); refunds = f(14); orders = R.getNat(a, 324, 4); holders = R.getNat(a, 328, 4); chain = R.getBlob(a, 332, 32) }
    };
    indexes = [{ name = "byCode"; keyBytes = 12; keyOf = func(_ : Nat, x : OfferingRow) : ?Blob { ?R.textKey(x.terms.code, OT.CODE_BYTES) } }];
  };

  /// An order: a cornerstone's commitment, an institutional bid (its limit price) or a retail application (what it
  /// paid); live until withdrawn; its allocation, the cash due for it and the refund once allocated.
  public type OrderRow = { offering : Nat; kind : OT.OrderKind; investor : Blob; price : Nat; lots : Nat; paid : Nat; live : Bool; allocLots : Nat; cashDue : Nat; refund : Nat; day : Nat };
  public let ORDER_ROW_BYTES = 96;   // offering 8, kind 1, investor 32, price 8, lots 8, paid 8, live 1, allocLots 8, cashDue 8, refund 8, day 4, pad
  public let orders : RS.Decl<OrderRow> = {
    table = "orders"; idBytes = 8; rowBytes = ORDER_ROW_BYTES;
    encode = func(x : OrderRow) : Blob {
      let b = R.buf(); R.putNat(b, x.offering, 8); R.putByte(b, K.kindCode(x.kind)); R.putBlob(b, x.investor, 32); R.putNat(b, x.price, 8); R.putNat(b, x.lots, 8); R.putNat(b, x.paid, 8);
      R.putBool(b, x.live); R.putNat(b, x.allocLots, 8); R.putNat(b, x.cashDue, 8); R.putNat(b, x.refund, 8); R.putNat(b, x.day, 4); padded(b, ORDER_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : OrderRow {
      let ?kind = K.kindOf(a[8]) else Runtime.trap("order row: bad kind byte");
      { offering = R.getNat(a, 0, 8); kind; investor = R.getBlob(a, 9, 32); price = R.getNat(a, 41, 8); lots = R.getNat(a, 49, 8); paid = R.getNat(a, 57, 8); live = R.getBool(a, 65);
        allocLots = R.getNat(a, 66, 8); cashDue = R.getNat(a, 74, 8); refund = R.getNat(a, 82, 8); day = R.getNat(a, 90, 4) }
    };
    indexes = [
      // every order of an offering in the order it came: the allocation's sweep
      { name = "byOffering"; keyBytes = 16; keyOf = func(id : Nat, x : OrderRow) : ?Blob { ?R.key2(x.offering, 8, id, 8) } },
      // the live order of an investor in an offering: one each
      { name = "liveInvestor"; keyBytes = 16; keyOf = func(_ : Nat, x : OrderRow) : ?Blob { if (x.live) ?R.key2(x.offering, 8, K.investorKey(x.investor), 8) else null } },
    ];
  };

  /// A rung of the book's ladder: the live bids' lots at one price level (the level counts ticks up from the low end).
  public type LevelRow = { offering : Nat; level : Nat; lots : Nat };
  public let LEVEL_ROW_BYTES = 24;   // offering 8, level 4, lots 8, pad
  public let levels : RS.Decl<LevelRow> = {
    table = "levels"; idBytes = 8; rowBytes = LEVEL_ROW_BYTES;
    encode = func(x : LevelRow) : Blob { let b = R.buf(); R.putNat(b, x.offering, 8); R.putNat(b, x.level, 4); R.putNat(b, x.lots, 8); padded(b, LEVEL_ROW_BYTES) };
    decode = func(a : [Nat8]) : LevelRow { { offering = R.getNat(a, 0, 8); level = R.getNat(a, 8, 4); lots = R.getNat(a, 12, 8) } };
    indexes = [{ name = "byLevel"; keyBytes = 12; keyOf = func(_ : Nat, x : LevelRow) : ?Blob { ?R.key2(x.offering, 8, x.level, 4) } }];
  };
  public type ProposalRow = MC.ProposalRow;
  public let proposals : RS.Decl<ProposalRow> = {
    table = "offeringProposals"; idBytes = 8; rowBytes = MC.PROPOSAL_ROW_BYTES; encode = MC.encodeProposalRow;
    decode = func(a : [Nat8]) : ProposalRow { MC.decodeProposalRow(Blob.fromArray(a)) };
    indexes = [{ name = "awaiting"; keyBytes = 8; keyOf = func(id : Nat, r : ProposalRow) : ?Blob { switch (r.status) { case (#awaiting) ?R.key(id, 8); case (_) null } } }];
  };
  public func checkSums() : Bool {
    12 + 48 + 32 + 32 + 8 * 6 + 2 * 3 + 1 + 2 * 2 + 4 + 4 * 4 == TERMS_BYTES
    and 1 + 8 * 15 + 4 + 4 + 32 == FIGURES_BYTES and TERMS_BYTES + FIGURES_BYTES <= OFFERING_ROW_BYTES
    and 8 + 1 + 32 + 8 + 8 + 8 + 1 + 8 + 8 + 8 + 4 == 94 and 94 <= ORDER_ROW_BYTES
    and 8 + 4 + 8 == 20 and 20 <= LEVEL_ROW_BYTES
  };

  // ═══════════════════════════════════════════════════════
  //  THE STATE
  // ═══════════════════════════════════════════════════════

  public type State = {
    log : DL.State;
    offeringRows : RS.Store; orderRows : RS.Store; levelRows : RS.Store; proposalRows : RS.Store;
    var nextOffering : Nat; var nextOrder : Nat; var nextLevel : Nat; var lastDay : Nat;
    var policies : [Auth.DualPolicy];
  };
  public func newState() : State { newStateOver(DL.newState()) };
  public func newStateOver(log : DL.State) : State {
    { log; offeringRows = RS.newStore(offerings); orderRows = RS.newStore(orders); levelRows = RS.newStore(levels); proposalRows = RS.newStore(proposals);
      var nextOffering = 1; var nextOrder = 1; var nextLevel = 1; var lastDay = 0; var policies = [] }
  };
  public func setPolicies(s : State, ps : [Auth.DualPolicy]) { s.policies := ps };
  func policyFor(s : State, permission : Text) : ?Auth.DualPolicy { Array.find<Auth.DualPolicy>(s.policies, func(p) { p.permission == permission }) };

  // ─── reads ──────────────────────────────────────────────────────────────────────────────

  func one<Rw>(store : RS.Store, decl : RS.Decl<Rw>, index : Text, key : Blob) : ?(Nat, Rw) {
    switch (RS.page(store, decl, index, key, key, null, 1)) { case (#ok(p)) { if (p.rows.size() == 0) null else ?p.rows[0] }; case (#err(_)) null }
  };
  public func offering(s : State, id : Nat) : ?OfferingRow { RS.get(s.offeringRows, offerings, id) };
  public func offeringByCode(s : State, code : Text) : ?(Nat, OfferingRow) {
    let n = Text.encodeUtf8(code).size(); if (n == 0 or n > OT.CODE_BYTES) return null; one(s.offeringRows, offerings, "byCode", R.textKey(code, OT.CODE_BYTES))
  };
  public func order(s : State, id : Nat) : ?OrderRow { RS.get(s.orderRows, orders, id) };
  public func ordersOf(s : State, off : Nat, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, OrderRow)> { let (lo, hi) = R.prefixRange(off, 8, 8); RS.page(s.orderRows, orders, "byOffering", lo, hi, cursor, limit) };
  public func liveOrderOf(s : State, off : Nat, investor : Blob) : ?(Nat, OrderRow) { one(s.orderRows, orders, "liveInvestor", R.key2(off, 8, K.investorKey(investor), 8)) };
  func level(s : State, off : Nat, lv : Nat) : ?(Nat, LevelRow) { one(s.levelRows, levels, "byLevel", R.key2(off, 8, lv, 4)) };
  func priceAt(t : OT.Terms, lv : Nat) : Nat { t.priceLow + lv * t.tick };
  func onTick(t : OT.Terms, p : Nat) : Bool { p >= t.priceLow and p <= t.priceHigh and (p - t.priceLow : Nat) % t.tick == 0 };
  /// The book's ladder: the live bids' lots at each price, from the high end down (bounded by the range's rungs).
  public func ladder(s : State, off : Nat) : [(Nat, Nat)] {
    let ?o = offering(s, off) else return [];
    let out = List.empty<(Nat, Nat)>();
    var lv = OT.levels(o.terms);
    while (lv > 0) { lv -= 1; switch (level(s, off, lv)) { case (?(_, r)) { if (r.lots > 0) List.add(out, (priceAt(o.terms, lv), r.lots)) }; case null {} } };
    List.toArray(out)
  };
  /// The live bids' lots at or above a price.
  public func bidDemandAt(s : State, off : Nat, price : Nat) : Nat {
    var d = 0; for ((p, l) in ladder(s, off).vals()) { if (p >= price) d += l }; d
  };
  /// The book's clearing price: the highest price at which the cornerstones and the bids at or above it cover the
  /// institutional tranche; none when no price in the range does.
  public func clearingPrice(s : State, off : Nat) : ?Nat {
    let ?o = offering(s, off) else return null;
    let need = OT.institutionalLots(o.terms);
    var cum = o.cornerLots;
    for ((p, l) in ladder(s, off).vals()) { cum += l; if (cum >= need) return ?p };
    if (cum >= need) ?o.terms.priceHigh else null
  };
  /// The hand-off's lines for the register: each order allocated shares (the order, the investor, the shares), in
  /// order, a page at a time.
  public func handOffLines(s : State, off : Nat, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, OrderRow)> { ordersOf(s, off, cursor, limit) };
  public func awaitingProposals(s : State, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, ProposalRow)> { let (lo, hi) = R.fullRange(8); RS.page(s.proposalRows, proposals, "awaiting", lo, hi, cursor, limit) };

  // ═══════════════════════════════════════════════════════
  //  VALIDATION
  // ═══════════════════════════════════════════════════════

  func textFits(field : Text, t : Text, max : Nat) : ?OT.Error {
    let n = Text.encodeUtf8(t).size();
    if (n == 0) return ?#InvalidText({ field; reason = "empty" });
    if (n > max) return ?#InvalidText({ field; reason = "longer than " # Nat.toText(max) # " bytes" });
    null
  };
  func commit(field : Text, b : Blob) : ?OT.Error { if (b.size() == 32) null else ?#InvalidTerms({ field; reason = "a 32-byte commitment" }) };
  func dayOk(s : State, d : Nat) : ?OT.Error { if (d < s.lastDay) ?#DayBackwards({ day = d; last = s.lastDay }) else null };
  func inState(off : Nat, o : OfferingRow, st : Nat) : ?OT.Error { if (o.state == st) null else ?#NotInState({ offering = off; state = o.state }) };
  func terms(t : OT.Terms, day : Nat) : ?OT.Error {
    switch (textFits("code", t.code, OT.CODE_BYTES)) { case (?e) return ?e; case null {} };
    switch (textFits("name", t.name, OT.NAME_BYTES)) { case (?e) return ?e; case null {} };
    switch (commit("issuer", t.issuer)) { case (?e) return ?e; case null {} };
    switch (commit("underwriter", t.underwriter)) { case (?e) return ?e; case null {} };
    if (t.lot == 0 or t.sharesOffered == 0 or t.sharesOffered % t.lot != 0) return ?#InvalidTerms({ field = "sharesOffered"; reason = "a positive number of whole lots" });
    if (t.sharesOutstanding < t.sharesOffered) return ?#InvalidTerms({ field = "sharesOutstanding"; reason = "at least the shares offered" });
    if (t.priceLow == 0 or t.tick == 0 or t.priceHigh < t.priceLow or (t.priceHigh - t.priceLow : Nat) % t.tick != 0) return ?#InvalidTerms({ field = "range"; reason = "a positive range from low to high on the tick" });
    if (OT.levels(t) > OT.MAX_LEVELS) return ?#InvalidTerms({ field = "range"; reason = "at most " # Nat.toText(OT.MAX_LEVELS) # " price levels" });
    if (t.retailBps > 10_000 or t.cornerstoneMaxBps > 10_000 or t.minSoldBps > 10_000 or t.minFloatBps > 10_000) return ?#InvalidTerms({ field = "rates"; reason = "shares of at most 10,000 basis points" });
    if (t.underwritingBps > 1_000) return ?#InvalidTerms({ field = "underwritingBps"; reason = "a fee of at most 10% of the proceeds" });
    if (OT.institutionalLots(t) == 0) return ?#InvalidTerms({ field = "retailBps"; reason = "an institutional tranche of at least a lot" });
    if (not (day <= t.bookOpen and t.bookOpen <= t.bookClose and t.bookOpen <= t.retailClose and t.bookClose < t.listingDay and t.retailClose < t.listingDay)) return ?#InvalidTerms({ field = "calendar"; reason = "the book opening, its and the retail close, then the listing" });
    null
  };
  func notLive(s : State, off : Nat, investor : Blob) : ?OT.Error {
    switch (commit("investor", investor)) { case (?e) return ?e; case null {} };
    if (liveOrderOf(s, off, investor) != null) ?#DuplicateInvestor({ offering = off }) else null
  };

  public func validate(s : State, c : OT.Command) : ?OT.Error {
    switch (c) {
      case (#openOffering(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        switch (terms(x.terms, x.day)) { case (?e) return ?e; case null {} };
        if (offeringByCode(s, x.terms.code) != null) return ?#DuplicateCode(x.terms.code);
        null
      };
      case (#commitCornerstone(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        let ?o = offering(s, x.offering) else return ?#UnknownOffering(x.offering);
        switch (inState(x.offering, o, OT.OPEN)) { case (?e) return ?e; case null {} };
        if (x.day >= o.terms.bookOpen) return ?#CornerstoneLate({ bookOpen = o.terms.bookOpen; day = x.day });
        let inst = OT.institutionalLots(o.terms);
        if (x.lots == 0 or x.lots > inst) return ?#InvalidLots({ lots = x.lots; max = inst });
        switch (notLive(s, x.offering, x.investor)) { case (?e) return ?e; case null {} };
        let cap = M.bpsOf(inst, o.terms.cornerstoneMaxBps);
        if (o.cornerLots + x.lots > cap) return ?#CornerstoneCap({ cap; committed = o.cornerLots; wanted = x.lots });
        null
      };
      case (#placeBid(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        let ?o = offering(s, x.offering) else return ?#UnknownOffering(x.offering);
        switch (inState(x.offering, o, OT.OPEN)) { case (?e) return ?e; case null {} };
        if (x.day < o.terms.bookOpen or x.day > o.terms.bookClose) return ?#BookClosed({ opens = o.terms.bookOpen; closes = o.terms.bookClose; day = x.day });
        if (not onTick(o.terms, x.price)) return ?#PriceOffRange({ price = x.price; low = o.terms.priceLow; high = o.terms.priceHigh; tick = o.terms.tick });
        let all = OT.offerLots(o.terms);
        if (x.lots == 0 or x.lots > all) return ?#InvalidLots({ lots = x.lots; max = all });
        notLive(s, x.offering, x.investor)
      };
      case (#withdrawBid(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        let ?r = order(s, x.order) else return ?#UnknownOrder(x.order);
        if (r.kind != #bid or not r.live) return ?#NotABid(x.order);
        let ?o = offering(s, r.offering) else return ?#UnknownOffering(r.offering);
        switch (inState(r.offering, o, OT.OPEN)) { case (?e) return ?e; case null {} };
        if (x.day > o.terms.bookClose) return ?#BookClosed({ opens = o.terms.bookOpen; closes = o.terms.bookClose; day = x.day });
        null
      };
      case (#subscribeRetail(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        let ?o = offering(s, x.offering) else return ?#UnknownOffering(x.offering);
        switch (inState(x.offering, o, OT.OPEN)) { case (?e) return ?e; case null {} };
        if (x.day < o.terms.bookOpen or x.day > o.terms.retailClose) return ?#BookClosed({ opens = o.terms.bookOpen; closes = o.terms.retailClose; day = x.day });
        let retail = OT.retailLots(o.terms);
        if (x.lots == 0 or x.lots > retail) return ?#InvalidLots({ lots = x.lots; max = retail });
        let due = x.lots * o.terms.lot * o.terms.priceHigh;
        if (x.paid != due) return ?#PaymentMismatch({ paid = x.paid; due });
        notLive(s, x.offering, x.investor)
      };
      case (#priceOffering(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        let ?o = offering(s, x.offering) else return ?#UnknownOffering(x.offering);
        switch (inState(x.offering, o, OT.OPEN)) { case (?e) return ?e; case null {} };
        let closes = Nat.max(o.terms.bookClose, o.terms.retailClose);
        if (x.day <= closes) return ?#BookStillOpen({ closes; day = x.day });
        if (not onTick(o.terms, x.price)) return ?#PriceOffRange({ price = x.price; low = o.terms.priceLow; high = o.terms.priceHigh; tick = o.terms.tick });
        let clearing = switch (clearingPrice(s, x.offering)) { case (?p) p; case null o.terms.priceLow };
        if (x.price > clearing) return ?#PriceAboveBook({ price = x.price; clearing });
        null
      };
      case (#allocate(x)) {
        let ?o = offering(s, x.offering) else return ?#UnknownOffering(x.offering);
        switch (inState(x.offering, o, OT.PRICED)) { case (?e) return ?e; case null {} };
        if (x.limit == 0 or x.limit > OT.MAX_SLICE) return ?#InvalidLimit(x.limit);
        null
      };
      case (#handOff(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        let ?o = offering(s, x.offering) else return ?#UnknownOffering(x.offering);
        switch (inState(x.offering, o, OT.ALLOCATED)) { case (?e) return ?e; case null {} };
        if (x.day < o.terms.listingDay) return ?#BeforeListing({ listingDay = o.terms.listingDay; day = x.day });
        let g = gate(o);
        if (g.floatBps < o.terms.minFloatBps or g.holders < o.terms.minHolders) return ?#ListingGate({ floatBps = g.floatBps; minFloatBps = o.terms.minFloatBps; holders = g.holders; minHolders = o.terms.minHolders });
        null
      };
      case (#withdrawOffering(x)) {
        switch (dayOk(s, x.day)) { case (?e) return ?e; case null {} };
        let ?o = offering(s, x.offering) else return ?#UnknownOffering(x.offering);
        if (o.state != OT.OPEN and o.state != OT.PRICED and o.state != OT.ALLOCATED) return ?#NotInState({ offering = x.offering; state = o.state });
        textFits("reason", x.reason, OT.REASON_BYTES)
      };
    }
  };
  /// The listing gate's figures: the free float (the shares the book's bidders and the retail investors were
  /// allocated, in basis points of the shares outstanding; the cornerstones' and the underwriter's are locked up and
  /// not free) and the holders (every order allocated a lot, and the underwriter when it took any up).
  public func gate(o : OfferingRow) : { floatBps : Nat; holders : Nat } {
    { floatBps = (o.bidsAlloc + o.retailAlloc) * o.terms.lot * M.BPS / o.terms.sharesOutstanding; holders = o.holders }
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  func dayOf(c : OT.Command) : Nat {
    switch (c) {
      case (#openOffering(x)) x.day; case (#commitCornerstone(x)) x.day; case (#placeBid(x)) x.day; case (#withdrawBid(x)) x.day; case (#subscribeRetail(x)) x.day;
      case (#priceOffering(x)) x.day; case (#allocate(_)) 0; case (#handOff(x)) x.day; case (#withdrawOffering(x)) x.day;
    }
  };
  func addLevel(s : State, off : Nat, lv : Nat, plus : Nat, minus : Nat) {
    switch (level(s, off, lv)) {
      case (?(id, r)) RS.put(s.levelRows, levels, id, { r with lots = r.lots + plus - minus : Nat });
      case null { let id = s.nextLevel; s.nextLevel += 1; RS.put(s.levelRows, levels, id, { offering = off; level = lv; lots = plus - minus : Nat }) };
    }
  };
  func newOrder(s : State, off : Nat, kind : OT.OrderKind, investor : Blob, price : Nat, lots : Nat, paid : Nat, day : Nat) : Nat {
    let id = s.nextOrder; s.nextOrder += 1;
    RS.put(s.orderRows, orders, id, { offering = off; kind; investor; price; lots; paid; live = true; allocLots = 0; cashDue = 0; refund = 0; day });
    id
  };

  public func apply(s : State, c : OT.Command) : OT.Effects {
    let d = dayOf(c);
    if (d > s.lastDay) s.lastDay := d;
    switch (c) {
      case (#openOffering(x)) {
        let id = s.nextOffering; s.nextOffering += 1;
        RS.put(s.offeringRows, offerings, id, { terms = x.terms; state = OT.OPEN; price = 0; cornerLots = 0; retailDemand = 0; retailPaid = 0; bidDemand = 0; bidsAlloc = 0; retailAlloc = 0; unsold = 0; underwriterLots = 0;
          cursor = 0; cumBid = 0; cumRetail = 0; allocatedLots = 0; orders = 0; holders = 0; cashDue = 0; refunds = 0; chain = K.zero32() });
        [id, OT.offerLots(x.terms), OT.institutionalLots(x.terms), OT.retailLots(x.terms), OT.levels(x.terms)]
      };
      case (#commitCornerstone(x)) {
        let ?o = offering(s, x.offering) else Runtime.trap("apply: an offering vanished");
        let id = newOrder(s, x.offering, #cornerstone, x.investor, 0, x.lots, 0, x.day);
        RS.put(s.offeringRows, offerings, x.offering, { o with cornerLots = o.cornerLots + x.lots; orders = o.orders + 1 });
        [id, o.cornerLots + x.lots]
      };
      case (#placeBid(x)) {
        let ?o = offering(s, x.offering) else Runtime.trap("apply: an offering vanished");
        let id = newOrder(s, x.offering, #bid, x.investor, x.price, x.lots, 0, x.day);
        let lv = (x.price - o.terms.priceLow : Nat) / o.terms.tick;
        addLevel(s, x.offering, lv, x.lots, 0);
        RS.put(s.offeringRows, offerings, x.offering, { o with orders = o.orders + 1 });
        [id, lv]
      };
      case (#withdrawBid(x)) {
        let ?r = order(s, x.order) else Runtime.trap("apply: an order vanished");
        let ?o = offering(s, r.offering) else Runtime.trap("apply: an offering vanished");
        let lv = (r.price - o.terms.priceLow : Nat) / o.terms.tick;
        RS.put(s.orderRows, orders, x.order, { r with live = false });
        addLevel(s, r.offering, lv, 0, r.lots);
        [x.order, lv]
      };
      case (#subscribeRetail(x)) {
        let ?o = offering(s, x.offering) else Runtime.trap("apply: an offering vanished");
        let id = newOrder(s, x.offering, #retail, x.investor, o.terms.priceHigh, x.lots, x.paid, x.day);
        RS.put(s.offeringRows, offerings, x.offering, { o with retailDemand = o.retailDemand + x.lots; retailPaid = o.retailPaid + x.paid; orders = o.orders + 1 });
        [id]
      };
      case (#priceOffering(x)) {
        let ?o = offering(s, x.offering) else Runtime.trap("apply: an offering vanished");
        let bidDemand = bidDemandAt(s, x.offering, x.price);
        let instDemand = o.cornerLots + bidDemand;
        let t = M.tranches(OT.institutionalLots(o.terms), OT.retailLots(o.terms), instDemand, o.retailDemand);
        let sold = t.inst + t.retail;
        // a best-efforts offering that sold less than its minimum fails: every order void, the retail refunded
        if (not o.terms.firmCommitment and sold * M.BPS < o.terms.minSoldBps * OT.offerLots(o.terms)) {
          RS.put(s.offeringRows, offerings, x.offering, { o with state = OT.WITHDRAWN; price = x.price; bidDemand; refunds = o.retailPaid });
          return [x.offering, x.price, instDemand, o.retailDemand, t.inst, t.retail, 0, t.unsold, 1]
        };
        let underwriterLots = if (o.terms.firmCommitment) t.unsold else 0;
        RS.put(s.offeringRows, offerings, x.offering, { o with state = OT.PRICED; price = x.price; bidDemand; bidsAlloc = t.inst - o.cornerLots : Nat; retailAlloc = t.retail;
          underwriterLots; unsold = t.unsold - underwriterLots : Nat; chain = K.head(x.offering, o.terms.code, x.price) });
        [x.offering, x.price, instDemand, o.retailDemand, t.inst, t.retail, underwriterLots, t.unsold - underwriterLots : Nat, 0]
      };
      case (#allocate(x)) {
        let ?o = offering(s, x.offering) else Runtime.trap("apply: an offering vanished");
        let page = switch (RS.page(s.orderRows, orders, "byOffering", R.key2(x.offering, 8, o.cursor, 8), R.key2(x.offering, 8, MAXK, 8), null, x.limit)) { case (#ok(p)) p; case (#err(_)) Runtime.trap("apply: the orders' index refused a page") };
        var cumBid = o.cumBid; var cumRetail = o.cumRetail; var chain = o.chain; var holders = o.holders; var allocated = o.allocatedLots; var cashDue = o.cashDue; var refunds = o.refunds;
        var sliceLots = 0; var cursor = o.cursor;
        for ((id, r) in page.rows.vals()) {
          let lots = switch (r.kind) {
            case (#cornerstone) r.lots;
            case (#bid) { if (r.live and r.price >= o.price) { let a = M.cumulativeShare(cumBid, r.lots, o.bidsAlloc, o.bidDemand); cumBid += r.lots; a } else 0 };
            case (#retail) { let a = M.cumulativeShare(cumRetail, r.lots, o.retailAlloc, o.retailDemand); cumRetail += r.lots; a };
          };
          let due = lots * o.terms.lot * o.price;
          let refund = if (r.kind == #retail) r.paid - due : Nat else 0;
          RS.put(s.orderRows, orders, id, { r with allocLots = lots; cashDue = due; refund });
          chain := K.link(chain, id, r.kind, r.investor, lots, due, refund);
          if (lots > 0) holders += 1;
          allocated += lots; cashDue += due; refunds += refund; sliceLots += lots; cursor := id + 1;
        };
        let done = page.next == null;
        if (done) {
          chain := K.tail(chain, o.terms.underwriter, o.underwriterLots);
          if (o.underwriterLots > 0) holders += 1;
        };
        RS.put(s.offeringRows, offerings, x.offering, { o with state = if (done) OT.ALLOCATED else OT.PRICED; cursor; cumBid; cumRetail; chain; holders; allocatedLots = allocated; cashDue; refunds });
        [x.offering, page.rows.size(), sliceLots, if (done) 1 else 0]
      };
      case (#handOff(x)) {
        let ?o = offering(s, x.offering) else Runtime.trap("apply: an offering vanished");
        let g = gate(o);
        let gross = (o.allocatedLots + o.underwriterLots) * o.terms.lot * o.price;
        let fee = M.feeHalfUp(gross, o.terms.underwritingBps);
        RS.put(s.offeringRows, offerings, x.offering, { o with state = OT.LISTED });
        [x.offering, gross, fee, gross - fee : Nat, g.floatBps, g.holders, o.underwriterLots * o.terms.lot, o.price]
      };
      case (#withdrawOffering(x)) {
        let ?o = offering(s, x.offering) else Runtime.trap("apply: an offering vanished");
        // withdrawn: every allocation void and every retail payment returned in full, whatever the allocation said
        RS.put(s.offeringRows, offerings, x.offering, { o with state = OT.WITHDRAWN; refunds = o.retailPaid });
        [x.offering, o.retailPaid]
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE LIFECYCLE
  // ═══════════════════════════════════════════════════════

  public type Authority = { hasGrant : (Principal, Auth.PermissionId) -> Bool; holdsRole : (Principal, Auth.RoleId) -> Bool };
  public type Outcome = { #executed : { block : Nat; effects : OT.Effects }; #proposed : { proposal : Cmd.ProposalId; required : Nat } };
  func appendExecuted(s : State, now : Nat64, caller : Principal, proposal : ?Cmd.ProposalId, version : Nat8, c : OT.Command) : (Nat, OT.Effects) {
    let effects = apply(s, c);
    let b = DL.append(s.log, K.codec, now, caller, #executed({ proposal; version; command = c; effects }), null);
    (b.index, effects)
  };
  public func submit(s : State, auth : Authority, now : Nat64, caller : Principal, c : OT.Command, partition : ?Text, justification : Text) : Result<Outcome> {
    let perm = permissionOf(c);
    if (not auth.hasGrant(caller, perm.id)) return #err(#auth(#NoGrant({ permission = perm.id })));
    switch (validate(s, c)) { case (?e) return #err(#offering(e)); case null {} };
    switch (MC.resolvePolicy(perm, policyFor(s, perm.id))) {
      case (#refuse(e)) #err(#auth(e));
      case (#single) { let (block, effects) = appendExecuted(s, now, caller, null, K.registry.current, c); #ok(#executed({ block; effects })) };
      case (#dual(policy)) {
        let ?bound = Cmd.bind(K.registry, c) else return #err(#encoding("the current encoding cannot represent this command"));
        let p : Cmd.Proposed = { permission = perm.id; partition; maker = caller; required = policy.required; eligibleRole = policy.eligibleRole; expiresAt = now + Nat64.fromNat(policy.ttlSeconds) * 1_000_000_000; justification; commandHash = bound.commandHash; commandEncoding = bound.commandEncoding };
        let trailer = Cmd.trailerWithBody(K.registry, bound.commandEncoding, c);
        let b = DL.append(s.log, K.codec, now, caller, #proposed(p), trailer);
        RS.put(s.proposalRows, proposals, b.index, { expiresAt = p.expiresAt; status = #awaiting; approvalBlocks = [] });
        #ok(#proposed({ proposal = b.index; required = policy.required }))
      };
    }
  };
  public func proposal(s : State, id : Cmd.ProposalId) : ?MC.Entry {
    let ?row = RS.get(s.proposalRows, proposals, id) else return null;
    let ?b = DL.get(s.log, K.codec, id) else return null;
    let #proposed(p) = b.event else return null;
    let approvals = Array.map<Nat, Principal>(row.approvalBlocks, func(i) { switch (DL.get(s.log, K.codec, i)) { case (?ab) ab.caller; case null Principal.fromText("aaaaa-aa") } });
    let status : MC.Status = switch (row.status) {
      case (#awaiting) #awaiting;
      case (#executed(at)) { let effects = switch (DL.get(s.log, K.codec, at)) { case (?xb) { switch (xb.event) { case (#executed(x)) x.effects; case (_) [] } }; case null [] }; #executed({ at; effects }) };
      case (#rejected(at)) { switch (DL.get(s.log, K.codec, at)) { case (?rb) { switch (rb.event) { case (#rejected(x)) #rejected({ by = x.checker; reason = x.reason }); case (_) #rejected({ by = b.caller; reason = "" }) } }; case null #rejected({ by = b.caller; reason = "" }) } };
      case (#expired(_)) #expired;
    };
    ?{ index = id; commandHash = p.commandHash; commandEncoding = p.commandEncoding; permission = p.permission; partition = p.partition; maker = p.maker; required = p.required; eligibleRole = p.eligibleRole; expiresAt = p.expiresAt; justification = p.justification; approvals; status }
  };
  public func proposedCommand(s : State, id : Cmd.ProposalId) : ?OT.Command {
    let ?b = DL.get(s.log, K.codec, id) else return null;
    let #proposed(p) = b.event else return null;
    Cmd.bodyOf(K.registry, p, b.trailer)
  };
  public func approve(s : State, auth : Authority, now : Nat64, checker : Principal, id : Cmd.ProposalId) : Result<Outcome> {
    if (not auth.hasGrant(checker, "command.approve")) return #err(#auth(#NoGrant({ permission = "command.approve" })));
    let ?e = proposal(s, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    switch (MC.checkApprover(e, checker, auth.holdsRole(checker, e.eligibleRole), now)) { case (?err) return #err(#auth(err)); case null {} };
    let ?c = proposedCommand(s, id) else return #err(#auth(#CommandHashMismatch({ index = id })));
    let ?b = DL.get(s.log, K.codec, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let #proposed(p) = b.event else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    if (not Cmd.matches(K.registry, p, c)) return #err(#auth(#CommandHashMismatch({ index = id })));
    let ?row = RS.get(s.proposalRows, proposals, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let ab = DL.append(s.log, K.codec, now, checker, #approved({ proposal = id; checker; commandHash = p.commandHash }), null);
    let approvalBlocks = Array.concat<Nat>(row.approvalBlocks, [ab.index]);
    if (approvalBlocks.size() < e.required) { RS.put(s.proposalRows, proposals, id, { row with approvalBlocks }); return #ok(#proposed({ proposal = id; required = e.required })) };
    switch (validate(s, c)) {
      case (?err) {
        let rb = DL.append(s.log, K.codec, now, checker, #rejected({ proposal = id; checker; reason = "no longer valid at execution: " # debug_show(err) }), null);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #rejected(rb.index) });
        #err(#offering(err))
      };
      case null {
        let (block, effects) = appendExecuted(s, now, checker, ?id, p.commandEncoding, c);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #executed(block) });
        #ok(#executed({ block; effects }))
      };
    }
  };
  public func reject(s : State, auth : Authority, now : Nat64, checker : Principal, id : Cmd.ProposalId, reason : Text) : Result<()> {
    if (not auth.hasGrant(checker, "command.reject")) return #err(#auth(#NoGrant({ permission = "command.reject" })));
    let ?e = proposal(s, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    switch (MC.checkApprover(e, checker, auth.holdsRole(checker, e.eligibleRole), now)) { case (?err) return #err(#auth(err)); case null {} };
    let ?row = RS.get(s.proposalRows, proposals, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let rb = DL.append(s.log, K.codec, now, checker, #rejected({ proposal = id; checker; reason }), null);
    RS.put(s.proposalRows, proposals, id, { row with status = #rejected(rb.index) });
    #ok(())
  };
  public func expire(s : State, now : Nat64, caller : Principal, limit : Nat) : Nat {
    var n = 0;
    switch (awaitingProposals(s, null, limit)) {
      case (#ok(p)) { for ((id, row) in p.rows.vals()) { if (row.expiresAt <= now) { let xb = DL.append(s.log, K.codec, now, caller, #expired({ proposal = id }), null); RS.put(s.proposalRows, proposals, id, { row with status = #expired(xb.index) }); n += 1 } } };
      case (#err(_)) {};
    };
    n
  };

  // ═══════════════════════════════════════════════════════
  //  THE REPLAY
  // ═══════════════════════════════════════════════════════

  func applyBlock(s : State, b : DL.Block<K.Event>) {
    switch (b.event) {
      case (#proposed(p)) RS.put(s.proposalRows, proposals, b.index, { expiresAt = p.expiresAt; status = #awaiting; approvalBlocks = [] });
      case (#approved(a)) { switch (RS.get(s.proposalRows, proposals, a.proposal)) { case (?row) RS.put(s.proposalRows, proposals, a.proposal, { row with approvalBlocks = Array.concat<Nat>(row.approvalBlocks, [b.index]) }); case null {} } };
      case (#rejected(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #rejected(b.index) }); case null {} } };
      case (#expired(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #expired(b.index) }); case null {} } };
      case (#executed(x)) {
        let effects = apply(s, x.command);
        switch (x.proposal) { case (?id) { switch (RS.get(s.proposalRows, proposals, id)) { case (?row) RS.put(s.proposalRows, proposals, id, { row with status = #executed(b.index) }); case null {} } }; case null {} };
        if (effects != x.effects) Runtime.trap("replay: block " # Nat.toText(b.index) # " recorded effects " # debug_show(x.effects) # " but the fold produced " # debug_show(effects));
      };
    }
  };
  public func replay(fresh : State) : Fold.Report { Fold.replay<K.Event, State>(fresh.log, K.codec, func(_ : Nat) : ?Blob { null }, fresh, applyBlock) };
  public func fingerprint(s : State) : Blob {
    let f = Fold.newFingerprint();
    func table<Rw>(name : Text, store : RS.Store, decl : RS.Decl<Rw>, next : Nat) {
      Fold.section(f, name, func(w : C.Writer) { w.nat(next); var i = 1; while (i < next) { switch (RS.get(store, decl, i)) { case (?r) { w.nat(i); w.blob(decl.encode(r)) }; case null {} }; i += 1 } });
    };
    table<OfferingRow>("offerings", s.offeringRows, offerings, s.nextOffering);
    table<OrderRow>("orders", s.orderRows, orders, s.nextOrder);
    table<LevelRow>("levels", s.levelRows, levels, s.nextLevel);
    Fold.section(f, "lastDay", func(w : C.Writer) { w.nat(s.lastDay) });
    Fold.section(f, "proposals", func(w : C.Writer) { var i = 0; let n = DL.length(s.log); while (i < n) { switch (RS.get(s.proposalRows, proposals, i)) { case (?r) { w.nat(i); w.blob(MC.encodeProposalRow(r)) }; case null {} }; i += 1 } });
    Fold.section(f, "log", func(w : C.Writer) { w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)) });
    Fold.fingerprintHash(f)
  };
  public func counts(s : State) : { offerings : Nat; orders : Nat; levels : Nat; blocks : Nat } {
    { offerings = RS.size(s.offeringRows); orders = RS.size(s.orderRows); levels = RS.size(s.levelRows); blocks = DL.length(s.log) }
  };
}
