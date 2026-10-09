/// BookCanonical.mo: the bytes of the book's commands and of its log's events. Version 1 is frozen from the first
/// deployment: a family's tag is its position in `BookTypes.Command`; every closed vocabulary's byte is listed here and
/// never renumbered; a byte the build does not know decodes to nothing.
///
/// Attribution: Thebes Core Team.

import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import E "mo:kernel/domain/Encoding";
import Cmd "mo:kernel/domain/Command";

import T "BookTypes";

module {

  public func sideCode(s : T.Side) : Nat8 { switch (s) { case (#buy) 1; case (#sell) 2 } };
  public func sideOf(c : Nat8) : ?T.Side { switch (c) { case 1 ?#buy; case 2 ?#sell; case _ null } };
  public func kindCode(k : T.Kind) : Nat8 { switch (k) { case (#limit) 1; case (#market) 2; case (#ioc) 3; case (#fok) 4; case (#stop) 5; case (#stopLimit) 6; case (#trailingStop) 7 } };
  public func kindOf(c : Nat8) : ?T.Kind { switch (c) { case 1 ?#limit; case 2 ?#market; case 3 ?#ioc; case 4 ?#fok; case 5 ?#stop; case 6 ?#stopLimit; case 7 ?#trailingStop; case _ null } };
  public func validityCode(v : T.Validity) : Nat8 { switch (v) { case (#day) 1; case (#gtc) 2; case (#gtd) 3 } };
  public func validityOf(c : Nat8) : ?T.Validity { switch (c) { case 1 ?#day; case 2 ?#gtc; case 3 ?#gtd; case _ null } };
  public func selfTradeCode(x : T.SelfTrade) : Nat8 { switch (x) { case (#cancelIncoming) 1; case (#cancelResting) 2; case (#cancelBoth) 3 } };
  public func selfTradeOf(c : Nat8) : ?T.SelfTrade { switch (c) { case 1 ?#cancelIncoming; case 2 ?#cancelResting; case 3 ?#cancelBoth; case _ null } };
  public func capacityCode(x : T.Capacity) : Nat8 { switch (x) { case (#agency) 1; case (#principal) 2 } };
  public func capacityOf(c : Nat8) : ?T.Capacity { switch (c) { case 1 ?#agency; case 2 ?#principal; case _ null } };
  public func statusCode(s : T.Status) : Nat8 { switch (s) { case (#waiting) 1; case (#live) 2; case (#filled) 3; case (#cancelled) 4 } };
  public func statusOf(c : Nat8) : ?T.Status { switch (c) { case 1 ?#waiting; case 2 ?#live; case 3 ?#filled; case 4 ?#cancelled; case _ null } };

  public func phaseCode(p : T.Phase) : Nat8 { switch (p) { case (#closed) 1; case (#continuous) 2; case (#auction) 3; case (#closingAuction) 4; case (#tradeAtClose) 5; case (#halted) 6 } };
  public func phaseOf(c : Nat8) : ?T.Phase { switch (c) { case 1 ?#closed; case 2 ?#continuous; case 3 ?#auction; case 4 ?#closingAuction; case 5 ?#tradeAtClose; case 6 ?#halted; case _ null } };

  /// An instrument's terms (SPEC §28): a class byte, then its fields; a day count by its byte (1 ACT/365 fixed, 2 30/360,
  /// 3 ACT/ACT ICMA).
  func writeTerms(w : C.Writer, t : T.Terms) {
    switch (t) {
      case (#bond(b)) { w.byte(1); w.nat(b.couponBps); w.nat(b.perYear); w.byte(basisCode(b.basis)); w.nat(b.maturity); w.nat(b.settleDays) };
      case (#receipt(x)) { w.byte(2); w.len16(x.warehouses.size()); for (h in x.warehouses.vals()) w.nat(h) };
      case (#certificate(x)) { w.byte(3); w.blob(x.registry) };
      case (#right(x)) { w.byte(4); w.nat(x.underlying); w.nat(x.price); w.nat(x.num); w.nat(x.den); w.nat(x.deadline); w.nat(x.issuer); w.nat(x.issuerMember) };
    }
  };
  public func basisCode(b : T.DayBasis) : Nat8 { switch (b) { case (#act365) 1; case (#thirty360) 2; case (#actActIcma) 3 } };
  public func basisOf(c : Nat8) : ?T.DayBasis { switch (c) { case 1 ?#act365; case 2 ?#thirty360; case 3 ?#actActIcma; case _ null } };
  func readTerms(r : C.Reader) : ?T.Terms {
    let ?k = r.byte() else return null;
    switch (k) {
      case 1 {
        let ?couponBps = r.nat() else return null; let ?perYear = r.nat() else return null; let ?bc = r.byte() else return null;
        let ?basis = basisOf(bc) else return null; let ?maturity = r.nat() else return null; let ?settleDays = r.nat() else return null;
        ?#bond({ couponBps; perYear; basis; maturity; settleDays })
      };
      case 2 {
        let ?n = r.len16() else return null;
        let out = List.empty<Nat>();
        for (_ in Nat.range(0, n)) { let ?h = r.nat() else return null; List.add(out, h) };
        ?#receipt({ warehouses = List.toArray(out) })
      };
      case 3 { let ?registry = r.blob() else return null; ?#certificate({ registry }) };
      case 4 {
        let ?underlying = r.nat() else return null; let ?price = r.nat() else return null; let ?num = r.nat() else return null;
        let ?den = r.nat() else return null; let ?deadline = r.nat() else return null; let ?issuer = r.nat() else return null;
        let ?issuerMember = r.nat() else return null;
        ?#right({ underlying; price; num; den; deadline; issuer; issuerMember })
      };
      case _ null;
    }
  };
  func writeConstituents(w : C.Writer, cs : [T.Constituent]) { w.len16(cs.size()); for (c in cs.vals()) { w.nat(c.instrument); w.nat(c.shares) } };
  func readConstituents(r : C.Reader) : ?[T.Constituent] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Constituent>();
    for (_ in Nat.range(0, n)) { let ?instrument = r.nat() else return null; let ?shares = r.nat() else return null; List.add(out, { instrument; shares }) };
    ?List.toArray(out)
  };
  func writeQuote(w : C.Writer, q : T.QuoteSide) { w.nat(q.instrument); w.nat(q.bidPrice); w.nat(q.askPrice); w.nat(q.qty); w.text(q.ref) };
  func readQuote(r : C.Reader) : ?T.QuoteSide {
    let ?instrument = r.nat() else return null; let ?bidPrice = r.nat() else return null; let ?askPrice = r.nat() else return null;
    let ?qty = r.nat() else return null; let ?ref = r.text() else return null;
    ?{ instrument; bidPrice; askPrice; qty; ref }
  };
  func writeBands(w : C.Writer, bs : [T.Band]) { w.len16(bs.size()); for (b in bs.vals()) { w.nat(b.fromPrice); w.nat(b.tick) } };
  func readBands(r : C.Reader) : ?[T.Band] {
    let ?n = r.len16() else return null;
    let out = List.empty<T.Band>();
    var i = 0;
    while (i < n) { let ?fromPrice = r.nat() else return null; let ?tick = r.nat() else return null; List.add(out, { fromPrice; tick }); i += 1 };
    ?List.toArray(out)
  };

  func writeV1(w : C.Writer, c : T.Command) : Bool {
    switch (c) {
      case (#openInstrument(x)) {
        w.byte(1); w.nat(x.instrument); w.principal(x.assetLedger); w.principal(x.cashLedger); w.nat(x.lot); w.nat(x.referencePrice); writeBands(w, x.bands); w.nat(x.collarBps);
        w.nat(x.staticBps); w.nat(x.dynamicBps); w.nat(x.interruptSecs)
      };
      case (#setTrading(x)) { w.byte(2); w.nat(x.instrument); w.bool(x.open) };
      case (#setReference(x)) { w.byte(3); w.nat(x.instrument); w.nat(x.price) };
      case (#deposit(x)) { w.byte(4); w.nat(x.account); w.nat(x.member); w.principal(x.ledger); w.nat(x.amount); w.blob(x.reference) };
      case (#withdraw(x)) { w.byte(5); w.nat(x.account); w.nat(x.member); w.principal(x.ledger); w.nat(x.amount) };
      case (#placeOrder(x)) {
        w.byte(6); w.nat(x.account); w.nat(x.instrument); w.byte(sideCode(x.side)); w.byte(kindCode(x.kind)); w.nat(x.qty); w.nat(x.price); w.nat(x.stopPrice); w.nat(x.peak);
        w.byte(validityCode(x.validity)); w.nat(x.gtdDay); w.byte(selfTradeCode(x.selfTrade)); w.byte(capacityCode(x.capacity)); w.bool(x.shortSale); w.text(x.clientRef); w.nat(x.oco); w.nat(x.trail); w.nat(x.member); w.nat(x.trader)
      };
      case (#cancelOrder(x)) { w.byte(7); w.nat(x.order) };
      case (#amendOrder(x)) { w.byte(8); w.nat(x.order); w.nat(x.qty); w.nat(x.price) };
      case (#massCancel(x)) { w.byte(9); w.nat(x.account); w.nat(x.member); w.nat(x.limit) };
      case (#flush) { w.byte(10) };
      case (#endOfDay(x)) { w.byte(11); w.nat(x.limit) };
      case (#expireGtd(x)) { w.byte(12); w.nat(x.day); w.nat(x.limit) };
      case (#clear(x)) { w.byte(13); w.nat64(x.time) };
      case (#setPhase(x)) { w.byte(14); w.nat(x.instrument); w.byte(phaseCode(x.phase)); w.nat64(x.endFrom); w.nat64(x.endTo) };
      case (#uncross(x)) { w.byte(15); w.nat(x.instrument); w.byte(phaseCode(x.next)) };
      case (#halt(x)) { w.byte(16); w.nat(x.instrument); w.text(x.reason) };
      case (#resume(x)) { w.byte(17); w.nat(x.instrument) };
      case (#kill(x)) { w.byte(18); w.nat(x.member); w.nat(x.trader); w.text(x.reason) };
      case (#killSweep(x)) { w.byte(19); w.nat(x.kill); w.nat(x.limit) };
      case (#revive(x)) { w.byte(20); w.nat(x.kill) };
      case (#setLimits(x)) { w.byte(21); w.nat(x.member); w.nat(x.maxOrderQty); w.nat(x.maxOrderValue); w.nat(x.creditLimit) };
      case (#sealDay(x)) { w.byte(22); w.nat(x.day) };
      case (#setBlackout(x)) { w.byte(23); w.nat(x.instrument); w.blob(x.client); w.nat(x.until); w.text(x.reason) };
      case (#liftBlackout(x)) { w.byte(24); w.nat(x.blackout) };
      case (#borrow(x)) { w.byte(25); w.nat(x.account); w.nat(x.member); w.nat(x.instrument); w.nat(x.qty); w.blob(x.reference) };
      case (#returnBorrow(x)) { w.byte(26); w.nat(x.account); w.nat(x.member); w.nat(x.instrument); w.nat(x.qty) };
      case (#setClearing(x)) { w.byte(27); w.nat(x.ccpAccount); w.nat(x.ccpMember); w.principal(x.cashLedger); w.nat(x.cycleSecs); w.nat(x.cycleDays); w.nat(x.penaltyBps); w.nat(x.deadlineCycles); w.nat(x.fundBps); w.nat(x.fundFloor) };
      case (#setMargin(x)) { w.byte(28); w.nat(x.instrument); w.nat(x.imBps) };
      case (#admitClearing(x)) { w.byte(29); w.nat(x.member); w.nat(x.settlementAccount); w.nat(x.creditLine) };
      case (#designateClearing(x)) { w.byte(30); w.nat(x.account); w.nat(x.member) };
      case (#postCollateral(x)) { w.byte(31); w.nat(x.member); w.nat(x.amount) };
      case (#withdrawCollateral(x)) { w.byte(32); w.nat(x.member); w.nat(x.amount) };
      case (#cutCycle(x)) { w.byte(33); w.nat(x.cycle); w.nat(x.settleDay) };
      case (#settleCycle(x)) { w.byte(34); w.nat(x.cycle) };
      case (#closeOut(x)) { w.byte(35); w.nat(x.member); w.nat(x.instrument) };
      case (#callFund) { w.byte(36) };
      case (#contributeFund(x)) { w.byte(37); w.nat(x.member); w.nat(x.amount) };
      case (#fundSkin(x)) { w.byte(38); w.nat(x.account); w.nat(x.amount) };
      case (#declareDefault(x)) { w.byte(39); w.nat(x.member); w.text(x.reason) };
      case (#closeDefault(x)) { w.byte(40); w.nat(x.member) };
      case (#setFeeSchedule(x)) { w.byte(41); w.nat(x.instrument); w.len16(x.levies.size()); for (l in x.levies.vals()) { w.nat(l.account); w.nat(l.ppm) } };
      case (#sealStatements(x)) { w.byte(42); w.nat(x.day) };
      case (#reconcileMember(x)) { w.byte(43); w.nat(x.member); w.nat(x.day); w.len16(x.balances.size()); for (b in x.balances.vals()) { w.nat(b.account); w.principal(b.ledger); w.nat(b.amount) } };
      case (#registerMaker(x)) { w.byte(44); w.nat(x.member); w.nat(x.instrument); w.nat(x.maxSpreadBps); w.nat(x.minQty); w.nat(x.presenceBps); w.nat(x.rebateBps) };
      case (#quote(x)) { w.byte(45); w.nat(x.account); w.nat(x.member); w.nat(x.trader); writeQuote(w, x.side) };
      case (#massQuote(x)) { w.byte(46); w.nat(x.account); w.nat(x.member); w.nat(x.trader); w.len16(x.sides.size()); for (q in x.sides.vals()) writeQuote(w, q) };
      case (#settleMakers(x)) { w.byte(47); w.nat(x.day) };
      case (#defineIndex(x)) { w.byte(48); w.nat(x.index); w.nat(x.base); w.nat(x.capBps); w.nat(x.haltBps); w.nat(x.suspendBps); writeConstituents(w, x.constituents) };
      case (#reviewIndex(x)) { w.byte(49); w.nat(x.index); writeConstituents(w, x.constituents) };
      case (#corporateAction(x)) {
        w.byte(50); w.nat(x.instrument);
        switch (x.action) { case (#split(a)) { w.byte(1); w.nat(a.num); w.nat(a.den) }; case (#dividend(a)) { w.byte(2); w.nat(a.amount) } };
        w.blob(x.reference)
      };
      case (#tripBreaker(x)) { w.byte(51); w.nat(x.index) };
      case (#setTerms(x)) { w.byte(52); w.nat(x.instrument); writeTerms(w, x.terms) };
      case (#defineNav(x)) { w.byte(53); w.nat(x.instrument); w.nat(x.units); w.nat(x.cash); writeConstituents(w, x.basket) };
      case (#issueReceipt(x)) { w.byte(54); w.nat(x.warehouse); w.nat(x.instrument); w.nat(x.account); w.nat(x.member); w.nat(x.qty); w.blob(x.reference) };
      case (#cancelReceipt(x)) { w.byte(55); w.nat(x.receipt); w.nat(x.account); w.nat(x.member) };
      case (#retire(x)) { w.byte(56); w.nat(x.account); w.nat(x.member); w.nat(x.trader); w.nat(x.instrument); w.nat(x.qty); w.blob(x.beneficiary) };
      case (#exercise(x)) { w.byte(57); w.nat(x.account); w.nat(x.member); w.nat(x.trader); w.nat(x.instrument); w.nat(x.qty) };
      case (#valueDate(x)) { w.byte(58); w.nat(x.instrument); w.nat(x.day) };
    };
    true
  };
  func readV1(r : C.Reader) : ?T.Command {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 {
        let ?instrument = r.nat() else return null; let ?assetLedger = r.principal() else return null; let ?cashLedger = r.principal() else return null;
        let ?lot = r.nat() else return null; let ?referencePrice = r.nat() else return null; let ?bands = readBands(r) else return null; let ?collarBps = r.nat() else return null;
        let ?staticBps = r.nat() else return null; let ?dynamicBps = r.nat() else return null; let ?interruptSecs = r.nat() else return null;
        ?#openInstrument({ instrument; assetLedger; cashLedger; lot; referencePrice; bands; collarBps; staticBps; dynamicBps; interruptSecs })
      };
      case 2 { let ?instrument = r.nat() else return null; let ?open = r.bool() else return null; ?#setTrading({ instrument; open }) };
      case 3 { let ?instrument = r.nat() else return null; let ?price = r.nat() else return null; ?#setReference({ instrument; price }) };
      case 4 { let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?ledger = r.principal() else return null; let ?amount = r.nat() else return null; let ?reference = r.blob() else return null; ?#deposit({ account; member; ledger; amount; reference }) };
      case 5 { let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?ledger = r.principal() else return null; let ?amount = r.nat() else return null; ?#withdraw({ account; member; ledger; amount }) };
      case 6 {
        let ?account = r.nat() else return null; let ?instrument = r.nat() else return null; let ?sc = r.byte() else return null; let ?side = sideOf(sc) else return null;
        let ?kc = r.byte() else return null; let ?kind = kindOf(kc) else return null; let ?qty = r.nat() else return null; let ?price = r.nat() else return null;
        let ?stopPrice = r.nat() else return null; let ?peak = r.nat() else return null; let ?vc = r.byte() else return null; let ?validity = validityOf(vc) else return null;
        let ?gtdDay = r.nat() else return null; let ?tc = r.byte() else return null; let ?selfTrade = selfTradeOf(tc) else return null;
        let ?cc = r.byte() else return null; let ?capacity = capacityOf(cc) else return null; let ?shortSale = r.bool() else return null;
        let ?clientRef = r.text() else return null; let ?oco = r.nat() else return null; let ?trail = r.nat() else return null;
        let ?member = r.nat() else return null; let ?trader = r.nat() else return null;
        ?#placeOrder({ account; instrument; side; kind; qty; price; stopPrice; peak; validity; gtdDay; selfTrade; capacity; shortSale; clientRef; oco; trail; member; trader })
      };
      case 7 { let ?order = r.nat() else return null; ?#cancelOrder({ order }) };
      case 8 { let ?order = r.nat() else return null; let ?qty = r.nat() else return null; let ?price = r.nat() else return null; ?#amendOrder({ order; qty; price }) };
      case 9 { let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?limit = r.nat() else return null; ?#massCancel({ account; member; limit }) };
      case 10 ?#flush;
      case 11 { let ?limit = r.nat() else return null; ?#endOfDay({ limit }) };
      case 12 { let ?day = r.nat() else return null; let ?limit = r.nat() else return null; ?#expireGtd({ day; limit }) };
      case 13 { let ?time = r.nat64() else return null; ?#clear({ time }) };
      case 14 { let ?instrument = r.nat() else return null; let ?pc = r.byte() else return null; let ?phase = phaseOf(pc) else return null; let ?endFrom = r.nat64() else return null; let ?endTo = r.nat64() else return null; ?#setPhase({ instrument; phase; endFrom; endTo }) };
      case 15 { let ?instrument = r.nat() else return null; let ?pc = r.byte() else return null; let ?next = phaseOf(pc) else return null; ?#uncross({ instrument; next }) };
      case 16 { let ?instrument = r.nat() else return null; let ?reason = r.text() else return null; ?#halt({ instrument; reason }) };
      case 17 { let ?instrument = r.nat() else return null; ?#resume({ instrument }) };
      case 18 { let ?member = r.nat() else return null; let ?trader = r.nat() else return null; let ?reason = r.text() else return null; ?#kill({ member; trader; reason }) };
      case 19 { let ?kill = r.nat() else return null; let ?limit = r.nat() else return null; ?#killSweep({ kill; limit }) };
      case 20 { let ?kill = r.nat() else return null; ?#revive({ kill }) };
      case 21 { let ?member = r.nat() else return null; let ?maxOrderQty = r.nat() else return null; let ?maxOrderValue = r.nat() else return null; let ?creditLimit = r.nat() else return null; ?#setLimits({ member; maxOrderQty; maxOrderValue; creditLimit }) };
      case 22 { let ?day = r.nat() else return null; ?#sealDay({ day }) };
      case 23 { let ?instrument = r.nat() else return null; let ?client = r.blob() else return null; let ?until = r.nat() else return null; let ?reason = r.text() else return null; ?#setBlackout({ instrument; client; until; reason }) };
      case 24 { let ?blackout = r.nat() else return null; ?#liftBlackout({ blackout }) };
      case 25 { let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?instrument = r.nat() else return null; let ?qty = r.nat() else return null; let ?reference = r.blob() else return null; ?#borrow({ account; member; instrument; qty; reference }) };
      case 26 { let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?instrument = r.nat() else return null; let ?qty = r.nat() else return null; ?#returnBorrow({ account; member; instrument; qty }) };
      case 27 {
        let ?ccpAccount = r.nat() else return null; let ?ccpMember = r.nat() else return null; let ?cashLedger = r.principal() else return null; let ?cycleSecs = r.nat() else return null;
        let ?cycleDays = r.nat() else return null; let ?penaltyBps = r.nat() else return null; let ?deadlineCycles = r.nat() else return null; let ?fundBps = r.nat() else return null;
        let ?fundFloor = r.nat() else return null;
        ?#setClearing({ ccpAccount; ccpMember; cashLedger; cycleSecs; cycleDays; penaltyBps; deadlineCycles; fundBps; fundFloor })
      };
      case 28 { let ?instrument = r.nat() else return null; let ?imBps = r.nat() else return null; ?#setMargin({ instrument; imBps }) };
      case 29 { let ?member = r.nat() else return null; let ?settlementAccount = r.nat() else return null; let ?creditLine = r.nat() else return null; ?#admitClearing({ member; settlementAccount; creditLine }) };
      case 30 { let ?account = r.nat() else return null; let ?member = r.nat() else return null; ?#designateClearing({ account; member }) };
      case 31 { let ?member = r.nat() else return null; let ?amount = r.nat() else return null; ?#postCollateral({ member; amount }) };
      case 32 { let ?member = r.nat() else return null; let ?amount = r.nat() else return null; ?#withdrawCollateral({ member; amount }) };
      case 33 { let ?cycle = r.nat() else return null; let ?settleDay = r.nat() else return null; ?#cutCycle({ cycle; settleDay }) };
      case 34 { let ?cycle = r.nat() else return null; ?#settleCycle({ cycle }) };
      case 35 { let ?member = r.nat() else return null; let ?instrument = r.nat() else return null; ?#closeOut({ member; instrument }) };
      case 36 ?#callFund;
      case 37 { let ?member = r.nat() else return null; let ?amount = r.nat() else return null; ?#contributeFund({ member; amount }) };
      case 38 { let ?account = r.nat() else return null; let ?amount = r.nat() else return null; ?#fundSkin({ account; amount }) };
      case 39 { let ?member = r.nat() else return null; let ?reason = r.text() else return null; ?#declareDefault({ member; reason }) };
      case 40 { let ?member = r.nat() else return null; ?#closeDefault({ member }) };
      case 41 {
        let ?instrument = r.nat() else return null; let ?n = r.len16() else return null;
        let out = List.empty<T.Levy>();
        for (_ in Nat.range(0, n)) { let ?account = r.nat() else return null; let ?ppm = r.nat() else return null; List.add(out, { account; ppm }) };
        ?#setFeeSchedule({ instrument; levies = List.toArray(out) })
      };
      case 42 { let ?day = r.nat() else return null; ?#sealStatements({ day }) };
      case 43 {
        let ?member = r.nat() else return null; let ?day = r.nat() else return null; let ?n = r.len16() else return null;
        let out = List.empty<T.Attested>();
        for (_ in Nat.range(0, n)) { let ?account = r.nat() else return null; let ?ledger = r.principal() else return null; let ?amount = r.nat() else return null; List.add(out, { account; ledger; amount }) };
        ?#reconcileMember({ member; day; balances = List.toArray(out) })
      };
      case 44 {
        let ?member = r.nat() else return null; let ?instrument = r.nat() else return null; let ?maxSpreadBps = r.nat() else return null;
        let ?minQty = r.nat() else return null; let ?presenceBps = r.nat() else return null; let ?rebateBps = r.nat() else return null;
        ?#registerMaker({ member; instrument; maxSpreadBps; minQty; presenceBps; rebateBps })
      };
      case 45 { let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?trader = r.nat() else return null; let ?side = readQuote(r) else return null; ?#quote({ account; member; trader; side }) };
      case 46 {
        let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?trader = r.nat() else return null; let ?n = r.len16() else return null;
        let out = List.empty<T.QuoteSide>();
        for (_ in Nat.range(0, n)) { let ?q = readQuote(r) else return null; List.add(out, q) };
        ?#massQuote({ account; member; trader; sides = List.toArray(out) })
      };
      case 47 { let ?day = r.nat() else return null; ?#settleMakers({ day }) };
      case 48 {
        let ?index = r.nat() else return null; let ?base = r.nat() else return null; let ?capBps = r.nat() else return null;
        let ?haltBps = r.nat() else return null; let ?suspendBps = r.nat() else return null; let ?constituents = readConstituents(r) else return null;
        ?#defineIndex({ index; base; capBps; haltBps; suspendBps; constituents })
      };
      case 49 { let ?index = r.nat() else return null; let ?constituents = readConstituents(r) else return null; ?#reviewIndex({ index; constituents }) };
      case 50 {
        let ?instrument = r.nat() else return null; let ?k = r.byte() else return null;
        let ?action : ?T.Action = (switch (k) {
          case 1 { switch (r.nat(), r.nat()) { case (?num, ?den) ?#split({ num; den }); case (_) null } };
          case 2 { switch (r.nat()) { case (?amount) ?#dividend({ amount }); case null null } };
          case _ null;
        }) else return null;
        let ?reference = r.blob() else return null;
        ?#corporateAction({ instrument; action; reference })
      };
      case 51 { let ?index = r.nat() else return null; ?#tripBreaker({ index }) };
      case 52 { let ?instrument = r.nat() else return null; let ?terms = readTerms(r) else return null; ?#setTerms({ instrument; terms }) };
      case 53 {
        let ?instrument = r.nat() else return null; let ?units = r.nat() else return null; let ?cash = r.nat() else return null;
        let ?basket = readConstituents(r) else return null;
        ?#defineNav({ instrument; units; cash; basket })
      };
      case 54 {
        let ?warehouse = r.nat() else return null; let ?instrument = r.nat() else return null; let ?account = r.nat() else return null;
        let ?member = r.nat() else return null; let ?qty = r.nat() else return null; let ?reference = r.blob() else return null;
        ?#issueReceipt({ warehouse; instrument; account; member; qty; reference })
      };
      case 55 { let ?receipt = r.nat() else return null; let ?account = r.nat() else return null; let ?member = r.nat() else return null; ?#cancelReceipt({ receipt; account; member }) };
      case 56 {
        let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?trader = r.nat() else return null;
        let ?instrument = r.nat() else return null; let ?qty = r.nat() else return null; let ?beneficiary = r.blob() else return null;
        ?#retire({ account; member; trader; instrument; qty; beneficiary })
      };
      case 57 {
        let ?account = r.nat() else return null; let ?member = r.nat() else return null; let ?trader = r.nat() else return null;
        let ?instrument = r.nat() else return null; let ?qty = r.nat() else return null;
        ?#exercise({ account; member; trader; instrument; qty })
      };
      case 58 { let ?instrument = r.nat() else return null; let ?day = r.nat() else return null; ?#valueDate({ instrument; day }) };
      case _ null;
    }
  };

  public let registry : E.Registry<T.Command> = { domainPrefix = "tachyon-book-command"; current = 1; encoders = [{ version = 1; write = writeV1; read = readV1 }] };

  public let families : [Text] = ["openInstrument", "setTrading", "setReference", "deposit", "withdraw", "placeOrder", "cancelOrder", "amendOrder", "massCancel", "flush", "endOfDay", "expireGtd", "clear",
    "setPhase", "uncross", "halt", "resume", "kill", "killSweep", "revive", "setLimits", "sealDay", "setBlackout", "liftBlackout", "borrow", "returnBorrow",
    "setClearing", "setMargin", "admitClearing", "designateClearing", "postCollateral", "withdrawCollateral", "cutCycle", "settleCycle", "closeOut", "callFund",
    "contributeFund", "fundSkin", "declareDefault", "closeDefault",
    "setFeeSchedule", "sealStatements", "reconcileMember", "registerMaker", "quote", "massQuote", "settleMakers",
    "defineIndex", "reviewIndex", "corporateAction", "tripBreaker",
    "setTerms", "defineNav", "issueReceipt", "cancelReceipt", "retire", "exercise", "valueDate"];
  public func familyOf(c : T.Command) : Text {
    switch (c) {
      case (#openInstrument(_)) "openInstrument"; case (#setTrading(_)) "setTrading"; case (#setReference(_)) "setReference"; case (#deposit(_)) "deposit";
      case (#withdraw(_)) "withdraw"; case (#placeOrder(_)) "placeOrder"; case (#cancelOrder(_)) "cancelOrder"; case (#amendOrder(_)) "amendOrder";
      case (#massCancel(_)) "massCancel"; case (#flush) "flush"; case (#endOfDay(_)) "endOfDay"; case (#expireGtd(_)) "expireGtd"; case (#clear(_)) "clear";
      case (#setPhase(_)) "setPhase"; case (#uncross(_)) "uncross"; case (#halt(_)) "halt"; case (#resume(_)) "resume"; case (#kill(_)) "kill"; case (#killSweep(_)) "killSweep";
      case (#revive(_)) "revive"; case (#setLimits(_)) "setLimits"; case (#sealDay(_)) "sealDay";
      case (#setBlackout(_)) "setBlackout"; case (#liftBlackout(_)) "liftBlackout"; case (#borrow(_)) "borrow"; case (#returnBorrow(_)) "returnBorrow";
      case (#setClearing(_)) "setClearing"; case (#setMargin(_)) "setMargin"; case (#admitClearing(_)) "admitClearing"; case (#designateClearing(_)) "designateClearing";
      case (#postCollateral(_)) "postCollateral"; case (#withdrawCollateral(_)) "withdrawCollateral"; case (#cutCycle(_)) "cutCycle"; case (#settleCycle(_)) "settleCycle"; case (#closeOut(_)) "closeOut";
      case (#callFund) "callFund"; case (#contributeFund(_)) "contributeFund"; case (#fundSkin(_)) "fundSkin"; case (#declareDefault(_)) "declareDefault"; case (#closeDefault(_)) "closeDefault";
      case (#setFeeSchedule(_)) "setFeeSchedule"; case (#sealStatements(_)) "sealStatements"; case (#reconcileMember(_)) "reconcileMember";
      case (#registerMaker(_)) "registerMaker"; case (#quote(_)) "quote"; case (#massQuote(_)) "massQuote"; case (#settleMakers(_)) "settleMakers";
      case (#defineIndex(_)) "defineIndex"; case (#reviewIndex(_)) "reviewIndex"; case (#corporateAction(_)) "corporateAction"; case (#tripBreaker(_)) "tripBreaker";
      case (#setTerms(_)) "setTerms"; case (#defineNav(_)) "defineNav"; case (#issueReceipt(_)) "issueReceipt"; case (#cancelReceipt(_)) "cancelReceipt";
      case (#retire(_)) "retire"; case (#exercise(_)) "exercise"; case (#valueDate(_)) "valueDate";
    }
  };

  /// The order's key (§3.2): SHA-256 under the book's domain of its account, side, price, quantity and client reference.
  public func orderKey(account : Nat, side : T.Side, price : Nat, qty : Nat, clientRef : Text) : Blob {
    let w = C.Writer(); w.nat(account); w.byte(sideCode(side)); w.nat(price); w.nat(qty); w.text(clientRef);
    C.hashWithDomainBlob("tachyon.book.order-key.v1", w.toBlob())
  };

  public type Event = {
    #proposed : Cmd.Proposed;
    #approved : Cmd.Approved;
    #rejected : Cmd.Rejected;
    #expired : Cmd.Expired;
    #executed : { proposal : ?Cmd.ProposalId; version : Nat8; command : T.Command; effects : T.Effects };
  };
  func writeEvent(w : C.Writer, e : Event) {
    switch (e) {
      case (#proposed(p)) { w.byte(1); Cmd.writeProposed(w, p) };
      case (#approved(a)) { w.byte(2); Cmd.writeApproved(w, a) };
      case (#rejected(x)) { w.byte(3); Cmd.writeRejected(w, x) };
      case (#expired(x)) { w.byte(4); Cmd.writeExpired(w, x) };
      case (#executed(x)) { w.byte(5); w.optNat(x.proposal); w.byte(x.version); switch (E.bytesAt(registry, x.version, x.command)) { case (?b) w.blob(b); case null w.blob("") }; w.nats(x.effects) };
    }
  };
  func readEvent(r : C.Reader) : ?Event {
    let ?tag = r.byte() else return null;
    switch (tag) {
      case 1 { let ?p = Cmd.readProposed(r) else return null; ?#proposed(p) };
      case 2 { let ?a = Cmd.readApproved(r) else return null; ?#approved(a) };
      case 3 { let ?x = Cmd.readRejected(r) else return null; ?#rejected(x) };
      case 4 { let ?x = Cmd.readExpired(r) else return null; ?#expired(x) };
      case 5 {
        let ?proposal = r.optNat() else return null; let ?version = r.byte() else return null; let ?bytes = r.blob() else return null;
        let ?command = E.readAt(registry, version, C.Reader(Blob.toArray(bytes))) else return null; let ?effects = r.nats() else return null;
        ?#executed({ proposal; version; command; effects })
      };
      case _ null;
    }
  };
  public let codec : DL.Codec<Event> = { version = 1; supports = func(v : Nat8) : Bool { v == 1 }; domain = "tachyon-book-log"; write = writeEvent; read = readEvent };
}
