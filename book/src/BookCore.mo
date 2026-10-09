/// BookCore.mo: the book (book/SPEC.md) as commands on a certified log, folded into fixed-width rows in stable memory:
/// the instruments as the book trades them, every order, every account's funds per ledger, the deposit references, and
/// the instruments due in the batch. The block is the batch: orders entered with one `now` clear together, at one price
/// per instrument, when the chain's time moves on.
///
/// The book reads the exchange's foundation (`exchange/src/ExchangeCore`) when it judges a command (who is a trader of
/// which member, which account is whose and open, what may be traded); applying a command reads only the command and the
/// book's own rows, so a replay of the book's log alone reproduces every row.
///
/// Attribution: Thebes Core Team.

import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import Sha256 "mo:sha2/Sha256";

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
import MP "mo:kernel/proof/MmrProof";
import Cal "mo:kernel/time/Calendar";
import Rounding "mo:kernel/num/Rounding";
import CivilDate "mo:kernel/num/CivilDate";
import DayCount "mo:kernel/num/DayCount";

import X "../../exchange/src/ExchangeCore";
import XText "../../exchange/src/ExchangeText";

import T "BookTypes";
import F "BookFeed";
import K "BookCanonical";
import L "BookLogic";

module {

  public type Error = { #book : T.Error; #auth : Auth.Error; #encoding : Text };
  public type Result<A> = Result.Result<A, Error>;

  // ═══════════════════════════════════════════════════════
  //  THE PERMISSION CATALOGUE
  // ═══════════════════════════════════════════════════════

  /// Opening an instrument binds the market: four eyes. A deposit is the depository's attestation by the transfer's
  /// reference, recorded once: single. An order, its cancel, its amendment, a withdrawal and a member's own mass cancel
  /// are a trader's acts for its member's accounts: single. The trading flag, the reference price, the flush and the
  /// sweeps are the scheduler's and the operator's system acts whose values the rows and the clock fix: single. The
  /// clear is recorded by the book itself and granted to no principal.
  public func catalogue() : Perm.Catalogue { [
    Perm.p("book.instrument.open", "instrument", #create, #command("openInstrument"), false, false, true),
    Perm.p("book.instrument.trading", "instrument", #update, #command("setTrading"), false, false, false),
    Perm.p("book.instrument.reference", "instrument", #update, #command("setReference"), false, false, false),
    Perm.p("book.funds.deposit", "funds", #create, #command("deposit"), false, false, false),
    Perm.p("book.funds.withdraw", "funds", #update, #command("withdraw"), false, false, false),
    Perm.p("book.order.place", "order", #create, #command("placeOrder"), false, false, false),
    Perm.p("book.order.cancel", "order", #close, #command("cancelOrder"), false, false, false),
    Perm.p("book.order.amend", "order", #update, #command("amendOrder"), false, false, false),
    Perm.p("book.order.masscancel", "order", #close, #command("massCancel"), false, false, false),
    Perm.p("book.batch.flush", "batch", #update, #command("flush"), false, false, false),
    Perm.p("book.sweep.endofday", "order", #close, #command("endOfDay"), false, false, false),
    Perm.p("book.sweep.expire", "order", #close, #command("expireGtd"), false, false, false),
    Perm.p("book.batch.clear", "batch", #update, #command("clear"), false, false, false),
    Perm.p("book.instrument.phase", "instrument", #update, #command("setPhase"), false, false, false),
    Perm.p("book.auction.uncross", "instrument", #update, #command("uncross"), false, false, false),
    Perm.p("book.instrument.halt", "instrument", #update, #command("halt"), false, false, true),
    Perm.p("book.instrument.resume", "instrument", #update, #command("resume"), false, false, true),
    Perm.p("book.kill.set", "kill", #create, #command("kill"), false, false, false),
    Perm.p("book.kill.sweep", "kill", #update, #command("killSweep"), false, false, false),
    Perm.p("book.kill.revive", "kill", #close, #command("revive"), false, false, true),
    Perm.p("book.risk.limits", "limits", #update, #command("setLimits"), false, false, true),
    Perm.p("book.day.seal", "day", #create, #command("sealDay"), false, false, false),
    Perm.p("book.insider.blackout", "insider", #create, #command("setBlackout"), false, false, true),
    Perm.p("book.insider.lift", "insider", #close, #command("liftBlackout"), false, false, true),
    Perm.p("book.borrow.record", "borrow", #create, #command("borrow"), false, false, false),
    Perm.p("book.borrow.return", "borrow", #update, #command("returnBorrow"), false, false, false),
    Perm.p("book.clearing.terms", "clearing", #update, #command("setClearing"), false, false, true),
    Perm.p("book.clearing.margin", "clearing", #update, #command("setMargin"), false, false, true),
    Perm.p("book.clearing.admit", "clearing", #create, #command("admitClearing"), false, false, true),
    Perm.p("book.clearing.designate", "clearing", #create, #command("designateClearing"), false, false, true),
    Perm.p("book.collateral.post", "collateral", #create, #command("postCollateral"), false, false, false),
    Perm.p("book.collateral.withdraw", "collateral", #update, #command("withdrawCollateral"), false, false, false),
    Perm.p("book.cycle.cut", "cycle", #create, #command("cutCycle"), false, false, false),
    Perm.p("book.cycle.settle", "cycle", #update, #command("settleCycle"), false, false, false),
    Perm.p("book.cycle.closeout", "cycle", #create, #command("closeOut"), false, false, false),
    Perm.p("book.fund.call", "fund", #update, #command("callFund"), false, false, false),
    Perm.p("book.fund.contribute", "fund", #create, #command("contributeFund"), false, false, false),
    Perm.p("book.fund.skin", "fund", #create, #command("fundSkin"), false, false, true),
    Perm.p("book.default.declare", "default", #create, #command("declareDefault"), false, false, true),
    Perm.p("book.default.close", "default", #close, #command("closeDefault"), false, false, true),
    Perm.p("book.fees.schedule", "fees", #update, #command("setFeeSchedule"), false, false, true),
    Perm.p("book.statements.seal", "statement", #create, #command("sealStatements"), false, false, false),
    Perm.p("book.member.reconcile", "reconciliation", #create, #command("reconcileMember"), false, false, false),
    Perm.p("book.maker.register", "maker", #create, #command("registerMaker"), false, false, true),
    Perm.p("book.maker.quote", "order", #create, #command("quote"), false, false, false),
    Perm.p("book.maker.massquote", "order", #create, #command("massQuote"), false, false, false),
    Perm.p("book.maker.settle", "maker", #update, #command("settleMakers"), false, false, false),
    Perm.p("book.index.define", "index", #create, #command("defineIndex"), false, false, true),
    Perm.p("book.index.review", "index", #update, #command("reviewIndex"), false, false, true),
    Perm.p("book.action.apply", "instrument", #update, #command("corporateAction"), false, false, true),
    Perm.p("book.breaker.trip", "index", #update, #command("tripBreaker"), false, false, false),
    Perm.p("book.terms.set", "instrument", #update, #command("setTerms"), false, false, true),
    Perm.p("book.nav.define", "fund", #create, #command("defineNav"), false, false, true),
    Perm.p("book.receipt.issue", "receipt", #create, #command("issueReceipt"), false, false, true),
    Perm.p("book.receipt.cancel", "receipt", #close, #command("cancelReceipt"), false, false, true),
    Perm.p("book.certificate.retire", "certificate", #close, #command("retire"), false, false, false),
    Perm.p("book.right.exercise", "right", #update, #command("exercise"), false, false, false),
    Perm.p("book.bond.valuedate", "instrument", #update, #command("valueDate"), false, false, false),
    Perm.p("book.attestors.set", "price", #update, #command("setAttestors"), false, false, true),
    Perm.p("book.price.attest", "price", #create, #command("attestPrice"), false, false, false),
    Perm.p("book.derivatives.settle", "position", #update, #command("settleDerivatives"), false, false, false),
    Perm.p("command.approve", "command", #approve, #method("approve"), false, false, false),
    Perm.p("command.reject", "command", #reject, #method("reject"), false, false, false),
  ] };
  public func singleActs() : [(Text, Text)] { [
    ("book.instrument.trading", "the scheduler opens or closes an instrument for clearing as its segment's phase changes; nothing moves but the flag"),
    ("book.instrument.reference", "the operator's system records the reference price on the tick; it bounds market orders' collar prices"),
    ("book.funds.deposit", "the depository attests a transfer into the venue by its reference, recorded once; the amount is the transfer's"),
    ("book.funds.withdraw", "a trader of the account's member takes available funds out; nothing held can be withdrawn"),
    ("book.order.place", "a trader of the account's member enters an order within the funds the account holds and the instrument's rules"),
    ("book.order.cancel", "a trader of the account's member cancels its order; what the order held returns"),
    ("book.order.amend", "a trader of the account's member changes its live order's quantity or price within its funds; priority follows the rule of section 5"),
    ("book.order.masscancel", "a trader of the account's member cancels the account's open orders in slices; what they held returns"),
    ("book.batch.flush", "the scheduler records a due clear when no other command arrives; the clear's outcome is the batch's"),
    ("book.sweep.endofday", "the scheduler cancels good-for-day orders after the close, in slices"),
    ("book.sweep.expire", "the scheduler cancels good-till-date orders past their day, the day being the chain's market day"),
    ("book.batch.clear", "the clear of a batch, recorded by the book when the chain's time moves past it; no principal submits it"),
    ("book.instrument.phase", "the scheduler moves an instrument to the phase its segment's schedule names; a halted instrument takes no phase"),
    ("book.auction.uncross", "the scheduler, or the venue at the drawn end, uncrosses a call auction at the price the rule of section 9 fixes"),
    ("book.kill.set", "the operator, or a trader of the member, blocks a member or a trader at once; lifting it takes four eyes"),
    ("book.kill.sweep", "the operator's system cancels a killed member's or trader's open orders in slices; what they held returns"),
    ("book.day.seal", "the scheduler seals the market day at its end: the day's statistics recorded and their file's hash written; it moves no order and no funds"),
    ("book.borrow.record", "the depository attests a securities loan settled at the custodian, as it attests a deposit: the shares credited and recorded owed"),
    ("book.borrow.return", "a trader of the member returns borrowed shares from its account; it moves what the account holds and what it owes, nothing else"),
    ("book.collateral.post", "a trader of the clearing member moves cash from its settlement account to the CCP as its collateral; nothing else moves"),
    ("book.collateral.withdraw", "a trader of the clearing member takes collateral back to its settlement account within its margin requirement and the CCP's free cash"),
    ("book.cycle.cut", "the scheduler closes the open cycle when its length has passed, or at the day's end with the settlement day the calendar gives"),
    ("book.cycle.settle", "the scheduler settles the oldest cut cycle when it is due; every amount is the fold's, none is typed"),
    ("book.cycle.closeout", "the scheduler sells, at the collar, the shares the CCP holds for a member past its deadline or in default; the rule fixes the order"),
    ("book.fund.call", "the scheduler sets each clearing member's fund requirement from its largest cycle purchase in the fold"),
    ("book.fund.contribute", "a trader of the clearing member pays its fund contribution from its settlement account, up to the requirement"),
    ("book.statements.seal", "the scheduler seals the members' open statements at the market day's end; the lines are the fills the fold recorded"),
    ("book.member.reconcile", "a trader of the member attests its own accounts' balances; the comparison with the book's is recorded and moves nothing"),
    ("book.maker.quote", "a registered maker's trader replaces its quote on one of its member's pre-funded accounts, both sides within its funds"),
    ("book.maker.massquote", "a registered maker's trader replaces up to sixteen quotes at once, each as a quote, all or nothing"),
    ("book.maker.settle", "the scheduler closes the makers' period at the day's end; presence and rebates are the fold's, none typed"),
    ("book.breaker.trip", "the market-wide breaker, recorded by the book itself in the block after the one that moved an index; no principal submits it"),
    ("book.certificate.retire", "a trader of the account's member retires certificates the account holds free; they leave circulation and nothing else moves"),
    ("book.price.attest", "an attestor records its own price for a derivative on the market day, once; the daily price is the median of the three"),
    ("book.derivatives.settle", "the scheduler settles a closed derivative's positions at the attested price or, at expiry, the index's level; every amount is the fold's"),
    ("book.bond.valuedate", "the scheduler records a bond's value date for the market day, the day the exchange's calendar gives; it moves nothing"),
    ("book.right.exercise", "a trader of the account's member exercises rights the account holds free by the deadline, paying the subscription from its own cash"),
  ] };
  public let commandNames : [Text] = K.families;
  public let methodNames : [Text] = ["approve", "reject"];
  public func permissionOf(c : T.Command) : Auth.Permission {
    switch (Perm.byCommand(catalogue(), K.familyOf(c))) { case (?p) p; case null Runtime.trap("catalogue: no permission guards " # K.familyOf(c)) }
  };

  // ═══════════════════════════════════════════════════════
  //  THE ROWS
  // ═══════════════════════════════════════════════════════

  let MAXP : Nat = 18_446_744_073_709_551_615;   // 2^64 - 1: a buy's price key is MAXP - price, so the best is first
  let PRINCIPAL_BYTES = 30;
  func padded(b : R.Buf, width : Nat) : Blob { while (b.size() < width) R.putByte(b, 0); R.done(b, width) };
  func putPrincipal(b : R.Buf, p : Principal) { let bs = Principal.toBlob(p); R.putNat(b, bs.size(), 1); for (x in bs.vals()) R.putByte(b, x); var k = bs.size(); while (k < 29) { R.putByte(b, 0); k += 1 } };
  func getPrincipal(a : [Nat8], off : Nat) : Principal { let n = R.getNat(a, off, 1); Principal.fromBlob(R.getBlob(a, off + 1, n)) };
  func priceKey(side : T.Side, price : Nat) : Nat { switch (side) { case (#buy) MAXP - price; case (#sell) price } };
  func sideByte(s : T.Side) : Nat8 { K.sideCode(s) };
  func isLiveish(o : T.Order) : Bool { o.status == #live or o.status == #waiting };
  func immediate(k : T.Kind) : Bool { k == #market or k == #ioc or k == #fok or k == #stop or k == #trailingStop };
  func isStop(k : T.Kind) : Bool { k == #stop or k == #stopLimit or k == #trailingStop };

  public let ORDER_ROW_BYTES = 176;   // see checkSums for the fields
  func encodeOrder(o : T.Order) : Blob {
    let b = R.buf();
    R.putNat(b, o.account, 8); R.putNat(b, o.instrument, 8); R.putByte(b, K.sideCode(o.side)); R.putByte(b, K.kindCode(o.kind)); R.putNat(b, o.qty, 8); R.putNat(b, o.remaining, 8);
    R.putNat(b, o.price, 8); R.putNat(b, o.stopPrice, 8); R.putNat(b, o.peak, 8); R.putByte(b, K.validityCode(o.validity)); R.putNat(b, o.gtdDay, 4);
    R.putByte(b, K.selfTradeCode(o.selfTrade)); R.putByte(b, K.capacityCode(o.capacity)); R.putBool(b, o.shortSale); R.putText(b, o.clientRef, T.CLIENT_REF_BYTES);
    R.putNat(b, o.oco, 8); R.putNat(b, Nat64.toNat(o.prio), 8); R.putBlob(b, o.key, 32); R.putByte(b, K.statusCode(o.status)); R.putNat(b, o.held, 8); R.putNat(b, o.filled, 8);
    R.putNat(b, o.trail, 8); R.putNat(b, o.member, 8); R.putNat(b, o.trader, 8);
    padded(b, ORDER_ROW_BYTES)
  };
  func decodeOrder(a : [Nat8]) : T.Order {
    let ?side = K.sideOf(a[16]) else Runtime.trap("order row: bad side byte");
    let ?kind = K.kindOf(a[17]) else Runtime.trap("order row: bad kind byte");
    let ?validity = K.validityOf(a[58]) else Runtime.trap("order row: bad validity byte");
    let ?selfTrade = K.selfTradeOf(a[63]) else Runtime.trap("order row: bad self-trade byte");
    let ?capacity = K.capacityOf(a[64]) else Runtime.trap("order row: bad capacity byte");
    let ?status = K.statusOf(a[134]) else Runtime.trap("order row: bad status byte");
    { account = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); side; kind; qty = R.getNat(a, 18, 8); remaining = R.getNat(a, 26, 8); price = R.getNat(a, 34, 8);
      stopPrice = R.getNat(a, 42, 8); peak = R.getNat(a, 50, 8); validity; gtdDay = R.getNat(a, 59, 4); selfTrade; capacity; shortSale = R.getBool(a, 65);
      clientRef = R.getText(a, 66, T.CLIENT_REF_BYTES); oco = R.getNat(a, 86, 8); prio = Nat64.fromNat(R.getNat(a, 94, 8)); key = R.getBlob(a, 102, 32); status; held = R.getNat(a, 135, 8); filled = R.getNat(a, 143, 8); trail = R.getNat(a, 151, 8); member = R.getNat(a, 159, 8); trader = R.getNat(a, 167, 8) }
  };
  func bookKey(o : T.Order) : Blob { let b = R.buf(); R.putNat(b, o.instrument, 8); R.putByte(b, sideByte(o.side)); R.putNat(b, priceKey(o.side, o.price), 8); R.putNat(b, Nat64.toNat(o.prio), 8); R.putBlob(b, o.key, 32); R.done(b, 57) };
  func stopKey(id : Nat, o : T.Order) : Blob { let b = R.buf(); R.putNat(b, o.instrument, 8); R.putByte(b, sideByte(o.side)); R.putNat(b, switch (o.side) { case (#buy) o.stopPrice; case (#sell) MAXP - o.stopPrice }, 8); R.putNat(b, id, 8); R.done(b, 25) };
  func ownKey(id : Nat, o : T.Order) : Blob { let b = R.buf(); R.putNat(b, o.account, 8); R.putNat(b, o.instrument, 8); R.putByte(b, sideByte(o.side)); R.putNat(b, priceKey(o.side, o.price), 8); R.putNat(b, id, 8); R.done(b, 33) };
  func trailKey(id : Nat, o : T.Order) : Blob { let b = R.buf(); R.putNat(b, o.instrument, 8); R.putByte(b, sideByte(o.side)); R.putNat(b, id, 8); R.done(b, 17) };
  func refKey(account : Nat, clientRef : Text) : Blob { let b = R.buf(); R.putNat(b, account, 8); R.putText(b, clientRef, T.CLIENT_REF_BYTES); R.done(b, 28) };
  public let orders : RS.Decl<T.Order> = {
    table = "orders"; idBytes = 8; rowBytes = ORDER_ROW_BYTES; encode = encodeOrder; decode = decodeOrder;
    indexes = [
      { name = "book"; keyBytes = 57; keyOf = func(_ : Nat, o : T.Order) : ?Blob { if (o.status == #live) ?bookKey(o) else null } },
      { name = "stops"; keyBytes = 25; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (o.status == #waiting) ?stopKey(id, o) else null } },
      { name = "own"; keyBytes = 33; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (isLiveish(o)) ?ownKey(id, o) else null } },
      { name = "ref"; keyBytes = 28; keyOf = func(_ : Nat, o : T.Order) : ?Blob { ?refKey(o.account, o.clientRef) } },
      { name = "day"; keyBytes = 8; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (isLiveish(o) and o.validity == #day) ?R.key(id, 8) else null } },
      { name = "gtd"; keyBytes = 12; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (isLiveish(o) and o.validity == #gtd) ?R.key2(o.gtdDay, 4, id, 8) else null } },
      { name = "trailing"; keyBytes = 17; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (o.status == #waiting and o.kind == #trailingStop) ?trailKey(id, o) else null } },
      { name = "member"; keyBytes = 16; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (isLiveish(o)) ?R.key2(o.member, 8, id, 8) else null } },
      { name = "trader"; keyBytes = 16; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (isLiveish(o)) ?R.key2(o.trader, 8, id, 8) else null } },
      { name = "immediate"; keyBytes = 16; keyOf = func(id : Nat, o : T.Order) : ?Blob { if (o.status == #live and immediate(o.kind)) ?R.key2(o.instrument, 8, id, 8) else null } },
    ];
  };

  public let BALANCE_ROW_BYTES = 64;   // account 8, ledger 30, available 8, held 8, pad 10
  func balanceKey(account : Nat, ledger : Principal) : Blob { let b = R.buf(); R.putNat(b, account, 8); putPrincipal(b, ledger); R.done(b, 38) };
  public let balances : RS.Decl<T.Balance> = {
    table = "balances"; idBytes = 8; rowBytes = BALANCE_ROW_BYTES;
    encode = func(x : T.Balance) : Blob { let b = R.buf(); R.putNat(b, x.account, 8); putPrincipal(b, x.ledger); R.putNat(b, x.available, 8); R.putNat(b, x.held, 8); padded(b, BALANCE_ROW_BYTES) };
    decode = func(a : [Nat8]) : T.Balance { { account = R.getNat(a, 0, 8); ledger = getPrincipal(a, 8); available = R.getNat(a, 38, 8); held = R.getNat(a, 46, 8) } };
    indexes = [{ name = "byAccountLedger"; keyBytes = 38; keyOf = func(_ : Nat, x : T.Balance) : ?Blob { ?balanceKey(x.account, x.ledger) } }];
  };
  public type RefRow = { reference : Blob };
  public let REF_ROW_BYTES = 32;
  public let refs : RS.Decl<RefRow> = {
    table = "depositrefs"; idBytes = 8; rowBytes = REF_ROW_BYTES;
    encode = func(x : RefRow) : Blob { let b = R.buf(); R.putBlob(b, x.reference, 32); R.done(b, REF_ROW_BYTES) };
    decode = func(a : [Nat8]) : RefRow { { reference = R.getBlob(a, 0, 32) } };
    indexes = [{ name = "byRef"; keyBytes = 32; keyOf = func(_ : Nat, x : RefRow) : ?Blob { ?x.reference } }];
  };
  public let INSTRUMENT_ROW_BYTES = 400;   // see checkSums for the fields
  public let instruments : RS.Decl<T.Instrument> = {
    table = "bookinstruments"; idBytes = 8; rowBytes = INSTRUMENT_ROW_BYTES;
    encode = func(x : T.Instrument) : Blob {
      let b = R.buf(); putPrincipal(b, x.assetLedger); putPrincipal(b, x.cashLedger); R.putNat(b, x.lot, 8); R.putNat(b, x.referencePrice, 8); R.putNat(b, x.bands.size(), 1);
      var i = 0; while (i < T.MAX_BANDS) { if (i < x.bands.size()) { R.putNat(b, x.bands[i].fromPrice, 8); R.putNat(b, x.bands[i].tick, 8) } else { R.putNat(b, 0, 8); R.putNat(b, 0, 8) }; i += 1 };
      R.putNat(b, x.collarBps, 4); R.putByte(b, K.phaseCode(x.phase)); R.putNat(b, x.lastPrice, 8);
      R.putNat(b, x.staticBps, 4); R.putNat(b, x.dynamicBps, 4); R.putNat(b, x.interruptSecs, 4); R.putNat(b, Nat64.toNat(x.endFrom), 8); R.putNat(b, Nat64.toNat(x.endTo), 8);
      R.putNat(b, Nat64.toNat(x.interruptUntil), 8); R.putNat(b, x.closePrice, 8);
      padded(b, INSTRUMENT_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : T.Instrument {
      let n = R.getNat(a, 76, 1);
      let bands = Array.tabulate<T.Band>(n, func(i) { { fromPrice = R.getNat(a, 77 + i * 16, 8); tick = R.getNat(a, 85 + i * 16, 8) } });
      let p = 77 + T.MAX_BANDS * 16;
      let ?phase = K.phaseOf(a[p + 4]) else Runtime.trap("instrument row: bad phase byte");
      { assetLedger = getPrincipal(a, 0); cashLedger = getPrincipal(a, 30); lot = R.getNat(a, 60, 8); referencePrice = R.getNat(a, 68, 8); bands; collarBps = R.getNat(a, p, 4); phase;
        lastPrice = R.getNat(a, p + 5, 8); staticBps = R.getNat(a, p + 13, 4); dynamicBps = R.getNat(a, p + 17, 4); interruptSecs = R.getNat(a, p + 21, 4);
        endFrom = Nat64.fromNat(R.getNat(a, p + 25, 8)); endTo = Nat64.fromNat(R.getNat(a, p + 33, 8)); interruptUntil = Nat64.fromNat(R.getNat(a, p + 41, 8)); closePrice = R.getNat(a, p + 49, 8) }
    };
    // a partial index: the instruments in a call phase, which the venue's random end reads (SPEC §8)
    indexes = [{ name = "calling"; keyBytes = 8; keyOf = func(id : Nat, x : T.Instrument) : ?Blob { if (x.phase == #auction or x.phase == #closingAuction) ?R.key(id, 8) else null } }];
  };
  /// The feed hash of every block (SPEC §13), by the block's index.
  public let feedHashes : RS.Decl<Blob> = {
    table = "feedhashes"; idBytes = 8; rowBytes = 32;
    encode = func(x : Blob) : Blob { x };
    decode = func(a : [Nat8]) : Blob { Blob.fromArray(a) };
    indexes = [];
  };
  /// An instrument's statistics (SPEC §15): for the session since the last seal, or for a sealed day.
  public type Stats = { first : Nat; high : Nat; low : Nat; last : Nat; closing : Nat; volume : Nat; value : Nat; trades : Nat };
  public let NO_STATS : Stats = { first = 0; high = 0; low = 0; last = 0; closing = 0; volume = 0; value = 0; trades = 0 };
  public let STATS_ROW_BYTES = 64;   // eight figures of 8 bytes
  func putStats(b : R.Buf, x : Stats) { for (v in [x.first, x.high, x.low, x.last, x.closing, x.volume, x.value, x.trades].vals()) R.putNat(b, v, 8) };
  func getStats(a : [Nat8], p : Nat) : Stats {
    { first = R.getNat(a, p, 8); high = R.getNat(a, p + 8, 8); low = R.getNat(a, p + 16, 8); last = R.getNat(a, p + 24, 8); closing = R.getNat(a, p + 32, 8);
      volume = R.getNat(a, p + 40, 8); value = R.getNat(a, p + 48, 8); trades = R.getNat(a, p + 56, 8) }
  };
  /// The session's statistics, by instrument id.
  public let statRows : RS.Decl<Stats> = {
    table = "sessionstats"; idBytes = 8; rowBytes = STATS_ROW_BYTES;
    encode = func(x : Stats) : Blob { let b = R.buf(); putStats(b, x); padded(b, STATS_ROW_BYTES) };
    decode = func(a : [Nat8]) : Stats { getStats(a, 0) };
    indexes = [];
  };
  /// A sealed day's row for an instrument: its statistics and the reference price at the seal, found by day.
  public type DayRow = { day : Nat; instrument : Nat; stats : Stats; reference : Nat };
  public let DAY_ROW_BYTES = 88;   // day 8, instrument 8, statistics 64, reference 8
  public let dayRows : RS.Decl<DayRow> = {
    table = "days"; idBytes = 8; rowBytes = DAY_ROW_BYTES;
    encode = func(x : DayRow) : Blob { let b = R.buf(); R.putNat(b, x.day, 8); R.putNat(b, x.instrument, 8); putStats(b, x.stats); R.putNat(b, x.reference, 8); padded(b, DAY_ROW_BYTES) };
    decode = func(a : [Nat8]) : DayRow { { day = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); stats = getStats(a, 16); reference = R.getNat(a, 80, 8) } };
    indexes = [{ name = "byDay"; keyBytes = 16; keyOf = func(_ : Nat, x : DayRow) : ?Blob { ?R.key2(x.day, 8, x.instrument, 8) } }];
  };
  /// A seal (SPEC §15): the day, the file's rows and its hash; found by day.
  public type SealRow = { day : Nat; rows : Nat; hash : Blob };
  public let SEAL_ROW_BYTES = 48;   // day 8, rows 8, hash 32
  public let sealRows : RS.Decl<SealRow> = {
    table = "seals"; idBytes = 8; rowBytes = SEAL_ROW_BYTES;
    encode = func(x : SealRow) : Blob { let b = R.buf(); R.putNat(b, x.day, 8); R.putNat(b, x.rows, 8); R.putBlob(b, x.hash, 32); padded(b, SEAL_ROW_BYTES) };
    decode = func(a : [Nat8]) : SealRow { { day = R.getNat(a, 0, 8); rows = R.getNat(a, 8, 8); hash = R.getBlob(a, 16, 32) } };
    indexes = [{ name = "byDay"; keyBytes = 8; keyOf = func(_ : Nat, x : SealRow) : ?Blob { ?R.key(x.day, 8) } }];
  };
  /// An insider blackout (SPEC §16): a client code barred from an instrument until the end of a market day (0: until
  /// lifted); found while active by (instrument, client).
  public type Blackout = { instrument : Nat; client : Blob; until : Nat; active : Bool };
  public let BLACKOUT_ROW_BYTES = 49;   // instrument 8, client 32, until 8, active 1
  func blackoutKey(instrument : Nat, client : Blob) : Blob { Blob.fromArray(Array.concat<Nat8>(Blob.toArray(R.key(instrument, 8)), Blob.toArray(client))) };
  public let blackoutRows : RS.Decl<Blackout> = {
    table = "blackouts"; idBytes = 8; rowBytes = BLACKOUT_ROW_BYTES;
    encode = func(x : Blackout) : Blob { let b = R.buf(); R.putNat(b, x.instrument, 8); R.putBlob(b, x.client, 32); R.putNat(b, x.until, 8); R.putBool(b, x.active); padded(b, BLACKOUT_ROW_BYTES) };
    decode = func(a : [Nat8]) : Blackout { { instrument = R.getNat(a, 0, 8); client = R.getBlob(a, 8, 32); until = R.getNat(a, 40, 8); active = R.getBool(a, 48) } };
    indexes = [{ name = "active"; keyBytes = 40; keyOf = func(_ : Nat, x : Blackout) : ?Blob { if (x.active) ?blackoutKey(x.instrument, x.client) else null } }];
  };
  /// Shares an account owes from securities loans in an instrument (SPEC §17); found by (account, instrument).
  public type BorrowRow = { account : Nat; instrument : Nat; owed : Nat };
  public let BORROW_ROW_BYTES = 24;
  public let borrowRows : RS.Decl<BorrowRow> = {
    table = "borrows"; idBytes = 8; rowBytes = BORROW_ROW_BYTES;
    encode = func(x : BorrowRow) : Blob { let b = R.buf(); R.putNat(b, x.account, 8); R.putNat(b, x.instrument, 8); R.putNat(b, x.owed, 8); padded(b, BORROW_ROW_BYTES) };
    decode = func(a : [Nat8]) : BorrowRow { { account = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); owed = R.getNat(a, 16, 8) } };
    indexes = [{ name = "byAccount"; keyBytes = 16; keyOf = func(_ : Nat, x : BorrowRow) : ?Blob { ?R.key2(x.account, 8, x.instrument, 8) } }];
  };
  // ── the central counterparty (SPEC §18 to §21) ──
  /// The market's clearing terms: the CCP's account and its member, the clearing currency, the cycle (seconds, or business
  /// days when not 0), the fail penalty a cycle, the close-out deadline in cycles, the fund's rate and floor.
  public type ClearingTerms = { ccpAccount : Nat; ccpMember : Nat; cashLedger : Principal; cycleSecs : Nat; cycleDays : Nat; penaltyBps : Nat; deadlineCycles : Nat; fundBps : Nat; fundFloor : Nat };
  public let TERMS_BYTES = 94;   // account 8, member 8, ledger 30, six figures of 8
  func encodeTerms(x : ClearingTerms) : Blob {
    let b = R.buf(); R.putNat(b, x.ccpAccount, 8); R.putNat(b, x.ccpMember, 8); putPrincipal(b, x.cashLedger);
    for (v in [x.cycleSecs, x.cycleDays, x.penaltyBps, x.deadlineCycles, x.fundBps, x.fundFloor].vals()) R.putNat(b, v, 8);
    padded(b, TERMS_BYTES)
  };
  /// A clearing member's row: its settlement account and credit line; what the CCP holds for it (collateral, its fund
  /// contribution) and the contribution required; its open buys' initial margin; its cash obligations in the cycles not
  /// yet settled (owed to it, owed by it); a rolled fail's debt and the cycles it has failed in a row; its largest cycle
  /// purchase; its status (1 active, 2 in default, 3 closed after default).
  public type ClearingMember = {
    member : Nat; settlementAccount : Nat; creditLine : Nat; collateral : Nat; fund : Nat; fundRequired : Nat; imOrders : Nat;
    owedTo : Nat; owedBy : Nat; debt : Nat; fails : Nat; peak : Nat; status : Nat;
  };
  public let CLEARING_ROW_BYTES = 97;   // twelve figures of 8, status 1
  public let clearingRows : RS.Decl<ClearingMember> = {
    table = "clearingmembers"; idBytes = 8; rowBytes = CLEARING_ROW_BYTES;
    encode = func(x : ClearingMember) : Blob {
      let b = R.buf();
      for (v in [x.member, x.settlementAccount, x.creditLine, x.collateral, x.fund, x.fundRequired, x.imOrders, x.owedTo, x.owedBy, x.debt, x.fails, x.peak].vals()) R.putNat(b, v, 8);
      R.putNat(b, x.status, 1); padded(b, CLEARING_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : ClearingMember {
      { member = R.getNat(a, 0, 8); settlementAccount = R.getNat(a, 8, 8); creditLine = R.getNat(a, 16, 8); collateral = R.getNat(a, 24, 8); fund = R.getNat(a, 32, 8);
        fundRequired = R.getNat(a, 40, 8); imOrders = R.getNat(a, 48, 8); owedTo = R.getNat(a, 56, 8); owedBy = R.getNat(a, 64, 8); debt = R.getNat(a, 72, 8);
        fails = R.getNat(a, 80, 8); peak = R.getNat(a, 88, 8); status = R.getNat(a, 96, 1) }
    };
    indexes = [{ name = "byMember"; keyBytes = 8; keyOf = func(_ : Nat, x : ClearingMember) : ?Blob { ?R.key(x.member, 8) } }];
  };
  /// An account designated for clearing, with its member.
  public type Designation = { account : Nat; member : Nat };
  public let designationRows : RS.Decl<Designation> = {
    table = "designations"; idBytes = 8; rowBytes = 16;
    encode = func(x : Designation) : Blob { let b = R.buf(); R.putNat(b, x.account, 8); R.putNat(b, x.member, 8); padded(b, 16) };
    decode = func(a : [Nat8]) : Designation { { account = R.getNat(a, 0, 8); member = R.getNat(a, 8, 8) } };
    indexes = [{ name = "byAccount"; keyBytes = 8; keyOf = func(_ : Nat, x : Designation) : ?Blob { ?R.key(x.account, 8) } }];
  };
  /// The shares the CCP holds for a member in an instrument (bought and not yet delivered, or pledged for its sales), and
  /// how many of them its open sales and close-outs hold.
  public type CustodyRow = { member : Nat; instrument : Nat; qty : Nat; held : Nat };
  public let custodyRows : RS.Decl<CustodyRow> = {
    table = "ccpcustody"; idBytes = 8; rowBytes = 32;
    encode = func(x : CustodyRow) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.instrument, 8); R.putNat(b, x.qty, 8); R.putNat(b, x.held, 8); padded(b, 32) };
    decode = func(a : [Nat8]) : CustodyRow { { member = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); qty = R.getNat(a, 16, 8); held = R.getNat(a, 24, 8) } };
    indexes = [{ name = "byMember"; keyBytes = 16; keyOf = func(_ : Nat, x : CustodyRow) : ?Blob { ?R.key2(x.member, 8, x.instrument, 8) } }];
  };
  /// An instrument's initial margin in basis points, by the instrument's id.
  public let marginRows : RS.Decl<Nat> = {
    table = "margins"; idBytes = 8; rowBytes = 8;
    encode = func(x : Nat) : Blob { let b = R.buf(); R.putNat(b, x, 8); padded(b, 8) };
    decode = func(a : [Nat8]) : Nat { R.getNat(a, 0, 8) };
    indexes = [];
  };
  /// A close-out order of the CCP and the member whose debt its proceeds pay.
  public type Closeout = { order : Nat; member : Nat };
  public let closeoutRows : RS.Decl<Closeout> = {
    table = "closeouts"; idBytes = 8; rowBytes = 16;
    encode = func(x : Closeout) : Blob { let b = R.buf(); R.putNat(b, x.order, 8); R.putNat(b, x.member, 8); padded(b, 16) };
    decode = func(a : [Nat8]) : Closeout { { order = R.getNat(a, 0, 8); member = R.getNat(a, 8, 8) } };
    indexes = [{ name = "byOrder"; keyBytes = 8; keyOf = func(_ : Nat, x : Closeout) : ?Blob { ?R.key(x.order, 8) } }];
  };
  /// A member's cash obligations in one cycle: owed to it (its sales) and owed by it (its purchases), gross.
  public type Obligation = { member : Nat; cycle : Nat; owedTo : Nat; owedBy : Nat };
  public let obligationRows : RS.Decl<Obligation> = {
    table = "obligations"; idBytes = 8; rowBytes = 32;
    encode = func(x : Obligation) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.cycle, 8); R.putNat(b, x.owedTo, 8); R.putNat(b, x.owedBy, 8); padded(b, 32) };
    decode = func(a : [Nat8]) : Obligation { { member = R.getNat(a, 0, 8); cycle = R.getNat(a, 8, 8); owedTo = R.getNat(a, 16, 8); owedBy = R.getNat(a, 24, 8) } };
    indexes = [{ name = "byMemberCycle"; keyBytes = 16; keyOf = func(_ : Nat, x : Obligation) : ?Blob { ?R.key2(x.member, 8, x.cycle, 8) } }];
  };
  /// The shares a member bought in an instrument in one cycle: not delivered before that cycle is paid (DvP).
  public type Bought = { member : Nat; instrument : Nat; cycle : Nat; qty : Nat };
  public let boughtRows : RS.Decl<Bought> = {
    table = "bought"; idBytes = 8; rowBytes = 32;
    encode = func(x : Bought) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.instrument, 8); R.putNat(b, x.cycle, 8); R.putNat(b, x.qty, 8); padded(b, 32) };
    decode = func(a : [Nat8]) : Bought { { member = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); cycle = R.getNat(a, 16, 8); qty = R.getNat(a, 24, 8) } };
    indexes = [{ name = "byKey"; keyBytes = 24; keyOf = func(_ : Nat, x : Bought) : ?Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.instrument, 8); R.putNat(b, x.cycle, 8); ?R.done(b, 24) } }];
  };
  /// A cut cycle, by its number: when it was cut, the market day it settles on (0: at once), whether it is settled.
  public type CycleRow = { cutAt : Nat64; settleDay : Nat; settled : Bool };
  public let cycleRows : RS.Decl<CycleRow> = {
    table = "cycles"; idBytes = 8; rowBytes = 17;
    encode = func(x : CycleRow) : Blob { let b = R.buf(); R.putNat(b, Nat64.toNat(x.cutAt), 8); R.putNat(b, x.settleDay, 8); R.putBool(b, x.settled); padded(b, 17) };
    decode = func(a : [Nat8]) : CycleRow { { cutAt = Nat64.fromNat(R.getNat(a, 0, 8)); settleDay = R.getNat(a, 8, 8); settled = R.getBool(a, 16) } };
    indexes = [];
  };
  /// A leg of the settlement range (SPEC §19): its kind (1 a pre-funded party's gross fill, 2 a cycle's net, 3 a transfer
  /// to or from the CCP outside a fill or a cycle: a sale's pledge, collateral, a fund contribution, the venue's skin), the
  /// ledger, the accounts it moves from and to, the units, the block that settled it. Leaf `i` is row `i + 1`. Every
  /// movement between two of the venue's accounts is a leg.
  public type Leg = { kind : Nat; ledger : Principal; from : Nat; to : Nat; units : Nat; block : Nat };
  public let LEG_ROW_BYTES = 63;   // kind 1, ledger 30, four figures of 8
  public let legRows : RS.Decl<Leg> = {
    table = "settlementlegs"; idBytes = 8; rowBytes = LEG_ROW_BYTES;
    encode = func(x : Leg) : Blob { let b = R.buf(); R.putNat(b, x.kind, 1); putPrincipal(b, x.ledger); R.putNat(b, x.from, 8); R.putNat(b, x.to, 8); R.putNat(b, x.units, 8); R.putNat(b, x.block, 8); padded(b, LEG_ROW_BYTES) };
    decode = func(a : [Nat8]) : Leg { { kind = R.getNat(a, 0, 1); ledger = getPrincipal(a, 1); from = R.getNat(a, 31, 8); to = R.getNat(a, 39, 8); units = R.getNat(a, 47, 8); block = R.getNat(a, 55, 8) } };
    indexes = [];
  };
  /// The settlement range's nodes in post-order (a leaf, then the parents its arrival completes): position `p` is row
  /// `p + 1`, each the node's hash under the kernel's proof hashing (`MmrProof`).
  public let nodeRows : RS.Decl<Blob> = {
    table = "settlementnodes"; idBytes = 8; rowBytes = 32;
    encode = func(x : Blob) : Blob { let b = R.buf(); R.putBlob(b, x, 32); R.done(b, 32) };
    decode = func(a : [Nat8]) : Blob { R.getBlob(a, 0, 32) };
    indexes = [];
  };
  // ── fees, statements, reconciliation (SPEC §22 to §24) ──
  /// An instrument's fee schedule: up to four levies, each its recipient account and its rate in parts per million.
  public let FEE_ROW_BYTES = 49;   // count 1, four levies of account 8 and rate 4
  public let feeRows : RS.Decl<[T.Levy]> = {
    table = "feeschedules"; idBytes = 8; rowBytes = FEE_ROW_BYTES;
    encode = func(x : [T.Levy]) : Blob {
      let b = R.buf(); R.putNat(b, x.size(), 1);
      for (k in Nat.range(0, 4)) { if (k < x.size()) { R.putNat(b, x[k].account, 8); R.putNat(b, x[k].ppm, 4) } else { R.putNat(b, 0, 8); R.putNat(b, 0, 4) } };
      padded(b, FEE_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : [T.Levy] { Array.tabulate<T.Levy>(R.getNat(a, 0, 1), func(k) { { account = R.getNat(a, 1 + 12 * k, 8); ppm = R.getNat(a, 9 + 12 * k, 4) } }) };
    indexes = [];
  };
  /// What the CCP owes a levy's account from clearing parties' fees, paid at a cycle (§22).
  public type Payable = { account : Nat; amount : Nat };
  public let payableRows : RS.Decl<Payable> = {
    table = "levypayable"; idBytes = 8; rowBytes = 16;
    encode = func(x : Payable) : Blob { let b = R.buf(); R.putNat(b, x.account, 8); R.putNat(b, x.amount, 8); padded(b, 16) };
    decode = func(a : [Nat8]) : Payable { { account = R.getNat(a, 0, 8); amount = R.getNat(a, 8, 8) } };
    indexes = [{ name = "byAccount"; keyBytes = 8; keyOf = func(_ : Nat, x : Payable) : ?Blob { ?R.key(x.account, 8) } }];
  };
  /// A member's fees on an instrument in the makers' open period (§22, §25).
  public type FeeTotal = { member : Nat; instrument : Nat; fees : Nat };
  public let feeTotalRows : RS.Decl<FeeTotal> = {
    table = "feetotals"; idBytes = 8; rowBytes = 24;
    encode = func(x : FeeTotal) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.instrument, 8); R.putNat(b, x.fees, 8); padded(b, 24) };
    decode = func(a : [Nat8]) : FeeTotal { { member = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); fees = R.getNat(a, 16, 8) } };
    indexes = [{ name = "byKey"; keyBytes = 16; keyOf = func(_ : Nat, x : FeeTotal) : ?Blob { ?R.key2(x.member, 8, x.instrument, 8) } }];
  };
  /// A member's open statement (§23): the hash chain's head and its count of lines.
  public type Statement = { member : Nat; head : Blob; lines : Nat };
  public let statementRows : RS.Decl<Statement> = {
    table = "statements"; idBytes = 8; rowBytes = 48;
    encode = func(x : Statement) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putBlob(b, x.head, 32); R.putNat(b, x.lines, 8); R.done(b, 48) };
    decode = func(a : [Nat8]) : Statement { { member = R.getNat(a, 0, 8); head = R.getBlob(a, 8, 32); lines = R.getNat(a, 40, 8) } };
    indexes = [{ name = "byMember"; keyBytes = 8; keyOf = func(_ : Nat, x : Statement) : ?Blob { ?R.key(x.member, 8) } }];
  };
  /// A sealed statement: the member, the market day, the head and the lines.
  public type StatementSeal = { member : Nat; day : Nat; head : Blob; lines : Nat };
  public let statementSealRows : RS.Decl<StatementSeal> = {
    table = "statementseals"; idBytes = 8; rowBytes = 56;
    encode = func(x : StatementSeal) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.day, 8); R.putBlob(b, x.head, 32); R.putNat(b, x.lines, 8); R.done(b, 56) };
    decode = func(a : [Nat8]) : StatementSeal { { member = R.getNat(a, 0, 8); day = R.getNat(a, 8, 8); head = R.getBlob(a, 16, 32); lines = R.getNat(a, 48, 8) } };
    indexes = [{ name = "byMemberDay"; keyBytes = 16; keyOf = func(_ : Nat, x : StatementSeal) : ?Blob { ?R.key2(x.member, 8, x.day, 8) } }];
  };
  /// A member reconciliation (§24): the member, the day, the rows compared, the matches, the breaks, the rows' hash.
  public type Recon = { member : Nat; day : Nat; rows : Nat; matched : Nat; breaks : Nat; hash : Blob };
  public let reconRows : RS.Decl<Recon> = {
    table = "memberrecons"; idBytes = 8; rowBytes = 72;
    encode = func(x : Recon) : Blob { let b = R.buf(); for (v in [x.member, x.day, x.rows, x.matched, x.breaks].vals()) R.putNat(b, v, 8); R.putBlob(b, x.hash, 32); R.done(b, 72) };
    decode = func(a : [Nat8]) : Recon { { member = R.getNat(a, 0, 8); day = R.getNat(a, 8, 8); rows = R.getNat(a, 16, 8); matched = R.getNat(a, 24, 8); breaks = R.getNat(a, 32, 8); hash = R.getBlob(a, 40, 32) } };
    indexes = [];
  };
  public let RECON_DOMAIN = "thebes.book.reconciliation.v1";
  /// A market maker's registration for an instrument (§25): its obligations and rebate, its live quote (the account and
  /// both sides' orders), and the period's measurement: whether, at the last act, the instrument traded continuously and
  /// the maker was present, the time of that act, and the time accrued present and in continuous trading.
  public type Maker = {
    member : Nat; instrument : Nat; maxSpreadBps : Nat; minQty : Nat; presenceBps : Nat; rebateBps : Nat;
    account : Nat; bid : Nat; ask : Nat; cont : Bool; present : Bool; lastAt : Nat64; presentNs : Nat; sessionNs : Nat;
  };
  public let MAKER_ROW_BYTES = 98;   // nine figures of 8, two flags, the last act 8, presence 8, session 8
  public let makerRows : RS.Decl<Maker> = {
    table = "makers"; idBytes = 8; rowBytes = MAKER_ROW_BYTES;
    encode = func(x : Maker) : Blob {
      let b = R.buf();
      for (v in [x.member, x.instrument, x.maxSpreadBps, x.minQty, x.presenceBps, x.rebateBps, x.account, x.bid, x.ask].vals()) R.putNat(b, v, 8);
      R.putBool(b, x.cont); R.putBool(b, x.present); R.putNat(b, Nat64.toNat(x.lastAt), 8); R.putNat(b, x.presentNs, 8); R.putNat(b, x.sessionNs, 8);
      padded(b, MAKER_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : Maker {
      { member = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); maxSpreadBps = R.getNat(a, 16, 8); minQty = R.getNat(a, 24, 8); presenceBps = R.getNat(a, 32, 8);
        rebateBps = R.getNat(a, 40, 8); account = R.getNat(a, 48, 8); bid = R.getNat(a, 56, 8); ask = R.getNat(a, 64, 8); cont = R.getBool(a, 72); present = R.getBool(a, 73);
        lastAt = Nat64.fromNat(R.getNat(a, 74, 8)); presentNs = R.getNat(a, 82, 8); sessionNs = R.getNat(a, 90, 8) }
    };
    indexes = [{ name = "byKey"; keyBytes = 16; keyOf = func(_ : Nat, x : Maker) : ?Blob { ?R.key2(x.member, 8, x.instrument, 8) } }];
  };
  /// A maker's period closed (§25): the day, the time present and in continuous trading, whether the obligation was met,
  /// the rebate paid.
  public type MakerDay = { member : Nat; instrument : Nat; day : Nat; presentNs : Nat; sessionNs : Nat; met : Bool; rebate : Nat };
  public let makerDayRows : RS.Decl<MakerDay> = {
    table = "makerdays"; idBytes = 8; rowBytes = 49;
    encode = func(x : MakerDay) : Blob { let b = R.buf(); for (v in [x.member, x.instrument, x.day, x.presentNs, x.sessionNs].vals()) R.putNat(b, v, 8); R.putBool(b, x.met); R.putNat(b, x.rebate, 8); padded(b, 49) };
    decode = func(a : [Nat8]) : MakerDay { { member = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); day = R.getNat(a, 16, 8); presentNs = R.getNat(a, 24, 8); sessionNs = R.getNat(a, 32, 8); met = R.getBool(a, 40); rebate = R.getNat(a, 41, 8) } };
    indexes = [];
  };
  public let MAX_MAKERS = 32;
  // ── indices (SPEC §26, §27) ──
  /// An index by its number: its base, cap and thresholds, the divisor and the adjusted capitalisation's scale (32
  /// bytes each), its level and reference in hundredths of a point, whether its breaker tripped (0 armed, 1 halted, 2
  /// suspended to the close).
  public type IndexRow = { base : Nat; capBps : Nat; haltBps : Nat; suspendBps : Nat; divisor : Nat; level : Nat; reference : Nat; tripped : Nat };
  public let INDEX_ROW_BYTES = 81;   // four figures of 8, the divisor 32, level and reference 8 each, the trip 1
  public let indexRows : RS.Decl<IndexRow> = {
    table = "indices"; idBytes = 8; rowBytes = INDEX_ROW_BYTES;
    encode = func(x : IndexRow) : Blob {
      let b = R.buf(); for (v in [x.base, x.capBps, x.haltBps, x.suspendBps].vals()) R.putNat(b, v, 8);
      R.putNat(b, x.divisor, 32); R.putNat(b, x.level, 8); R.putNat(b, x.reference, 8); R.putNat(b, x.tripped, 1); padded(b, INDEX_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : IndexRow {
      { base = R.getNat(a, 0, 8); capBps = R.getNat(a, 8, 8); haltBps = R.getNat(a, 16, 8); suspendBps = R.getNat(a, 24, 8); divisor = R.getNat(a, 32, 32);
        level = R.getNat(a, 64, 8); reference = R.getNat(a, 72, 8); tripped = R.getNat(a, 80, 1) }
    };
    indexes = [];
  };
  /// A constituent of an index: its free-float shares and its capping factor in parts per billion.
  public type ConstituentRow = { index : Nat; instrument : Nat; shares : Nat; factor : Nat };
  public let constituentRows : RS.Decl<ConstituentRow> = {
    table = "constituents"; idBytes = 8; rowBytes = 32;
    encode = func(x : ConstituentRow) : Blob { let b = R.buf(); for (v in [x.index, x.instrument, x.shares, x.factor].vals()) R.putNat(b, v, 8); padded(b, 32) };
    decode = func(a : [Nat8]) : ConstituentRow { { index = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); shares = R.getNat(a, 16, 8); factor = R.getNat(a, 24, 8) } };
    indexes = [{ name = "byIndex"; keyBytes = 16; keyOf = func(_ : Nat, x : ConstituentRow) : ?Blob { ?R.key2(x.index, 8, x.instrument, 8) } }];
  };
  /// The index's path: every level it took, with the block.
  public type PathRow = { index : Nat; block : Nat; level : Nat };
  public let pathRows : RS.Decl<PathRow> = {
    table = "indexpath"; idBytes = 8; rowBytes = 24;
    encode = func(x : PathRow) : Blob { let b = R.buf(); for (v in [x.index, x.block, x.level].vals()) R.putNat(b, v, 8); padded(b, 24) };
    decode = func(a : [Nat8]) : PathRow { { index = R.getNat(a, 0, 8); block = R.getNat(a, 8, 8); level = R.getNat(a, 16, 8) } };
    indexes = [];
  };
  // ── instrument classes (SPEC §28 to §32) ──
  /// An instrument's class terms, by its instrument id: the class byte, seven figures (a bond's coupon, coupons a year, day
  /// count, maturity and settlement days; a right's underlying, price, ratio, deadline, issuer and the issuer's member),
  /// the receipt's licensed warehouses with their count, the certificate's registry hash.
  public let TERMS_ROW_BYTES = 154;   // class 1, seven figures of 8, a count 1, eight warehouses of 8, a hash 32
  public let termsRows : RS.Decl<T.Terms> = {
    table = "terms"; idBytes = 8; rowBytes = TERMS_ROW_BYTES;
    encode = func(x : T.Terms) : Blob {
      let b = R.buf();
      let (k, f, hs, h) : (Nat, [Nat], [Nat], Blob) = switch (x) {
        case (#bond(t)) (1, [t.couponBps, t.perYear, Nat8.toNat(K.basisCode(t.basis)), t.maturity, t.settleDays, 0, 0], [], zero32());
        case (#receipt(t)) (2, [0, 0, 0, 0, 0, 0, 0], t.warehouses, zero32());
        case (#certificate(t)) (3, [0, 0, 0, 0, 0, 0, 0], [], t.registry);
        case (#right(t)) (4, [t.underlying, t.price, t.num, t.den, t.deadline, t.issuer, t.issuerMember], [], zero32());
        case (#future(t)) (5, [t.index, t.multiplier, t.expiry, t.imBps, 0, 0, 0], [], zero32());
        case (#option(t)) (6, [t.index, t.strike, if (t.call) 1 else 0, t.multiplier, t.expiry, t.aBps, t.bBps], [], zero32());
      };
      R.putNat(b, k, 1); for (v in f.vals()) R.putNat(b, v, 8); R.putNat(b, hs.size(), 1);
      for (j in Nat.range(0, T.MAX_WAREHOUSES)) R.putNat(b, if (j < hs.size()) hs[j] else 0, 8);
      R.putBlob(b, h, 32); R.done(b, TERMS_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : T.Terms {
      let f = Array.tabulate<Nat>(7, func(j) { R.getNat(a, 1 + 8 * j, 8) });
      switch (R.getNat(a, 0, 1)) {
        case 1 { #bond({ couponBps = f[0]; perYear = f[1]; basis = switch (K.basisOf(Nat8.fromNat(f[2]))) { case (?x) x; case null Runtime.trap("terms: a day count") }; maturity = f[3]; settleDays = f[4] }) };
        case 2 { #receipt({ warehouses = Array.tabulate<Nat>(R.getNat(a, 57, 1), func(j) { R.getNat(a, 58 + 8 * j, 8) }) }) };
        case 3 { #certificate({ registry = R.getBlob(a, 122, 32) }) };
        case 4 { #right({ underlying = f[0]; price = f[1]; num = f[2]; den = f[3]; deadline = f[4]; issuer = f[5]; issuerMember = f[6] }) };
        case 5 { #future({ index = f[0]; multiplier = f[1]; expiry = f[2]; imBps = f[3] }) };
        case _ { #option({ index = f[0]; strike = f[1]; call = f[2] == 1; multiplier = f[3]; expiry = f[4]; aBps = f[5]; bBps = f[6] }) };
      }
    };
    indexes = [];
  };
  func zero32() : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })) };
  /// A fund's indicative value (SPEC §29), by the fund's instrument id: the units of a creation, its cash, and the iNAV a
  /// unit in minor units.
  public type NavRow = { units : Nat; cash : Nat; inav : Nat };
  public let navRows : RS.Decl<NavRow> = {
    table = "navs"; idBytes = 8; rowBytes = 24;
    encode = func(x : NavRow) : Blob { let b = R.buf(); for (v in [x.units, x.cash, x.inav].vals()) R.putNat(b, v, 8); R.done(b, 24) };
    decode = func(a : [Nat8]) : NavRow { { units = R.getNat(a, 0, 8); cash = R.getNat(a, 8, 8); inav = R.getNat(a, 16, 8) } };
    indexes = [];
  };
  /// A fund's basket line: the instrument and its shares in a creation unit.
  public type BasketRow = { fund : Nat; instrument : Nat; shares : Nat };
  public let basketRows : RS.Decl<BasketRow> = {
    table = "baskets"; idBytes = 8; rowBytes = 24;
    encode = func(x : BasketRow) : Blob { let b = R.buf(); for (v in [x.fund, x.instrument, x.shares].vals()) R.putNat(b, v, 8); R.done(b, 24) };
    decode = func(a : [Nat8]) : BasketRow { { fund = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); shares = R.getNat(a, 16, 8) } };
    indexes = [{ name = "byFund"; keyBytes = 16; keyOf = func(_ : Nat, x : BasketRow) : ?Blob { ?R.key2(x.fund, 8, x.instrument, 8) } }];
  };
  /// The iNAV's path: every value it took, with the block (as the index's path, §26).
  public let navPathRows : RS.Decl<PathRow> = {
    table = "navpath"; idBytes = 8; rowBytes = 24;
    encode = func(x : PathRow) : Blob { let b = R.buf(); for (v in [x.index, x.block, x.level].vals()) R.putNat(b, v, 8); R.done(b, 24) };
    decode = func(a : [Nat8]) : PathRow { { index = R.getNat(a, 0, 8); block = R.getNat(a, 8, 8); level = R.getNat(a, 16, 8) } };
    indexes = [];
  };
  /// A warehouse receipt (SPEC §30): the warehouse, the instrument (the graded commodity), the account it was issued to,
  /// the quantity, whether it is live, the warehouse's document hash.
  public type Receipt = { warehouse : Nat; instrument : Nat; account : Nat; qty : Nat; live : Bool; reference : Blob };
  public let RECEIPT_ROW_BYTES = 65;   // four figures of 8, live 1, the document hash 32
  public let receiptRows : RS.Decl<Receipt> = {
    table = "receipts"; idBytes = 8; rowBytes = RECEIPT_ROW_BYTES;
    encode = func(x : Receipt) : Blob { let b = R.buf(); for (v in [x.warehouse, x.instrument, x.account, x.qty].vals()) R.putNat(b, v, 8); R.putBool(b, x.live); R.putBlob(b, x.reference, 32); R.done(b, RECEIPT_ROW_BYTES) };
    decode = func(a : [Nat8]) : Receipt { { warehouse = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); account = R.getNat(a, 16, 8); qty = R.getNat(a, 24, 8); live = R.getBool(a, 32); reference = R.getBlob(a, 33, 32) } };
    indexes = [{ name = "byRef"; keyBytes = 32; keyOf = func(_ : Nat, x : Receipt) : ?Blob { ?x.reference } }];
  };
  /// A certificate's retirement (SPEC §31): the account, the instrument, the quantity, the beneficiary's hash.
  public type Retirement = { account : Nat; instrument : Nat; qty : Nat; beneficiary : Blob };
  public let retireRows : RS.Decl<Retirement> = {
    table = "retirements"; idBytes = 8; rowBytes = 56;
    encode = func(x : Retirement) : Blob { let b = R.buf(); for (v in [x.account, x.instrument, x.qty].vals()) R.putNat(b, v, 8); R.putBlob(b, x.beneficiary, 32); R.done(b, 56) };
    decode = func(a : [Nat8]) : Retirement { { account = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); qty = R.getNat(a, 16, 8); beneficiary = R.getBlob(a, 24, 32) } };
    indexes = [];
  };
  /// A right's exercise (SPEC §32): the account, the right, the rights given up, the new shares it is entitled to, the
  /// subscription it paid.
  public type Entitlement = { account : Nat; instrument : Nat; rights : Nat; shares : Nat; paid : Nat };
  public let entitlementRows : RS.Decl<Entitlement> = {
    table = "entitlements"; idBytes = 8; rowBytes = 40;
    encode = func(x : Entitlement) : Blob { let b = R.buf(); for (v in [x.account, x.instrument, x.rights, x.shares, x.paid].vals()) R.putNat(b, v, 8); R.done(b, 40) };
    decode = func(a : [Nat8]) : Entitlement { { account = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); rights = R.getNat(a, 16, 8); shares = R.getNat(a, 24, 8); paid = R.getNat(a, 32, 8) } };
    indexes = [];
  };
  /// The units of a ledger the book holds (SPEC §28): moved by deposits, withdrawals, loans, receipts, retirements and
  /// exercises, never by a fill; equal to the sum of the ledger's balances.
  public type Supply = { ledger : Principal; units : Nat };
  public let SUPPLY_ROW_BYTES = 38;   // the ledger 30, the units 8
  public let supplyRows : RS.Decl<Supply> = {
    table = "supply"; idBytes = 8; rowBytes = SUPPLY_ROW_BYTES;
    encode = func(x : Supply) : Blob { let b = R.buf(); putPrincipal(b, x.ledger); R.putNat(b, x.units, 8); R.done(b, SUPPLY_ROW_BYTES) };
    decode = func(a : [Nat8]) : Supply { { ledger = getPrincipal(a, 0); units = R.getNat(a, PRINCIPAL_BYTES, 8) } };
    indexes = [{ name = "byLedger"; keyBytes = PRINCIPAL_BYTES; keyOf = func(_ : Nat, x : Supply) : ?Blob { ?ledgerKey(x.ledger) } }];
  };
  /// A bond's value date, by its instrument id (§28).
  public type ValueDate = { day : Nat };
  public let valueDateRows : RS.Decl<ValueDate> = {
    table = "valuedates"; idBytes = 8; rowBytes = 8;
    encode = func(x : ValueDate) : Blob { let b = R.buf(); R.putNat(b, x.day, 8); R.done(b, 8) };
    decode = func(a : [Nat8]) : ValueDate { { day = R.getNat(a, 0, 8) } };
    indexes = [];
  };
  // ── derivatives (SPEC §33 to §35) ──
  /// The three attestors, by their number (1 to 3).
  public type Attestor = { attestor : Principal };
  public let attestorRows : RS.Decl<Attestor> = {
    table = "attestors"; idBytes = 8; rowBytes = 30;
    encode = func(x : Attestor) : Blob { let b = R.buf(); putPrincipal(b, x.attestor); R.done(b, 30) };
    decode = func(a : [Nat8]) : Attestor { { attestor = getPrincipal(a, 0) } };
    indexes = [];
  };
  /// An attested price: the derivative, the market day, the attestor's number, the price.
  public type Attestation = { instrument : Nat; day : Nat; attestor : Nat; price : Nat };
  func attestKey(inst : Nat, day : Nat, n : Nat) : Blob { let b = R.buf(); R.putNat(b, inst, 8); R.putNat(b, day, 8); R.putNat(b, n, 1); R.done(b, 17) };
  public let attestationRows : RS.Decl<Attestation> = {
    table = "attestations"; idBytes = 8; rowBytes = 25;
    encode = func(x : Attestation) : Blob { let b = R.buf(); R.putNat(b, x.instrument, 8); R.putNat(b, x.day, 8); R.putNat(b, x.attestor, 1); R.putNat(b, x.price, 8); R.done(b, 25) };
    decode = func(a : [Nat8]) : Attestation { { instrument = R.getNat(a, 0, 8); day = R.getNat(a, 8, 8); attestor = R.getNat(a, 16, 1); price = R.getNat(a, 17, 8) } };
    indexes = [{ name = "byKey"; keyBytes = 17; keyOf = func(_ : Nat, x : Attestation) : ?Blob { ?attestKey(x.instrument, x.day, x.attestor) } }];
  };
  /// An account's position in a derivative against the CCP: its member, long or short, the contracts, the price it is
  /// marked at, its initial margin.
  public type Position = { account : Nat; instrument : Nat; member : Nat; long : Bool; qty : Nat; mark : Nat; im : Nat };
  public let POSITION_ROW_BYTES = 49;   // account, instrument, member 8 each, long 1, quantity, mark, margin 8 each
  public let positionRows : RS.Decl<Position> = {
    table = "positions"; idBytes = 8; rowBytes = POSITION_ROW_BYTES;
    encode = func(x : Position) : Blob {
      let b = R.buf(); for (v in [x.account, x.instrument, x.member].vals()) R.putNat(b, v, 8); R.putBool(b, x.long);
      for (v in [x.qty, x.mark, x.im].vals()) R.putNat(b, v, 8); R.done(b, POSITION_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : Position {
      { account = R.getNat(a, 0, 8); instrument = R.getNat(a, 8, 8); member = R.getNat(a, 16, 8); long = R.getBool(a, 24); qty = R.getNat(a, 25, 8); mark = R.getNat(a, 33, 8); im = R.getNat(a, 41, 8) }
    };
    indexes = [{ name = "byKey"; keyBytes = 16; keyOf = func(_ : Nat, x : Position) : ?Blob { ?R.key2(x.account, 8, x.instrument, 8) } },
               { name = "open"; keyBytes = 16; keyOf = func(_ : Nat, x : Position) : ?Blob { if (x.qty > 0) ?R.key2(x.instrument, 8, x.account, 8) else null } }];
  };
  /// A derivative's settlement state, by its instrument id: the mark (the last settlement price), the last day settled
  /// whole, the run in progress (its day, its price, the last account settled, what it has owed members and what it has
  /// charged them so far: the CCP's open balance within the run), whether it expired.
  public type Deriv = { mark : Nat; settled : Nat; runDay : Nat; runPrice : Nat; cursor : Nat; runTo : Nat; runBy : Nat; expired : Bool };
  public let derivRows : RS.Decl<Deriv> = {
    table = "derivatives"; idBytes = 8; rowBytes = 57;
    encode = func(x : Deriv) : Blob { let b = R.buf(); for (v in [x.mark, x.settled, x.runDay, x.runPrice, x.cursor, x.runTo, x.runBy].vals()) R.putNat(b, v, 8); R.putBool(b, x.expired); R.done(b, 57) };
    decode = func(a : [Nat8]) : Deriv {
      { mark = R.getNat(a, 0, 8); settled = R.getNat(a, 8, 8); runDay = R.getNat(a, 16, 8); runPrice = R.getNat(a, 24, 8); cursor = R.getNat(a, 32, 8);
        runTo = R.getNat(a, 40, 8); runBy = R.getNat(a, 48, 8); expired = R.getBool(a, 56) }
    };
    indexes = [];
  };
  /// A clearing member's positions' initial margin, by its member number.
  public type MemberIm = { im : Nat };
  public let memberImRows : RS.Decl<MemberIm> = {
    table = "positionmargin"; idBytes = 8; rowBytes = 8;
    encode = func(x : MemberIm) : Blob { let b = R.buf(); R.putNat(b, x.im, 8); R.done(b, 8) };
    decode = func(a : [Nat8]) : MemberIm { { im = R.getNat(a, 0, 8) } };
    indexes = [];
  };
  func ledgerKey(p : Principal) : Blob { let b = R.buf(); putPrincipal(b, p); R.done(b, PRINCIPAL_BYTES) };
  public let E18 = 1_000_000_000_000_000_000;
  public let E9 = 1_000_000_000;
  /// A drop-copy row (SPEC §14): a block that concerns a member, and whether it is the member's own act.
  public type DropRow = { member : Nat; block : Nat; own : Bool };
  public let DROP_ROW_BYTES = 17;   // member 8, block 8, own 1
  public let dropRows : RS.Decl<DropRow> = {
    table = "drops"; idBytes = 8; rowBytes = DROP_ROW_BYTES;
    encode = func(x : DropRow) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.block, 8); R.putBool(b, x.own); padded(b, DROP_ROW_BYTES) };
    decode = func(a : [Nat8]) : DropRow { { member = R.getNat(a, 0, 8); block = R.getNat(a, 8, 8); own = R.getBool(a, 16) } };
    indexes = [{ name = "byMember"; keyBytes = 16; keyOf = func(_ : Nat, x : DropRow) : ?Blob { ?R.key2(x.member, 8, x.block, 8) } }];
  };
  /// A kill switch (SPEC §11), by its sequence number; its index finds the active one of a member or a trader.
  public let KILL_ROW_BYTES = 24;   // member 8, trader 8, active 1, pad 7
  /// A trader's kill is keyed by its trader, a member's by its member.
  func killKey(x : T.Kill) : Blob { if (x.trader != 0) R.key2(2, 1, x.trader, 8) else R.key2(1, 1, x.member, 8) };
  public let kills : RS.Decl<T.Kill> = {
    table = "kills"; idBytes = 8; rowBytes = KILL_ROW_BYTES;
    encode = func(x : T.Kill) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.trader, 8); R.putBool(b, x.active); padded(b, KILL_ROW_BYTES) };
    decode = func(a : [Nat8]) : T.Kill { { member = R.getNat(a, 0, 8); trader = R.getNat(a, 8, 8); active = R.getBool(a, 16) } };
    indexes = [{ name = "active"; keyBytes = 9; keyOf = func(_ : Nat, x : T.Kill) : ?Blob { if (x.active) ?killKey(x) else null } }];
  };
  /// A member's risk limits and use (SPEC §11), by sequence number; found by member.
  public type LimitRow = { member : Nat; limits : T.Limits };
  public let LIMIT_ROW_BYTES = 40;   // member 8, max quantity 8, max value 8, credit 8, used 8
  public let limitRows : RS.Decl<LimitRow> = {
    table = "limits"; idBytes = 8; rowBytes = LIMIT_ROW_BYTES;
    encode = func(x : LimitRow) : Blob {
      let b = R.buf(); R.putNat(b, x.member, 8); R.putNat(b, x.limits.maxOrderQty, 8); R.putNat(b, x.limits.maxOrderValue, 8); R.putNat(b, x.limits.creditLimit, 8); R.putNat(b, x.limits.used, 8);
      R.done(b, LIMIT_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : LimitRow { { member = R.getNat(a, 0, 8); limits = { maxOrderQty = R.getNat(a, 8, 8); maxOrderValue = R.getNat(a, 16, 8); creditLimit = R.getNat(a, 24, 8); used = R.getNat(a, 32, 8) } } };
    indexes = [{ name = "byMember"; keyBytes = 8; keyOf = func(_ : Nat, x : LimitRow) : ?Blob { ?R.key(x.member, 8) } }];
  };
  /// An instrument due in the next clear: it has live orders entered in the batch, or stops a clear just triggered.
  public type DueRow = { due : Bool };
  public let DUE_ROW_BYTES = 8;
  public let dues : RS.Decl<DueRow> = {
    table = "due"; idBytes = 8; rowBytes = DUE_ROW_BYTES;
    encode = func(x : DueRow) : Blob { let b = R.buf(); R.putBool(b, x.due); padded(b, DUE_ROW_BYTES) };
    decode = func(a : [Nat8]) : DueRow { { due = R.getBool(a, 0) } };
    indexes = [{ name = "due"; keyBytes = 8; keyOf = func(id : Nat, x : DueRow) : ?Blob { if (x.due) ?R.key(id, 8) else null } }];
  };
  public type ProposalRow = MC.ProposalRow;
  public let proposals : RS.Decl<ProposalRow> = {
    table = "proposals"; idBytes = 8; rowBytes = MC.PROPOSAL_ROW_BYTES; encode = MC.encodeProposalRow;
    decode = func(a : [Nat8]) : ProposalRow { MC.decodeProposalRow(Blob.fromArray(a)) };
    indexes = [{ name = "awaiting"; keyBytes = 8; keyOf = func(id : Nat, r : ProposalRow) : ?Blob { switch (r.status) { case (#awaiting) ?R.key(id, 8); case (_) null } } }];
  };

  public func checkSums() : Bool {
    8 + 8 + 1 + 1 + 8 + 8 + 8 + 8 + 8 + 1 + 4 + 1 + 1 + 1 + T.CLIENT_REF_BYTES + 8 + 8 + 32 + 1 + 8 + 8 + 8 + 8 + 8 == 175 and 175 <= ORDER_ROW_BYTES
    and 8 + PRINCIPAL_BYTES + 8 + 8 == 54 and 54 <= BALANCE_ROW_BYTES
    and PRINCIPAL_BYTES * 2 + 8 + 8 + 1 + T.MAX_BANDS * 16 + 4 + 1 + 8 + 4 + 4 + 4 + 8 + 8 + 8 + 8 == 390 and 390 <= INSTRUMENT_ROW_BYTES
    and 8 + 8 + 1 <= KILL_ROW_BYTES and 8 * 5 == LIMIT_ROW_BYTES
    and 32 <= REF_ROW_BYTES and 1 <= DUE_ROW_BYTES
    and 8 * 4 + 32 + 8 * 2 + 1 == INDEX_ROW_BYTES
    and 1 + 7 * 8 + 1 + T.MAX_WAREHOUSES * 8 + 32 == TERMS_ROW_BYTES and 8 * 4 + 1 + 32 == RECEIPT_ROW_BYTES and PRINCIPAL_BYTES + 8 == SUPPLY_ROW_BYTES and 8 * 3 + 1 + 8 * 3 == POSITION_ROW_BYTES
    and 1 + 4 * (8 + 4) == FEE_ROW_BYTES and 9 * 8 + 2 + 8 * 3 == MAKER_ROW_BYTES
    and 8 * 12 + 1 == CLEARING_ROW_BYTES and 1 + PRINCIPAL_BYTES + 8 * 4 == LEG_ROW_BYTES and 8 + 8 + PRINCIPAL_BYTES + 8 * 6 == TERMS_BYTES
  };

  // ═══════════════════════════════════════════════════════
  //  THE STATE
  // ═══════════════════════════════════════════════════════

  public type State = {
    log : DL.State;
    var orderRows : RS.Store; balanceRows : RS.Store; refRows : RS.Store; var instrumentRows : RS.Store; dueRows : RS.Store; proposalRows : RS.Store;
    killRows : RS.Store; limitStore : RS.Store;
    /// The public feed's chain (SPEC §13): every block's feed hash by its index, the head, and the next block to project.
    feedRows : RS.Store; var feedHead : Blob; var feedNext : Nat;
    /// The drop copy's index (SPEC §14): a row for every (member, block) the block concerns, written with the feed.
    dropStore : RS.Store; var nextDrop : Nat;
    /// The day's statistics (SPEC §15): the session's by instrument, every sealed day's rows, and the last day sealed.
    statStore : RS.Store; dayStore : RS.Store; var nextDayRow : Nat; var lastSealed : Nat; sealStore : RS.Store; var nextSeal : Nat;
    /// The instruments the book holds, in id order (written when one opens; the fold rebuilds it): what the fingerprint,
    /// the seal and the readers walk, in place of every possible id.
    var instrumentList : [Nat];
    /// Insider blackouts and securities loans (SPEC §16, §17).
    blackoutStore : RS.Store; var nextBlackout : Nat; borrowStore : RS.Store; var nextBorrow : Nat;
    /// The central counterparty (SPEC §18 to §21) and the settlement range (§19).
    var clearing : ?ClearingTerms; clearingStore : RS.Store; var nextClearing : Nat; designationStore : RS.Store; var nextDesignation : Nat;
    custodyStore : RS.Store; var nextCustody : Nat; marginStore : RS.Store; closeoutStore : RS.Store; var nextCloseout : Nat;
    obligationStore : RS.Store; var nextObligation : Nat; boughtStore : RS.Store; var nextBought : Nat; cycleStore : RS.Store;
    /// The open cycle, the last cycle settled, the last cut's time, the open clearing buys' value the CCP's cash is
    /// committed to, the venue's skin-in-the-game (its own cash and the fail penalties).
    var cycleNo : Nat; var settledThrough : Nat; var lastCut : Nat64; var ccpCommitted : Nat; var skin : Nat;
    legStore : RS.Store; var nextLeg : Nat; nodeStore : RS.Store; var nextNode : Nat;
    /// The index of the block being applied (a leg records it); set before every apply, by the append or by the replay.
    var applying : Nat;
    /// Fees, statements, reconciliations (SPEC §22 to §24).
    feeStore : RS.Store; payableStore : RS.Store; var nextPayable : Nat; feeTotalStore : RS.Store; var nextFeeTotal : Nat;
    statementStore : RS.Store; var nextStatement : Nat; statementSealStore : RS.Store; var nextStatementSeal : Nat; var lastStatementDay : Nat;
    reconStore : RS.Store; var nextRecon : Nat;
    /// Market makers (SPEC §25).
    makerStore : RS.Store; var nextMaker : Nat; makerDayStore : RS.Store; var nextMakerDay : Nat; var lastMakerDay : Nat;
    /// Indices (SPEC §26, §27): the rows by number, the constituents, the path; whether an act moved a price; the index
    /// whose breaker is due (0 none); the time of the last suspension to the close.
    indexStore : RS.Store; constituentStore : RS.Store; var nextConstituent : Nat; pathStore : RS.Store; var nextPath : Nat;
    var pricesMoved : Bool; var breakerDue : Nat; var suspendedAt : Nat64;
    /// Instrument classes (SPEC §28 to §32): terms by instrument, funds' iNAVs, baskets and path, receipts, retirements,
    /// entitlements, and every ledger's units in the book.
    termsStore : RS.Store; navStore : RS.Store; basketStore : RS.Store; var nextBasket : Nat; navPathStore : RS.Store; var nextNavPath : Nat;
    receiptStore : RS.Store; var nextReceipt : Nat; retireStore : RS.Store; var nextRetire : Nat; entitlementStore : RS.Store; var nextEntitlement : Nat;
    supplyStore : RS.Store; var nextSupply : Nat; valueDateStore : RS.Store;
    /// Derivatives (SPEC §33 to §35): the attestors, the attestations, the positions, each derivative's settlement state,
    /// each member's positions' margin.
    attestorStore : RS.Store; attestationStore : RS.Store; var nextAttestation : Nat; positionStore : RS.Store; var nextPosition : Nat;
    derivStore : RS.Store; memberImStore : RS.Store;
    var nextOrder : Nat; var nextBalance : Nat; var nextRef : Nat; var nextKill : Nat; var nextLimit : Nat;
    /// The batch waiting to clear: the time (a block's `now`) its orders were entered with; 0 when none.
    var batchTime : Nat64;
    /// How many instruments are due, and the time of the log's last block: kept as the rows and the log change (and
    /// rebuilt by the fold), so that recording a due clear reads neither the due index nor the log.
    var dueCount : Nat;
    var lastTime : Nat64;
    /// Low-water marks: for a range the book walks (an index and a key prefix), a key below which the range holds no live
    /// entry. A walk starts at its mark and moves it to the first live entry it meets; a write lowers it. An index keeps
    /// the entries of rows that left it (the row store's tombstones) until compaction, so without the marks a walk from
    /// the best price would pass every order that ever left the top of the book. Reads still verify every entry, so a
    /// mark only saves work; the fold rebuilds the marks from nothing.
    marks : Map.Map<Blob, Blob>;
    var policies : [Auth.DualPolicy];
  };
  public func newState() : State { newStateOver(DL.newState()) };
  public func newStateOver(log : DL.State) : State {
    { log; var orderRows = RS.newStore(orders); balanceRows = RS.newStore(balances); refRows = RS.newStore(refs); var instrumentRows = RS.newStore(instruments); dueRows = RS.newStore(dues);
      proposalRows = RS.newStore(proposals); killRows = RS.newStore(kills); limitStore = RS.newStore(limitRows);
      feedRows = RS.newStore(feedHashes); var feedHead = F.genesis(); var feedNext = 0; dropStore = RS.newStore(dropRows); var nextDrop = 1;
      statStore = RS.newStore(statRows); dayStore = RS.newStore(dayRows); var nextDayRow = 1; var lastSealed = 0; sealStore = RS.newStore(sealRows); var nextSeal = 1; var instrumentList = []; blackoutStore = RS.newStore(blackoutRows); var nextBlackout = 1; borrowStore = RS.newStore(borrowRows); var nextBorrow = 1;
      var clearing = null; clearingStore = RS.newStore(clearingRows); var nextClearing = 1; designationStore = RS.newStore(designationRows); var nextDesignation = 1;
      custodyStore = RS.newStore(custodyRows); var nextCustody = 1; marginStore = RS.newStore(marginRows); closeoutStore = RS.newStore(closeoutRows); var nextCloseout = 1;
      obligationStore = RS.newStore(obligationRows); var nextObligation = 1; boughtStore = RS.newStore(boughtRows); var nextBought = 1; cycleStore = RS.newStore(cycleRows);
      var cycleNo = 1; var settledThrough = 0; var lastCut = 0; var ccpCommitted = 0; var skin = 0;
      legStore = RS.newStore(legRows); var nextLeg = 0; nodeStore = RS.newStore(nodeRows); var nextNode = 0; var applying = 0;
      feeStore = RS.newStore(feeRows); payableStore = RS.newStore(payableRows); var nextPayable = 1; feeTotalStore = RS.newStore(feeTotalRows); var nextFeeTotal = 1;
      statementStore = RS.newStore(statementRows); var nextStatement = 1; statementSealStore = RS.newStore(statementSealRows); var nextStatementSeal = 1; var lastStatementDay = 0;
      reconStore = RS.newStore(reconRows); var nextRecon = 1;
      makerStore = RS.newStore(makerRows); var nextMaker = 1; makerDayStore = RS.newStore(makerDayRows); var nextMakerDay = 1; var lastMakerDay = 0;
      indexStore = RS.newStore(indexRows); constituentStore = RS.newStore(constituentRows); var nextConstituent = 1; pathStore = RS.newStore(pathRows); var nextPath = 1;
      var pricesMoved = false; var breakerDue = 0; var suspendedAt = 0;
      termsStore = RS.newStore(termsRows); navStore = RS.newStore(navRows); basketStore = RS.newStore(basketRows); var nextBasket = 1; navPathStore = RS.newStore(navPathRows); var nextNavPath = 1;
      receiptStore = RS.newStore(receiptRows); var nextReceipt = 1; retireStore = RS.newStore(retireRows); var nextRetire = 1; entitlementStore = RS.newStore(entitlementRows); var nextEntitlement = 1;
      supplyStore = RS.newStore(supplyRows); var nextSupply = 1; valueDateStore = RS.newStore(valueDateRows);
      attestorStore = RS.newStore(attestorRows); attestationStore = RS.newStore(attestationRows); var nextAttestation = 1; positionStore = RS.newStore(positionRows); var nextPosition = 1;
      derivStore = RS.newStore(derivRows); memberImStore = RS.newStore(memberImRows);
      var nextOrder = 1; var nextBalance = 1; var nextRef = 1; var nextKill = 1; var nextLimit = 1; var batchTime = 0; var dueCount = 0; var lastTime = 0; marks = Map.empty<Blob, Blob>(); var policies = [] }
  };
  public func setPolicies(s : State, ps : [Auth.DualPolicy]) { s.policies := ps };
  func policyFor(s : State, permission : Text) : ?Auth.DualPolicy { Array.find<Auth.DualPolicy>(s.policies, func(p) { p.permission == permission }) };

  // ─── reads ──────────────────────────────────────────────────────────────────────────────
  /// The first row under an index range. A page stops at its scan budget and may hold no row while the range still
  /// does (the entries it examined were stale: rows since cancelled, filled or moved), so the walk follows the cursor
  /// until a row or the end of the range.
  func first<Rw>(store : RS.Store, decl : RS.Decl<Rw>, index : Text, lo : Blob, hi : Blob) : ?(Nat, Rw) {
    var cursor : ?Page.Cursor = null;
    loop {
      switch (RS.page(store, decl, index, lo, hi, cursor, 1)) {
        case (#ok(p)) {
          if (p.rows.size() > 0) return ?p.rows[0];
          switch (p.next) { case (?n) cursor := ?n; case null return null };
        };
        case (#err(_)) return null;
      };
    };
  };
  func one<Rw>(store : RS.Store, decl : RS.Decl<Rw>, index : Text, key : Blob) : ?(Nat, Rw) { first(store, decl, index, key, key) };
  public func order(s : State, id : T.OrderId) : ?T.Order { RS.get(s.orderRows, orders, id) };
  public func instrument(s : State, id : T.InstrumentId) : ?T.Instrument { RS.get(s.instrumentRows, instruments, id) };
  /// SPEC §9: an instrument's indicative auction price in a call phase (an auction or the closing auction): the price,
  /// volume and surplus its uncross would give now, and whether the price lies within the static band (outside it the
  /// uncross trades nothing); null outside a call phase or when nothing crosses. A read: it changes nothing.
  public func indicative(s : State, inst : Nat) : ?{ price : Nat; volume : Nat; surplus : Int; withinBand : Bool } {
    let ?i = instrument(s, inst) else return null;
    if (i.phase != #auction and i.phase != #closingAuction) return null;
    let ?(bids, asks) = crossingViews(s, inst) else return null;
    switch (L.indicative(bids, asks, i.lot, if (i.lastPrice != 0) i.lastPrice else i.referencePrice)) {
      case (?(price, volume, surplus)) ?{ price; volume; surplus; withinBand = L.within(price, i.referencePrice, i.staticBps) };
      case null null;
    }
  };
  /// The most instruments `inCallPhase` returns.
  public let MAX_CALLING = 200;
  /// The instruments in a call phase (an auction or the closing auction), in id order, at most `limit` of them (at most
  /// `MAX_CALLING`) from the first id at or after `from`.
  public func inCallPhase(s : State, from : Nat, limit : Nat) : [(Nat, T.Instrument)] {
    let out = List.empty<(Nat, T.Instrument)>();
    let want = Nat.min(limit, MAX_CALLING);
    var cursor : ?Page.Cursor = null;
    label pages loop {
      switch (RS.page(s.instrumentRows, instruments, "calling", R.key(from, 8), R.key(2 ** 64 - 1, 8), cursor, want - List.size(out))) {
        case (#ok(p)) {
          for (row in p.rows.vals()) List.add(out, row);
          switch (p.next) { case (?n) { if (List.size(out) >= want) break pages; cursor := ?n }; case null break pages };
        };
        case (#err(_)) break pages;
      };
    };
    List.toArray(out)
  };
  public func balance(s : State, account : T.AccountId, ledger : Principal) : T.Balance {
    switch (one(s.balanceRows, balances, "byAccountLedger", balanceKey(account, ledger))) { case (?(_, b)) b; case null { { account; ledger; available = 0; held = 0 } } }
  };
  public func orderByRef(s : State, account : T.AccountId, clientRef : Text) : ?(T.OrderId, T.Order) {
    if (Text.encodeUtf8(clientRef).size() == 0 or Text.encodeUtf8(clientRef).size() > T.CLIENT_REF_BYTES) return null;
    one(s.orderRows, orders, "ref", refKey(account, clientRef))
  };
  /// Bytes `prefix` followed by `rest` bytes of 0x00 (low) or 0xFF (high): a key range over everything under a prefix.
  /// The bytes after a side's 9-byte prefix in a key of the book (57-byte keys) or of the stops (25).
  func sideRest(ix : Nat8) : Nat { if (ix == STOPS) 16 else 48 };
  func span(prefix : Blob, rest : Nat) : (Blob, Blob) {
    let lo = Blob.fromArray(Array.concat(Blob.toArray(prefix), Array.tabulate<Nat8>(rest, func(_) { 0 })));
    let hi = Blob.fromArray(Array.concat(Blob.toArray(prefix), Array.tabulate<Nat8>(rest, func(_) { 255 })));
    (lo, hi)
  };
  func sidePrefix(inst : Nat, side : T.Side) : Blob { let b = R.buf(); R.putNat(b, inst, 8); R.putByte(b, sideByte(side)); R.done(b, 9) };
  func instPrefix(inst : Nat) : Blob { R.key(inst, 8) };
  func ownPrefix(account : Nat, inst : Nat, side : T.Side) : Blob { let b = R.buf(); R.putNat(b, account, 8); R.putNat(b, inst, 8); R.putByte(b, sideByte(side)); R.done(b, 17) };
  func accountPrefix(account : Nat) : Blob { R.key(account, 8) };

  // ─── low-water marks ──────────────────────────────────────────────────────────────────────
  let BOOK : Nat8 = 1; let STOPS : Nat8 = 2; let OWN : Nat8 = 3; let OWN_ALL : Nat8 = 4; let IMMEDIATE : Nat8 = 5; let DAY : Nat8 = 6; let GTD : Nat8 = 7; let TRAILING : Nat8 = 8;
  let MEMBER : Nat8 = 9; let TRADER : Nat8 = 10;
  func markOf(ix : Nat8, prefix : Blob) : Blob { Blob.fromArray(Array.concat<Nat8>([ix], Blob.toArray(prefix))) };
  func indexOf(ix : Nat8) : Text {
    if (ix == BOOK) "book" else if (ix == STOPS) "stops" else if (ix == OWN or ix == OWN_ALL) "own" else if (ix == IMMEDIATE) "immediate" else if (ix == DAY) "day" else if (ix == GTD) "gtd"
    else if (ix == MEMBER) "member" else if (ix == TRADER) "trader" else "trailing"
  };
  func keyIn(ix : Nat8, id : Nat, o : T.Order) : Blob {
    if (ix == BOOK) bookKey(o) else if (ix == STOPS) stopKey(id, o) else if (ix == OWN or ix == OWN_ALL) ownKey(id, o)
    else if (ix == IMMEDIATE) R.key2(o.instrument, 8, id, 8) else if (ix == DAY) R.key(id, 8) else if (ix == GTD) R.key2(o.gtdDay, 4, id, 8)
    else if (ix == MEMBER) R.key2(o.member, 8, id, 8) else if (ix == TRADER) R.key2(o.trader, 8, id, 8) else trailKey(id, o)
  };
  func lower(s : State, ix : Nat8, prefix : Blob, key : Blob) {
    let mk = markOf(ix, prefix);
    switch (Map.get(s.marks, Blob.compare, mk)) { case (?m) { if (Blob.compare(key, m) == #less) Map.add(s.marks, Blob.compare, mk, key) }; case null {} };
  };
  /// The rows of an index between `lo` and `hi`, from the range's mark, in key order, `pageSize` at a time; `visit`
  /// returns false to stop. The mark moves to the first row met, or to `hi` when the range holds none.
  func walk(s : State, ix : Nat8, prefix : Blob, lo : Blob, hi : Blob, pageSize : Nat, visit : (Nat, T.Order) -> Bool) {
    let mk = markOf(ix, prefix);
    let start = switch (Map.get(s.marks, Blob.compare, mk)) { case (?m) { if (Blob.compare(m, lo) == #greater) m else lo }; case null lo };
    if (Blob.compare(start, hi) == #greater) return;
    var cursor : ?Page.Cursor = null;
    var met = false;
    label w loop {
      switch (RS.page(s.orderRows, orders, indexOf(ix), start, hi, cursor, pageSize)) {
        case (#ok(p)) {
          for ((id, o) in p.rows.vals()) {
            if (not met) { Map.add(s.marks, Blob.compare, mk, keyIn(ix, id, o)); met := true };
            if (not visit(id, o)) break w;
          };
          switch (p.next) { case (?n) cursor := ?n; case null { if (not met) Map.add(s.marks, Blob.compare, mk, hi); break w } };
        };
        // a range the index refuses is a range built wrong: swallowed, it would answer "no row" for every range
        case (#err(e)) Runtime.trap("walk: the " # indexOf(ix) # " index refused the range: " # debug_show(e));
      };
    };
  };
  /// The best live order of a side (the highest buy, the lowest sell), if any.
  public func best(s : State, inst : T.InstrumentId, side : T.Side) : ?(T.OrderId, T.Order) {
    let (lo, hi) = span(sidePrefix(inst, side), 48);
    var found : ?(T.OrderId, T.Order) = null;
    walk(s, BOOK, sidePrefix(inst, side), lo, hi, 1, func(id : Nat, o : T.Order) : Bool { found := ?(id, o); false });
    found
  };
  /// A side's live orders best first, a page at a time.
  public func depth(s : State, inst : T.InstrumentId, side : T.Side, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(T.OrderId, T.Order)> {
    let (lo, hi) = span(sidePrefix(inst, side), 48);
    let start = switch (Map.get(s.marks, Blob.compare, markOf(BOOK, sidePrefix(inst, side)))) { case (?m) { if (Blob.compare(m, lo) == #greater and Blob.compare(m, hi) != #greater) m else lo }; case null lo };
    RS.page(s.orderRows, orders, "book", start, hi, cursor, limit)
  };
  public func awaitingProposals(s : State, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, ProposalRow)> { let (lo, hi) = R.fullRange(8); RS.page(s.proposalRows, proposals, "awaiting", lo, hi, cursor, limit) };

  // ─── funds ──────────────────────────────────────────────────────────────────────────────
  func putBalance(s : State, b : T.Balance) {
    switch (one(s.balanceRows, balances, "byAccountLedger", balanceKey(b.account, b.ledger))) {
      case (?(id, _)) RS.put(s.balanceRows, balances, id, b);
      case null { let id = s.nextBalance; s.nextBalance += 1; RS.put(s.balanceRows, balances, id, b) };
    }
  };
  func credit(s : State, account : Nat, ledger : Principal, amount : Nat) { if (amount > 0) { let b = balance(s, account, ledger); putBalance(s, { b with available = b.available + amount }) } };
  func hold(s : State, account : Nat, ledger : Principal, amount : Nat) {
    let b = balance(s, account, ledger);
    if (b.available < amount) Runtime.trap("hold: the funds were checked at entry");
    putBalance(s, { b with available = b.available - amount; held = b.held + amount });
  };
  func release(s : State, account : Nat, ledger : Principal, amount : Nat) {
    if (amount == 0) return;
    let b = balance(s, account, ledger);
    if (b.held < amount) Runtime.trap("release: more than is held");
    putBalance(s, { b with available = b.available + amount; held = b.held - amount });
  };
  /// Held funds leaving the account (a fill's payment or delivery).
  func spendHeld(s : State, account : Nat, ledger : Principal, amount : Nat) {
    if (amount == 0) return;
    let b = balance(s, account, ledger);
    if (b.held < amount) Runtime.trap("spend: more than is held");
    putBalance(s, { b with held = b.held - amount });
  };
  func holdingLedger(i : T.Instrument, side : T.Side) : Principal { switch (side) { case (#buy) i.cashLedger; case (#sell) i.assetLedger } };
  func holdingOf(side : T.Side, price : Nat, qty : Nat) : Nat { switch (side) { case (#buy) price * qty; case (#sell) qty } };
  // ─── fees (SPEC §22) ───────────────────────────────────────────────────────────────────────
  public let PPM = 1_000_000;
  public func feeSchedule(s : State, inst : Nat) : [T.Levy] { switch (RS.get(s.feeStore, feeRows, inst)) { case (?x) x; case null [] } };
  func feePpm(s : State, inst : Nat) : Nat { var t = 0; for (l in feeSchedule(s, inst).vals()) t += l.ppm; t };
  /// A side's fee on a value: value × the total rate, quantised once, half-even.
  public func feeOn(s : State, inst : Nat, value : Nat) : Nat {
    let ppm = feePpm(s, inst);
    if (ppm == 0) return 0;
    let n = value * ppm; let q = n / PPM; let r = n % PPM;
    if (2 * r > PPM) q + 1 else if (2 * r < PPM) q else q + q % 2
  };
  /// What a pre-funded buy holds for `qty` at `price`: the value, the fee on it rounded up, one minor unit per lot (the
  /// most a fill's half-even rounding can take); the value alone without a schedule.
  func buyHold(s : State, i : T.Instrument, inst : Nat, price : Nat, qty : Nat) : Nat {
    let ppm = feePpm(s, inst);
    // a bond's buy also holds the most its fill can accrue (SPEC §28); the fee is on the clean value
    let bound = accrualBound(s, inst, qty);
    if (ppm == 0) price * qty + bound else price * qty + ceilDiv(price * qty * ppm, PPM) + qty / i.lot + bound
  };
  func holdNeed(s : State, i : T.Instrument, inst : Nat, side : T.Side, price : Nat, qty : Nat) : Nat {
    switch (side) { case (#buy) buyHold(s, i, inst, price, qty); case (#sell) qty }
  };
  /// A fee split among the instrument's levies by the largest remainder of their rates (the kernel's allocation).
  func feeParts(s : State, inst : Nat, fee : Nat) : [(Nat, Nat)] {
    let levies = feeSchedule(s, inst);
    if (fee == 0 or levies.size() == 0) return [];
    switch (Rounding.allocate(fee, Array.map<T.Levy, Nat>(levies, func(l) { l.ppm }))) {
      case (#ok(parts)) Array.tabulate<(Nat, Nat)>(levies.size(), func(k) { (levies[k].account, parts[k]) });
      case (#err(_)) Runtime.trap("fees: a schedule's rates were checked above zero");
    }
  };
  /// A pre-funded party's fee paid from its account to the levies, each part a leg (kind 4).
  func payFee(s : State, inst : Nat, account : Nat, ledger : Principal, fee : Nat) {
    for ((to, part) in feeParts(s, inst, fee).vals()) { if (part > 0) { move(s, account, to, ledger, part); appendLeg(s, 4, ledger, account, to, part) } };
  };
  /// A clearing party's fee: the CCP owes it to the levies until a cycle pays them.
  func owePayable(s : State, inst : Nat, fee : Nat) {
    for ((to, part) in feeParts(s, inst, fee).vals()) {
      if (part > 0) {
        switch (one(s.payableStore, payableRows, "byAccount", R.key(to, 8))) {
          case (?(id, x)) RS.put(s.payableStore, payableRows, id, { x with amount = x.amount + part });
          case null { let id = s.nextPayable; s.nextPayable += 1; RS.put(s.payableStore, payableRows, id, { account = to; amount = part }) };
        };
      };
    };
  };
  public func payableTotal(s : State) : Nat { var t = 0; var i = 1; while (i < s.nextPayable) { switch (RS.get(s.payableStore, payableRows, i)) { case (?x) t += x.amount; case null {} }; i += 1 }; t };
  func addFeeTotal(s : State, member : Nat, inst : Nat, fee : Nat) {
    if (fee == 0) return;
    switch (one(s.feeTotalStore, feeTotalRows, "byKey", R.key2(member, 8, inst, 8))) {
      case (?(id, x)) RS.put(s.feeTotalStore, feeTotalRows, id, { x with fees = x.fees + fee });
      case null { let id = s.nextFeeTotal; s.nextFeeTotal += 1; RS.put(s.feeTotalStore, feeTotalRows, id, { member; instrument = inst; fees = fee }) };
    }
  };
  public func feeTotalOf(s : State, member : Nat, inst : Nat) : Nat { switch (one(s.feeTotalStore, feeTotalRows, "byKey", R.key2(member, 8, inst, 8))) { case (?(_, x)) x.fees; case null 0 } };

  // ─── statements (SPEC §23) ─────────────────────────────────────────────────────────────────
  public func statementOf(s : State, member : Nat) : Statement {
    switch (one(s.statementStore, statementRows, "byMember", R.key(member, 8))) { case (?(_, x)) x; case null ({ member; head = F.genesis(); lines = 0 } : Statement) }
  };
  /// A statement line: the block, the order, the side (1 buy, 2 sell), the quantity, the price, the fee; chained.
  public func statementLine(block : Nat, order : Nat, side : Nat, qty : Nat, price : Nat, fee : Nat) : Blob {
    let w = C.Writer(); for (v in [block, order, side, qty, price, fee].vals()) w.nat(v); w.toBlob()
  };
  public func chainLine(head : Blob, line : Blob) : Blob { Sha256.fromArray(#sha256, Array.concat<Nat8>(Blob.toArray(head), Blob.toArray(line))) };
  func appendStatement(s : State, member : Nat, order : Nat, side : T.Side, qty : Nat, price : Nat, fee : Nat) {
    let line = statementLine(s.applying, order, (if (side == #buy) 1 else 2), qty, price, fee);
    switch (one(s.statementStore, statementRows, "byMember", R.key(member, 8))) {
      case (?(id, x)) RS.put(s.statementStore, statementRows, id, { x with head = chainLine(x.head, line); lines = x.lines + 1 });
      case null { let id = s.nextStatement; s.nextStatement += 1; RS.put(s.statementStore, statementRows, id, { member; head = chainLine(F.genesis(), line); lines = 1 }) };
    }
  };
  public func statementSealOf(s : State, member : Nat, day : Nat) : ?StatementSeal { switch (one(s.statementSealStore, statementSealRows, "byMemberDay", R.key2(member, 8, day, 8))) { case (?(_, x)) ?x; case null null } };
  public func reconOf(s : State, id : Nat) : ?Recon { RS.get(s.reconStore, reconRows, id) };

  // ─── indices (SPEC §26, §27) ───────────────────────────────────────────────────────────────
  func halfEvenDiv(n : Nat, d : Nat) : Nat { let q = n / d; let r = n % d; if (2 * r > d) q + 1 else if (2 * r < d) q else q + q % 2 };
  public func indexRowOf(s : State, index : Nat) : ?IndexRow { RS.get(s.indexStore, indexRows, index) };
  public func constituentsOf(s : State, index : Nat) : [(Nat, ConstituentRow)] {
    let out = List.empty<(Nat, ConstituentRow)>();
    var cursor : ?Page.Cursor = null;
    label reading loop {
      switch (RS.page(s.constituentStore, constituentRows, "byIndex", R.key2(index, 8, 0, 8), R.key2(index, 8, MAXP, 8), cursor, 100)) {
        case (#ok(p)) { for (r in p.rows.vals()) List.add(out, r); switch (p.next) { case (?n) cursor := ?n; case null break reading } };
        case (#err(_)) break reading;
      };
    };
    List.toArray(out)
  };
  func instrumentMark(s : State, inst : Nat) : Nat { switch (instrument(s, inst)) { case (?i) markPrice(i); case null 0 } };
  /// The adjusted capitalisation: each constituent's mark × its free-float shares × its factor.
  func capitalisation(s : State, index : Nat) : Nat { var m = 0; for ((_, c) in constituentsOf(s, index).vals()) m += instrumentMark(s, c.instrument) * c.shares * c.factor; m };
  /// SPEC §26: the capping factors (parts per billion) for marks × shares `m` under a cap in basis points: those above it
  /// fixed at it, the rest in proportion, until none is above.
  public func capFactors(m : [Nat], capBps : Nat) : [Nat] {
    let n = m.size();
    let capped = VarArray.repeat<Bool>(false, n);
    if (capBps == 0) return Array.tabulate<Nat>(n, func(_) { E9 });
    var changed = true;
    while (changed) {
      changed := false;
      var rest = 0; var k = 0;
      for (j in Nat.range(0, n)) { if (capped[j]) k += 1 else rest += m[j] };
      for (j in Nat.range(0, n)) {
        // the uncapped share of the rest: m_j / rest × (10_000 - k × cap) / 10_000, above the cap when m_j × (10_000 - k cap) > cap × rest
        if (not capped[j] and rest > 0 and k * capBps < 10_000 and m[j] * (10_000 - k * capBps) > capBps * rest) { capped[j] := true; changed := true };
      };
    };
    var rest = 0; var k = 0;
    for (j in Nat.range(0, n)) { if (capped[j]) k += 1 else rest += m[j] };
    Array.tabulate<Nat>(n, func(j) { if (not capped[j] or m[j] == 0 or k * capBps >= 10_000) E9 else halfEvenDiv(capBps * rest * E9, m[j] * (10_000 - k * capBps)) })
  };
  /// The constituents written with their factors at the present marks.
  func putConstituents(s : State, index : Nat, cs : [T.Constituent], capBps : Nat) {
    let marks = Array.map<T.Constituent, Nat>(cs, func(c) { instrumentMark(s, c.instrument) * c.shares });
    let factors = capFactors(marks, capBps);
    for (k in Nat.range(0, cs.size())) {
      let row = { index; instrument = cs[k].instrument; shares = cs[k].shares; factor = factors[k] };
      switch (one(s.constituentStore, constituentRows, "byIndex", R.key2(index, 8, cs[k].instrument, 8))) {
        case (?(id, _)) RS.put(s.constituentStore, constituentRows, id, row);
        case null { let id = s.nextConstituent; s.nextConstituent += 1; RS.put(s.constituentStore, constituentRows, id, row) };
      };
    };
  };
  func addPath(s : State, index : Nat, level : Nat) { RS.put(s.pathStore, pathRows, s.nextPath, { index; block = s.applying; level }); s.nextPath += 1 };
  /// The divisor set again so the level does not move by itself (§26, continuity).
  func keepLevel(s : State, index : Nat) {
    let ?x = indexRowOf(s, index) else return;
    let m = capitalisation(s, index);
    if (m > 0 and x.level > 0) RS.put(s.indexStore, indexRows, index, { x with divisor = halfEvenDiv(m * E18, x.level) });
  };
  /// After an act that moved a price: every index's level again; a changed one recorded; a breaker due when a move from
  /// the reference crosses a threshold not yet tripped (§27).
  func recomputeIndices(s : State) {
    for (index in Nat.range(1, T.MAX_INDICES + 1)) {
      switch (indexRowOf(s, index)) {
        case (?x) {
          let m = capitalisation(s, index);
          let level = if (x.divisor == 0) 0 else halfEvenDiv(m * E18, x.divisor);
          if (level != x.level) { RS.put(s.indexStore, indexRows, index, { x with level }); addPath(s, index, level) };
          let move = if (level > x.reference) level - x.reference else x.reference - level;
          let halt = x.tripped == 0 and move * 10_000 >= x.haltBps * x.reference;
          let suspend = x.tripped < 2 and x.suspendBps > 0 and move * 10_000 >= x.suspendBps * x.reference;
          if ((halt or suspend) and s.breakerDue == 0) s.breakerDue := index;
        };
        case null {};
      };
    };
  };
  /// A price quantised half-even to its tick, at least one tick.
  func toTick(i : T.Instrument, p : Nat) : Nat { let t = L.tickAt(i.bands, p); Nat.max(t, halfEvenDiv(p, t) * t) };
  /// Whether an instrument has a live or waiting order on either side.
  func openOrder(s : State, inst : Nat) : Bool {
    var found = false;
    for (ix in [BOOK, STOPS].vals()) {
      for (side in [#buy, #sell].vals()) {
        let prefix = sidePrefix(inst, side);
        let (lo, hi) = span(prefix, sideRest(ix));
        walk(s, ix, prefix, lo, hi, 8, func(_ : Nat, o : T.Order) : Bool { if (isLiveish(o) and o.instrument == inst) { found := true; false } else true });
      };
    };
    found
  };
  func constituentRefusal(s : State, cs : [T.Constituent]) : ?T.Error {
    if (cs.size() == 0 or cs.size() > T.MAX_CONSTITUENTS) return ?#InvalidTerms({ reason = "one to fifty constituents" });
    for (k in Nat.range(0, cs.size())) {
      if (instrument(s, cs[k].instrument) == null) return ?#UnknownInstrument({ instrument = cs[k].instrument });
      if (cs[k].shares == 0) return ?#InvalidTerms({ reason = "free-float shares above zero" });
      for (j in Nat.range(0, k)) { if (cs[j].instrument == cs[k].instrument) return ?#InvalidTerms({ reason = "a constituent once" }) };
    };
    null
  };
  public func pathOf(s : State, id : Nat) : ?PathRow { RS.get(s.pathStore, pathRows, id) };

  // ─── instrument classes (SPEC §28 to §32) ──────────────────────────────────────────────────
  public func termsOf(s : State, inst : Nat) : ?T.Terms { RS.get(s.termsStore, termsRows, inst) };
  public type Bond = { couponBps : Nat; perYear : Nat; basis : T.DayBasis; maturity : Nat; settleDays : Nat };
  func bondOf(s : State, inst : Nat) : ?Bond { switch (termsOf(s, inst)) { case (?#bond(b)) ?b; case (_) null } };
  public func valueDateOf(s : State, inst : Nat) : Nat { switch (RS.get(s.valueDateStore, valueDateRows, inst)) { case (?v) v.day; case null 0 } };
  /// The day `months` whole months before (year, month, day), a day past that month's end taken as its last day.
  func monthsBack(y : Nat, m : Nat, d : Nat, months : Nat) : Nat {
    let total = y * 12 + (m - 1) - months;
    let y2 = total / 12; let m2 = total % 12 + 1;
    switch (CivilDate.fromCivil(y2, m2, Nat.min(d, CivilDate.daysInMonth(y2, m2)))) { case (?x) x; case null Runtime.trap("monthsBack: a civil date") }
  };
  /// A bond's coupon dates around `day` (SPEC §28): the last on or before it and the next after it, stepping back from
  /// the maturity a coupon period at a time. `day` is before the maturity (an order is refused past it).
  public func couponAround(maturity : Nat, perYear : Nat, day : Nat) : (Nat, Nat) {
    let (y, m, d) = CivilDate.toCivil(maturity);
    let step = 12 / perYear;
    var next = maturity; var k = 1;
    loop {
      let c = monthsBack(y, m, d, k * step);
      if (c <= day) return (c, next);
      next := c; k += 1;
    }
  };
  /// The interest accrued on `qty` units of a bond for value `day` (SPEC §28): the face × the coupon × the day count's
  /// fraction from the last coupon date, in one division, half-even. ACT/365 fixed and 30/360 are the kernel's (ISO
  /// 20022 A004, A006); ACT/ACT ICMA within a period is the days elapsed over the coupons a year × the period's days
  /// (ICMA Rule 251), composed here because the kernel's A001 fraction is the whole period's.
  public func accruedOn(b : Bond, qty : Nat, day : Nat) : Nat {
    let (last, next) = couponAround(b.maturity, b.perYear, day);
    let (num, den) = switch (b.basis) {
      case (#act365) { let f = DayCount.fraction(#a004_Act365Fixed, last, day); (f.numerator, f.denominator) };
      case (#thirty360) { let f = DayCount.fraction(#a006_Thirty360Isda, last, day); (f.numerator, f.denominator) };
      case (#actActIcma) (day - last, b.perYear * (next - last));
    };
    if (num == 0) 0 else halfEvenDiv(T.BOND_FACE * qty * b.couponBps * num, 10_000 * den)
  };
  /// The most a fill of `qty` units can accrue whatever its value date (a coupon period's interest under the most a period
  /// can count: 31 days a month over 360), rounded up: what a buy holds and the CCP commits to beyond the clean value.
  func accrualBound(s : State, inst : Nat, qty : Nat) : Nat {
    switch (bondOf(s, inst)) { case (?b) ceilDiv(T.BOND_FACE * qty * b.couponBps * 31 * (12 / b.perYear), 10_000 * 360); case null 0 }
  };
  /// An order's value: its clean value and, for a bond, the most it can accrue.
  func valueOf(s : State, inst : Nat, price : Nat, qty : Nat) : Nat { price * qty * multiplierOf(s, inst) + accrualBound(s, inst, qty) };
  /// A ledger's units in the book (SPEC §28), and their change.
  public func supplyOf(s : State, ledger : Principal) : Nat { switch (one(s.supplyStore, supplyRows, "byLedger", ledgerKey(ledger))) { case (?(_, r)) r.units; case null 0 } };
  func moveSupply(s : State, ledger : Principal, up : Nat, down : Nat) {
    switch (one(s.supplyStore, supplyRows, "byLedger", ledgerKey(ledger))) {
      case (?(id, r)) RS.put(s.supplyStore, supplyRows, id, { r with units = r.units + up - down });
      case null { let id = s.nextSupply; s.nextSupply += 1; RS.put(s.supplyStore, supplyRows, id, { ledger; units = up - down }) };
    }
  };
  /// Whether an instrument's units exist only by receipts (§30).
  func isReceipt(s : State, inst : Nat) : Bool { switch (termsOf(s, inst)) { case (?#receipt(_)) true; case (_) false } };
  /// Whether a ledger is a receipt instrument's units.
  func receiptLedger(s : State, ledger : Principal) : Bool {
    for (inst in s.instrumentList.vals()) { switch (instrument(s, inst)) { case (?i) { if (Principal.equal(i.assetLedger, ledger) and isReceipt(s, inst)) return true }; case null {} } };
    false
  };
  /// What refuses an order or a quote on an instrument for its class on market day `today` (§28, §32).
  func classRefusal(s : State, inst : Nat, today : Nat) : ?T.Error {
    switch (termsOf(s, inst)) {
      case (?#bond(b)) {
        if (today >= b.maturity) return ?#InvalidTerms({ reason = "a bond before its maturity" });
        let v = valueDateOf(s, inst);
        if (v == 0 or v < today or v >= b.maturity) return ?#InvalidTerms({ reason = "the bond's value date for the day recorded first" });
        null
      };
      case (?#right(r)) { if (today > r.deadline) ?#InvalidTerms({ reason = "rights past their deadline" }) else null };
      case (?#future(_) or ?#option(_)) {
        let expired = switch (derivOf(s, inst)) { case (?d) d.expired; case null false };
        if (today > expiryOf(s, inst) or expired) ?#InvalidTerms({ reason = "a contract before its expiry" }) else null
      };
      case (_) null;
    }
  };
  /// What refuses a derivative's terms (§34, §35): an index the book computes, a multiplier, an expiry not past, the
  /// clearing in the instrument's currency.
  func derivTermsRefusal(s : State, i : T.Instrument, index : Nat, multiplier : Nat, expiry : Nat, today : Nat) : ?T.Error {
    if (indexRowOf(s, index) == null) return ?#InvalidTerms({ reason = "an index the book computes" });
    if (multiplier == 0) return ?#InvalidTerms({ reason = "a multiplier above zero" });
    if (expiry < today) return ?#InvalidTerms({ reason = "an expiry not past" });
    let ?t = s.clearing else return ?#InvalidTerms({ reason = "a derivative cleared by the venue's CCP" });
    if (not Principal.equal(i.cashLedger, t.cashLedger)) return ?#InvalidTerms({ reason = "a derivative settled in the clearing currency" });
    null
  };
  public func navOf(s : State, fund : Nat) : ?NavRow { RS.get(s.navStore, navRows, fund) };
  public func basketOf(s : State, fund : Nat) : [BasketRow] {
    let out = List.empty<BasketRow>();
    var cursor : ?Page.Cursor = null;
    label pages loop {
      switch (RS.page(s.basketStore, basketRows, "byFund", R.key2(fund, 8, 0, 8), R.key2(fund, 8, MAXP, 8), cursor, 100)) {
        case (#ok(p)) { for ((_, r) in p.rows.vals()) List.add(out, r); switch (p.next) { case (?n) cursor := ?n; case null break pages } };
        case (#err(e)) Runtime.trap("basketOf: " # debug_show(e));
      };
    };
    List.toArray(out)
  };
  /// A fund's iNAV a unit (§29): the basket at its marks and the cash over the units of a creation, half-even.
  func inavOf(s : State, fund : Nat, units : Nat, cash : Nat) : Nat {
    var m = cash;
    for (b in basketOf(s, fund).vals()) m += instrumentMark(s, b.instrument) * b.shares;
    halfEvenDiv(m, units)
  };
  /// After an act that moved a price: every fund's iNAV again, a changed one recorded on its path.
  func recomputeNavs(s : State) {
    for (fund in s.instrumentList.vals()) {
      switch (navOf(s, fund)) {
        case (?n) {
          let v = inavOf(s, fund, n.units, n.cash);
          if (v != n.inav) { RS.put(s.navStore, navRows, fund, { n with inav = v }); addNavPath(s, fund, v) };
        };
        case null {};
      };
    };
  };
  func addNavPath(s : State, fund : Nat, v : Nat) { RS.put(s.navPathStore, navPathRows, s.nextNavPath, { index = fund; block = s.applying; level = v }); s.nextNavPath += 1 };
  public func navPathOf(s : State, id : Nat) : ?PathRow { RS.get(s.navPathStore, navPathRows, id) };
  public func receiptOf(s : State, id : Nat) : ?Receipt { RS.get(s.receiptStore, receiptRows, id) };
  public func retirementOf(s : State, id : Nat) : ?Retirement { RS.get(s.retireStore, retireRows, id) };
  public func entitlementOf(s : State, id : Nat) : ?Entitlement { RS.get(s.entitlementStore, entitlementRows, id) };

  // ─── derivatives (SPEC §33 to §35) ─────────────────────────────────────────────────────────
  public type Future = { index : Nat; multiplier : Nat; expiry : Nat; imBps : Nat };
  public type OptionTerms = { index : Nat; strike : Nat; call : Bool; multiplier : Nat; expiry : Nat; aBps : Nat; bBps : Nat };
  func futureOf(s : State, inst : Nat) : ?Future { switch (termsOf(s, inst)) { case (?#future(f)) ?f; case (_) null } };
  func optionOf(s : State, inst : Nat) : ?OptionTerms { switch (termsOf(s, inst)) { case (?#option(o)) ?o; case (_) null } };
  public func isDerivative(s : State, inst : Nat) : Bool { switch (termsOf(s, inst)) { case (?#future(_) or ?#option(_)) true; case (_) false } };
  /// A contract's multiplier (1 for anything not a derivative), its expiry and its index.
  func multiplierOf(s : State, inst : Nat) : Nat { switch (termsOf(s, inst)) { case (?#future(f)) f.multiplier; case (?#option(o)) o.multiplier; case (_) 1 } };
  func expiryOf(s : State, inst : Nat) : Nat { switch (termsOf(s, inst)) { case (?#future(f)) f.expiry; case (?#option(o)) o.expiry; case (_) 0 } };
  func indexOfDeriv(s : State, inst : Nat) : Nat { switch (termsOf(s, inst)) { case (?#future(f)) f.index; case (?#option(o)) o.index; case (_) 0 } };
  public func derivOf(s : State, inst : Nat) : ?Deriv { RS.get(s.derivStore, derivRows, inst) };
  func indexLevel(s : State, index : Nat) : Nat { switch (indexRowOf(s, index)) { case (?x) x.level; case null 0 } };
  public func attestorOf(s : State, n : Nat) : ?Principal { switch (RS.get(s.attestorStore, attestorRows, n)) { case (?a) ?a.attestor; case null null } };
  func attestationOf(s : State, inst : Nat, day : Nat, n : Nat) : ?Attestation { switch (one(s.attestationStore, attestationRows, "byKey", attestKey(inst, day, n))) { case (?(_, a)) ?a; case null null } };
  /// The daily price (§33): the median of the three attestors' prices for the day, when all three attested.
  public func attestedPrice(s : State, inst : Nat, day : Nat) : ?Nat {
    switch (attestationOf(s, inst, day, 1), attestationOf(s, inst, day, 2), attestationOf(s, inst, day, 3)) {
      case (?a, ?b, ?c) { let x = a.price; let y = b.price; let z = c.price; ?Nat.max(Nat.min(x, y), Nat.min(Nat.max(x, y), z)) };
      case (_) null;
    }
  };
  public func positionOf(s : State, account : Nat, inst : Nat) : ?(Nat, Position) { one(s.positionStore, positionRows, "byKey", R.key2(account, 8, inst, 8)) };
  public func memberImOf(s : State, member : Nat) : Nat { switch (RS.get(s.memberImStore, memberImRows, member)) { case (?x) x.im; case null 0 } };
  /// An option's intrinsic value at the index's level (§35), in hundredths of a point.
  func intrinsic(o : OptionTerms, u : Nat) : Nat { if (o.call) (if (u > o.strike) u - o.strike else 0) else (if (o.strike > u) o.strike - u else 0) };
  /// An option writer's margin on `qty` contracts (§35): the premium at `premium` and the greater of a × the index less
  /// what the option is out of the money and b × the index (a call) or b × the strike (a put), × the multiplier, rounded
  /// up.
  func writerIm(o : OptionTerms, qty : Nat, premium : Nat, u : Nat) : Nat {
    let otm = if (o.call) (if (o.strike > u) o.strike - u else 0) else (if (u > o.strike) u - o.strike else 0);
    let a = o.aBps * u; let away = otm * 10_000;
    let risk = Nat.max(if (a > away) a - away else 0, o.bBps * (if (o.call) u else o.strike));
    ceilDiv(qty * o.multiplier * (premium * 10_000 + risk), 10_000)
  };
  /// The initial margin of a position or an order on a derivative (§34, §35): a future's notional at `price` × its rate,
  /// rounded up, either side; an option's premium for a buyer; a writer's margin for a seller.
  func derivIm(s : State, inst : Nat, long : Bool, qty : Nat, price : Nat) : Nat {
    switch (termsOf(s, inst)) {
      case (?#future(f)) ceilDiv(qty * price * f.multiplier * f.imBps, 10_000);
      case (?#option(o)) { if (long) qty * price * o.multiplier else writerIm(o, qty, price, indexLevel(s, o.index)) };
      case (_) 0;
    }
  };
  func putMemberIm(s : State, member : Nat, up : Nat, down : Nat) {
    RS.put(s.memberImStore, memberImRows, member, { im = memberImOf(s, member) + up - down });
  };
  /// A fill of `qty` contracts at `price` for `account` netted into its position (§34): a buy reduces a short first, a sale
  /// a long; what is new is marked at the derivative's mark. The position's margin follows; the member's with it.
  func movePosition(s : State, account : Nat, member : Nat, inst : Nat, buy : Bool, qty : Nat) {
    let mark = switch (derivOf(s, inst)) { case (?d) d.mark; case null 0 };
    let (id, p) = switch (positionOf(s, account, inst)) {
      case (?(i, x)) (i, x);
      case null { let i = s.nextPosition; s.nextPosition += 1; (i, { account; instrument = inst; member; long = buy; qty = 0; mark; im = 0 }) };
    };
    let (long, q) = if (p.qty == 0) (buy, qty) else if (p.long == buy) (p.long, p.qty + qty) else if (p.qty >= qty) (p.long, p.qty - qty) else (buy, qty - p.qty);
    // every position is marked at its derivative's mark: a settlement marks them all, and no fill lands within one
    let im = if (q == 0) 0 else derivIm(s, inst, long, q, mark);
    RS.put(s.positionStore, positionRows, id, { p with long; qty = q; im; mark });
    putMemberIm(s, member, im, p.im);
  };

  // ─── market makers (SPEC §25) ──────────────────────────────────────────────────────────────
  public func makerOf(s : State, member : Nat, inst : Nat) : ?(Nat, Maker) { one(s.makerStore, makerRows, "byKey", R.key2(member, 8, inst, 8)) };
  public func makerDayOf(s : State, id : Nat) : ?MakerDay { RS.get(s.makerDayStore, makerDayRows, id) };
  /// Whether a maker is present now: its instrument trading continuously, both sides of its quote live with at least
  /// the minimum quantity each, the spread within the maximum (spread × 20,000 ≤ the maximum × (bid + ask)).
  func presentNow(s : State, m : Maker) : (Bool, Bool) {
    let cont = switch (instrument(s, m.instrument)) { case (?i) i.phase == #continuous; case null false };
    if (not cont or m.bid == 0) return (cont, false);
    switch (order(s, m.bid), order(s, m.ask)) {
      case (?b, ?a) {
        let ok = b.status == #live and a.status == #live and b.remaining >= m.minQty and a.remaining >= m.minQty and a.price > b.price
          and (a.price - b.price) * 20_000 <= m.maxSpreadBps * (a.price + b.price);
        (cont, ok)
      };
      case (_) (cont, false);
    }
  };
  /// After every act: each registration accrues the time since the last act to its continuous session and its presence
  /// (as the last act left them), then is judged again as this act leaves it.
  func accrueMakers(s : State, now : Nat64) {
    var id = 1;
    while (id < s.nextMaker) {
      switch (RS.get(s.makerStore, makerRows, id)) {
        case (?m) {
          let dt = if (m.lastAt != 0 and now > m.lastAt) Nat64.toNat(now - m.lastAt) else 0;
          let (cont, present) = presentNow(s, m);
          let next = { m with sessionNs = m.sessionNs + (if (m.cont) dt else 0); presentNs = m.presentNs + (if (m.present) dt else 0); cont; present; lastAt = now };
          if (next != m) RS.put(s.makerStore, makerRows, id, next);
        };
        case null {};
      };
      id += 1;
    };
  };
  /// A quote's entry checks (§25), for every side of a quote or mass quote on one pre-funded account: the maker
  /// registered, the instrument open, both prices on the tick and within the static band, the bid below the ask, whole
  /// lots, fresh client references, and the funds — what the replaced quotes hold counted as released.
  func quoteRefusal(s : State, xs : X.State, now : Nat64, caller : Principal, account : Nat, member : Nat, trader : Nat, sides : [T.QuoteSide]) : ?T.Error {
    switch (ownAccount(xs, caller, account)) { case (?e) return ?e; case null {} };
    switch (X.account(xs, account), X.traderByPrincipal(xs, caller)) {
      case (?a, ?(tid, _)) { if (a.member != member or tid != trader) return ?#NotYourAccount({ account }) };
      case (_) return ?#NotYourAccount({ account });
    };
    if (isCcp(s, account) or clearingOf(s, account) != null) return ?#InvalidTerms({ reason = "a quote on a pre-funded account" });
    if (sides.size() == 0 or sides.size() > T.MAX_MASS_QUOTE) return ?#InvalidTerms({ reason = "one to sixteen quotes" });
    switch (killedFor(s, member, trader)) { case (?k) return ?#Killed({ kill = k }); case null {} };
    var cashNeed = 0; var cashFreed = 0; var netAdded : Int = 0;
    var cashLedger : ?Principal = null;
    for (k in Nat.range(0, sides.size())) {
      let q = sides[k];
      for (j in Nat.range(0, k)) { if (sides[j].instrument == q.instrument) return ?#InvalidTerms({ reason = "one quote an instrument" }) };
      let ?(_, mk) = makerOf(s, member, q.instrument) else return ?#NotAMaker({ member; instrument = q.instrument });
      switch (X.mayTrade(xs, caller, q.instrument)) { case (?e) return ?#MayNotTrade({ code = XText.code(e) }); case null {} };
      let ?i = instrument(s, q.instrument) else return ?#UnknownInstrument({ instrument = q.instrument });
      if (i.phase == #halted) return ?#InstrumentHalted({ instrument = q.instrument });
      switch (classRefusal(s, q.instrument, X.marketTime(xs, now).0)) { case (?e) return ?e; case null {} };
      if (isDerivative(s, q.instrument)) return ?#InvalidTerms({ reason = "a derivative is quoted on no pre-funded account" });
      if (blackedOut(s, xs, account, q.instrument, now)) return ?#InsiderBlackout({ instrument = q.instrument });
      if (q.qty == 0 or q.qty % i.lot != 0) return ?#NotALot({ qty = q.qty; lot = i.lot });
      let n = Text.encodeUtf8(q.ref).size();
      if (n == 0 or n + 2 > T.CLIENT_REF_BYTES) return ?#InvalidTerms({ reason = "a quote reference of 1 to 18 bytes" });
      for (side in [".b", ".a"].vals()) { if (orderByRef(s, account, q.ref # side) != null) return ?#DuplicateClientRef({ clientRef = q.ref # side }) };
      for (p in [q.bidPrice, q.askPrice].vals()) {
        if (not L.onTick(i.bands, p)) return ?#PriceOffTick({ price = p; tick = L.tickAt(i.bands, p) });
        let (lo, hi) = L.band(i.referencePrice, i.staticBps);
        if (p < lo or p > hi) return ?#PriceOutsideBand({ price = p; low = lo; high = hi });
      };
      if (q.bidPrice >= q.askPrice) return ?#InvalidPrice({ reason = "a bid below the ask" });
      // the replaced quote's funds count as released; its open value as replaced in the risk limits
      let (oldBidHeld, oldAskHeld, oldValue) = switch (mk.account == account) {
        case true {
          let bh = switch (order(s, mk.bid)) { case (?o) (if (isLiveish(o)) o.held else 0); case null 0 };
          let ah = switch (order(s, mk.ask)) { case (?o) (if (isLiveish(o)) o.held else 0); case null 0 };
          let ov = (switch (order(s, mk.bid)) { case (?o) openValue(s, o); case null 0 }) + (switch (order(s, mk.ask)) { case (?o) openValue(s, o); case null 0 });
          (bh, ah, ov)
        };
        case false (0, 0, 0);
      };
      let value = valueOf(s, q.instrument, q.bidPrice, q.qty) + valueOf(s, q.instrument, q.askPrice, q.qty);
      switch (riskRefusal(s, member, q.qty, value, oldValue)) { case (?e) return ?e; case null {} };
      // the earlier quotes of a mass quote count against the member's credit with this one
      netAdded += value - oldValue;
      switch (limitsOf(s, member)) {
        case (?(_, r)) { let use = r.limits.used + netAdded; if (r.limits.creditLimit != 0 and use > r.limits.creditLimit) return ?#RiskLimit({ figure = "credit"; limit = r.limits.creditLimit; wanted = Int.abs(use) }) };
        case null {};
      };
      switch (cashLedger) { case (?l) { if (not Principal.equal(l, i.cashLedger)) return ?#InvalidTerms({ reason = "quotes in one currency" }) }; case null cashLedger := ?i.cashLedger };
      cashNeed += buyHold(s, i, q.instrument, q.bidPrice, q.qty); cashFreed += oldBidHeld;
      let freeShares = ownedFree(s, account, i, q.instrument) + oldAskHeld;
      if (q.qty > freeShares) return ?#ShortSaleNotFlagged({ free = freeShares; wanted = q.qty });
    };
    switch (cashLedger) {
      case (?l) { let b = balance(s, account, l); if (cashNeed > b.available + cashFreed) return ?#InsufficientFunds({ ledger = l; available = b.available + cashFreed; wanted = cashNeed }) };
      case null {};
    };
    null
  };
  /// The quotes entered: for each instrument, the maker's live sides cancelled, then the bid and the ask placed as limit
  /// orders good for the day (each as an order's entry is applied). Effects per quote: the instrument, the orders
  /// cancelled, then each side's order, status, price and shown quantity.
  func enterQuotes(s : State, now : Nat64, account : Nat, member : Nat, trader : Nat, sides : [T.QuoteSide], tag : Nat) : T.Effects {
    let fx = List.empty<Nat>(); List.add(fx, tag); List.add(fx, sides.size());
    for (q in sides.vals()) {
      let ?(mid, mk) = makerOf(s, member, q.instrument) else Runtime.trap("quote: a maker vanished");
      let cancelled = List.empty<Nat>();
      for (oid in [mk.bid, mk.ask].vals()) { switch (order(s, oid)) { case (?o) { if (isLiveish(o)) { close(s, oid, o, #cancelled); List.add(cancelled, oid) } }; case null {} } };
      let place = func(side : T.Side, price : Nat, ref : Text) : [Nat] {
        applyCommand(s, now, #placeOrder({ account; instrument = q.instrument; side; kind = #limit; qty = q.qty; price; stopPrice = 0; peak = 0; validity = #day; gtdDay = 0;
          selfTrade = #cancelResting; capacity = #principal; shortSale = false; clientRef = ref; oco = 0; trail = 0; member; trader }))
      };
      let eb = place(#buy, q.bidPrice, q.ref # ".b");
      let ea = place(#sell, q.askPrice, q.ref # ".a");
      // own resting orders the sides crossed were cancelled at their entry (self-trade prevention, §3.5)
      for (e in [eb, ea].vals()) { for (k in Nat.range(5, e.size())) List.add(cancelled, e[k]) };
      RS.put(s.makerStore, makerRows, mid, { mk with account; bid = eb[1]; ask = ea[1] });
      List.add(fx, q.instrument); List.add(fx, List.size(cancelled)); for (c in List.values(cancelled)) List.add(fx, c);
      for (e in [eb, ea].vals()) { for (k in Nat.range(1, 5)) List.add(fx, e[k]) };
    };
    List.toArray(fx)
  };

  /// Available funds leaving an account (a transfer the checks covered).
  func debit(s : State, account : Nat, ledger : Principal, amount : Nat) {
    if (amount == 0) return;
    let b = balance(s, account, ledger);
    if (b.available < amount) Runtime.trap("debit: the funds were checked");
    putBalance(s, { b with available = b.available - amount });
  };
  func move(s : State, from : Nat, to : Nat, ledger : Principal, amount : Nat) { debit(s, from, ledger, amount); credit(s, to, ledger, amount) };

  // ─── the central counterparty (SPEC §18 to §21) ──────────────────────────────────────────
  public let MAX_CLEARING_MEMBERS = 64;
  func ceilDiv(a : Nat, b : Nat) : Nat { (a + b - 1) / b };
  /// Initial margin on a value at a rate in basis points, rounded up.
  func imFor(bps : Nat, value : Nat) : Nat { ceilDiv(bps * value, 10_000) };
  public func clearingTerms(s : State) : ?ClearingTerms { s.clearing };
  public func clearingMember(s : State, member : Nat) : ?(Nat, ClearingMember) { one(s.clearingStore, clearingRows, "byMember", R.key(member, 8)) };
  func updateMember(s : State, member : Nat, f : ClearingMember -> ClearingMember) {
    let ?(id, r) = clearingMember(s, member) else Runtime.trap("clearing: a member vanished");
    RS.put(s.clearingStore, clearingRows, id, f(r))
  };
  /// The clearing member an account is designated to, if it is a clearing account.
  public func clearingOf(s : State, account : Nat) : ?Nat { switch (one(s.designationStore, designationRows, "byAccount", R.key(account, 8))) { case (?(_, d)) ?d.member; case null null } };
  public func custodyOf(s : State, member : Nat, inst : Nat) : CustodyRow {
    switch (one(s.custodyStore, custodyRows, "byMember", R.key2(member, 8, inst, 8))) { case (?(_, r)) r; case null ({ member; instrument = inst; qty = 0; held = 0 } : CustodyRow) }
  };
  func putCustody(s : State, c : CustodyRow) {
    switch (one(s.custodyStore, custodyRows, "byMember", R.key2(c.member, 8, c.instrument, 8))) {
      case (?(id, _)) RS.put(s.custodyStore, custodyRows, id, c);
      case null { let id = s.nextCustody; s.nextCustody += 1; RS.put(s.custodyStore, custodyRows, id, c) };
    }
  };
  /// Every custody row of a member, in instrument order (at most one an instrument).
  public func custodyRowsOf(s : State, member : Nat) : [CustodyRow] {
    let out = List.empty<CustodyRow>();
    var cursor : ?Page.Cursor = null;
    label reading loop {
      switch (RS.page(s.custodyStore, custodyRows, "byMember", R.key2(member, 8, 0, 8), R.key2(member, 8, MAXP, 8), cursor, 100)) {
        case (#ok(p)) { for ((_, r) in p.rows.vals()) List.add(out, r); switch (p.next) { case (?n) cursor := ?n; case null break reading } };
        case (#err(_)) break reading;
      };
    };
    List.toArray(out)
  };
  public func marginOf(s : State, inst : Nat) : ?Nat { RS.get(s.marginStore, marginRows, inst) };
  public func obligationOf(s : State, member : Nat, cycle : Nat) : ?(Nat, Obligation) { one(s.obligationStore, obligationRows, "byMemberCycle", R.key2(member, 8, cycle, 8)) };
  /// Adds to a member's obligations in a cycle, and to its row's totals over its unsettled cycles.
  func owe(s : State, member : Nat, cycle : Nat, to : Nat, by : Nat) {
    switch (obligationOf(s, member, cycle)) {
      case (?(id, o)) RS.put(s.obligationStore, obligationRows, id, { o with owedTo = o.owedTo + to; owedBy = o.owedBy + by });
      case null { let id = s.nextObligation; s.nextObligation += 1; RS.put(s.obligationStore, obligationRows, id, { member; cycle; owedTo = to; owedBy = by }) };
    };
    updateMember(s, member, func(r : ClearingMember) : ClearingMember { { r with owedTo = r.owedTo + to; owedBy = r.owedBy + by } });
  };
  func boughtKey(member : Nat, inst : Nat, cycle : Nat) : Blob { let b = R.buf(); R.putNat(b, member, 8); R.putNat(b, inst, 8); R.putNat(b, cycle, 8); R.done(b, 24) };
  public func boughtOf(s : State, member : Nat, inst : Nat, cycle : Nat) : Nat { switch (one(s.boughtStore, boughtRows, "byKey", boughtKey(member, inst, cycle))) { case (?(_, r)) r.qty; case null 0 } };
  func addBought(s : State, member : Nat, inst : Nat, cycle : Nat, qty : Nat) {
    switch (one(s.boughtStore, boughtRows, "byKey", boughtKey(member, inst, cycle))) {
      case (?(id, r)) RS.put(s.boughtStore, boughtRows, id, { r with qty = r.qty + qty });
      case null { let id = s.nextBought; s.nextBought += 1; RS.put(s.boughtStore, boughtRows, id, { member; instrument = inst; cycle; qty }) };
    }
  };
  public func cycleOf(s : State, cycle : Nat) : ?CycleRow { RS.get(s.cycleStore, cycleRows, cycle) };
  /// The price a position is valued at: the last trade, or the reference before any.
  func markPrice(i : T.Instrument) : Nat { if (i.lastPrice != 0) i.lastPrice else i.referencePrice };
  /// The value of the shares the CCP holds for a member, each instrument at its mark.
  func custodyValue(s : State, member : Nat) : Nat {
    var v = 0;
    for (c in custodyRowsOf(s, member).vals()) { if (c.qty > 0) { switch (instrument(s, c.instrument)) { case (?i) v += c.qty * markPrice(i); case null {} } } };
    v
  };
  /// Variation margin (SPEC §18): what a member owes in its unsettled cycles and rolled debt beyond what it is owed and the
  /// value of the shares the CCP holds for it; at least 0.
  public func variationOf(s : State, r : ClearingMember) : Nat {
    let owes = r.owedBy + r.debt; let has = r.owedTo + custodyValue(s, r.member);
    if (owes > has) owes - has else 0
  };
  /// The CCP's cash on its account, and what is free of the open clearing buys it is committed to.
  public func ccpCash(s : State) : Nat { switch (s.clearing) { case (?t) balance(s, t.ccpAccount, t.cashLedger).available; case null 0 } };
  public func ccpFree(s : State) : Nat { let c = ccpCash(s); if (c > s.ccpCommitted) c - s.ccpCommitted else 0 };
  /// A member's requirement against its resources (SPEC §18): its fund contribution paid up to the call, and its open
  /// buys' initial margin (`imOrders`, changed by `add` and `drop`) with variation margin within its collateral and credit
  /// line (`release` of collateral taken out first).
  func marginRefusal(s : State, r : ClearingMember, add : Nat, drop : Nat, release : Nat) : ?T.Error {
    if (r.fund < r.fundRequired) return ?#FundShort({ required = r.fundRequired; paid = r.fund });
    let required = r.imOrders + add - drop + variationOf(s, r) + memberImOf(s, r.member);
    let available = r.collateral + r.creditLine - release;
    if (required > available) ?#MarginShort({ required; available }) else null
  };
  /// The shares a clearing member may sell (SPEC §18): what the CCP holds for it free of its sales, and what its settlement
  /// account holds (free of what it owes on loans, unless the sale is flagged short).
  func clearingSellable(s : State, r : ClearingMember, i : T.Instrument, inst : Nat, flagged : Bool) : Nat {
    let c = custodyOf(s, r.member, inst);
    (c.qty - c.held) + (if (flagged) balance(s, r.settlementAccount, i.assetLedger).available else ownedFree(s, r.settlementAccount, i, inst))
  };
  /// A clearing sale's shares pledged to the CCP: what the CCP holds for the member free of its sales first, the rest from
  /// its settlement account into the CCP's account. The order's hold on them is recorded by `putOrder`.
  func pledge(s : State, member : Nat, i : T.Instrument, inst : Nat, qty : Nat) {
    let ?t = s.clearing else Runtime.trap("pledge: no clearing");
    let ?(_, r) = clearingMember(s, member) else Runtime.trap("pledge: a member vanished");
    let c = custodyOf(s, member, inst);
    let free = c.qty - c.held;
    if (free >= qty) return;
    move(s, r.settlementAccount, t.ccpAccount, i.assetLedger, qty - free);
    appendLeg(s, 3, i.assetLedger, r.settlementAccount, t.ccpAccount, qty - free);
    putCustody(s, { c with qty = c.qty + qty - free });
  };
  /// An order's clearing records as it changes (SPEC §18): a clearing buy's initial margin (what it holds) in its member's
  /// row and its open value in the CCP's commitment; a clearing sale's or a close-out's held shares in the custody row.
  func clearingMove(s : State, id : Nat, o : T.Order, v0 : Nat, v1 : Nat, h0 : Nat) {
    switch (clearingOf(s, o.account)) {
      // a derivative's order holds margin on either side and commits the CCP to nothing: no value moves at its fill
      case (?m) { if (isDerivative(s, o.instrument)) { updateMember(s, m, func(r : ClearingMember) : ClearingMember { { r with imOrders = r.imOrders + o.held - h0 } }); return } };
      case null {};
    };
    switch (clearingOf(s, o.account)) {
      case (?m) {
        switch (o.side) {
          case (#buy) { updateMember(s, m, func(r : ClearingMember) : ClearingMember { { r with imOrders = r.imOrders + o.held - h0 } }); s.ccpCommitted := s.ccpCommitted + v1 - v0 };
          case (#sell) { let c = custodyOf(s, m, o.instrument); putCustody(s, { c with held = c.held + o.held - h0 }) };
        };
      };
      case null {
        switch (s.clearing) {
          case (?t) {
            if (o.account == t.ccpAccount) {
              switch (one(s.closeoutStore, closeoutRows, "byOrder", R.key(id, 8))) {
                case (?(_, co)) { let c = custodyOf(s, co.member, o.instrument); putCustody(s, { c with held = c.held + o.held - h0 }) };
                case null {};
              };
            };
          };
          case null {};
        };
      };
    };
  };

  // ─── the settlement range (SPEC §19): a Merkle mountain range under the kernel's proof hashing ───────────────────
  func popcount(n : Nat) : Nat { var c = 0; var x = n; while (x > 0) { c += x % 2; x /= 2 }; c };
  /// The post-order position of leaf `i`, and of the node of height `h` whose leaves start at `j * 2^h`.
  func leafPos(i : Nat) : Nat { 2 * i - popcount(i) };
  func nodePos(h : Nat, j : Nat) : Nat { leafPos((j + 1) * 2 ** h - 1) + h };
  func nodeAt(s : State, h : Nat, j : Nat) : Blob { let ?x = RS.get(s.nodeStore, nodeRows, nodePos(h, j) + 1) else Runtime.trap("settlement range: a node is missing"); x };
  func putNode(s : State, h : Nat, j : Nat, x : Blob) {
    if (nodePos(h, j) != s.nextNode) Runtime.trap("settlement range: a node out of order");
    s.nextNode += 1; RS.put(s.nodeStore, nodeRows, s.nextNode, x)
  };
  public func legHash(l : Leg) : Blob { MP.hashLeaf(legRows.encode(l)) };
  /// A leg appended: its leaf, then the parents it completes.
  func appendLeg(s : State, kind : Nat, ledger : Principal, from : Nat, to : Nat, units : Nat) {
    if (units == 0) return;
    let l : Leg = { kind; ledger; from; to; units; block = s.applying };
    let i = s.nextLeg; s.nextLeg += 1; RS.put(s.legStore, legRows, s.nextLeg, l);
    var h = legHash(l); putNode(s, 0, i, h);
    var height = 0; var j = i;
    while (j % 2 == 1) { h := MP.hashNode(nodeAt(s, height, j - 1), h); height += 1; j /= 2; putNode(s, height, j, h) };
  };
  /// The range's peaks, highest first, for its first `n` leaves.
  func peaksOf(s : State, n : Nat) : [Blob] {
    let out = List.empty<Blob>();
    var off = 0; var h = 64;
    while (h > 0) { h -= 1; if ((n / 2 ** h) % 2 == 1) { List.add(out, nodeAt(s, h, off / 2 ** h)); off += 2 ** h } };
    List.toArray(out)
  };
  /// The settlement range's leaf count and root (the root of no leaves is 32 zero bytes).
  public func settlementRoot(s : State) : (Nat, Blob) {
    switch (MP.bagPeaks(peaksOf(s, s.nextLeg))) { case (?r) (s.nextLeg, r); case null (0, F.genesis()) }
  };
  /// The root the range had when it held its first `n` legs (1 to the present count): the nodes of those legs are stored
  /// before any later leg's, so every earlier root stays computable.
  public func settlementRootAt(s : State, n : Nat) : ?Blob { if (n == 0 or n > s.nextLeg) null else MP.bagPeaks(peaksOf(s, n)) };
  /// Leg `i` and its inclusion proof against the present root.
  public func settlementProof(s : State, i : Nat) : ?{ leg : Leg; proof : MP.Proof } { settlementProofAt(s, i, s.nextLeg) };
  /// Leg `i` and its inclusion proof against the root the range had at `n` legs.
  public func settlementProofAt(s : State, i : Nat, n : Nat) : ?{ leg : Leg; proof : MP.Proof } {
    if (i >= n or n > s.nextLeg) return null;
    let ?leg = RS.get(s.legStore, legRows, i + 1) else return null;
    var off = 0; var h = 64; var k = 0;
    while (h > 0) {
      h -= 1;
      if ((n / 2 ** h) % 2 == 1) {
        if (i < off + 2 ** h) {
          let sib = List.empty<Blob>();
          var j = i;
          for (level in Nat.range(0, h)) { List.add(sib, nodeAt(s, level, if (j % 2 == 0) j + 1 else j - 1)); j /= 2 };
          return ?{ leg; proof = { siblings = List.toArray(sib); peakIndex = k; peaks = peaksOf(s, n) } };
        };
        off += 2 ** h; k += 1;
      };
    };
    null
  };
  public func legOf(s : State, i : Nat) : ?Leg { RS.get(s.legStore, legRows, i + 1) };
  /// The member a close-out order of the CCP is for, if the order is one.
  public func closeoutOf(s : State, order : Nat) : ?Nat { switch (one(s.closeoutStore, closeoutRows, "byOrder", R.key(order, 8))) { case (?(_, c)) ?c.member; case null null } };
  /// The clearing's figures: the CCP's commitment, the skin-in-the-game, the open cycle, the last settled, the last cut.
  public func clearingFigures(s : State) : (Nat, Nat, Nat, Nat, Nat64) { (s.ccpCommitted, s.skin, s.cycleNo, s.settledThrough, s.lastCut) };

  // ═══════════════════════════════════════════════════════
  //  VALIDATION
  // ═══════════════════════════════════════════════════════

  /// The account and the caller: an open account of a member the caller is an active trader of. Membership is judged
  /// before the account's status, so another member's account answers only NotYourAccount, never whether it is closed
  /// (no read or refusal tells one member about another's accounts).
  func ownAccount(xs : X.State, caller : Principal, account : Nat) : ?T.Error {
    let ?a = X.account(xs, account) else return ?#UnknownAccount({ account });
    let ?(_, t) = X.traderByPrincipal(xs, caller) else return ?#NotYourAccount({ account });
    if (t.status != #active or t.member != a.member) return ?#NotYourAccount({ account });
    if (a.status != #open) return ?#AccountClosed({ account });
    null
  };
  /// Whether the account's client code is blacked out for the instrument at the act's market day (SPEC §16).
  func blackedOut(s : State, xs : X.State, account : Nat, inst : Nat, now : Nat64) : Bool {
    let ?a = X.account(xs, account) else return false;
    if (a.client.size() != 32) return false;
    switch (one(s.blackoutStore, blackoutRows, "active", blackoutKey(inst, a.client))) {
      case (?(_, bo)) bo.until == 0 or X.marketTime(xs, now).0 <= bo.until;
      case null false;
    }
  };
  /// What an account owes in an instrument from securities loans (SPEC §17).
  public func owedOf(s : State, account : Nat, inst : Nat) : Nat { switch (one(s.borrowStore, borrowRows, "byAccount", R.key2(account, 8, inst, 8))) { case (?(_, r)) r.owed; case null 0 } };
  func putOwed(s : State, account : Nat, inst : Nat, owed : Nat) {
    switch (one(s.borrowStore, borrowRows, "byAccount", R.key2(account, 8, inst, 8))) {
      case (?(id, r)) RS.put(s.borrowStore, borrowRows, id, { r with owed });
      case null { let id = s.nextBorrow; s.nextBorrow += 1; RS.put(s.borrowStore, borrowRows, id, { account; instrument = inst; owed }) };
    }
  };
  /// The shares an account owns free of other sales: its available shares less what it owes, at least 0 (SPEC §17).
  func ownedFree(s : State, account : Nat, i : T.Instrument, inst : Nat) : Nat {
    let avail = balance(s, account, i.assetLedger).available;
    let owed = owedOf(s, account, inst);
    if (avail > owed) avail - owed else 0
  };
  /// The price a short sale may not go below: the last trade, or the reference before any (SPEC §17).
  func shortFloor(i : T.Instrument) : Nat { if (i.lastPrice != 0) i.lastPrice else i.referencePrice };
  /// The member an account belongs to in the exchange's rows (0 for no such account).
  func memberOf(xs : X.State, account : Nat) : Nat { switch (X.account(xs, account)) { case (?a) a.member; case null 0 } };
  func ownOrder(s : State, xs : X.State, caller : Principal, id : Nat) : Result.Result<T.Order, T.Error> {
    let ?o = order(s, id) else return #err(#UnknownOrder({ order = id }));
    switch (ownAccount(xs, caller, o.account)) { case (?_) return #err(#NotYourOrder({ order = id })); case null {} };
    if (not isLiveish(o)) return #err(#OrderClosed({ order = id }));
    #ok(o)
  };
  /// The effective price of an order at entry (§6): a market order's or a stop's collar price, otherwise its limit.
  func effectivePrice(i : T.Instrument, side : T.Side, kind : T.Kind, price : Nat) : Nat {
    switch (kind) { case (#market or #stop or #trailingStop) L.collarPrice(side, i.referencePrice, i.collarBps, i.bands); case (_) price }
  };
  /// The account's own live orders on the other side of the instrument that a new order at `price` would cross.
  func crossingOwn(s : State, account : Nat, inst : Nat, side : T.Side, price : Nat, limit : Nat) : [(T.OrderId, T.Order)] {
    let other : T.Side = switch (side) { case (#buy) #sell; case (#sell) #buy };
    let prefix = ownPrefix(account, inst, other);
    let (lo, hi) = span(prefix, 16);
    let out = List.empty<(T.OrderId, T.Order)>();
    walk(s, OWN, prefix, lo, hi, 8, func(id : Nat, o : T.Order) : Bool {
      if (o.status != #live) return true;
      let crosses = switch (side) { case (#buy) price >= o.price; case (#sell) price <= o.price };
      if (not crosses) return false;   // best first: none after it crosses either
      List.add(out, (id, o));
      List.size(out) < limit
    });
    List.toArray(out)
  };

  public func validate(s : State, xs : X.State, now : Nat64, caller : Principal, c : T.Command) : ?T.Error {
    switch (c) {
      case (#openInstrument(x)) {
        if (instrument(s, x.instrument) != null) return ?#InstrumentOpenAlready({ instrument = x.instrument });
        let ?xi = X.instrument(xs, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (xi.status == #delisted) return ?#UnknownInstrument({ instrument = x.instrument });
        if (not Principal.equal(xi.assetLedger, x.assetLedger)) return ?#InstrumentMismatch({ field = "assetLedger" });
        if (not Principal.equal(xi.cashLedger, x.cashLedger)) return ?#InstrumentMismatch({ field = "cashLedger" });
        if (xi.lot != x.lot) return ?#InstrumentMismatch({ field = "lot" });
        let ?tbl = X.tickTable(xs, xi.tickTable) else return ?#InstrumentMismatch({ field = "bands" });
        if (tbl.bands.size() != x.bands.size()) return ?#InstrumentMismatch({ field = "bands" });
        var i = 0;
        while (i < x.bands.size()) { if (tbl.bands[i].fromPrice != x.bands[i].fromPrice or tbl.bands[i].tick != x.bands[i].tick) return ?#InstrumentMismatch({ field = "bands" }); i += 1 };
        // the first day (SPEC §12): the reference is the exchange's, the hand-off's
        if (xi.referencePrice != x.referencePrice) return ?#InstrumentMismatch({ field = "referencePrice" });
        if (x.collarBps == 0 or x.collarBps >= 10_000) return ?#InvalidTerms({ reason = "a collar between 0 and 100 per cent" });
        if (x.staticBps == 0 or x.staticBps >= 10_000 or x.collarBps > x.staticBps) return ?#InvalidTerms({ reason = "a static band above the collar and below 100 per cent" });
        if (x.dynamicBps >= 10_000) return ?#InvalidTerms({ reason = "a dynamic band below 100 per cent" });
        if (x.interruptSecs > 86_400) return ?#InvalidTerms({ reason = "an interruption of at most a day" });
        // the reference is the exchange's, which the exchange checked on these bands: no tick check here can refuse
        null
      };
      case (#setTrading(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase == #halted) return ?#InstrumentHalted({ instrument = x.instrument });
        switch (derivOf(s, x.instrument)) { case (?d) { if (x.open and d.runDay != 0) return ?#InvalidTerms({ reason = "a derivative's settlement run finished first" }) }; case null {} };
        if (i.interruptUntil != 0) return ?#InvalidTerms({ reason = "an interruption ends by its uncross" });
        if (x.open == (i.phase == #continuous)) return ?#InvalidTerms({ reason = "the instrument is already so" });
        null
      };
      case (#setReference(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (not L.onTick(i.bands, x.price)) return ?#PriceOffTick({ price = x.price; tick = L.tickAt(i.bands, x.price) });
        null
      };
      case (#deposit(x)) {
        let ?a = X.account(xs, x.account) else return ?#UnknownAccount({ account = x.account });
        if (a.member != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        if (isCcp(s, x.account)) return ?#InvalidTerms({ reason = "the central counterparty's account moves only by clearing" });
        if (x.amount == 0) return ?#InvalidTerms({ reason = "an amount above zero" });
        if (x.reference.size() != 32) return ?#InvalidTerms({ reason = "a 32-byte reference" });
        if (one(s.refRows, refs, "byRef", x.reference) != null) return ?#DuplicateReference;
        if (receiptLedger(s, x.ledger)) return ?#InvalidTerms({ reason = "a receipt's units come only from its warehouse" });
        null
      };
      case (#withdraw(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        if (memberOf(xs, x.account) != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        if (x.amount == 0) return ?#InvalidTerms({ reason = "an amount above zero" });
        if (isCcp(s, x.account)) return ?#InvalidTerms({ reason = "the central counterparty's account moves only by clearing" });
        let b = balance(s, x.account, x.ledger);
        if (b.available < x.amount) return ?#InsufficientFunds({ ledger = x.ledger; available = b.available; wanted = x.amount });
        if (receiptLedger(s, x.ledger)) return ?#InvalidTerms({ reason = "a receipt's units leave only by its cancellation" });
        null
      };
      case (#placeOrder(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        // the order records its member and its trader: they must be the account's and the caller's
        switch (X.account(xs, x.account), X.traderByPrincipal(xs, caller)) {
          case (?a, ?(tid, _)) { if (a.member != x.member or tid != x.trader) return ?#NotYourAccount({ account = x.account }) };
          case (_) return ?#NotYourAccount({ account = x.account });
        };
        if (isCcp(s, x.account)) return ?#InvalidTerms({ reason = "the central counterparty's account trades only its close-outs" });
        switch (X.mayTrade(xs, caller, x.instrument)) { case (?e) return ?#MayNotTrade({ code = XText.code(e) }); case null {} };
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase == #halted) return ?#InstrumentHalted({ instrument = x.instrument });
        switch (classRefusal(s, x.instrument, X.marketTime(xs, now).0)) { case (?e) return ?e; case null {} };
        if (isDerivative(s, x.instrument)) {
          if (clearingOf(s, x.account) == null) return ?#InvalidTerms({ reason = "a derivative traded on a clearing account" });
          if (x.shortSale) return ?#InvalidTerms({ reason = "a derivative's sale is a position, never a short sale" });
        };
        switch (killedFor(s, x.member, x.trader)) { case (?k) return ?#Killed({ kill = k }); case null {} };
        if (blackedOut(s, xs, x.account, x.instrument, now)) return ?#InsiderBlackout({ instrument = x.instrument });
        if (x.qty == 0 or x.qty % i.lot != 0) return ?#NotALot({ qty = x.qty; lot = i.lot });
        if (x.peak != 0 and (x.peak % i.lot != 0 or x.peak >= x.qty)) return ?#NotALot({ qty = x.peak; lot = i.lot });
        let n = Text.encodeUtf8(x.clientRef).size();
        if (n == 0 or n > T.CLIENT_REF_BYTES) return ?#InvalidTerms({ reason = "a client reference of 1 to 20 bytes" });
        if (orderByRef(s, x.account, x.clientRef) != null) return ?#DuplicateClientRef({ clientRef = x.clientRef });
        switch (x.kind) {
          case (#market) { if (x.price != 0 or x.stopPrice != 0) return ?#InvalidPrice({ reason = "a market order names no price" }) };
          case (#stop) { if (x.price != 0) return ?#InvalidPrice({ reason = "a stop names no limit" }); if (not L.onTick(i.bands, x.stopPrice)) return ?#PriceOffTick({ price = x.stopPrice; tick = L.tickAt(i.bands, x.stopPrice) }) };
          case (#trailingStop) {
            if (x.price != 0) return ?#InvalidPrice({ reason = "a stop names no limit" });
            if (not L.onTick(i.bands, x.stopPrice)) return ?#PriceOffTick({ price = x.stopPrice; tick = L.tickAt(i.bands, x.stopPrice) });
            if (x.trail == 0 or x.trail % L.tickAt(i.bands, x.stopPrice) != 0) return ?#InvalidPrice({ reason = "a trail of whole ticks" });
          };
          case (#stopLimit) {
            if (not L.onTick(i.bands, x.price)) return ?#PriceOffTick({ price = x.price; tick = L.tickAt(i.bands, x.price) });
            if (not L.onTick(i.bands, x.stopPrice)) return ?#PriceOffTick({ price = x.stopPrice; tick = L.tickAt(i.bands, x.stopPrice) });
          };
          case (_) { if (x.stopPrice != 0) return ?#InvalidPrice({ reason = "only a stop names a stop price" }); if (not L.onTick(i.bands, x.price)) return ?#PriceOffTick({ price = x.price; tick = L.tickAt(i.bands, x.price) }) };
        };
        if (x.kind != #trailingStop and x.trail != 0) return ?#InvalidTerms({ reason = "only a trailing stop names a trail" });
        if (x.kind == #trailingStop and trailingCount(s, x.instrument, x.side) >= T.MAX_TRAILING) return ?#TrailingStopsFull({ instrument = x.instrument; max = T.MAX_TRAILING });
        if (immediate(x.kind) and x.validity != #day) return ?#InvalidTerms({ reason = "an immediate order is good for the day" });
        if (x.peak != 0 and x.kind != #limit) return ?#InvalidTerms({ reason = "only a limit order is an iceberg" });
        if ((i.phase == #auction or i.phase == #closingAuction) and (x.kind == #ioc or x.kind == #fok)) return ?#InvalidTerms({ reason = "no immediate-or-cancel or fill-or-kill in an auction" });
        if (x.validity == #gtd) { let (today, _) = X.marketTime(xs, now); if (x.gtdDay < today) return ?#NotTheChainsDay({ day = today }) } else { if (x.gtdDay != 0) return ?#InvalidTerms({ reason = "a day only for good-till-date" }) };
        if (x.oco != 0) {
          let ?o = order(s, x.oco) else return ?#InvalidOco({ order = x.oco });
          if (o.account != x.account or o.instrument != x.instrument or not isLiveish(o) or o.oco != 0) return ?#InvalidOco({ order = x.oco });
        };
        // the static band (SPEC §10) on a limit price
        if (x.kind == #limit or x.kind == #ioc or x.kind == #fok or x.kind == #stopLimit) {
          let (lo, hi) = L.band(i.referencePrice, i.staticBps);
          if (x.price < lo or x.price > hi) return ?#PriceOutsideBand({ price = x.price; low = lo; high = hi });
        };
        // short sales (SPEC §17): flagged, a limit at or above the floor; unflagged, no more than the account owns free
        if (x.shortSale and x.side == #buy) return ?#InvalidTerms({ reason = "a short sale sells" });
        if (x.side == #sell and not isDerivative(s, x.instrument)) {
          if (x.shortSale) {
            let limited = x.kind == #limit or x.kind == #ioc or x.kind == #fok or x.kind == #stopLimit;
            if (not limited or x.price < shortFloor(i)) return ?#ShortSalePrice({ price = x.price; floor = shortFloor(i) });
          } else {
            let free = sellableFree(s, x.account, i, x.instrument);
            if (x.qty > free) return ?#ShortSaleNotFlagged({ free; wanted = x.qty });
          };
        };
        let price = effectivePrice(i, x.side, x.kind, x.price);
        switch (riskRefusal(s, x.member, x.qty, valueOf(s, x.instrument, price, x.qty), 0)) { case (?e) return ?e; case null {} };
        let need = holdNeed(s, i, x.instrument, x.side, price, x.qty);
        let ledger = holdingLedger(i, x.side);
        // self-trade prevention (§3.5), judged with the account's own live orders now: cancel-incoming refuses;
        // cancel-both cancels the incoming order too, so it holds nothing; cancel-resting cancels own orders on the
        // other side, which hold the other ledger, so this side's funds must cover the order in full
        let crossing = if (isStop(x.kind)) [] else crossingOwn(s, x.account, x.instrument, x.side, price, 1);
        if (crossing.size() > 0 and x.selfTrade == #cancelIncoming) return ?#SelfTradePrevented({ resting = crossing[0].0 });
        let incomingCancelled = crossing.size() > 0 and x.selfTrade == #cancelBoth;
        if (not incomingCancelled) {
          switch (clearingOf(s, x.account)) {
            case null { let b = balance(s, x.account, ledger); if (b.available < need) return ?#InsufficientFunds({ ledger; available = b.available; wanted = need }) };
            case (?m) { switch (clearingRefusal(s, m, i, x.instrument, x.side, x.shortSale, price, x.qty, 0, 0)) { case (?e) return ?e; case null {} } };
          };
        };
        null
      };
      case (#cancelOrder(x)) { switch (ownOrder(s, xs, caller, x.order)) { case (#err(e)) ?e; case (#ok(_)) null } };
      case (#amendOrder(x)) {
        let o = switch (ownOrder(s, xs, caller, x.order)) { case (#err(e)) return ?e; case (#ok(o)) o };
        if (o.kind != #limit or o.status != #live) return ?#InvalidTerms({ reason = "only a live limit order is amended" });
        let ?i = instrument(s, o.instrument) else return ?#UnknownInstrument({ instrument = o.instrument });
        if (i.phase == #halted) return ?#InstrumentHalted({ instrument = o.instrument });
        switch (killedFor(s, o.member, o.trader)) { case (?k) return ?#Killed({ kill = k }); case null {} };
        if (blackedOut(s, xs, o.account, o.instrument, now)) return ?#InsiderBlackout({ instrument = o.instrument });
        if (x.qty == 0 or x.qty % i.lot != 0) return ?#NotALot({ qty = x.qty; lot = i.lot });
        if (o.peak != 0 and o.peak >= x.qty) return ?#NotALot({ qty = x.qty; lot = i.lot });
        if (not L.onTick(i.bands, x.price)) return ?#PriceOffTick({ price = x.price; tick = L.tickAt(i.bands, x.price) });
        if (x.qty == o.remaining and x.price == o.price) return ?#InvalidTerms({ reason = "nothing to amend" });
        let (blo, bhi) = L.band(i.referencePrice, i.staticBps);
        if (x.price < blo or x.price > bhi) return ?#PriceOutsideBand({ price = x.price; low = blo; high = bhi });
        // short sales (SPEC §17): a flagged one's new price at or above the floor; an unflagged one adds only what is owned free
        if (o.side == #sell) {
          if (o.shortSale) { if (x.price < shortFloor(i)) return ?#ShortSalePrice({ price = x.price; floor = shortFloor(i) }) }
          else if (x.qty > o.remaining) { let free = sellableFree(s, o.account, i, o.instrument); if (x.qty - o.remaining > free) return ?#ShortSaleNotFlagged({ free; wanted = x.qty - o.remaining }) };
        };
        switch (riskRefusal(s, o.member, x.qty, valueOf(s, o.instrument, x.price, x.qty), openValue(s, o))) { case (?e) return ?e; case null {} };
        let need = holdNeed(s, i, o.instrument, o.side, x.price, x.qty);
        let ledger = holdingLedger(i, o.side);
        switch (clearingOf(s, o.account)) {
          case null { let b = balance(s, o.account, ledger); if (need > o.held and b.available < need - o.held) return ?#InsufficientFunds({ ledger; available = b.available; wanted = need - o.held }) };
          case (?m) { switch (clearingRefusal(s, m, i, o.instrument, o.side, o.shortSale, x.price, x.qty, o.held, openValue(s, o))) { case (?e) return ?e; case null {} } };
        };
        let crossing = crossingOwn(s, o.account, o.instrument, o.side, x.price, 1);
        if (crossing.size() > 0) return ?#SelfTradePrevented({ resting = crossing[0].0 });
        null
      };
      case (#massCancel(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        if (memberOf(xs, x.account) != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        null
      };
      case (#flush) { if (s.batchTime == 0 and s.dueCount == 0) ?#NothingToClear else null };
      case (#endOfDay(_)) null;
      case (#expireGtd(x)) { let (today, _) = X.marketTime(xs, now); if (x.day != today) ?#NotTheChainsDay({ day = today }) else null };
      case (#clear(_)) ?#ClearNotSubmittable;
      case (#setPhase(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase == #halted) return ?#InstrumentHalted({ instrument = x.instrument });
        if (i.interruptUntil != 0) return ?#InvalidTerms({ reason = "an interruption ends by its uncross" });
        if (x.phase == #halted) return ?#InvalidTerms({ reason = "a halt is an act under four eyes" });
        if (x.phase == i.phase) return ?#InvalidTerms({ reason = "the instrument is already so" });
        let call = x.phase == #auction or x.phase == #closingAuction;
        if (call) { if ((x.endFrom == 0) != (x.endTo == 0) or x.endFrom > x.endTo) return ?#InvalidTerms({ reason = "a random end window from its start to its end" }) }
        else { if (x.endFrom != 0 or x.endTo != 0) return ?#InvalidTerms({ reason = "a random end window only for an auction" }) };
        null
      };
      case (#uncross(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase != #auction and i.phase != #closingAuction) return ?#NotInAuction({ instrument = x.instrument });
        if (i.endFrom != 0 and now < i.endFrom) return ?#AuctionNotEnded({ until = i.endFrom });
        if (i.interruptUntil != 0 and now < i.interruptUntil) return ?#AuctionNotEnded({ until = i.interruptUntil });
        if (x.next != #continuous and x.next != #tradeAtClose and x.next != #closed) return ?#InvalidTerms({ reason = "continuous, trade at close or closed after an uncross" });
        null
      };
      case (#halt(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase == #halted) return ?#InstrumentHalted({ instrument = x.instrument });
        reasonRefusal(x.reason)
      };
      case (#resume(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase != #halted) return ?#InvalidTerms({ reason = "the instrument is not halted" });
        // a market-wide suspension holds to the close: nothing resumes before the next market day (SPEC §27)
        if (s.suspendedAt != 0 and X.marketTime(xs, now).0 <= X.marketTime(xs, s.suspendedAt).0) return ?#InvalidTerms({ reason = "suspended to the close" });
        null
      };
      case (#kill(x)) {
        if (x.member == 0) return ?#InvalidTerms({ reason = "a member" });
        switch (reasonRefusal(x.reason)) { case (?e) return ?e; case null {} };
        if (X.member(xs, x.member) == null) return ?#InvalidTerms({ reason = "no such member" });
        if (x.trader != 0) { switch (X.trader(xs, x.trader)) { case (?t) { if (t.member != x.member) return ?#InvalidTerms({ reason = "a trader of the member" }) }; case null return ?#InvalidTerms({ reason = "no such trader" }) } };
        let targetMember = x.member;
        // a trader kills within its own member; the operator, anywhere
        switch (X.traderByPrincipal(xs, caller)) {
          case (?(_, t)) { if (t.status != #active or t.member != targetMember) return ?#InvalidTerms({ reason = "a trader kills within its own member" }) };
          case null {};
        };
        if (activeKill(s, if (x.trader != 0) 2 else 1, if (x.trader != 0) x.trader else x.member) != null) return ?#InvalidTerms({ reason = "already killed" });
        null
      };
      case (#killSweep(x)) {
        let ?k = kill(s, x.kill) else return ?#UnknownKill({ kill = x.kill });
        if (not k.active) return ?#InvalidTerms({ reason = "the kill is revived" });
        null
      };
      case (#revive(x)) {
        let ?k = kill(s, x.kill) else return ?#UnknownKill({ kill = x.kill });
        if (not k.active) return ?#InvalidTerms({ reason = "the kill is revived" });
        if (firstOpenOf(s, k) != null) return ?#OrdersStillOpen({ kill = x.kill });
        if (k.trader == 0) { switch (clearingMember(s, k.member)) { case (?(_, r)) { if (r.status == 2) return ?#InvalidTerms({ reason = "a member in default is closed through the waterfall first" }) }; case null {} } };
        null
      };
      case (#setLimits(x)) {
        if (X.member(xs, x.member) == null) return ?#InvalidTerms({ reason = "no such member" });
        null
      };
      // SPEC §16
      case (#setBlackout(x)) {
        if (instrument(s, x.instrument) == null) return ?#UnknownInstrument({ instrument = x.instrument });
        if (x.client.size() != 32) return ?#InvalidTerms({ reason = "a 32-byte client code" });
        if (x.until != 0 and x.until < X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "a day not past" });
        switch (reasonRefusal(x.reason)) { case (?e) return ?e; case null {} };
        if (one(s.blackoutStore, blackoutRows, "active", blackoutKey(x.instrument, x.client)) != null) return ?#InvalidTerms({ reason = "already blacked out" });
        null
      };
      case (#liftBlackout(x)) {
        switch (RS.get(s.blackoutStore, blackoutRows, x.blackout)) { case (?b) { if (not b.active) return ?#UnknownBlackout({ blackout = x.blackout }) }; case null return ?#UnknownBlackout({ blackout = x.blackout }) };
        null
      };
      // SPEC §17
      case (#borrow(x)) {
        let ?a = X.account(xs, x.account) else return ?#UnknownAccount({ account = x.account });
        if (a.member != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        if (isCcp(s, x.account)) return ?#InvalidTerms({ reason = "the central counterparty's account moves only by clearing" });
        if (instrument(s, x.instrument) == null) return ?#UnknownInstrument({ instrument = x.instrument });
        if (isReceipt(s, x.instrument)) return ?#InvalidTerms({ reason = "a receipt's units come only from its warehouse" });
        if (x.qty == 0) return ?#InvalidTerms({ reason = "a quantity above zero" });
        if (x.reference.size() != 32) return ?#InvalidTerms({ reason = "a 32-byte reference" });
        if (one(s.refRows, refs, "byRef", x.reference) != null) return ?#DuplicateReference;
        null
      };
      case (#returnBorrow(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        if (memberOf(xs, x.account) != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        // kept: a receipt's units are never lent (`borrow` refuses them), so nothing of one is owed and this refuses first
        if (x.qty == 0 or x.qty > owedOf(s, x.account, x.instrument)) return ?#InvalidTerms({ reason = "no more than is owed" });
        let b = balance(s, x.account, i.assetLedger);
        if (b.available < x.qty) return ?#InsufficientFunds({ ledger = i.assetLedger; available = b.available; wanted = x.qty });
        null
      };
      // SPEC §15: the market day of the act, later than every day sealed
      case (#sealDay(x)) {
        if (x.day != X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "the market day of the act" });
        if (x.day <= s.lastSealed) return ?#InvalidTerms({ reason = "a day later than the last sealed" });
        null
      };
      // SPEC §18 to §21
      case (#setClearing(x)) {
        let ?a = X.account(xs, x.ccpAccount) else return ?#UnknownAccount({ account = x.ccpAccount });
        if (a.member != x.ccpMember) return ?#InvalidTerms({ reason = "the account's member" });
        if (a.status != #open) return ?#AccountClosed({ account = x.ccpAccount });
        if (x.cycleDays == 0 and x.cycleSecs == 0) return ?#InvalidTerms({ reason = "a cycle of seconds or of business days" });
        if (x.cycleDays > 10) return ?#InvalidTerms({ reason = "a cycle of at most ten business days" });
        if (x.penaltyBps > 10_000 or x.fundBps > 10_000) return ?#InvalidTerms({ reason = "rates of at most 100 per cent" });
        if (x.deadlineCycles == 0) return ?#InvalidTerms({ reason = "a deadline of at least one cycle" });
        switch (s.clearing) {
          case (?t) { if (t.ccpAccount != x.ccpAccount or t.ccpMember != x.ccpMember or not Principal.equal(t.cashLedger, x.cashLedger)) return ?#InvalidTerms({ reason = "the CCP's account, member and currency are fixed" }) };
          case null {
            // the CCP's account starts empty and idle, so everything on it is the clearing's
            if (clearingOf(s, x.ccpAccount) != null) return ?#InvalidTerms({ reason = "an account not designated for clearing" });
            if (hasLiveOrder(s, x.ccpAccount) or not accountEmpty(s, x.ccpAccount)) return ?#InvalidTerms({ reason = "an empty account with no orders" });
          };
        };
        null
      };
      case (#setMargin(x)) {
        if (instrument(s, x.instrument) == null) return ?#UnknownInstrument({ instrument = x.instrument });
        if (x.imBps == 0 or x.imBps > 10_000) return ?#InvalidTerms({ reason = "a margin above 0 and at most 100 per cent" });
        null
      };
      case (#admitClearing(x)) {
        let ?t = s.clearing else return ?#InvalidTerms({ reason = "the clearing terms set first" });
        if (X.member(xs, x.member) == null) return ?#InvalidTerms({ reason = "no such member" });
        if (x.member == t.ccpMember) return ?#InvalidTerms({ reason = "a member other than the central counterparty's" });
        if (clearingMember(s, x.member) != null) return ?#InvalidTerms({ reason = "already a clearing member" });
        if (RS.size(s.clearingStore) >= MAX_CLEARING_MEMBERS) return ?#InvalidTerms({ reason = "at most 64 clearing members" });
        let ?a = X.account(xs, x.settlementAccount) else return ?#UnknownAccount({ account = x.settlementAccount });
        if (a.member != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        if (a.status != #open) return ?#AccountClosed({ account = x.settlementAccount });
        null
      };
      case (#designateClearing(x)) {
        let ?(_, r) = clearingMember(s, x.member) else return ?#NotClearing({ member = x.member });
        if (r.status != 1) return ?#NotClearing({ member = x.member });
        let ?a = X.account(xs, x.account) else return ?#UnknownAccount({ account = x.account });
        if (a.member != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        if (clearingOf(s, x.account) != null) return ?#InvalidTerms({ reason = "already designated" });
        // an order's kind is its account's at entry: an account with orders open is designated once they close
        if (hasLiveOrder(s, x.account)) return ?#InvalidTerms({ reason = "an account with no open orders" });
        null
      };
      case (#postCollateral(x)) {
        let r = switch (ownClearing(s, xs, caller, x.member)) { case (#err(e)) return ?e; case (#ok(r)) r };
        if (r.status == 2) return ?#InvalidTerms({ reason = "a member in default" });
        if (x.amount == 0) return ?#InvalidTerms({ reason = "an amount above zero" });
        let ?t = s.clearing else return ?#NotClearing({ member = x.member });   // kept: a clearing member implies the terms
        let b = balance(s, r.settlementAccount, t.cashLedger);
        if (b.available < x.amount) return ?#InsufficientFunds({ ledger = t.cashLedger; available = b.available; wanted = x.amount });
        null
      };
      case (#withdrawCollateral(x)) {
        let r = switch (ownClearing(s, xs, caller, x.member)) { case (#err(e)) return ?e; case (#ok(r)) r };
        if (r.status == 2) return ?#InvalidTerms({ reason = "a member in default" });
        if (x.amount == 0 or x.amount > r.collateral) return ?#InvalidTerms({ reason = "an amount above zero and within the collateral" });
        switch (marginRefusal(s, { r with fundRequired = 0 }, 0, 0, x.amount)) { case (?e) return ?e; case null {} };
        if (ccpFree(s) < x.amount) return ?#LiquidityShort({ needed = x.amount; free = ccpFree(s) });
        null
      };
      case (#cutCycle(x)) {
        let ?t = s.clearing else return ?#InvalidTerms({ reason = "the clearing terms set first" });
        // a derivative's run owes members part of what it will charge others: no cycle is cut until it finishes (§34)
        for (i in s.instrumentList.vals()) { switch (derivOf(s, i)) { case (?d) { if (d.runDay != 0) return ?#InvalidTerms({ reason = "a derivative's settlement run finished first" }) }; case null {} } };
        if (x.cycle != s.cycleNo) return ?#InvalidTerms({ reason = "the open cycle" });
        if (t.cycleDays == 0) {
          if (x.settleDay != 0) return ?#InvalidTerms({ reason = "a cycle of seconds settles at once" });
          if (s.settledThrough + 1 != s.cycleNo) return ?#InvalidTerms({ reason = "the last cycle settled first" });
          let due = Nat64.toNat(s.lastCut) + t.cycleSecs * 1_000_000_000;
          if (s.lastCut != 0 and Nat64.toNat(now) < due) return ?#CycleNotDue({ due });
        } else {
          let today = X.marketTime(xs, now).0;
          let day = settlementDay(xs, today, t.cycleDays);
          if (x.settleDay != day) return ?#InvalidTerms({ reason = "the settlement day the calendar gives" });
          if (s.cycleNo > 1) { switch (cycleOf(s, s.cycleNo - 1)) { case (?c) { if (c.settleDay >= day) return ?#InvalidTerms({ reason = "one cut a market day" }) }; case null {} } };
        };
        null
      };
      case (#settleCycle(x)) {
        if (s.clearing == null) return ?#InvalidTerms({ reason = "the clearing terms set first" });
        if (x.cycle != s.settledThrough + 1 or x.cycle >= s.cycleNo) return ?#InvalidTerms({ reason = "the oldest cut cycle" });
        let ?c = cycleOf(s, x.cycle) else return ?#InvalidTerms({ reason = "the oldest cut cycle" });   // kept: a cut cycle has its row
        if (c.settleDay != 0 and X.marketTime(xs, now).0 < c.settleDay) return ?#CycleNotDue({ due = c.settleDay });
        null
      };
      case (#closeOut(x)) {
        let ?t = s.clearing else return ?#InvalidTerms({ reason = "the clearing terms set first" });
        let ?(_, r) = clearingMember(s, x.member) else return ?#NotClearing({ member = x.member });
        if (r.status != 2 and (r.debt == 0 or r.fails < t.deadlineCycles)) return ?#InvalidTerms({ reason = "a member past its deadline or in default" });
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase != #continuous) return ?#InvalidTerms({ reason = "an instrument trading continuously" });
        let c = custodyOf(s, x.member, x.instrument);
        if ((c.qty - c.held) / i.lot == 0) return ?#InvalidTerms({ reason = "shares to close out" });
        null
      };
      case (#callFund) {
        if (s.clearing == null) return ?#InvalidTerms({ reason = "the clearing terms set first" });
        if (activeMembers(s).size() == 0) return ?#InvalidTerms({ reason = "a clearing member" });
        null
      };
      case (#contributeFund(x)) {
        let r = switch (ownClearing(s, xs, caller, x.member)) { case (#err(e)) return ?e; case (#ok(r)) r };
        if (r.status != 1) return ?#NotClearing({ member = x.member });
        if (x.amount == 0 or r.fund + x.amount > r.fundRequired) return ?#InvalidTerms({ reason = "an amount above zero and within the requirement" });
        let ?t = s.clearing else return ?#NotClearing({ member = x.member });   // kept: a clearing member implies the terms
        let b = balance(s, r.settlementAccount, t.cashLedger);
        if (b.available < x.amount) return ?#InsufficientFunds({ ledger = t.cashLedger; available = b.available; wanted = x.amount });
        null
      };
      case (#fundSkin(x)) {
        let ?t = s.clearing else return ?#InvalidTerms({ reason = "the clearing terms set first" });
        let ?a = X.account(xs, x.account) else return ?#UnknownAccount({ account = x.account });
        if (a.member != t.ccpMember or x.account == t.ccpAccount) return ?#InvalidTerms({ reason = "an account of the central counterparty's member" });
        if (x.amount == 0) return ?#InvalidTerms({ reason = "an amount above zero" });
        let b = balance(s, x.account, t.cashLedger);
        if (b.available < x.amount) return ?#InsufficientFunds({ ledger = t.cashLedger; available = b.available; wanted = x.amount });
        null
      };
      case (#declareDefault(x)) {
        let ?(_, r) = clearingMember(s, x.member) else return ?#NotClearing({ member = x.member });
        if (r.status != 1) return ?#NotClearing({ member = x.member });
        reasonRefusal(x.reason)
      };
      case (#closeDefault(x)) {
        let ?(_, r) = clearingMember(s, x.member) else return ?#NotClearing({ member = x.member });
        if (r.status != 2) return ?#InvalidTerms({ reason = "a member in default" });
        let (lo, hi) = R.prefixRange(x.member, 8, 8);
        if (first(s.orderRows, orders, "member", lo, hi) != null) return ?#InvalidTerms({ reason = "the member's orders cancelled first" });
        for (c in custodyRowsOf(s, x.member).vals()) { if (c.qty > 0) return ?#InvalidTerms({ reason = "the member's shares closed out first" }) };
        if (r.owedTo != 0 or r.owedBy != 0) return ?#InvalidTerms({ reason = "the member's cycles settled first" });
        null
      };
      // SPEC §22 to §25
      case (#setFeeSchedule(x)) {
        if (instrument(s, x.instrument) == null) return ?#UnknownInstrument({ instrument = x.instrument });
        if (x.levies.size() == 0 or x.levies.size() > T.MAX_LEVIES) return ?#InvalidTerms({ reason = "one to four levies" });
        var total = 0;
        for (k in Nat.range(0, x.levies.size())) {
          let l = x.levies[k];
          if (l.ppm == 0) return ?#InvalidTerms({ reason = "a levy's rate above zero" });
          total += l.ppm;
          let ?a = X.account(xs, l.account) else return ?#UnknownAccount({ account = l.account });
          if (a.status != #open) return ?#AccountClosed({ account = l.account });
          if (isCcp(s, l.account) or clearingOf(s, l.account) != null) return ?#InvalidTerms({ reason = "a levy's account neither the CCP's nor a clearing account" });
          for (j in Nat.range(0, k)) { if (x.levies[j].account == l.account) return ?#InvalidTerms({ reason = "a levy's account once" }) };
        };
        if (total > 100_000) return ?#InvalidTerms({ reason = "fees of at most 10 per cent a side" });
        // a buy holds its fee at entry, so the schedule changes only while no buy of the instrument is open
        if (openBuy(s, x.instrument)) return ?#InvalidTerms({ reason = "an instrument with no open buy" });
        null
      };
      case (#sealStatements(x)) {
        if (x.day != X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "the market day of the act" });
        if (x.day <= s.lastStatementDay) return ?#InvalidTerms({ reason = "a day later than the last sealed" });
        null
      };
      case (#reconcileMember(x)) {
        let ?(_, t) = X.traderByPrincipal(xs, caller) else return ?#NotYourAccount({ account = 0 });
        if (t.status != #active or t.member != x.member) return ?#NotYourAccount({ account = 0 });
        if (x.day > X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "a day not to come" });
        if (x.balances.size() == 0 or x.balances.size() > T.MAX_ATTESTED) return ?#InvalidTerms({ reason = "one to sixty-four balances" });
        for (k in Nat.range(0, x.balances.size())) {
          let b = x.balances[k];
          let ?a = X.account(xs, b.account) else return ?#UnknownAccount({ account = b.account });
          if (a.member != x.member) return ?#NotYourAccount({ account = b.account });
          for (j in Nat.range(0, k)) { if (x.balances[j].account == b.account and Principal.equal(x.balances[j].ledger, b.ledger)) return ?#InvalidTerms({ reason = "a balance once" }) };
        };
        null
      };
      case (#registerMaker(x)) {
        let ?m = X.member(xs, x.member) else return ?#InvalidTerms({ reason = "no such member" });
        if (not m.marketMaker) return ?#NotAMaker({ member = x.member; instrument = x.instrument });
        if (instrument(s, x.instrument) == null) return ?#UnknownInstrument({ instrument = x.instrument });
        if (makerOf(s, x.member, x.instrument) != null) return ?#InvalidTerms({ reason = "already registered" });
        if (s.nextMaker > MAX_MAKERS) return ?#InvalidTerms({ reason = "at most 32 registrations" });
        if (x.maxSpreadBps == 0 or x.maxSpreadBps > 10_000 or x.minQty == 0 or x.presenceBps > 10_000 or x.rebateBps > 10_000) return ?#InvalidTerms({ reason = "a spread, a quantity, a presence and a rebate within their ranges" });
        null
      };
      case (#quote(x)) quoteRefusal(s, xs, now, caller, x.account, x.member, x.trader, [x.side]);
      case (#massQuote(x)) quoteRefusal(s, xs, now, caller, x.account, x.member, x.trader, x.sides);
      case (#defineIndex(x)) {
        if (x.index == 0 or x.index > T.MAX_INDICES) return ?#InvalidTerms({ reason = "an index numbered one to eight" });
        if (indexRowOf(s, x.index) != null) return ?#InvalidTerms({ reason = "already defined" });
        if (x.base == 0) return ?#InvalidTerms({ reason = "a base above zero" });
        switch (constituentRefusal(s, x.constituents)) { case (?e) return ?e; case null {} };
        if (x.capBps > 10_000 or (x.capBps > 0 and x.capBps * x.constituents.size() <= 10_000)) return ?#InvalidTerms({ reason = "a cap the constituents can meet" });
        if (x.haltBps == 0 or x.haltBps > 10_000 or (x.suspendBps != 0 and (x.suspendBps <= x.haltBps or x.suspendBps > 10_000))) return ?#InvalidTerms({ reason = "a halt threshold, and a suspension's above it" });
        null
      };
      case (#reviewIndex(x)) {
        let ?_ = indexRowOf(s, x.index) else return ?#InvalidTerms({ reason = "no such index" });
        switch (constituentRefusal(s, x.constituents)) { case (?e) return ?e; case null {} };
        let now_ = constituentsOf(s, x.index);
        if (now_.size() != x.constituents.size()) return ?#InvalidTerms({ reason = "the same constituents" });
        for (c in x.constituents.vals()) { if (one(s.constituentStore, constituentRows, "byIndex", R.key2(x.index, 8, c.instrument, 8)) == null) return ?#InvalidTerms({ reason = "the same constituents" }) };
        null
      };
      case (#corporateAction(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase != #closed) return ?#InvalidTerms({ reason = "an instrument closed" });
        if (openOrder(s, x.instrument)) return ?#InvalidTerms({ reason = "an instrument with no open order" });
        if (x.reference.size() != 32) return ?#InvalidTerms({ reason = "the custody action's 32-byte hash" });
        switch (x.action) {
          case (#split(a)) { if (a.num == 0 or a.den == 0 or a.num == a.den) return ?#InvalidTerms({ reason = "a split of two different counts" }) };
          case (#dividend(a)) { if (a.amount == 0 or a.amount >= markPrice(i)) return ?#InvalidTerms({ reason = "a dividend below the price" }) };
        };
        null
      };
      case (#tripBreaker(_)) ?#ClearNotSubmittable;
      // SPEC §28 to §32
      case (#setTerms(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (termsOf(s, x.instrument) != null) return ?#InvalidTerms({ reason = "an instrument's class is set once" });
        if (i.phase != #closed) return ?#InvalidTerms({ reason = "an instrument closed" });
        if (openOrder(s, x.instrument)) return ?#InvalidTerms({ reason = "an instrument with no open order" });
        let today = X.marketTime(xs, now).0;
        switch (x.terms) {
          case (#bond(b)) {
            if (b.couponBps > 10_000) return ?#InvalidTerms({ reason = "a coupon of at most 100 per cent" });
            if (b.perYear != 1 and b.perYear != 2 and b.perYear != 4 and b.perYear != 12) return ?#InvalidTerms({ reason = "1, 2, 4 or 12 coupons a year" });
            if (b.maturity <= today or b.maturity > today + 50 * 366) return ?#InvalidTerms({ reason = "a maturity after today, within fifty years" });
            if (b.settleDays > 5) return ?#InvalidTerms({ reason = "settlement within five business days" });
          };
          case (#receipt(r)) {
            if (r.warehouses.size() == 0 or r.warehouses.size() > T.MAX_WAREHOUSES) return ?#InvalidTerms({ reason = "one to eight licensed warehouses" });
            for (k in Nat.range(0, r.warehouses.size())) {
              if (r.warehouses[k] == 0) return ?#InvalidTerms({ reason = "a warehouse numbered above zero" });
              for (j in Nat.range(0, k)) { if (r.warehouses[j] == r.warehouses[k]) return ?#InvalidTerms({ reason = "a warehouse once" }) };
            };
            // the units exist only by receipts: none in the book yet, and a ledger no other instrument uses
            if (supplyOf(s, i.assetLedger) != 0) return ?#InvalidTerms({ reason = "no unit of the instrument in the book" });
            for (other in s.instrumentList.vals()) {
              if (other != x.instrument) { switch (instrument(s, other)) { case (?o) { if (Principal.equal(o.assetLedger, i.assetLedger) or Principal.equal(o.cashLedger, i.assetLedger)) return ?#InvalidTerms({ reason = "a ledger of its own" }) }; case null {} } };
            };
          };
          case (#certificate(c)) { if (c.registry.size() != 32) return ?#InvalidTerms({ reason = "the registry's 32-byte hash" }) };
          case (#future(f)) {
            switch (derivTermsRefusal(s, i, f.index, f.multiplier, f.expiry, today)) { case (?e) return ?e; case null {} };
            if (f.imBps == 0 or f.imBps > 10_000) return ?#InvalidTerms({ reason = "an initial margin of 1 to 10,000 basis points" });
          };
          case (#option(o)) {
            switch (derivTermsRefusal(s, i, o.index, o.multiplier, o.expiry, today)) { case (?e) return ?e; case null {} };
            if (o.strike == 0) return ?#InvalidTerms({ reason = "a strike above zero" });
            if (o.bBps == 0 or o.bBps > o.aBps or o.aBps > 10_000) return ?#InvalidTerms({ reason = "margin rates with 0 < b <= a <= 10,000" });
          };
          case (#right(r)) {
            if (r.underlying == x.instrument or instrument(s, r.underlying) == null) return ?#InvalidTerms({ reason = "an underlying instrument the book trades" });
            if (r.price == 0 or r.num == 0 or r.den == 0) return ?#InvalidTerms({ reason = "a subscription price and ratio above zero" });
            if (r.deadline < today) return ?#InvalidTerms({ reason = "a deadline not past" });
            let ?a = X.account(xs, r.issuer) else return ?#UnknownAccount({ account = r.issuer });
            if (a.status != #open or isCcp(s, r.issuer)) return ?#InvalidTerms({ reason = "the issuer's open account" });
            if (a.member != r.issuerMember) return ?#InvalidTerms({ reason = "the issuer account's member" });
          };
        };
        null
      };
      case (#defineNav(x)) {
        if (instrument(s, x.instrument) == null) return ?#UnknownInstrument({ instrument = x.instrument });
        if (navOf(s, x.instrument) != null) return ?#InvalidTerms({ reason = "already defined" });
        if (x.units == 0) return ?#InvalidTerms({ reason = "a creation unit above zero" });
        if (x.basket.size() == 0 or x.basket.size() > T.MAX_BASKET) return ?#InvalidTerms({ reason = "one to fifty lines" });
        for (k in Nat.range(0, x.basket.size())) {
          if (x.basket[k].instrument == x.instrument) return ?#InvalidTerms({ reason = "a fund not in its own basket" });
          if (instrument(s, x.basket[k].instrument) == null) return ?#UnknownInstrument({ instrument = x.basket[k].instrument });
          if (x.basket[k].shares == 0) return ?#InvalidTerms({ reason = "shares above zero" });
          for (j in Nat.range(0, k)) { if (x.basket[j].instrument == x.basket[k].instrument) return ?#InvalidTerms({ reason = "a line once" }) };
        };
        null
      };
      case (#issueReceipt(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        let ws = switch (termsOf(s, x.instrument)) { case (?#receipt(r)) r.warehouses; case (_) return ?#InvalidTerms({ reason = "an instrument of receipts" }) };
        if (Array.find<Nat>(ws, func(h) { h == x.warehouse }) == null) return ?#InvalidTerms({ reason = "a warehouse licensed for the instrument" });
        let ?a = X.account(xs, x.account) else return ?#UnknownAccount({ account = x.account });
        if (a.member != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        if (a.status != #open) return ?#AccountClosed({ account = x.account });
        if (isCcp(s, x.account)) return ?#InvalidTerms({ reason = "the central counterparty's account moves only by clearing" });
        if (x.qty == 0 or x.qty % i.lot != 0) return ?#NotALot({ qty = x.qty; lot = i.lot });
        if (x.reference.size() != 32) return ?#InvalidTerms({ reason = "the warehouse document's 32-byte hash" });
        if (one(s.receiptStore, receiptRows, "byRef", x.reference) != null) return ?#DuplicateReference;
        null
      };
      case (#cancelReceipt(x)) {
        let ?r = receiptOf(s, x.receipt) else return ?#InvalidTerms({ reason = "no such receipt" });
        if (not r.live) return ?#InvalidTerms({ reason = "a live receipt" });
        let ?i = instrument(s, r.instrument) else return ?#UnknownInstrument({ instrument = r.instrument });   // kept: a receipt names an instrument the book trades
        let ?a = X.account(xs, x.account) else return ?#UnknownAccount({ account = x.account });
        if (a.member != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        let b = balance(s, x.account, i.assetLedger);
        if (b.available < r.qty) return ?#InsufficientFunds({ ledger = i.assetLedger; available = b.available; wanted = r.qty });
        null
      };
      case (#retire(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        switch (X.account(xs, x.account), X.traderByPrincipal(xs, caller)) {
          case (?a, ?(tid, _)) { if (a.member != x.member or tid != x.trader) return ?#NotYourAccount({ account = x.account }) };
          case (_) return ?#NotYourAccount({ account = x.account });
        };
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        switch (termsOf(s, x.instrument)) { case (?#certificate(_)) {}; case (_) return ?#InvalidTerms({ reason = "an instrument of certificates" }) };
        if (x.qty == 0) return ?#InvalidTerms({ reason = "a quantity above zero" });
        if (x.beneficiary.size() != 32) return ?#InvalidTerms({ reason = "the beneficiary's 32-byte hash" });
        let b = balance(s, x.account, i.assetLedger);
        if (b.available < x.qty) return ?#InsufficientFunds({ ledger = i.assetLedger; available = b.available; wanted = x.qty });
        null
      };
      case (#exercise(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        switch (X.account(xs, x.account), X.traderByPrincipal(xs, caller)) {
          case (?a, ?(tid, _)) { if (a.member != x.member or tid != x.trader) return ?#NotYourAccount({ account = x.account }) };
          case (_) return ?#NotYourAccount({ account = x.account });
        };
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        let r = switch (termsOf(s, x.instrument)) { case (?#right(r)) r; case (_) return ?#InvalidTerms({ reason = "an instrument of rights" }) };
        if (X.marketTime(xs, now).0 > r.deadline) return ?#InvalidTerms({ reason = "rights past their deadline" });
        if (x.qty == 0 or x.qty % r.den != 0) return ?#InvalidTerms({ reason = "rights for whole new shares" });
        if (x.account == r.issuer) return ?#InvalidTerms({ reason = "an account other than the issuer's" });
        let rb = balance(s, x.account, i.assetLedger);
        if (rb.available < x.qty) return ?#InsufficientFunds({ ledger = i.assetLedger; available = rb.available; wanted = x.qty });
        let pay = r.price * (x.qty / r.den) * r.num;
        let cb = balance(s, x.account, i.cashLedger);
        if (cb.available < pay) return ?#InsufficientFunds({ ledger = i.cashLedger; available = cb.available; wanted = pay });
        null
      };
      case (#setAttestors(x)) {
        if (x.attestors.size() != 3) return ?#InvalidTerms({ reason = "three attestors" });
        if (Principal.equal(x.attestors[0], x.attestors[1]) or Principal.equal(x.attestors[0], x.attestors[2]) or Principal.equal(x.attestors[1], x.attestors[2])) return ?#InvalidTerms({ reason = "three different attestors" });
        null
      };
      case (#attestPrice(x)) {
        let ?p = attestorOf(s, x.attestor) else return ?#InvalidTerms({ reason = "an attestor numbered one to three" });
        if (not Principal.equal(p, caller)) return ?#InvalidTerms({ reason = "the attestor's own price" });
        if (not isDerivative(s, x.instrument)) return ?#InvalidTerms({ reason = "a derivative" });
        // a price is for the day it is given: one for another day would mark the positions at a stale price
        if (x.day != X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "the market day's price" });
        if (attestationOf(s, x.instrument, x.day, x.attestor) != null) return ?#InvalidTerms({ reason = "an attestor's price once a day" });
        if (x.price == 0) return ?#InvalidTerms({ reason = "a price above zero" });
        null
      };
      case (#settleDerivatives(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        let ?d = derivOf(s, x.instrument) else return ?#InvalidTerms({ reason = "a derivative" });
        if (x.day != X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "the market day's settlement" });
        if (d.expired or x.day <= d.settled) return ?#InvalidTerms({ reason = "a day not settled" });
        if (d.runDay != 0 and d.runDay != x.day) return ?#InvalidTerms({ reason = "the run in progress finished first" });
        if (x.day > expiryOf(s, x.instrument)) return ?#InvalidTerms({ reason = "a contract before its expiry" });
        if (i.phase != #closed) return ?#InvalidTerms({ reason = "a derivative closed for the day" });
        if (x.limit == 0 or x.limit > 500) return ?#InvalidTerms({ reason = "1 to 500 positions a message" });
        if (x.day == expiryOf(s, x.instrument)) {
          if (indexLevel(s, indexOfDeriv(s, x.instrument)) == 0) return ?#InvalidTerms({ reason = "the index's level at expiry" });
        } else if (d.runDay == 0 and attestedPrice(s, x.instrument, x.day) == null) return ?#InvalidTerms({ reason = "three attestations for the day" });
        null
      };
      case (#valueDate(x)) {
        let ?b = bondOf(s, x.instrument) else return ?#InvalidTerms({ reason = "a bond" });
        let day = settlementDay(xs, X.marketTime(xs, now).0, b.settleDays);
        if (x.day != day) return ?#InvalidTerms({ reason = "the value date the calendar gives" });
        if (x.day >= b.maturity) return ?#InvalidTerms({ reason = "a value date before the maturity" });
        null
      };
      case (#settleMakers(x)) {
        if (x.day != X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "the market day of the act" });
        if (x.day <= s.lastMakerDay) return ?#InvalidTerms({ reason = "a day later than the last settled" });
        null
      };
    }
  };
  /// Whether an account is the central counterparty's.
  func isCcp(s : State, account : Nat) : Bool { switch (s.clearing) { case (?t) t.ccpAccount == account; case null false } };
  /// Whether an instrument has a live or waiting buy (its book side or its stops).
  func openBuy(s : State, inst : Nat) : Bool {
    var found = false;
    for (ix in [BOOK, STOPS].vals()) {
      let prefix = sidePrefix(inst, #buy);
      let (lo, hi) = span(prefix, sideRest(ix));
      walk(s, ix, prefix, lo, hi, 8, func(_ : Nat, o : T.Order) : Bool { if (isLiveish(o) and o.instrument == inst and o.side == #buy) { found := true; false } else true });
    };
    found
  };
  /// Whether an account has a live or waiting order.
  func hasLiveOrder(s : State, account : Nat) : Bool {
    let prefix = accountPrefix(account);
    let (lo, hi) = span(prefix, 25);
    var found = false;
    walk(s, OWN_ALL, prefix, lo, hi, 8, func(_ : Nat, o : T.Order) : Bool { if (isLiveish(o)) { found := true; false } else true });
    found
  };
  /// Whether an account holds nothing in any ledger.
  func accountEmpty(s : State, account : Nat) : Bool {
    let (lo, hi) = R.prefixRange(account, 8, PRINCIPAL_BYTES);
    var cursor : ?Page.Cursor = null;
    loop {
      switch (RS.page(s.balanceRows, balances, "byAccountLedger", lo, hi, cursor, 100)) {
        case (#ok(p)) { for ((_, b) in p.rows.vals()) { if (b.available != 0 or b.held != 0) return false }; switch (p.next) { case (?n) cursor := ?n; case null return true } };
        case (#err(_)) return false;
      };
    };
  };
  /// The caller as a trader of the clearing member it acts for.
  func ownClearing(s : State, xs : X.State, caller : Principal, member : Nat) : Result.Result<ClearingMember, T.Error> {
    let ?(_, r) = clearingMember(s, member) else return #err(#NotClearing({ member }));
    let ?(_, t) = X.traderByPrincipal(xs, caller) else return #err(#NotYourAccount({ account = r.settlementAccount }));
    if (t.status != #active or t.member != member) return #err(#NotYourAccount({ account = r.settlementAccount }));
    #ok(r)
  };
  /// The market day `days` business days after `today`, by the exchange's calendar (SPEC §19).
  func settlementDay(xs : X.State, today : Nat, days : Nat) : Nat {
    var d = today; var k = 0;
    while (k < days) { d += 1; while (not Cal.isBusinessDay(X.calendarFor(xs, d), d)) d += 1; k += 1 };
    d
  };
  /// The shares an account may sell unflagged: a clearing account its member's (SPEC §18), any other what it owns free.
  func sellableFree(s : State, account : Nat, i : T.Instrument, inst : Nat) : Nat {
    switch (clearingOf(s, account)) {
      case (?m) { switch (clearingMember(s, m)) { case (?(_, r)) clearingSellable(s, r, i, inst, false); case null 0 } };
      case null ownedFree(s, account, i, inst);
    }
  };
  /// A clearing order's entry checks (SPEC §18), for an order of `qty` at `price` replacing one that held `heldBefore`
  /// with the open value `valueBefore`: a buy's initial margin and the CCP's free cash, a sale's shares.
  func clearingRefusal(s : State, m : Nat, i : T.Instrument, inst : Nat, side : T.Side, flagged : Bool, price : Nat, qty : Nat, heldBefore : Nat, valueBefore : Nat) : ?T.Error {
    let ?t = s.clearing else return ?#NotClearing({ member = m });             // kept: a designation implies the terms
    let ?(_, r) = clearingMember(s, m) else return ?#NotClearing({ member = m }); // kept: a designation names an admitted member
    if (r.status != 1) return ?#NotClearing({ member = m });
    if (not Principal.equal(i.cashLedger, t.cashLedger)) return ?#InvalidTerms({ reason = "an instrument settled in the clearing currency" });
    // a derivative's order holds its initial margin on either side; nothing is paid or delivered at the fill (§34, §35)
    if (isDerivative(s, inst)) {
      let im = derivIm(s, inst, side == #buy, qty, price);
      if (im > heldBefore) { switch (marginRefusal(s, r, im, heldBefore, 0)) { case (?e) return ?e; case null {} } };
      return null;
    };
    switch (side) {
      case (#buy) {
        let ?bps = marginOf(s, inst) else return ?#InvalidTerms({ reason = "an instrument with a margin rate" });
        let value = valueOf(s, inst, price, qty);
        let im = imFor(bps, value);
        if (im > heldBefore) { switch (marginRefusal(s, r, im, heldBefore, 0)) { case (?e) return ?e; case null {} } };
        let free = ccpFree(s);
        if (value > valueBefore and free < value - valueBefore) return ?#LiquidityShort({ needed = value - valueBefore; free });
        null
      };
      case (#sell) {
        let avail = clearingSellable(s, r, i, inst, flagged);
        if (qty > heldBefore and qty - heldBefore > avail) ?#InsufficientFunds({ ledger = i.assetLedger; available = avail; wanted = qty - heldBefore }) else null
      };
    }
  };
  /// The clearing members not closed, in member order.
  func activeMembers(s : State) : [ClearingMember] { Array.filter<ClearingMember>(clearingMembers(s), func(r) { r.status == 1 }) };
  public func clearingMembers(s : State) : [ClearingMember] {
    let out = List.empty<ClearingMember>();
    var cursor : ?Page.Cursor = null;
    let (lo, hi) = R.fullRange(8);
    label reading loop {
      switch (RS.page(s.clearingStore, clearingRows, "byMember", lo, hi, cursor, 100)) {
        case (#ok(p)) { for ((_, r) in p.rows.vals()) List.add(out, r); switch (p.next) { case (?n) cursor := ?n; case null break reading } };
        case (#err(_)) break reading;
      };
    };
    List.toArray(out)
  };

  func reasonRefusal(t : Text) : ?T.Error {
    let n = Text.encodeUtf8(t).size();
    if (n == 0 or n > 256) ?#InvalidTerms({ reason = "a reason of 1 to 256 bytes" }) else null
  };
  /// SPEC §11: an order's quantity, its value, and the member's use with it (in place of `replacing`) against the limits.
  func riskRefusal(s : State, member : Nat, qty : Nat, value : Nat, replacing : Nat) : ?T.Error {
    let ?(_, r) = limitsOf(s, member) else return null;
    let l = r.limits;
    if (l.maxOrderQty != 0 and qty > l.maxOrderQty) return ?#RiskLimit({ figure = "quantity"; limit = l.maxOrderQty; wanted = qty });
    if (l.maxOrderValue != 0 and value > l.maxOrderValue) return ?#RiskLimit({ figure = "value"; limit = l.maxOrderValue; wanted = value });
    let use = l.used + value - replacing;
    if (l.creditLimit != 0 and use > l.creditLimit) return ?#RiskLimit({ figure = "credit"; limit = l.creditLimit; wanted = use });
    null
  };
  /// The first open order of a kill's target, if any.
  func firstOpenOf(s : State, k : T.Kill) : ?(Nat, T.Order) {
    let (ix, who) = if (k.trader != 0) ("trader", k.trader) else ("member", k.member);
    let (lo, hi) = R.prefixRange(who, 8, 8);
    first(s.orderRows, orders, ix, lo, hi)
  };


  func markDue(s : State, inst : Nat, due : Bool) {
    let was = switch (RS.get(s.dueRows, dues, inst)) { case (?d) d.due; case null false };
    if (was == due) return;
    if (due) s.dueCount += 1 else s.dueCount -= 1;
    RS.put(s.dueRows, dues, inst, { due })
  };

  // ═══════════════════════════════════════════════════════
  //  APPLY (the fold's only writer)
  // ═══════════════════════════════════════════════════════

  /// An order's open value (SPEC §11): price × remaining while it is live or waiting, else nothing.
  /// An order's open value as the risk limits count it (SPEC §11, §28): a bond's with the most it can accrue.
  public func openValueOf(s : State, o : T.Order) : Nat { openValue(s, o) };
  func openValue(s : State, o : T.Order) : Nat { if (isLiveish(o)) valueOf(s, o.instrument, o.price, o.remaining) else 0 };
  public func limitsOf(s : State, member : Nat) : ?(Nat, LimitRow) { one(s.limitStore, limitRows, "byMember", R.key(member, 8)) };
  func putLimits(s : State, member : Nat, f : T.Limits -> T.Limits) {
    switch (limitsOf(s, member)) {
      case (?(id, r)) RS.put(s.limitStore, limitRows, id, { r with limits = f(r.limits) });
      case null { let id = s.nextLimit; s.nextLimit += 1; RS.put(s.limitStore, limitRows, id, { member; limits = f({ maxOrderQty = 0; maxOrderValue = 0; creditLimit = 0; used = 0 }) }) };
    }
  };
  /// The active kill of a member or of a trader, if any.
  func activeKill(s : State, kind : Nat, id : Nat) : ?Nat { switch (one(s.killRows, kills, "active", R.key2(kind, 1, id, 8))) { case (?(k, _)) ?k; case null null } };
  func killedFor(s : State, member : Nat, trader : Nat) : ?Nat { switch (activeKill(s, 1, member)) { case (?k) ?k; case null activeKill(s, 2, trader) } };
  public func kill(s : State, id : Nat) : ?T.Kill { RS.get(s.killRows, kills, id) };

  func putOrder(s : State, id : Nat, o : T.Order) {
    let (before, heldBefore) = switch (RS.get(s.orderRows, orders, id)) { case (?p) (openValue(s, p), p.held); case null (0, 0) };
    RS.put(s.orderRows, orders, id, o);
    // the member's use moves by the change in the order's open value
    let after = openValue(s, o);
    if (after != before) putLimits(s, o.member, func(l : T.Limits) : T.Limits { { l with used = l.used + after - before } });
    // a clearing order's margin, the CCP's commitment, and pledged shares move with it (SPEC §18)
    if (after != before or o.held != heldBefore) clearingMove(s, id, o, before, after, heldBefore);
    // every key the row now holds lowers its range's mark
    if (o.status == #live) {
      lower(s, BOOK, sidePrefix(o.instrument, o.side), bookKey(o));
      if (immediate(o.kind)) lower(s, IMMEDIATE, instPrefix(o.instrument), R.key2(o.instrument, 8, id, 8));
    };
    if (o.status == #waiting) {
      lower(s, STOPS, sidePrefix(o.instrument, o.side), stopKey(id, o));
      if (o.kind == #trailingStop) lower(s, TRAILING, sidePrefix(o.instrument, o.side), trailKey(id, o));
    };
    if (isLiveish(o)) {
      lower(s, OWN, ownPrefix(o.account, o.instrument, o.side), ownKey(id, o));
      lower(s, OWN_ALL, accountPrefix(o.account), ownKey(id, o));
      lower(s, MEMBER, R.key(o.member, 8), R.key2(o.member, 8, id, 8));
      lower(s, TRADER, R.key(o.trader, 8), R.key2(o.trader, 8, id, 8));
      if (o.validity == #day) lower(s, DAY, "", R.key(id, 8));
      if (o.validity == #gtd) lower(s, GTD, "", R.key2(o.gtdDay, 4, id, 8));
    };
  };
  /// An order leaves the book: what it still holds returns, its status becomes `status`.
  func close(s : State, id : Nat, o : T.Order, status : T.Status) {
    // a clearing order holds nothing on its account: its margin or its pledge returns through `putOrder`
    if (clearingOf(s, o.account) == null) {
      switch (instrument(s, o.instrument)) { case (?i) release(s, o.account, holdingLedger(i, o.side), o.held); case null Runtime.trap("close: instrument vanished") };
    };
    putOrder(s, id, { o with status; held = 0 });
  };
  func cancelOco(s : State, o : T.Order, out : List.List<Nat>) {
    if (o.oco == 0) return;
    switch (order(s, o.oco)) { case (?p) { if (isLiveish(p)) { close(s, o.oco, p, #cancelled); List.add(out, o.oco) } }; case null {} };
  };

  /// Effects by family: [tag] then
  ///   openInstrument, setTrading, setReference: [instrument]; deposit: [account, amount]; withdraw: [account, amount];
  ///   placeOrder: [order, status, price, shown, cancelled own orders...]; cancelOrder: [order]; amendOrder: [order,
  ///   priority kept 1/0, shown];
  ///   massCancel / endOfDay / expireGtd: [count, orders...]; flush: []; clear: per instrument cleared, [instrument, price,
  ///   volume, pairs, (buy, sell, quantity)..., cancelled, orders..., triggered, (order, side 1 buy 2 sell, price, shown)...,
  ///   icebergs traded, (order, shown)..., interrupted 1/0]; setPhase:
  ///   [instrument, phase]; uncross: [instrument, price, volume, pairs, (buy, sell, quantity)..., cancelled, orders...,
  ///   icebergs traded, (order, shown)..., phase after]; halt, resume: [instrument]; kill: [kill]; killSweep: [kill, count, orders...]; revive: [kill];
  ///   setLimits: [member].
  /// A command applied, then every market maker's presence accrued to its time (SPEC §25).
  public func apply(s : State, now : Nat64, c : T.Command) : T.Effects {
    let e = applyCommand(s, now, c);
    // the indices follow the prices this act moved (SPEC §26)
    if (s.pricesMoved) { s.pricesMoved := false; recomputeIndices(s); recomputeNavs(s) };
    accrueMakers(s, now);
    e
  };
  func applyCommand(s : State, now : Nat64, c : T.Command) : T.Effects {
    switch (c) {
      case (#openInstrument(x)) {
        RS.put<T.Instrument>(s.instrumentRows, instruments, x.instrument, { assetLedger = x.assetLedger; cashLedger = x.cashLedger; lot = x.lot; referencePrice = x.referencePrice; bands = x.bands;
          collarBps = x.collarBps; phase = (#closed : T.Phase); lastPrice = 0; staticBps = x.staticBps; dynamicBps = x.dynamicBps; interruptSecs = x.interruptSecs; endFrom = 0; endTo = 0; interruptUntil = 0; closePrice = 0 });
        s.instrumentList := Array.sort<Nat>(Array.concat<Nat>(s.instrumentList, [x.instrument]), Nat.compare);
        [1, x.instrument]
      };
      case (#setTrading(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put<T.Instrument>(s.instrumentRows, instruments, x.instrument, { i with phase = (if (x.open) #continuous else #closed : T.Phase) });
        if (x.open) markDue(s, x.instrument, true);
        [2, x.instrument]
      };
      case (#setReference(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put<T.Instrument>(s.instrumentRows, instruments, x.instrument, { i with referencePrice = x.price });
        s.pricesMoved := true;
        [3, x.instrument]
      };
      case (#deposit(x)) {
        let id = s.nextRef; s.nextRef += 1;
        RS.put(s.refRows, refs, id, { reference = x.reference });
        credit(s, x.account, x.ledger, x.amount);
        moveSupply(s, x.ledger, x.amount, 0);
        [4, x.account, x.amount]
      };
      case (#withdraw(x)) {
        let b = balance(s, x.account, x.ledger);
        putBalance(s, { b with available = b.available - x.amount });
        moveSupply(s, x.ledger, 0, x.amount);
        [5, x.account, x.amount]
      };
      case (#placeOrder(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let id = s.nextOrder; s.nextOrder += 1;
        let price = effectivePrice(i, x.side, x.kind, x.price);
        let cancelled = List.empty<Nat>();
        let stop = isStop(x.kind);
        var incomingCancelled = false;
        if (not stop) {
          let crossing = crossingOwn(s, x.account, x.instrument, x.side, price, T.MAX_SWEEP);
          if (crossing.size() > 0) {
            for ((rid, ro) in crossing.vals()) { close(s, rid, ro, #cancelled); List.add(cancelled, rid) };
            if (x.selfTrade == #cancelBoth) incomingCancelled := true;
          };
        };
        let need = holdNeed(s, i, x.instrument, x.side, price, x.qty);
        let key = K.orderKey(x.account, x.side, price, x.qty, x.clientRef);
        let status : T.Status = if (incomingCancelled) #cancelled else if (stop) #waiting else #live;
        // a pre-funded order holds what it needs; a clearing buy its initial margin, a clearing sale its pledged shares
        let held = if (incomingCancelled) 0 else switch (clearingOf(s, x.account)) {
          case null { hold(s, x.account, holdingLedger(i, x.side), need); need };
          case (?m) {
            if (isDerivative(s, x.instrument)) derivIm(s, x.instrument, x.side == #buy, x.qty, price)
            else switch (x.side) { case (#buy) imFor(switch (marginOf(s, x.instrument)) { case (?b) b; case null 0 }, valueOf(s, x.instrument, price, x.qty)); case (#sell) { pledge(s, m, i, x.instrument, x.qty); x.qty } }
          };
        };
        putOrder(s, id, { account = x.account; instrument = x.instrument; side = x.side; kind = x.kind; qty = x.qty; remaining = x.qty; price; stopPrice = x.stopPrice;
          peak = x.peak; validity = x.validity; gtdDay = x.gtdDay; selfTrade = x.selfTrade; capacity = x.capacity; shortSale = x.shortSale; clientRef = x.clientRef;
          oco = x.oco; trail = x.trail; member = x.member; trader = x.trader; prio = now; key; status; held; filled = 0 });
        // a one-cancels-other pair is linked both ways
        if (x.oco != 0) { switch (order(s, x.oco)) { case (?p) putOrder(s, x.oco, { p with oco = id }); case null {} } };
        if (status == #live) { markDue(s, x.instrument, true); if (s.batchTime == 0) s.batchTime := now };
        // a stop may already be triggered by the last clear's price: the instrument is due at the next clear
        if (status == #waiting) markDue(s, x.instrument, true);
        // what the order rests at and shows (0 unless live): the feed's add (SPEC §13)
        let shows = if (status == #live) (if (x.peak == 0) x.qty else Nat.min(x.peak, x.qty)) else 0;
        Array.concat<Nat>([6, id, Nat8.toNat(K.statusCode(status)), price, shows], List.toArray(cancelled))
      };
      case (#cancelOrder(x)) {
        let ?o = order(s, x.order) else Runtime.trap("apply: order vanished");
        close(s, x.order, o, #cancelled);
        [7, x.order]
      };
      case (#amendOrder(x)) {
        let ?o = order(s, x.order) else Runtime.trap("apply: order vanished");
        let ?i = instrument(s, o.instrument) else Runtime.trap("apply: instrument vanished");
        let keeps = x.price == o.price and x.qty <= o.remaining;
        let ledger = holdingLedger(i, o.side);
        let need = holdNeed(s, i, o.instrument, o.side, x.price, x.qty);
        let held = switch (clearingOf(s, o.account)) {
          case null { if (need > o.held) hold(s, o.account, ledger, need - o.held) else release(s, o.account, ledger, o.held - need); need };
          case (?m) {
            if (isDerivative(s, o.instrument)) derivIm(s, o.instrument, o.side == #buy, x.qty, x.price)
            else switch (o.side) { case (#buy) imFor(switch (marginOf(s, o.instrument)) { case (?b) b; case null 0 }, valueOf(s, o.instrument, x.price, x.qty)); case (#sell) { if (x.qty > o.held) pledge(s, m, i, o.instrument, x.qty - o.held); x.qty } }
          };
        };
        let qty = o.filled + x.qty;
        putOrder(s, x.order, { o with remaining = x.qty; qty; price = x.price; held; prio = if (keeps) o.prio else now;
          key = if (keeps) o.key else K.orderKey(o.account, o.side, x.price, x.qty, o.clientRef) });
        markDue(s, o.instrument, true);
        if (s.batchTime == 0) s.batchTime := now;
        // what it shows: nothing while it waits hidden (a stop), so an amendment does not reveal it (SPEC §13)
        [8, x.order, if (keeps) 1 else 0, if (o.status != #live) 0 else if (o.peak == 0) x.qty else Nat.min(o.peak, x.qty)]
      };
      case (#massCancel(x)) {
        let (lo, hi) = span(accountPrefix(x.account), 25);
        sweep(s, OWN_ALL, accountPrefix(x.account), lo, hi, Nat.min(x.limit, T.MAX_SWEEP), 9)
      };
      case (#flush) [10];
      case (#endOfDay(x)) { let (lo, hi) = R.fullRange(8); sweep(s, DAY, "", lo, hi, Nat.min(x.limit, T.MAX_SWEEP), 11) };
      case (#expireGtd(x)) {
        if (x.day == 0) return [12, 0];
        // the dated orders whose day is before x.day: the index keys (day, id) from (0, 0) to (x.day - 1, the last id);
        // the range is the rule, so every live order it yields is swept
        sweep(s, GTD, "", R.key2(0, 4, 0, 8), R.key2(x.day - 1, 4, MAXP, 8), Nat.min(x.limit, T.MAX_SWEEP), 12)
      };
      case (#clear(x)) clearBatch(s, x.time);
      case (#setPhase(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put<T.Instrument>(s.instrumentRows, instruments, x.instrument, { i with phase = x.phase; endFrom = x.endFrom; endTo = x.endTo });
        markDue(s, x.instrument, true);
        [14, x.instrument, Nat8.toNat(K.phaseCode(x.phase))]
      };
      case (#uncross(x)) uncross(s, now, x.instrument, x.next);
      case (#halt(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put<T.Instrument>(s.instrumentRows, instruments, x.instrument, { i with phase = (#halted : T.Phase); endFrom = 0; endTo = 0; interruptUntil = 0 });
        markDue(s, x.instrument, true);
        [16, x.instrument]
      };
      case (#resume(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put<T.Instrument>(s.instrumentRows, instruments, x.instrument, { i with phase = (#auction : T.Phase) });
        [17, x.instrument]
      };
      case (#kill(x)) {
        let id = s.nextKill; s.nextKill += 1;
        RS.put(s.killRows, kills, id, { member = x.member; trader = x.trader; active = true });
        [18, id]
      };
      case (#killSweep(x)) {
        let ?k = kill(s, x.kill) else Runtime.trap("apply: kill vanished");
        let (ix, who) = if (k.trader != 0) (TRADER, k.trader) else (MEMBER, k.member);
        let (lo, hi) = R.prefixRange(who, 8, 8);
        let done = List.empty<Nat>();
        let limit = Nat.min(x.limit, T.MAX_SWEEP);
        walk(s, ix, R.key(who, 8), lo, hi, 100, func(id : Nat, o : T.Order) : Bool {
          if (List.size(done) >= limit) return false;
          close(s, id, o, #cancelled); List.add(done, id);
          true
        });
        Array.concat<Nat>([19, x.kill, List.size(done)], List.toArray(done))
      };
      case (#revive(x)) {
        let ?k = kill(s, x.kill) else Runtime.trap("apply: kill vanished");
        RS.put(s.killRows, kills, x.kill, { k with active = false });
        [20, x.kill]
      };
      case (#setLimits(x)) {
        putLimits(s, x.member, func(l : T.Limits) : T.Limits { { l with maxOrderQty = x.maxOrderQty; maxOrderValue = x.maxOrderValue; creditLimit = x.creditLimit } });
        [21, x.member]
      };
      case (#setBlackout(x)) {
        let id = s.nextBlackout; s.nextBlackout += 1;
        RS.put(s.blackoutStore, blackoutRows, id, { instrument = x.instrument; client = x.client; until = x.until; active = true });
        [23, id]
      };
      case (#liftBlackout(x)) {
        let ?b = RS.get(s.blackoutStore, blackoutRows, x.blackout) else Runtime.trap("apply: blackout vanished");
        RS.put(s.blackoutStore, blackoutRows, x.blackout, { b with active = false });
        [24, x.blackout]
      };
      case (#borrow(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let id = s.nextRef; s.nextRef += 1;
        RS.put(s.refRows, refs, id, { reference = x.reference });
        credit(s, x.account, i.assetLedger, x.qty);
        moveSupply(s, i.assetLedger, x.qty, 0);
        putOwed(s, x.account, x.instrument, owedOf(s, x.account, x.instrument) + x.qty);
        [25, x.account, x.qty]
      };
      case (#returnBorrow(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let b = balance(s, x.account, i.assetLedger);
        putBalance(s, { b with available = b.available - x.qty });
        moveSupply(s, i.assetLedger, 0, x.qty);
        putOwed(s, x.account, x.instrument, owedOf(s, x.account, x.instrument) - x.qty);
        [26, x.account, x.qty]
      };
      case (#sealDay(x)) {
        let (rows, hash) = seal(s, x.day);
        Array.concat<Nat>([22, x.day, rows], Array.map<Nat8, Nat>(Blob.toArray(hash), func(b) { Nat8.toNat(b) }))
      };
      // SPEC §18 to §21
      case (#setClearing(x)) {
        s.clearing := ?{ ccpAccount = x.ccpAccount; ccpMember = x.ccpMember; cashLedger = x.cashLedger; cycleSecs = x.cycleSecs; cycleDays = x.cycleDays;
          penaltyBps = x.penaltyBps; deadlineCycles = x.deadlineCycles; fundBps = x.fundBps; fundFloor = x.fundFloor };
        [27, x.ccpAccount]
      };
      case (#setMargin(x)) { RS.put(s.marginStore, marginRows, x.instrument, x.imBps); [28, x.instrument, x.imBps] };
      case (#admitClearing(x)) {
        let id = s.nextClearing; s.nextClearing += 1;
        RS.put(s.clearingStore, clearingRows, id, { member = x.member; settlementAccount = x.settlementAccount; creditLine = x.creditLine; collateral = 0; fund = 0;
          fundRequired = 0; imOrders = 0; owedTo = 0; owedBy = 0; debt = 0; fails = 0; peak = 0; status = 1 });
        [29, x.member]
      };
      case (#designateClearing(x)) {
        let id = s.nextDesignation; s.nextDesignation += 1;
        RS.put(s.designationStore, designationRows, id, { account = x.account; member = x.member });
        [30, x.account, x.member]
      };
      case (#postCollateral(x)) {
        let ?t = s.clearing else Runtime.trap("apply: no clearing");
        let ?(_, r) = clearingMember(s, x.member) else Runtime.trap("apply: a member vanished");
        move(s, r.settlementAccount, t.ccpAccount, t.cashLedger, x.amount);
        appendLeg(s, 3, t.cashLedger, r.settlementAccount, t.ccpAccount, x.amount);
        updateMember(s, x.member, func(m : ClearingMember) : ClearingMember { { m with collateral = m.collateral + x.amount } });
        [31, x.member, x.amount]
      };
      case (#withdrawCollateral(x)) {
        let ?t = s.clearing else Runtime.trap("apply: no clearing");
        let ?(_, r) = clearingMember(s, x.member) else Runtime.trap("apply: a member vanished");
        move(s, t.ccpAccount, r.settlementAccount, t.cashLedger, x.amount);
        appendLeg(s, 3, t.cashLedger, t.ccpAccount, r.settlementAccount, x.amount);
        updateMember(s, x.member, func(m : ClearingMember) : ClearingMember { { m with collateral = m.collateral - x.amount } });
        [32, x.member, x.amount]
      };
      case (#cutCycle(x)) {
        RS.put(s.cycleStore, cycleRows, x.cycle, { cutAt = now; settleDay = x.settleDay; settled = false });
        s.cycleNo += 1; s.lastCut := now;
        [33, x.cycle, x.settleDay]
      };
      case (#settleCycle(x)) settleCycle(s, x.cycle);
      case (#closeOut(x)) {
        let ?t = s.clearing else Runtime.trap("apply: no clearing");
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let c = custodyOf(s, x.member, x.instrument);
        let q = (c.qty - c.held) / i.lot * i.lot;
        let id = s.nextOrder; s.nextOrder += 1;
        let price = effectivePrice(i, #sell, #market, 0);
        let clientRef = "closeout " # Nat.toText(id);
        // the close-out row first: the order's hold lands on the member's custody as it is written
        RS.put(s.closeoutStore, closeoutRows, s.nextCloseout, { order = id; member = x.member }); s.nextCloseout += 1;
        hold(s, t.ccpAccount, i.assetLedger, q);
        putOrder(s, id, { account = t.ccpAccount; instrument = x.instrument; side = #sell; kind = #market; qty = q; remaining = q; price; stopPrice = 0; peak = 0;
          validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #principal; shortSale = false; clientRef; oco = 0; trail = 0; member = t.ccpMember;
          trader = 0; prio = now; key = K.orderKey(t.ccpAccount, #sell, price, q, clientRef); status = #live; held = q; filled = 0 });
        markDue(s, x.instrument, true);
        if (s.batchTime == 0) s.batchTime := now;
        [35, id, Nat8.toNat(K.statusCode(#live)), price, q, x.member]
      };
      case (#callFund) {
        let ?t = s.clearing else Runtime.trap("apply: no clearing");
        let act = activeMembers(s);
        let floorShare = ceilDiv(t.fundFloor, act.size());
        let fx = List.empty<Nat>(); List.add(fx, 36); List.add(fx, act.size());
        for (r in act.vals()) {
          let required = Nat.max(floorShare, ceilDiv(t.fundBps * r.peak, 10_000));
          updateMember(s, r.member, func(m : ClearingMember) : ClearingMember { { m with fundRequired = required } });
          List.add(fx, r.member); List.add(fx, required);
        };
        List.toArray(fx)
      };
      case (#contributeFund(x)) {
        let ?t = s.clearing else Runtime.trap("apply: no clearing");
        let ?(_, r) = clearingMember(s, x.member) else Runtime.trap("apply: a member vanished");
        move(s, r.settlementAccount, t.ccpAccount, t.cashLedger, x.amount);
        appendLeg(s, 3, t.cashLedger, r.settlementAccount, t.ccpAccount, x.amount);
        updateMember(s, x.member, func(m : ClearingMember) : ClearingMember { { m with fund = m.fund + x.amount } });
        [37, x.member, x.amount]
      };
      case (#fundSkin(x)) {
        let ?t = s.clearing else Runtime.trap("apply: no clearing");
        move(s, x.account, t.ccpAccount, t.cashLedger, x.amount);
        appendLeg(s, 3, t.cashLedger, x.account, t.ccpAccount, x.amount);
        s.skin += x.amount;
        [38, x.account, x.amount]
      };
      case (#declareDefault(x)) {
        updateMember(s, x.member, func(m : ClearingMember) : ClearingMember { { m with status = 2 } });
        // the member is killed (SPEC §11) unless it is already
        let k = switch (activeKill(s, 1, x.member)) {
          case (?_) 0;
          case null { let id = s.nextKill; s.nextKill += 1; RS.put(s.killRows, kills, id, { member = x.member; trader = 0; active = true }); id };
        };
        [39, x.member, k]
      };
      case (#closeDefault(x)) closeDefault(s, x.member);
      case (#setFeeSchedule(x)) { RS.put(s.feeStore, feeRows, x.instrument, x.levies); [41, x.instrument, x.levies.size()] };
      case (#sealStatements(x)) {
        let fx = List.empty<Nat>(); List.add(fx, 42); List.add(fx, x.day);
        let sealed = List.empty<(Nat, Nat)>();
        var id = 1;
        while (id < s.nextStatement) {
          switch (RS.get(s.statementStore, statementRows, id)) {
            case (?st) {
              if (st.lines > 0) {
                RS.put(s.statementSealStore, statementSealRows, s.nextStatementSeal, { member = st.member; day = x.day; head = st.head; lines = st.lines }); s.nextStatementSeal += 1;
                RS.put(s.statementStore, statementRows, id, { st with head = F.genesis(); lines = 0 });
                List.add(sealed, (st.member, st.lines));
              };
            };
            case null {};
          };
          id += 1;
        };
        s.lastStatementDay := x.day;
        List.add(fx, List.size(sealed)); for ((m, n) in List.values(sealed)) { List.add(fx, m); List.add(fx, n) };
        List.toArray(fx)
      };
      case (#reconcileMember(x)) {
        let w = C.Writer(); w.text(RECON_DOMAIN); w.nat(x.member); w.nat(x.day); w.nat(x.balances.size());
        var matched = 0;
        for (b in x.balances.vals()) {
          let have = balance(s, b.account, b.ledger);
          let book = have.available + have.held;
          if (book == b.amount) matched += 1;
          w.nat(b.account); w.principal(b.ledger); w.nat(b.amount); w.nat(book);
        };
        let id = s.nextRecon; s.nextRecon += 1;
        let breaks = x.balances.size() - matched;
        RS.put(s.reconStore, reconRows, id, { member = x.member; day = x.day; rows = x.balances.size(); matched; breaks; hash = Sha256.fromArray(#sha256, w.toArray()) });
        [43, id, matched, breaks]
      };
      case (#registerMaker(x)) {
        let id = s.nextMaker; s.nextMaker += 1;
        RS.put(s.makerStore, makerRows, id, { member = x.member; instrument = x.instrument; maxSpreadBps = x.maxSpreadBps; minQty = x.minQty; presenceBps = x.presenceBps;
          rebateBps = x.rebateBps; account = 0; bid = 0; ask = 0; cont = false; present = false; lastAt = now; presentNs = 0; sessionNs = 0 });
        [44, id]
      };
      case (#quote(x)) enterQuotes(s, now, x.account, x.member, x.trader, [x.side], 45);
      case (#massQuote(x)) enterQuotes(s, now, x.account, x.member, x.trader, x.sides, 46);
      case (#settleMakers(x)) settleMakers(s, now, x.day);
      case (#defineIndex(x)) {
        putConstituents(s, x.index, x.constituents, x.capBps);
        let m = capitalisation(s, x.index);
        let divisor = halfEvenDiv(m * E18, x.base * 100);
        let level = halfEvenDiv(m * E18, divisor);
        RS.put(s.indexStore, indexRows, x.index, { base = x.base; capBps = x.capBps; haltBps = x.haltBps; suspendBps = x.suspendBps; divisor; level; reference = level; tripped = 0 });
        addPath(s, x.index, level);
        [48, x.index, level]
      };
      case (#reviewIndex(x)) {
        let ?row = indexRowOf(s, x.index) else Runtime.trap("apply: an index vanished");
        putConstituents(s, x.index, x.constituents, row.capBps);
        keepLevel(s, x.index);
        [49, x.index, row.level]
      };
      case (#corporateAction(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let (ref, last) = switch (x.action) {
          case (#split(a)) (toTick(i, halfEvenDiv(i.referencePrice * a.den, a.num)), if (i.lastPrice == 0) 0 else toTick(i, halfEvenDiv(i.lastPrice * a.den, a.num)));
          case (#dividend(a)) (toTick(i, i.referencePrice - Nat.min(i.referencePrice - 1, a.amount)), if (i.lastPrice == 0) 0 else toTick(i, i.lastPrice - Nat.min(i.lastPrice - 1, a.amount)));
        };
        RS.put<T.Instrument>(s.instrumentRows, instruments, x.instrument, { i with referencePrice = ref; lastPrice = last });
        var touched = 0;
        for (index in Nat.range(1, T.MAX_INDICES + 1)) {
          switch (one(s.constituentStore, constituentRows, "byIndex", R.key2(index, 8, x.instrument, 8))) {
            case (?(id, c)) {
              switch (x.action) { case (#split(a)) RS.put(s.constituentStore, constituentRows, id, { c with shares = halfEvenDiv(c.shares * a.num, a.den) }); case (#dividend(_)) {} };
              keepLevel(s, index); touched += 1;
            };
            case null {};
          };
        };
        [50, x.instrument, ref, touched]
      };
      // SPEC §28 to §32
      case (#setTerms(x)) {
        RS.put(s.termsStore, termsRows, x.instrument, x.terms);
        switch (x.terms, instrument(s, x.instrument)) {
          case (#future(_) or #option(_), ?i) RS.put(s.derivStore, derivRows, x.instrument, { mark = i.referencePrice; settled = 0; runDay = 0; runPrice = 0; cursor = 0; runTo = 0; runBy = 0; expired = false });
          case (_) {};
        };
        [52, x.instrument, switch (x.terms) { case (#bond(_)) 1; case (#receipt(_)) 2; case (#certificate(_)) 3; case (#right(_)) 4; case (#future(_)) 5; case (#option(_)) 6 }]
      };
      case (#defineNav(x)) {
        for (b in x.basket.vals()) { let id = s.nextBasket; s.nextBasket += 1; RS.put(s.basketStore, basketRows, id, { fund = x.instrument; instrument = b.instrument; shares = b.shares }) };
        let v = inavOf(s, x.instrument, x.units, x.cash);
        RS.put(s.navStore, navRows, x.instrument, { units = x.units; cash = x.cash; inav = v });
        addNavPath(s, x.instrument, v);
        [53, x.instrument, v]
      };
      case (#issueReceipt(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let id = s.nextReceipt; s.nextReceipt += 1;
        RS.put(s.receiptStore, receiptRows, id, { warehouse = x.warehouse; instrument = x.instrument; account = x.account; qty = x.qty; live = true; reference = x.reference });
        credit(s, x.account, i.assetLedger, x.qty);
        moveSupply(s, i.assetLedger, x.qty, 0);
        [54, id, x.account, x.qty]
      };
      case (#cancelReceipt(x)) {
        let ?r = receiptOf(s, x.receipt) else Runtime.trap("apply: a receipt vanished");
        let ?i = instrument(s, r.instrument) else Runtime.trap("apply: instrument vanished");
        debit(s, x.account, i.assetLedger, r.qty);
        moveSupply(s, i.assetLedger, 0, r.qty);
        RS.put(s.receiptStore, receiptRows, x.receipt, { r with live = false });
        [55, x.receipt, x.account, r.qty]
      };
      case (#retire(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        debit(s, x.account, i.assetLedger, x.qty);
        moveSupply(s, i.assetLedger, 0, x.qty);
        let id = s.nextRetire; s.nextRetire += 1;
        RS.put(s.retireStore, retireRows, id, { account = x.account; instrument = x.instrument; qty = x.qty; beneficiary = x.beneficiary });
        [56, id, x.qty]
      };
      case (#exercise(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let r = switch (termsOf(s, x.instrument)) { case (?#right(r)) r; case (_) Runtime.trap("apply: a right's terms vanished") };
        let shares = x.qty / r.den * r.num;
        let pay = r.price * shares;
        debit(s, x.account, i.assetLedger, x.qty);
        moveSupply(s, i.assetLedger, 0, x.qty);
        move(s, x.account, r.issuer, i.cashLedger, pay);
        appendLeg(s, 7, i.cashLedger, x.account, r.issuer, pay);
        let id = s.nextEntitlement; s.nextEntitlement += 1;
        RS.put(s.entitlementStore, entitlementRows, id, { account = x.account; instrument = x.instrument; rights = x.qty; shares; paid = pay });
        [57, id, shares, pay]
      };
      case (#valueDate(x)) {
        RS.put(s.valueDateStore, valueDateRows, x.instrument, { day = x.day });
        [58, x.instrument, x.day]
      };
      case (#setAttestors(x)) {
        for (k in Nat.range(0, 3)) RS.put(s.attestorStore, attestorRows, k + 1, { attestor = x.attestors[k] });
        [59]
      };
      case (#attestPrice(x)) {
        let id = s.nextAttestation; s.nextAttestation += 1;
        RS.put(s.attestationStore, attestationRows, id, { instrument = x.instrument; day = x.day; attestor = x.attestor; price = x.price });
        [60, x.instrument, x.day, x.attestor, switch (attestedPrice(s, x.instrument, x.day)) { case (?m) m; case null 0 }]
      };
      case (#settleDerivatives(x)) settleDerivatives(s, x.instrument, x.day, x.limit);
      case (#tripBreaker(x)) {
        let ?row = indexRowOf(s, x.index) else Runtime.trap("apply: an index vanished");
        let move = if (row.level > row.reference) row.level - row.reference else row.reference - row.level;
        let kind = if (row.suspendBps > 0 and move * 10_000 >= row.suspendBps * row.reference) 2 else 1;
        RS.put(s.indexStore, indexRows, x.index, { row with tripped = kind });
        if (kind == 2) s.suspendedAt := now;
        s.breakerDue := 0;
        let halted = List.empty<Nat>();
        for (inst in s.instrumentList.vals()) {
          switch (instrument(s, inst)) {
            case (?i) { if (i.phase != #halted) { RS.put<T.Instrument>(s.instrumentRows, instruments, inst, { i with phase = (#halted : T.Phase); endFrom = 0; endTo = 0; interruptUntil = 0 }); markDue(s, inst, true); List.add(halted, inst) } };
            case null {};
          };
        };
        Array.concat<Nat>([51, x.index, row.level, kind, List.size(halted)], List.toArray(halted))
      };
    }
  };

  /// SPEC §34, §35: a slice of a derivative's daily settlement, `limit` open positions from the run's cursor. The price is
  /// the run's: the attested median before the expiry, the index's level on the expiry day. A future's position is
  /// owed or owes (price − mark) × the contracts × the multiplier in the open cycle and is marked at the price; an
  /// option's is marked (its writer's margin follows). On the expiry day every position closes: a future after its last
  /// variation, an option paying its intrinsic value from its writers to its holders. The run ends when no open position
  /// is left after the cursor. Effects: [61, instrument, day, price, done, n, (account, member, owed to it, owed by it)...].
  func settleDerivatives(s : State, inst : Nat, day : Nat, limit : Nat) : T.Effects {
    let ?d = derivOf(s, inst) else Runtime.trap("apply: a derivative vanished");
    let final = day == expiryOf(s, inst);
    let price = if (d.runDay != 0) d.runPrice else if (final) indexLevel(s, indexOfDeriv(s, inst)) else switch (attestedPrice(s, inst, day)) { case (?m) m; case null Runtime.trap("apply: the attestations were checked") };
    let mult = multiplierOf(s, inst);
    let start = if (d.runDay != 0) d.cursor + 1 else 0;
    let out = List.empty<Nat>();
    var n = 0; var last = d.cursor; var done = false; var sumTo = 0; var sumBy = 0;
    // the slice: up to `limit` + 1 open positions after the cursor, the pages followed to the range's end (a page may stop
    // at its scan budget short of its rows); the run is done when no more than `limit` were left
    let found = List.empty<(Nat, Position)>();
    var cursor : ?Page.Cursor = null;
    label pages loop {
      switch (RS.page(s.positionStore, positionRows, "open", R.key2(inst, 8, start, 8), R.key2(inst, 8, MAXP, 8), cursor, limit + 1 - List.size(found))) {
        case (#ok(pg)) {
          for (row in pg.rows.vals()) { if (List.size(found) <= limit) List.add(found, row) };
          switch (pg.next) { case (?c) { if (List.size(found) > limit) break pages; cursor := ?c }; case null break pages };
        };
        case (#err(e)) Runtime.trap("settleDerivatives: " # debug_show(e));
      };
    };
    done := List.size(found) <= limit;
    for ((id, p) in List.toArray(found).vals()) {
      if (n < limit) {
          var to = 0; var by = 0;
          switch (termsOf(s, inst)) {
            case (?#future(_)) {
              let amt = (if (price > p.mark) price - p.mark else p.mark - price) * p.qty * mult;
              if ((price > p.mark) == p.long) to := amt else by := amt;
              if (price == p.mark) { to := 0; by := 0 };
            };
            case (?#option(o)) { if (final) { let pay = intrinsic(o, price) * p.qty * mult; if (p.long) to := pay else by := pay } };
            case (_) {};
          };
          if (to > 0 or by > 0) owe(s, p.member, s.cycleNo, to, by);
          sumTo += to; sumBy += by;
          let (qty, im) = if (final) (0, 0) else (p.qty, derivIm(s, inst, p.long, p.qty, price));
          RS.put(s.positionStore, positionRows, id, { p with qty; im; mark = price });
          putMemberIm(s, p.member, im, p.im);
          for (v in [p.account, p.member, to, by].vals()) List.add(out, v);
          n += 1; last := p.account;
      };
    };
    RS.put(s.derivStore, derivRows, inst,
      if (done) ({ mark = price; settled = day; runDay = 0; runPrice = 0; cursor = 0; runTo = 0; runBy = 0; expired = final } : Deriv)
      else ({ d with runDay = day; runPrice = price; cursor = last; runTo = d.runTo + sumTo; runBy = d.runBy + sumBy } : Deriv));
    Array.concat<Nat>([61, inst, day, price, if (done) 1 else 0, n], List.toArray(out))
  };
  /// SPEC §25: the makers' period closed for a market day. Every registration's presence accrued to now; the
  /// obligation met when it was present for at least its required share of the continuous session (and there was one);
  /// a maker that met it paid its rebate — its fees on the instrument in the period × its rebate rate, half-even — from
  /// the exchange's fee account (the schedule's first levy) to its quote's account, when that account holds it; the
  /// period's figures reset. Effects: [47, day, registrations, (member, instrument, present, session, met, rebate)...].
  func settleMakers(s : State, now : Nat64, day : Nat) : T.Effects {
    accrueMakers(s, now);
    let fx = List.empty<Nat>(); List.add(fx, 47); List.add(fx, day); List.add(fx, s.nextMaker - 1);
    var id = 1;
    while (id < s.nextMaker) {
      switch (RS.get(s.makerStore, makerRows, id)) {
        case (?m) {
          let met = m.sessionNs > 0 and m.presentNs * 10_000 >= m.presenceBps * m.sessionNs;
          let fees = feeTotalOf(s, m.member, m.instrument);
          let n = fees * m.rebateBps; let q = n / 10_000; let r = n % 10_000;
          let due = if (2 * r > 10_000) q + 1 else if (2 * r < 10_000) q else q + q % 2;
          var rebate = 0;
          let levies = feeSchedule(s, m.instrument);
          switch (instrument(s, m.instrument)) {
            case (?i) {
              if (met and due > 0 and m.account != 0 and levies.size() > 0 and balance(s, levies[0].account, i.cashLedger).available >= due) {
                move(s, levies[0].account, m.account, i.cashLedger, due);
                appendLeg(s, 5, i.cashLedger, levies[0].account, m.account, due);
                rebate := due;
              };
            };
            case null {};
          };
          RS.put(s.makerDayStore, makerDayRows, s.nextMakerDay, { member = m.member; instrument = m.instrument; day; presentNs = m.presentNs; sessionNs = m.sessionNs; met; rebate }); s.nextMakerDay += 1;
          RS.put(s.makerStore, makerRows, id, { m with presentNs = 0; sessionNs = 0 });
          switch (one(s.feeTotalStore, feeTotalRows, "byKey", R.key2(m.member, 8, m.instrument, 8))) { case (?(fid, f)) RS.put(s.feeTotalStore, feeTotalRows, fid, { f with fees = 0 }); case null {} };
          for (v in [m.member, m.instrument, m.presentNs, m.sessionNs, (if (met) 1 else 0), rebate].vals()) List.add(fx, v);
        };
        case null {};
      };
      id += 1;
    };
    s.lastMakerDay := day;
    List.toArray(fx)
  };
  /// SPEC §19: the oldest cut cycle settled, every clearing member all or nothing. Payers first, so the receivers are paid
  /// out of what the payers brought in: a payer's net (its purchases in the cycle and its rolled debt less its sales) is
  /// paid from its settlement account if it holds it, else it fails and the net rolls with the penalty. A receiver is paid
  /// within the CCP's free cash, else the amount rolls to it in the next cycle. A member that owes nothing after the cycle
  /// receives the shares the CCP holds for it free of its sales and of its purchases in later cycles.
  /// Effects: [34, cycle, outcomes, (member, 1 paid / 2 failed / 3 received / 4 rolled to it, amount)..., deliveries,
  /// (member, instrument, quantity)..., levies paid, (account, amount)...].
  func settleCycle(s : State, k : Nat) : T.Effects {
    let ?t = s.clearing else Runtime.trap("apply: no clearing");
    let outcomes = List.empty<(Nat, Nat, Nat)>();
    let deliveries = List.empty<(Nat, Nat, Nat)>();
    // every member's side is fixed before any leg moves: what it owes (its cycle's purchases and its rolled debt) and what
    // it is owed, as the cycle was cut; settling one member never moves another between the two passes
    let plan = Array.map<ClearingMember, (Nat, Nat, Nat, Nat)>(clearingMembers(s), func(r0) {
      let (to, by) = switch (obligationOf(s, r0.member, k)) { case (?(_, o)) (o.owedTo, o.owedBy); case null (0, 0) };
      (r0.member, to, by, by + r0.debt)
    });
    let levies = List.empty<(Nat, Nat)>();
    for (payers in [true, false].vals()) {
      // between the passes, the levies are paid what clearing parties' fees owe them, each in full within the free cash
      if (not payers) {
        var id = 1;
        while (id < s.nextPayable) {
          switch (RS.get(s.payableStore, payableRows, id)) {
            case (?x) {
              if (x.amount > 0 and ccpFree(s) >= x.amount) {
                move(s, t.ccpAccount, x.account, t.cashLedger, x.amount);
                appendLeg(s, 4, t.cashLedger, t.ccpAccount, x.account, x.amount);
                RS.put(s.payableStore, payableRows, id, { x with amount = 0 });
                List.add(levies, (x.account, x.amount));
              };
            };
            case null {};
          };
          id += 1;
        };
      };
      for ((member, to, by, pay) in plan.vals()) {
        let ?(_, r) = clearingMember(s, member) else Runtime.trap("settle: a member vanished");
        if (r.status != 3 and (pay > to) == payers) {
          let cleared = func(m : ClearingMember) : ClearingMember { { m with owedTo = m.owedTo - to; owedBy = m.owedBy - by; debt = 0; fails = 0; peak = Nat.max(m.peak, by) } };
          if (payers) {
            let a = pay - to;
            if (balance(s, r.settlementAccount, t.cashLedger).available >= a) {
              move(s, r.settlementAccount, t.ccpAccount, t.cashLedger, a);
              appendLeg(s, 2, t.cashLedger, r.settlementAccount, t.ccpAccount, a);
              updateMember(s, r.member, cleared);
              List.add(outcomes, (r.member, 1, a));
            } else {
              let penalty = ceilDiv(a * t.penaltyBps, 10_000);
              s.skin += penalty;
              updateMember(s, r.member, func(m : ClearingMember) : ClearingMember { { m with owedTo = m.owedTo - to; owedBy = m.owedBy - by; debt = a + penalty; fails = m.fails + 1; peak = Nat.max(m.peak, by) } });
              List.add(outcomes, (r.member, 2, a + penalty));
            };
          } else {
            let a = to - pay;
            updateMember(s, r.member, cleared);
            if (a > 0) {
              if (ccpFree(s) >= a) {
                move(s, t.ccpAccount, r.settlementAccount, t.cashLedger, a);
                appendLeg(s, 2, t.cashLedger, t.ccpAccount, r.settlementAccount, a);
                List.add(outcomes, (r.member, 3, a));
              } else { owe(s, r.member, k + 1, a, 0); List.add(outcomes, (r.member, 4, a)) };
            } else if (to != 0 or by != 0) List.add(outcomes, (r.member, 3, 0));
          };
          deliver(s, t, r.member, k, deliveries);
        };
      };
    };
    switch (cycleOf(s, k)) { case (?c) RS.put(s.cycleStore, cycleRows, k, { c with settled = true }); case null Runtime.trap("settle: the cycle vanished") };
    s.settledThrough := k;
    let fx = List.empty<Nat>();
    List.add(fx, 34); List.add(fx, k); List.add(fx, List.size(outcomes));
    for ((m, o, a) in List.values(outcomes)) { List.add(fx, m); List.add(fx, o); List.add(fx, a) };
    List.add(fx, List.size(deliveries));
    for ((m, i, q) in List.values(deliveries)) { List.add(fx, m); List.add(fx, i); List.add(fx, q) };
    List.add(fx, List.size(levies));
    for ((a, x) in List.values(levies)) { List.add(fx, a); List.add(fx, x) };
    List.toArray(fx)
  };
  /// A member that owes nothing and is not in default receives, in each instrument, the shares the CCP holds for it free
  /// of its sales, less what it bought in cycles after `k` (not yet paid): delivery against payment.
  func deliver(s : State, t : ClearingTerms, member : Nat, k : Nat, out : List.List<(Nat, Nat, Nat)>) {
    let ?(_, r) = clearingMember(s, member) else Runtime.trap("deliver: a member vanished");
    if (r.debt != 0 or r.status != 1) return;
    for (c in custodyRowsOf(s, member).vals()) {
      var later = 0; var j = k + 1;
      while (j <= s.cycleNo) { later += boughtOf(s, member, c.instrument, j); j += 1 };
      let free = c.qty - c.held;
      if (free > later) {
        let d = free - later;
        let ?i = instrument(s, c.instrument) else Runtime.trap("deliver: instrument vanished");
        move(s, t.ccpAccount, r.settlementAccount, i.assetLedger, d);
        putCustody(s, { c with qty = c.qty - d });
        appendLeg(s, 2, i.assetLedger, t.ccpAccount, r.settlementAccount, d);
        List.add(out, (member, c.instrument, d));
      };
    };
  };
  /// SPEC §21: a member in default, its orders cancelled, its shares sold and its cycles settled, has what it still owes
  /// met in a fixed order: its collateral, its fund contribution, the venue's skin-in-the-game, then the other active
  /// members' contributions pro rata to them (whole units; the units left go to the largest remainders, ties in member
  /// order). What it had beyond its loss stays as its collateral, to withdraw; what no layer covers stays its debt.
  /// Effects: [40, member, from collateral, from its fund, from skin, from others, uncovered, others, (member, amount)...].
  func closeDefault(s : State, member : Nat) : T.Effects {
    let ?(_, r) = clearingMember(s, member) else Runtime.trap("apply: a member vanished");
    var rest = r.debt;
    let fromCollateral = Nat.min(rest, r.collateral); rest -= fromCollateral;
    let fromFund = Nat.min(rest, r.fund); rest -= fromFund;
    let fromSkin = Nat.min(rest, s.skin); rest -= fromSkin; s.skin -= fromSkin;
    let others = Array.filter<ClearingMember>(activeMembers(s), func(o) { o.member != member and o.fund > 0 });
    var total = 0; for (o in others.vals()) total += o.fund;
    let take = Nat.min(rest, total);
    let shares = Array.tabulate<Nat>(others.size(), func(j) { if (total == 0) 0 else take * others[j].fund / total });
    var given = 0; for (x in shares.vals()) given += x;
    // the units left: to the largest remainders, ties in member order (the list is in member order and the sort is stable)
    let order = Array.sort<Nat>(Array.tabulate<Nat>(others.size(), func(j) { j }), func(a, b) {
      Nat.compare(take * others[b].fund % total, take * others[a].fund % total)
    });
    let extraVar = VarArray.repeat<Nat>(0, others.size());
    var left = take - given; var j = 0;
    while (left > 0) { extraVar[order[j]] += 1; left -= 1; j += 1 };
    let fx = List.empty<Nat>();
    for (x in [40, member, fromCollateral, fromFund, fromSkin, take].vals()) List.add(fx, x);
    rest -= take;
    List.add(fx, rest); List.add(fx, others.size());
    for (n in Nat.range(0, others.size())) {
      let share = shares[n] + extraVar[n];
      updateMember(s, others[n].member, func(m : ClearingMember) : ClearingMember { { m with fund = m.fund - share } });
      List.add(fx, others[n].member); List.add(fx, share);
    };
    updateMember(s, member, func(m : ClearingMember) : ClearingMember {
      { m with collateral = m.collateral - fromCollateral + (m.fund - fromFund); fund = 0; fundRequired = 0; debt = rest; fails = 0; status = 3 }
    });
    List.toArray(fx)
  };

  /// SPEC §9: the uncross of a call auction at the price its rule fixes, then the phase it names. A price outside the
  /// static band trades nothing and the auction continues.
  func uncross(s : State, now : Nat64, inst : Nat, next : T.Phase) : T.Effects {
    let ?i0 = instrument(s, inst) else Runtime.trap("apply: instrument vanished");
    let cancelled = List.empty<Nat>();
    let pairs = List.empty<(Nat, Nat, Nat)>();
    var price = 0; var volume = 0;
    switch (crossingViews(s, inst)) {
      case (?(bids, asks)) {
        let r = L.uncross(bids, asks, i0.lot, if (i0.lastPrice != 0) i0.lastPrice else i0.referencePrice);
        switch (r.price) {
          case (?p) { if (not L.within(p, i0.referencePrice, i0.staticBps)) return [15, inst, 0, 0, 0, 0, 0, Nat8.toNat(K.phaseCode(i0.phase))] };
          case null {};
        };
        let (p, v) = execute(s, inst, i0, r, now, cancelled, pairs); price := p; volume := v;
      };
      case null {};
    };
    endImmediates(s, inst, cancelled);
    let ?i1 = instrument(s, inst) else Runtime.trap("apply: instrument vanished");
    let last = if (price > 0) price else i1.lastPrice;
    let close = if (i0.phase == #closingAuction) (if (last > 0) last else i1.referencePrice) else i1.closePrice;
    // the session's closing price: the closing auction's (SPEC §15)
    if (i0.phase == #closingAuction) RS.put(s.statStore, statRows, inst, { statsOf(s, inst) with closing = close });
    RS.put<T.Instrument>(s.instrumentRows, instruments, inst, { i1 with phase = next; endFrom = 0; endTo = 0; interruptUntil = 0; closePrice = close });
    if (price > 0) afterTrade(s, inst, price);
    markDue(s, inst, true);
    let fx = List.empty<Nat>();
    for (x in [15, inst, price, volume, List.size(pairs)].vals()) List.add(fx, x);
    for ((b, a, q) in List.values(pairs)) { List.add(fx, b); List.add(fx, a); List.add(fx, q) };
    List.add(fx, List.size(cancelled)); for (x in List.values(cancelled)) List.add(fx, x);
    let shown = shownAfter(s, pairs);
    List.add(fx, shown.size()); for ((t, sh) in shown.vals()) { List.add(fx, t); List.add(fx, sh) };
    List.add(fx, Nat8.toNat(K.phaseCode(next)));
    List.toArray(fx)
  };

  /// Cancels up to `limit` open orders found under an index range, in index order.
  func sweep(s : State, ix : Nat8, prefix : Blob, lo : Blob, hi : Blob, limit : Nat, tag : Nat) : T.Effects {
    let done = List.empty<Nat>();
    walk(s, ix, prefix, lo, hi, 100, func(id : Nat, o : T.Order) : Bool {
      if (List.size(done) >= limit) return false;
      if (isLiveish(o)) { close(s, id, o, #cancelled); List.add(done, id) };
      true
    });
    Array.concat<Nat>([tag, List.size(done)], List.toArray(done))
  };

  // ─── the clear (§1, §3) ──────────────────────────────────────────────────────────────────
  /// The live orders of a side that can trade against the other side's best: best first, while they cross `bound`.
  func crossingSide(s : State, inst : Nat, side : T.Side, bound : Nat) : [(T.OrderId, T.Order)] {
    let out = List.empty<(T.OrderId, T.Order)>();
    let (lo, hi) = span(sidePrefix(inst, side), 48);
    walk(s, BOOK, sidePrefix(inst, side), lo, hi, 32, func(id : Nat, o : T.Order) : Bool {
      let crosses = switch (side) { case (#buy) o.price >= bound; case (#sell) o.price <= bound };
      if (crosses) List.add(out, (id, o));
      crosses
    });
    List.toArray(out)
  };

  func triggerStops(s : State, inst : Nat, i : T.Instrument, time : Nat64, out : List.List<(Nat, Nat, Nat, Nat)>, cancelled : List.List<Nat>) {
    if (i.lastPrice == 0) return;
    for (side in [#buy, #sell].vals()) {
      let (lo, hi) = span(sidePrefix(inst, side), 16);
      let hits = List.empty<(T.OrderId, T.Order)>();
      walk(s, STOPS, sidePrefix(inst, side), lo, hi, 32, func(id : Nat, o : T.Order) : Bool {
        let hit = switch (side) { case (#buy) i.lastPrice >= o.stopPrice; case (#sell) i.lastPrice <= o.stopPrice };
        if (hit) List.add(hits, (id, o));
        hit   // stops in trigger order: none after one that does not trigger
      });
      for ((id, _) in List.values(hits)) {
        // read again: an earlier trigger in this loop may have cancelled it (its one-cancels-other partner)
        switch (order(s, id)) {
          case (?o) {
            if (o.status == #waiting) {
              putOrder(s, id, { o with status = #live; prio = time });
              // revealed: what the order shows from now on (SPEC §13)
              List.add(out, (id, if (o.side == #buy) 1 else 2, o.price, shownOf(o)));
              // a triggered stop is judged against the account's own live orders now (§3.5): it was not at entry
              let crossing = crossingOwn(s, o.account, inst, o.side, o.price, T.MAX_SWEEP);
              if (crossing.size() > 0) {
                if (o.selfTrade != #cancelIncoming) { for ((rid, ro) in crossing.vals()) { close(s, rid, ro, #cancelled); List.add(cancelled, rid) } };
                if (o.selfTrade != #cancelResting) { switch (order(s, id)) { case (?live) { close(s, id, live, #cancelled); List.add(cancelled, id) }; case null {} } };
              };
              switch (order(s, id)) { case (?live) cancelOco(s, live, cancelled); case null {} };
            };
          };
          case null {};
        };
      };
    };
  };

  func toBid((id, o) : (T.OrderId, T.Order)) : L.Bid { { id; price = o.price; qty = o.remaining; prio = o.prio; key = o.key; fok = o.kind == #fok } };
  /// The auction's view of an instrument when its best buy crosses its best sell: each side's orders that cross the other
  /// side's best.
  func crossingViews(s : State, inst : Nat) : ?([L.Bid], [L.Bid]) {
    switch (best(s, inst, #buy), best(s, inst, #sell)) {
      case (?(_, bb), ?(_, ba)) {
        if (bb.price < ba.price) return null;
        ?(Array.map<(T.OrderId, T.Order), L.Bid>(crossingSide(s, inst, #buy, ba.price), toBid), Array.map<(T.OrderId, T.Order), L.Bid>(crossingSide(s, inst, #sell, bb.price), toBid))
      };
      case (_) null;
    }
  };
  /// An auction's result carried out (§3.2, §3.3, §4): fill-or-kill orders removed are cancelled; each pair paid and
  /// delivered at the price; icebergs whose peak filled take `time` as their priority; a filled linked order cancels its
  /// pair; a filled order releases what it still holds. Returns the price and the volume (0, 0 when nothing traded).
  func execute(s : State, inst : Nat, i0 : T.Instrument, r : L.Result, time : Nat64, cancelled : List.List<Nat>, pairs : List.List<(Nat, Nat, Nat)>) : (Nat, Nat) {
    for (k in r.killed.vals()) { switch (order(s, k)) { case (?o) { close(s, k, o, #cancelled); List.add(cancelled, k) }; case null {} } };
    let ?p = r.price else return (0, 0);
    for ((b, a, q) in r.pairs.vals()) {
      let ?bo = order(s, b) else Runtime.trap("clear: buy vanished");
      let ?ao = order(s, a) else Runtime.trap("clear: sell vanished");
      settlePair(s, inst, i0, b, bo, a, ao, p, q);
      for ((oid, o0) in [(b, bo), (a, ao)].vals()) {
        // a clearing buy's margin falls with what remains; every other order's hold by what the fill took
        let held = if (isDerivative(s, inst)) o0.held * (o0.remaining - q) / o0.remaining else switch (o0.side, clearingOf(s, o0.account) != null) {
          case (#buy, true) o0.held * (o0.remaining - q) / o0.remaining;
          case (#buy, false) buyHold(s, i0, inst, o0.price, o0.remaining - q);
          case (#sell, _) o0.held - q;
        };
        let remaining = o0.remaining - q;
        putOrder(s, oid, { o0 with remaining; filled = o0.filled + q; held; status = if (remaining == 0) #filled else #live });
      };
      List.add(pairs, (b, a, q));
      addTrade(s, inst, p, q);
    };
    // an iceberg whose fill reached its displayed peak (the peak shown when the clear began) takes this priority (§2)
    for ((oid, f) in r.fills.vals()) {
      switch (order(s, oid)) {
        case (?o) { if (o.peak != 0 and o.remaining > 0 and f >= Nat.min(o.peak, o.remaining + f)) putOrder(s, oid, { o with prio = time }) };
        case null {};
      };
    };
    // a one-cancels-other order that filled cancels its pair; a filled order releases what it still holds
    for ((b, a, _) in r.pairs.vals()) {
      for (oid in [b, a].vals()) {
        switch (order(s, oid)) {
          case (?o) { cancelOco(s, o, cancelled); if (o.status == #filled and o.held > 0) close(s, oid, o, #filled) };
          case null {};
        };
      };
    };
    (p, r.volume)
  };
  /// One pair's settlement at the fill (SPEC §18): each side as its party's kind says. A pre-funded buyer pays out of what
  /// it holds at its own price (the difference returns to it) and receives the shares; a pre-funded seller delivers what it
  /// holds and is paid. A clearing party's fill is novated: its member owes or is owed the value in the open cycle, and the
  /// shares it buys or sells are the CCP's custody. Where one side is pre-funded and the other clearing, the CCP pays or is
  /// paid, delivers or receives. Every movement of a pre-funded party is a leg of the settlement range.
  func settlePair(s : State, inst : Nat, i0 : T.Instrument, b : Nat, bo : T.Order, a : Nat, ao : T.Order, p : Nat, q : Nat) {
    if (isDerivative(s, inst)) return settleDerivativePair(s, inst, b, bo, a, ao, p, q);
    let v = p * q;
    // a bond's interest accrued to its value date, paid by the buyer to the seller beside the clean value (SPEC §28)
    let ai = switch (bondOf(s, inst)) { case (?bd) accruedOn(bd, q, valueDateOf(s, inst)); case null 0 };
    let bm = clearingOf(s, bo.account); let am = clearingOf(s, ao.account);
    let ccp = switch (s.clearing) { case (?t) t.ccpAccount; case null 0 };
    // each side's fee on the fill's value (SPEC §22)
    let feeB = feeOn(s, inst, v); let feeS = feeOn(s, inst, v);
    switch (bm) {
      case null {
        // the buy's hold recomputed for what remains: what it held beyond that pays the value and the fee, the rest returns
        let after = buyHold(s, i0, inst, bo.price, bo.remaining - q);
        spendHeld(s, bo.account, i0.cashLedger, bo.held - after);
        // the fee stays with the buyer here and is paid to the levies below, as a leg
        credit(s, bo.account, i0.cashLedger, bo.held - after - v - ai);
        credit(s, bo.account, i0.assetLedger, q);
      };
      case (?m) { owe(s, m, s.cycleNo, 0, v + ai + feeB); owePayable(s, inst, feeB); addBought(s, m, inst, s.cycleNo, q); let c = custodyOf(s, m, inst); putCustody(s, { c with qty = c.qty + q }) };
    };
    switch (am) {
      case null { spendHeld(s, ao.account, i0.assetLedger, q); credit(s, ao.account, i0.cashLedger, v + ai) };
      case (?m) { owe(s, m, s.cycleNo, v + ai, feeS); owePayable(s, inst, feeS); let c = custodyOf(s, m, inst); putCustody(s, { c with qty = c.qty - q }) };
    };
    switch (bm, am) {
      case (null, null) { appendLeg(s, 1, i0.cashLedger, bo.account, ao.account, v); appendLeg(s, 1, i0.assetLedger, ao.account, bo.account, q); accruedLeg(s, i0, bo.account, ao.account, ai) };
      case (null, ?_) {
        // the CCP is paid by the buyer and delivers out of the shares it holds
        credit(s, ccp, i0.cashLedger, v + ai); debit(s, ccp, i0.assetLedger, q);
        appendLeg(s, 1, i0.cashLedger, bo.account, ccp, v); appendLeg(s, 1, i0.assetLedger, ccp, bo.account, q); accruedLeg(s, i0, bo.account, ccp, ai);
      };
      case (?_, null) {
        // the CCP pays the seller out of the cash committed at the buy's entry and receives the shares
        debit(s, ccp, i0.cashLedger, v + ai); credit(s, ccp, i0.assetLedger, q);
        appendLeg(s, 1, i0.cashLedger, ccp, ao.account, v); appendLeg(s, 1, i0.assetLedger, ao.account, ccp, q); accruedLeg(s, i0, ccp, ao.account, ai);
      };
      case (?_, ?_) {};
    };
    // a pre-funded party pays its fee to the levies now (the buyer out of what it held, the seller out of its proceeds)
    if (bm == null) payFee(s, inst, bo.account, i0.cashLedger, feeB);
    if (am == null) payFee(s, inst, ao.account, i0.cashLedger, feeS);
    addFeeTotal(s, bo.member, inst, feeB); addFeeTotal(s, ao.member, inst, feeS);
    appendStatement(s, bo.member, b, #buy, q, p, feeB); appendStatement(s, ao.member, a, #sell, q, p, feeS);
    // a close-out's proceeds, net of its fee, pay its member's debt; what is left over is owed to the member (SPEC §20)
    if (am == null and ao.account == ccp and ccp != 0) {
      switch (one(s.closeoutStore, closeoutRows, "byOrder", R.key(a, 8))) {
        case (?(_, co)) {
          let c = custodyOf(s, co.member, inst); putCustody(s, { c with qty = c.qty - q });
          let ?(_, r) = clearingMember(s, co.member) else Runtime.trap("close-out: a member vanished");
          let net = v + ai - feeS;
          let paid = Nat.min(r.debt, net);
          updateMember(s, co.member, func(x : ClearingMember) : ClearingMember { { x with debt = x.debt - paid } });
          if (net > paid) owe(s, co.member, s.cycleNo, net - paid, 0);
        };
        case null {};
      };
    };
  };
  /// A derivative's fill (§34, §35), novated: both parties are clearing members' accounts and trade against the CCP. A
  /// future's trade is marked at once to the contract's mark, the buyer owed (or owing) (mark − price) × the contracts ×
  /// the multiplier and the seller the opposite, in the open cycle; an option's buyer owes the premium and its writer is
  /// owed it. Fees on the notional or premium as any clearing party's; both positions netted.
  func settleDerivativePair(s : State, inst : Nat, b : Nat, bo : T.Order, a : Nat, ao : T.Order, p : Nat, q : Nat) {
    let ?bm = clearingOf(s, bo.account) else Runtime.trap("settle: a derivative's buyer clears");
    let ?am = clearingOf(s, ao.account) else Runtime.trap("settle: a derivative's seller clears");
    let mult = multiplierOf(s, inst);
    let v = p * q * mult;
    switch (termsOf(s, inst)) {
      case (?#future(_)) {
        let mark = switch (derivOf(s, inst)) { case (?d) d.mark; case null p };
        let d = (if (mark > p) mark - p else p - mark) * q * mult;
        if (mark >= p) { owe(s, bm, s.cycleNo, d, 0); owe(s, am, s.cycleNo, 0, d) } else { owe(s, bm, s.cycleNo, 0, d); owe(s, am, s.cycleNo, d, 0) };
      };
      case (_) { owe(s, bm, s.cycleNo, 0, v); owe(s, am, s.cycleNo, v, 0) };
    };
    let feeB = feeOn(s, inst, v); let feeS = feeOn(s, inst, v);
    owe(s, bm, s.cycleNo, 0, feeB); owePayable(s, inst, feeB);
    owe(s, am, s.cycleNo, 0, feeS); owePayable(s, inst, feeS);
    addFeeTotal(s, bo.member, inst, feeB); addFeeTotal(s, ao.member, inst, feeS);
    movePosition(s, bo.account, bm, inst, true, q);
    movePosition(s, ao.account, am, inst, false, q);
    appendStatement(s, bo.member, b, #buy, q, p, feeB); appendStatement(s, ao.member, a, #sell, q, p, feeS);
  };
  /// A bond fill's accrued interest as its own leg (kind 6), when there is any.
  func accruedLeg(s : State, i0 : T.Instrument, from : Nat, to : Nat, ai : Nat) { if (ai > 0) appendLeg(s, 6, i0.cashLedger, from, to, ai) };
  /// The quantity an order shows (SPEC §2, §13): an iceberg its peak, or what remains when less; any other order what
  /// remains.
  public func shownOf(o : T.Order) : Nat { if (o.peak == 0) o.remaining else Nat.min(o.peak, o.remaining) };
  /// The icebergs a clear traded that stay live, each with the quantity it shows after the clear, in the order they first
  /// appear in the pairs (SPEC §13: the feed cannot compute it, the hidden part never being published).
  func shownAfter(s : State, pairs : List.List<(Nat, Nat, Nat)>) : [(Nat, Nat)] {
    let seen = Map.empty<Nat, Bool>();
    let out = List.empty<(Nat, Nat)>();
    for ((b, a, _) in List.values(pairs)) {
      for (oid in [b, a].vals()) {
        if (Map.get(seen, Nat.compare, oid) == null) {
          Map.add(seen, Nat.compare, oid, true);
          switch (order(s, oid)) { case (?o) { if (o.peak != 0 and o.status == #live) List.add(out, (oid, shownOf(o))) }; case null {} };
        };
      };
    };
    List.toArray(out)
  };
  public let DAY_FILE_DOMAIN = "thebes.book.day.v1";
  /// The instruments the book holds, in id order.
  func instrumentIds(s : State) : [Nat] {
    let out = List.empty<Nat>();
    for (i in s.instrumentList.vals()) List.add(out, i);
    List.toArray(out)
  };
  /// The day's file from its rows (SPEC §15).
  func dayFileOf(day : Nat, rows : [DayRow]) : Blob {
    let w = C.Writer(); w.text(DAY_FILE_DOMAIN); w.nat(day); w.len16(rows.size());
    for (r in rows.vals()) {
      w.nat(r.instrument);
      for (v in [r.stats.first, r.stats.high, r.stats.low, r.stats.last, r.stats.closing, r.stats.volume, r.stats.value, r.stats.trades, r.reference].vals()) w.nat(v);
    };
    w.toBlob()
  };
  /// The seal: every instrument's session recorded as the day's, a new session begun; the file's rows and hash.
  func seal(s : State, day : Nat) : (Nat, Blob) {
    let rows = Array.map<Nat, DayRow>(instrumentIds(s), func(i) {
      let reference = switch (instrument(s, i)) { case (?x) x.referencePrice; case null 0 };
      { day; instrument = i; stats = statsOf(s, i); reference }
    });
    for (r in rows.vals()) { RS.put(s.dayStore, dayRows, s.nextDayRow, r); s.nextDayRow += 1; RS.put(s.statStore, statRows, r.instrument, NO_STATS) };
    s.lastSealed := day;
    let hash = Sha256.fromBlob(#sha256, dayFileOf(day, rows));
    RS.put(s.sealStore, sealRows, s.nextSeal, { day; rows = rows.size(); hash }); s.nextSeal += 1;
    // every index's reference is its level at the close, its breaker armed again (SPEC §27)
    for (index in Nat.range(1, T.MAX_INDICES + 1)) { switch (indexRowOf(s, index)) { case (?x) RS.put(s.indexStore, indexRows, index, { x with reference = x.level; tripped = 0 }); case null {} } };
    (rows.size(), hash)
  };
  /// A day's seal, if it was sealed.
  public func sealOf(s : State, day : Nat) : ?SealRow { switch (one(s.sealStore, sealRows, "byDay", R.key(day, 8))) { case (?(_, r)) ?r; case null null } };
  /// A sealed day's file, rebuilt from its rows; null for a day not sealed.
  public func dayFile(s : State, day : Nat) : ?Blob {
    let ?sealed = sealOf(s, day) else return null;
    let rows = List.empty<DayRow>();
    var cursor : ?Page.Cursor = null;
    label reading loop {
      switch (RS.page(s.dayStore, dayRows, "byDay", R.key2(day, 8, 0, 8), R.key2(day, 8, 2 ** 64 - 1, 8), cursor, 500)) {
        case (#ok(p)) { for ((_, r) in p.rows.vals()) List.add(rows, r); switch (p.next) { case (?n) cursor := ?n; case null break reading } };
        case (#err(_)) break reading;
      };
    };
    if (List.size(rows) != sealed.rows) Runtime.trap("day file: the day's rows are not the seal's");
    ?dayFileOf(day, List.toArray(rows))
  };
  /// A trade of `q` at `p` in the instrument's session statistics (SPEC §15).
  func addTrade(s : State, inst : Nat, p : Nat, q : Nat) {
    let x = statsOf(s, inst);
    RS.put(s.statStore, statRows, inst, { x with first = if (x.trades == 0) p else x.first; high = Nat.max(x.high, p); low = if (x.trades == 0) p else Nat.min(x.low, p);
      last = p; volume = x.volume + q; value = x.value + p * q; trades = x.trades + 1 });
  };
  /// An instrument's statistics for the session since the last seal.
  public func statsOf(s : State, inst : Nat) : Stats { switch (RS.get(s.statStore, statRows, inst)) { case (?x) x; case null NO_STATS } };
  /// The live immediate orders of an instrument cancelled (they cannot wait).
  func endImmediates(s : State, inst : Nat, cancelled : List.List<Nat>) {
    let (ilo, ihi) = R.prefixRange(inst, 8, 8);
    let ends = List.empty<(Nat, T.Order)>();
    walk(s, IMMEDIATE, instPrefix(inst), ilo, ihi, 100, func(id : Nat, o : T.Order) : Bool { List.add(ends, (id, o)); true });
    for ((id, o) in List.values(ends)) { if (o.status == #live) { close(s, id, o, #cancelled); List.add(cancelled, id) } };
  };
  /// After a trade at `price`: the last price, trailing stops follow it, and stops it reaches are due (§2).
  func afterTrade(s : State, inst : Nat, price : Nat) {
    s.pricesMoved := true;
    let ?i1 = instrument(s, inst) else Runtime.trap("clear: instrument vanished");
    RS.put<T.Instrument>(s.instrumentRows, instruments, inst, { i1 with lastPrice = price });
    trailStops(s, inst, i1.bands, price);
    if (stopsHit(s, inst, price)) markDue(s, inst, true);
  };

  func clearBatch(s : State, time : Nat64) : T.Effects {
    let fx = List.empty<Nat>();
    List.add(fx, 13);
    // every instrument due, in id order
    let (dlo, dhi) = R.fullRange(8);
    let due = List.empty<Nat>();
    var dc : ?Page.Cursor = null;
    label d loop { switch (RS.page(s.dueRows, dues, "due", dlo, dhi, dc, 100)) { case (#ok(p)) { for ((id, _) in p.rows.vals()) List.add(due, id); switch (p.next) { case (?n) dc := ?n; case null break d } }; case (#err(_)) break d } };
    for (inst in List.values(due)) {
      let ?i0 = instrument(s, inst) else Runtime.trap("clear: instrument vanished");
      markDue(s, inst, false);
      let cancelled = List.empty<Nat>();
      let triggered = List.empty<(Nat, Nat, Nat, Nat)>();
      var price = 0; var volume = 0;
      var interrupted = false;
      let pairs = List.empty<(Nat, Nat, Nat)>();
      switch (i0.phase) {
        case (#continuous) {
          triggerStops(s, inst, i0, time, triggered, cancelled);
          switch (crossingViews(s, inst)) {
            case (?(bids, asks)) {
              let r = L.auction(bids, asks, i0.lot);
              // the bands (SPEC §10): a price outside either trades nothing and interrupts
              let outside = switch (r.price) {
                case (?p) { not L.within(p, i0.referencePrice, i0.staticBps) or (i0.dynamicBps != 0 and not L.within(p, if (i0.lastPrice != 0) i0.lastPrice else i0.referencePrice, i0.dynamicBps)) };
                case null false;
              };
              if (outside) interrupted := true else { let (p, v) = execute(s, inst, i0, r, time, cancelled, pairs); price := p; volume := v };
            };
            case null {};
          };
        };
        case (#tradeAtClose) {
          // trade at the closing price only (SPEC §8)
          let bids = Array.map<(T.OrderId, T.Order), L.Bid>(crossingSide(s, inst, #buy, i0.closePrice), toBid);
          let asks = Array.map<(T.OrderId, T.Order), L.Bid>(crossingSide(s, inst, #sell, i0.closePrice), toBid);
          if (bids.size() > 0 and asks.size() > 0) { let (p, v) = execute(s, inst, i0, L.auctionAt(bids, asks, i0.lot, i0.closePrice), time, cancelled, pairs); price := p; volume := v };
        };
        case (_) {};
      };
      // the batch's immediate orders end with the clear (§1 step 4), except in a call phase, where they wait (§8)
      if (i0.phase != #auction and i0.phase != #closingAuction) endImmediates(s, inst, cancelled);
      if (interrupted) {
        let ?i1 = instrument(s, inst) else Runtime.trap("clear: instrument vanished");
        RS.put<T.Instrument>(s.instrumentRows, instruments, inst, { i1 with phase = (#auction : T.Phase); interruptUntil = time + Nat64.fromNat(i1.interruptSecs) * 1_000_000_000; endFrom = 0; endTo = 0 });
      };
      if (price > 0) afterTrade(s, inst, price);
      List.add(fx, inst); List.add(fx, price); List.add(fx, volume); List.add(fx, List.size(pairs));
      for ((b, a, q) in List.values(pairs)) { List.add(fx, b); List.add(fx, a); List.add(fx, q) };
      List.add(fx, List.size(cancelled)); for (x in List.values(cancelled)) List.add(fx, x);
      List.add(fx, List.size(triggered)); for ((t, sd, tp, sh) in List.values(triggered)) { List.add(fx, t); List.add(fx, sd); List.add(fx, tp); List.add(fx, sh) };
      let shown = shownAfter(s, pairs);
      List.add(fx, shown.size()); for ((t, sh) in shown.vals()) { List.add(fx, t); List.add(fx, sh) };
      List.add(fx, if (interrupted) 1 else 0);
    };
    s.batchTime := 0;
    List.toArray(fx)
  };

  /// The instrument's trailing stops of a side, at most `T.MAX_TRAILING` of them.
  func trailing(s : State, inst : Nat, side : T.Side) : [(T.OrderId, T.Order)] {
    let (lo, hi) = span(sidePrefix(inst, side), 8);
    let out = List.empty<(T.OrderId, T.Order)>();
    walk(s, TRAILING, sidePrefix(inst, side), lo, hi, 100, func(id : Nat, o : T.Order) : Bool { List.add(out, (id, o)); true });
    List.toArray(out)
  };
  func trailingCount(s : State, inst : Nat, side : T.Side) : Nat { trailing(s, inst, side).size() };
  /// After a clear that traded at `price` (§2): a sell trailing stop's stop rises to the price less its trail, on the
  /// tick below; a buy trailing stop's falls to the price plus its trail, on the tick above; never the other way.
  func trailStops(s : State, inst : Nat, bands : [T.Band], price : Nat) {
    for (side in [#buy, #sell].vals()) {
      for ((id, o) in trailing(s, inst, side).vals()) {
        let next = switch (side) {
          case (#sell) {
            if (price <= o.trail) o.stopPrice else {
              let c : Nat = price - o.trail;
              let floor = c - c % L.tickAt(bands, c);
              if (floor > o.stopPrice) floor else o.stopPrice
            }
          };
          case (#buy) {
            let c = price + o.trail;
            let t = L.tickAt(bands, c);
            let ceil = if (c % t == 0) c else c + (t - c % t);
            if (ceil < o.stopPrice) ceil else o.stopPrice
          };
        };
        if (next != o.stopPrice) putOrder(s, id, { o with stopPrice = next });
      };
    };
  };

  func stopsHit(s : State, inst : Nat, last : Nat) : Bool {
    for (side in [#buy, #sell].vals()) {
      let (lo, hi) = span(sidePrefix(inst, side), 16);
      var found : ?T.Order = null;
      walk(s, STOPS, sidePrefix(inst, side), lo, hi, 1, func(_ : Nat, o : T.Order) : Bool { found := ?o; false });
      switch (found) {
        case (?o) { if ((side == #buy and last >= o.stopPrice) or (side == #sell and last <= o.stopPrice)) return true };
        case null {};
      };
    };
    false
  };

  // ═══════════════════════════════════════════════════════
  //  THE LIFECYCLE
  // ═══════════════════════════════════════════════════════

  public type Authority = { hasGrant : (Principal, Auth.PermissionId) -> Bool; holdsRole : (Principal, Auth.RoleId) -> Bool };
  public type Outcome = { #executed : { block : Nat; effects : T.Effects }; #proposed : { proposal : Cmd.ProposalId; required : Nat } };

  func appendExecuted(s : State, now : Nat64, caller : Principal, proposal : ?Cmd.ProposalId, version : Nat8, c : T.Command) : (Nat, T.Effects) {
    s.applying := DL.length(s.log);
    let effects = apply(s, now, c);
    let b = DL.append(s.log, K.codec, now, caller, #executed({ proposal; version; command = c; effects }), null);
    s.lastTime := now;
    // an index moved past a threshold: the breaker in the next block, every instrument halted in it (SPEC §27)
    if (s.breakerDue != 0) ignore appendExecuted(s, now, caller, null, K.registry.current, #tripBreaker({ index = s.breakerDue }));
    (b.index, effects)
  };

  /// The clear due at the chain's time `now` (§1): when a batch is waiting from an earlier time, or an instrument is due
  /// and the time has moved on, the clear is recorded as a block of its own, before anything else is judged. Returns
  /// the clear's block, if one was recorded.
  /// The feed carried to the log's end: every block not yet projected gets its message's hash, chained (SPEC §13). Run at
  /// the end of every entry that appends and after a replay, so the chain is the same however the log was made.
  func feedTo(s : State) {
    let n = DL.length(s.log);
    while (s.feedNext < n) {
      let ?b = DL.get(s.log, K.codec, s.feedNext) else Runtime.trap("feed: a block of the log does not read");
      let h = F.chain(s.feedHead, F.message(b));
      RS.put(s.feedRows, feedHashes, s.feedNext, h);
      s.feedHead := h;
      for ((member, own) in concerned(s, b).vals()) { RS.put(s.dropStore, dropRows, s.nextDrop, { member; block = s.feedNext; own }); s.nextDrop += 1 };
      s.feedNext += 1;
    };
  };
  /// Block `i`'s feed message, its feed hash, and the hash before it (the genesis value before block 0); null past the
  /// log's end.
  public func feedEntry(s : State, i : Nat) : ?{ message : Blob; hash : Blob; previous : Blob } {
    if (i >= s.feedNext) return null;
    let ?b = DL.get(s.log, K.codec, i) else return null;
    let ?hash = RS.get(s.feedRows, feedHashes, i) else return null;
    let previous = if (i == 0) F.genesis() else switch (RS.get(s.feedRows, feedHashes, i - 1)) { case (?h) h; case null return null };
    ?{ message = F.message(b); hash; previous }
  };
  public func feedHeadOf(s : State) : (Nat, Blob) { (s.feedNext, s.feedHead) };
  /// The members a block concerns, each with whether the block is its own act, in member order (SPEC §14).
  func concerned(s : State, b : DL.Block<K.Event>) : [(Nat, Bool)] {
    let out = Map.empty<Nat, Bool>();
    func own(m : Nat) { if (m != 0) Map.add(out, Nat.compare, m, true) };
    func touched(oid : Nat) { switch (order(s, oid)) { case (?o) { if (Map.get(out, Nat.compare, o.member) == null) Map.add(out, Nat.compare, o.member, false) }; case null {} } };
    func mentioned(m : Nat) { if (m != 0 and Map.get(out, Nat.compare, m) == null) Map.add(out, Nat.compare, m, false) };
    func killMember(id : Nat) : Nat { switch (kill(s, id)) { case (?k) k.member; case null 0 } };
    switch (b.event) {
      case (#executed(x)) {
        let e = x.effects;
        switch (x.command) {
          case (#placeOrder(c)) own(c.member);
          case (#cancelOrder(c)) { switch (order(s, c.order)) { case (?o) own(o.member); case null {} } };
          case (#amendOrder(c)) { switch (order(s, c.order)) { case (?o) own(o.member); case null {} } };
          case (#deposit(c)) own(c.member);
          case (#withdraw(c)) own(c.member);
          case (#massCancel(c)) own(c.member);
          case (#kill(c)) own(c.member);
          case (#revive(c)) own(killMember(c.kill));
          case (#killSweep(c)) own(killMember(c.kill));
          case (#setLimits(c)) own(c.member);
          case (#borrow(c)) own(c.member);
          case (#returnBorrow(c)) own(c.member);
          case (#admitClearing(c)) own(c.member);
          case (#designateClearing(c)) own(c.member);
          case (#postCollateral(c)) own(c.member);
          case (#withdrawCollateral(c)) own(c.member);
          case (#contributeFund(c)) own(c.member);
          case (#declareDefault(c)) own(c.member);
          case (#closeDefault(c)) { own(c.member); for (j in Nat.range(0, e[7])) mentioned(e[8 + 2 * j]) };
          case (#closeOut(c)) own(c.member);
          case (#callFund) { for (j in Nat.range(0, e[1])) mentioned(e[2 + 2 * j]) };
          case (#reconcileMember(c)) own(c.member);
          case (#issueReceipt(c)) own(c.member);
          case (#cancelReceipt(c)) own(c.member);
          case (#retire(c)) own(c.member);
          case (#exercise(c)) { own(c.member); switch (termsOf(s, c.instrument)) { case (?#right(r)) mentioned(r.issuerMember); case (_) {} } };
          case (#settleDerivatives(_)) { for (j in Nat.range(0, e[5])) mentioned(e[7 + 4 * j]) };
          case (#registerMaker(c)) own(c.member);
          case (#quote(c)) { own(c.member); var p = 2; for (_ in Nat.range(0, e[1])) { let nc = e[p + 1]; for (j in Nat.range(0, nc)) touched(e[p + 2 + j]); p += 2 + nc + 8 } };
          case (#massQuote(c)) { own(c.member); var p = 2; for (_ in Nat.range(0, e[1])) { let nc = e[p + 1]; for (j in Nat.range(0, nc)) touched(e[p + 2 + j]); p += 2 + nc + 8 } };
          case (#sealStatements(_)) { for (j in Nat.range(0, e[2])) mentioned(e[3 + 2 * j]) };
          case (#settleMakers(_)) { for (j in Nat.range(0, e[2])) mentioned(e[3 + 6 * j]) };
          case (#settleCycle(_)) {
            let n = e[2]; for (j in Nat.range(0, n)) mentioned(e[3 + 3 * j]);
            let d = e[3 + 3 * n]; for (j in Nat.range(0, d)) mentioned(e[4 + 3 * n + 3 * j]);
          };
          case (#endOfDay(_) or #expireGtd(_)) { for (oid in Array.sliceToArray<Nat>(e, 2, 2 + e[1]).vals()) touched(oid) };
          case (#clear(_)) {
            var k = 1;
            while (k < e.size()) {
              let np = e[k + 3]; var p = k + 4;
              for (_ in Nat.range(0, np)) { touched(e[p]); touched(e[p + 1]); p += 3 };
              let nc = e[p]; for (j in Nat.range(0, nc)) touched(e[p + 1 + j]); p += 1 + nc;
              let nt = e[p]; for (j in Nat.range(0, nt)) touched(e[p + 1 + 4 * j]); p += 1 + 4 * nt;
              let ns = e[p]; for (j in Nat.range(0, ns)) touched(e[p + 1 + 2 * j]); p += 1 + 2 * ns;
              k := p + 1;
            };
          };
          case (#uncross(_)) {
            let np = e[4]; var p = 5;
            for (_ in Nat.range(0, np)) { touched(e[p]); touched(e[p + 1]); p += 3 };
            let nc = e[p]; for (j in Nat.range(0, nc)) touched(e[p + 1 + j]); p += 1 + nc;
            let ns = e[p]; for (j in Nat.range(0, ns)) touched(e[p + 1 + 2 * j]);
          };
          case (_) {};
        };
      };
      case (_) {};
    };
    Iter.toArray(Map.entries(out))
  };
  /// The most entries one page of a drop copy holds.
  public let MAX_DROP_PAGE = 100;
  /// A member's drop copy from block `from` (SPEC §14): up to `limit` entries (at most `MAX_DROP_PAGE`), each the block's
  /// index, whether it is the member's own, and the stored block (its own) or the block's public message (not its own);
  /// and the block to read from next, when more remain.
  public func dropCopy(s : State, member : Nat, from : Nat, limit : Nat) : { entries : [(Nat, Bool, Blob)]; next : ?Nat } {
    let want = Nat.max(1, Nat.min(limit, MAX_DROP_PAGE));
    // one row more than the page, to know where the next page starts; the row store may answer in several pages
    let rows = List.empty<DropRow>();
    var cursor : ?Page.Cursor = null;
    label reading loop {
      switch (RS.page(s.dropStore, dropRows, "byMember", R.key2(member, 8, from, 8), R.key2(member, 8, 2 ** 64 - 1, 8), cursor, want + 1 - List.size(rows))) {
        case (#ok(p)) { for ((_, row) in p.rows.vals()) List.add(rows, row); if (List.size(rows) > want) break reading; switch (p.next) { case (?n) cursor := ?n; case null break reading } };
        case (#err(_)) break reading;
      };
    };
    let all = List.toArray(rows);
    let page = Array.sliceToArray<DropRow>(all, 0, Nat.min(want, all.size()));
    let entries = Array.map<DropRow, (Nat, Bool, Blob)>(page, func(row) {
      let bytes = if (row.own) { switch (DL.rawBlock(s.log, row.block)) { case (?raw) raw; case null Runtime.trap("drop copy: a block does not read") } }
        else { switch (DL.get(s.log, K.codec, row.block)) { case (?bk) F.message(bk); case null Runtime.trap("drop copy: a block does not read") } };
      (row.block, row.own, bytes)
    });
    { entries; next = if (all.size() > want) ?all[want].block else null }
  };
  public func flushDue(s : State, now : Nat64, caller : Principal) : ?Nat { let r = flushDueAt(s, now, caller); feedTo(s); r };
  func flushDueAt(s : State, now : Nat64, caller : Principal) : ?Nat {
    let pending : Nat64 = if (s.batchTime != 0) s.batchTime else if (s.dueCount > 0) s.lastTime else 0;
    if (pending == 0 or now <= pending) return null;
    let (block, _) = appendExecuted(s, now, caller, null, K.registry.current, #clear({ time = pending }));
    ?block
  };


  public func submit(s : State, xs : X.State, auth : Authority, now : Nat64, caller : Principal, c : T.Command, partition : ?Text, justification : Text) : Result<Outcome> {
    let r = submitAt(s, xs, auth, now, caller, c, partition, justification); feedTo(s); r
  };
  func submitAt(s : State, xs : X.State, auth : Authority, now : Nat64, caller : Principal, c : T.Command, partition : ?Text, justification : Text) : Result<Outcome> {
    ignore flushDueAt(s, now, caller);
    let perm = permissionOf(c);
    if (not auth.hasGrant(caller, perm.id)) return #err(#auth(#NoGrant({ permission = perm.id })));
    switch (validate(s, xs, now, caller, c)) { case (?e) return #err(#book(e)); case null {} };
    switch (MC.resolvePolicy(perm, policyFor(s, perm.id))) {
      case (#refuse(e)) #err(#auth(e));
      case (#single) { let (block, effects) = appendExecuted(s, now, caller, null, K.registry.current, c); ignore upkeep(s); ignore instrumentUpkeep(s); #ok(#executed({ block; effects })) };
      case (#dual(policy)) {
        let ?bound = Cmd.bind(K.registry, c) else return #err(#encoding("the current encoding cannot represent this command"));
        let p : Cmd.Proposed = { permission = perm.id; partition; maker = caller; required = policy.required; eligibleRole = policy.eligibleRole; expiresAt = now + Nat64.fromNat(policy.ttlSeconds) * 1_000_000_000; justification; commandHash = bound.commandHash; commandEncoding = bound.commandEncoding };
        let trailer = Cmd.trailerWithBody(K.registry, bound.commandEncoding, c);
        let b = DL.append(s.log, K.codec, now, caller, #proposed(p), trailer);
        s.lastTime := now;
        RS.put(s.proposalRows, proposals, b.index, { expiresAt = p.expiresAt; status = #awaiting; approvalBlocks = [] });
        #ok(#proposed({ proposal = b.index; required = policy.required }))
      };
    }
  };
  public func proposedCommand(s : State, id : Cmd.ProposalId) : ?T.Command {
    let ?b = DL.get(s.log, K.codec, id) else return null;
    let #proposed(p) = b.event else return null;
    Cmd.bodyOf(K.registry, p, b.trailer)
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
  public func approve(s : State, xs : X.State, auth : Authority, now : Nat64, checker : Principal, id : Cmd.ProposalId) : Result<Outcome> {
    let r = approveAt(s, xs, auth, now, checker, id); feedTo(s); r
  };
  func approveAt(s : State, xs : X.State, auth : Authority, now : Nat64, checker : Principal, id : Cmd.ProposalId) : Result<Outcome> {
    ignore flushDueAt(s, now, checker);
    if (not auth.hasGrant(checker, "command.approve")) return #err(#auth(#NoGrant({ permission = "command.approve" })));
    let ?e = proposal(s, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    switch (MC.checkApprover(e, checker, auth.holdsRole(checker, e.eligibleRole), now)) { case (?err) return #err(#auth(err)); case null {} };
    let ?c = proposedCommand(s, id) else return #err(#auth(#CommandHashMismatch({ index = id })));
    let ?b = DL.get(s.log, K.codec, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let #proposed(p) = b.event else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    if (not Cmd.matches(K.registry, p, c)) return #err(#auth(#CommandHashMismatch({ index = id })));
    let ?row = RS.get(s.proposalRows, proposals, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let ab = DL.append(s.log, K.codec, now, checker, #approved({ proposal = id; checker; commandHash = p.commandHash }), null);
    s.lastTime := now;
    let approvalBlocks = Array.concat<Nat>(row.approvalBlocks, [ab.index]);
    if (approvalBlocks.size() < e.required) { RS.put(s.proposalRows, proposals, id, { row with approvalBlocks }); return #ok(#proposed({ proposal = id; required = e.required })) };
    switch (validate(s, xs, now, p.maker, c)) {
      case (?err) {
        let rb = DL.append(s.log, K.codec, now, checker, #rejected({ proposal = id; checker; reason = "no longer valid at execution: " # debug_show(err) }), null);
        s.lastTime := now;
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #rejected(rb.index) });
        #err(#book(err))
      };
      case null {
        let (block, effects) = appendExecuted(s, now, checker, ?id, p.commandEncoding, c);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #executed(block) });
        #ok(#executed({ block; effects }))
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  func applyBlock(s : State, b : DL.Block<K.Event>) {
    s.lastTime := b.timestamp;
    switch (b.event) {
      case (#proposed(p)) RS.put(s.proposalRows, proposals, b.index, { expiresAt = p.expiresAt; status = #awaiting; approvalBlocks = [] });
      case (#approved(a)) { switch (RS.get(s.proposalRows, proposals, a.proposal)) { case (?row) RS.put(s.proposalRows, proposals, a.proposal, { row with approvalBlocks = Array.concat<Nat>(row.approvalBlocks, [b.index]) }); case null {} } };
      case (#rejected(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #rejected(b.index) }); case null {} } };
      case (#expired(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #expired(b.index) }); case null {} } };
      case (#executed(x)) {
        s.applying := b.index;
        let effects = apply(s, b.timestamp, x.command);
        switch (x.proposal) { case (?id) { switch (RS.get(s.proposalRows, proposals, id)) { case (?row) RS.put(s.proposalRows, proposals, id, { row with status = #executed(b.index) }); case null {} } }; case null {} };
        if (effects != x.effects) Runtime.trap("replay: block " # Nat.toText(b.index) # " recorded effects " # debug_show(x.effects) # " but the fold produced " # debug_show(effects));
      };
    }
  };
  public func replay(fresh : State) : Fold.Report {
    let r = Fold.replay<K.Event, State>(fresh.log, K.codec, func(_ : Nat) : ?Blob { null }, fresh, applyBlock);
    feedTo(fresh);
    r
  };
  public func fingerprint(s : State) : Blob {
    let f = Fold.newFingerprint();
    func table<Rw>(name : Text, store : RS.Store, decl : RS.Decl<Rw>, next : Nat) {
      Fold.section(f, name, func(w : C.Writer) { w.nat(next); var i = 1; while (i < next) { switch (RS.get(store, decl, i)) { case (?r) { w.nat(i); w.blob(decl.encode(r)) }; case null {} }; i += 1 } });
    };
    table<T.Order>("orders", s.orderRows, orders, s.nextOrder);
    table<T.Balance>("balances", s.balanceRows, balances, s.nextBalance);
    table<RefRow>("depositrefs", s.refRows, refs, s.nextRef);
    // instruments and dues are keyed by the exchange's instrument id
    Fold.section(f, "instruments", func(w : C.Writer) { for (i in s.instrumentList.vals()) { switch (RS.get(s.instrumentRows, instruments, i)) { case (?r) { w.nat(i); w.blob(instruments.encode(r)) }; case null {} } } });
    Fold.section(f, "due", func(w : C.Writer) { for (i in s.instrumentList.vals()) { switch (RS.get(s.dueRows, dues, i)) { case (?r) { if (r.due) w.nat(i) }; case null {} } } });
    Fold.section(f, "batch", func(w : C.Writer) { w.nat64(s.batchTime) });
    Fold.section(f, "proposals", func(w : C.Writer) { var i = 0; let n = DL.length(s.log); while (i < n) { switch (RS.get(s.proposalRows, proposals, i)) { case (?r) { w.nat(i); w.blob(MC.encodeProposalRow(r)) }; case null {} }; i += 1 } });
    table<T.Kill>("kills", s.killRows, kills, s.nextKill);
    table<LimitRow>("limits", s.limitStore, limitRows, s.nextLimit);
    Fold.section(f, "feed", func(w : C.Writer) { w.nat(s.feedNext); w.blobRaw(s.feedHead) });
    table<DropRow>("drops", s.dropStore, dropRows, s.nextDrop);
    Fold.section(f, "stats", func(w : C.Writer) { for (i in s.instrumentList.vals()) { switch (RS.get(s.statStore, statRows, i)) { case (?r) { w.nat(i); w.blob(statRows.encode(r)) }; case null {} } } });
    table<DayRow>("days", s.dayStore, dayRows, s.nextDayRow);
    table<SealRow>("seals", s.sealStore, sealRows, s.nextSeal);
    table<Blackout>("blackouts", s.blackoutStore, blackoutRows, s.nextBlackout);
    table<BorrowRow>("borrows", s.borrowStore, borrowRows, s.nextBorrow);
    Fold.section(f, "clearing", func(w : C.Writer) { clearingScalars(s, w) });
    table<ClearingMember>("clearingmembers", s.clearingStore, clearingRows, s.nextClearing);
    table<Designation>("designations", s.designationStore, designationRows, s.nextDesignation);
    table<CustodyRow>("ccpcustody", s.custodyStore, custodyRows, s.nextCustody);
    Fold.section(f, "margins", func(w : C.Writer) { margins(s, w) });
    table<Closeout>("closeouts", s.closeoutStore, closeoutRows, s.nextCloseout);
    table<Obligation>("obligations", s.obligationStore, obligationRows, s.nextObligation);
    table<Bought>("bought", s.boughtStore, boughtRows, s.nextBought);
    table<CycleRow>("cycles", s.cycleStore, cycleRows, s.cycleNo);
    table<Leg>("settlementlegs", s.legStore, legRows, s.nextLeg + 1);
    table<Blob>("settlementnodes", s.nodeStore, nodeRows, s.nextNode + 1);
    Fold.section(f, "fees", func(w : C.Writer) { feeScalars(s, w) });
    table<Payable>("levypayable", s.payableStore, payableRows, s.nextPayable);
    table<FeeTotal>("feetotals", s.feeTotalStore, feeTotalRows, s.nextFeeTotal);
    table<Statement>("statements", s.statementStore, statementRows, s.nextStatement);
    table<StatementSeal>("statementseals", s.statementSealStore, statementSealRows, s.nextStatementSeal);
    table<Recon>("memberrecons", s.reconStore, reconRows, s.nextRecon);
    table<Maker>("makers", s.makerStore, makerRows, s.nextMaker);
    table<MakerDay>("makerdays", s.makerDayStore, makerDayRows, s.nextMakerDay);
    table<IndexRow>("indices", s.indexStore, indexRows, T.MAX_INDICES + 1);
    table<ConstituentRow>("constituents", s.constituentStore, constituentRows, s.nextConstituent);
    table<PathRow>("indexpath", s.pathStore, pathRows, s.nextPath);
    Fold.section(f, "breaker", func(w : C.Writer) { w.nat(s.breakerDue); w.nat64(s.suspendedAt) });
    Fold.section(f, "classes", func(w : C.Writer) { classScalars(s, w) });
    table<BasketRow>("baskets", s.basketStore, basketRows, s.nextBasket);
    table<PathRow>("navpath", s.navPathStore, navPathRows, s.nextNavPath);
    table<Receipt>("receipts", s.receiptStore, receiptRows, s.nextReceipt);
    table<Retirement>("retirements", s.retireStore, retireRows, s.nextRetire);
    table<Entitlement>("entitlements", s.entitlementStore, entitlementRows, s.nextEntitlement);
    table<Supply>("supply", s.supplyStore, supplyRows, s.nextSupply);
    table<Attestor>("attestors", s.attestorStore, attestorRows, 4);
    table<Attestation>("attestations", s.attestationStore, attestationRows, s.nextAttestation);
    table<Position>("positions", s.positionStore, positionRows, s.nextPosition);
    Fold.section(f, "positionmargin", func(w : C.Writer) { positionMargins(s, w) });
    Fold.section(f, "log", func(w : C.Writer) { w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)) });
    Fold.fingerprintHash(f)
  };
  func clearingScalars(s : State, w : C.Writer) {
    w.optBlob(switch (s.clearing) { case (?t) ?encodeTerms(t); case null null });
    w.nat(s.cycleNo); w.nat(s.settledThrough); w.nat64(s.lastCut); w.nat(s.ccpCommitted); w.nat(s.skin)
  };
  /// The fee schedules by instrument, and the statements' and makers' last days.
  func feeScalars(s : State, w : C.Writer) {
    for (i in s.instrumentList.vals()) { switch (RS.get(s.feeStore, feeRows, i)) { case (?r) { w.nat(i); w.blob(feeRows.encode(r)) }; case null {} } };
    w.nat(s.lastStatementDay); w.nat(s.lastMakerDay)
  };
  /// The instruments' terms, funds' iNAV rows and bonds' value dates, by instrument (SPEC §28 to §32).
  func classScalars(s : State, w : C.Writer) {
    for (i in s.instrumentList.vals()) {
      switch (termsOf(s, i)) { case (?t) { w.nat(i); w.byte(1); w.blob(termsRows.encode(t)) }; case null {} };
      switch (navOf(s, i)) { case (?n) { w.nat(i); w.byte(2); w.blob(navRows.encode(n)) }; case null {} };
      switch (RS.get(s.valueDateStore, valueDateRows, i)) { case (?v) { w.nat(i); w.byte(3); w.nat(v.day) }; case null {} };
      switch (derivOf(s, i)) { case (?d) { w.nat(i); w.byte(4); w.blob(derivRows.encode(d)) }; case null {} };
    };
  };
  /// Every clearing member's positions' margin, in member order (SPEC §34).
  func positionMargins(s : State, w : C.Writer) {
    for (r in clearingMembers(s).vals()) { switch (RS.get(s.memberImStore, memberImRows, r.member)) { case (?x) { w.nat(r.member); w.nat(x.im) }; case null {} } };
  };
  func margins(s : State, w : C.Writer) { for (i in s.instrumentList.vals()) { switch (RS.get(s.marginStore, marginRows, i)) { case (?r) { w.nat(i); w.nat(r) }; case null {} } } };
  /// One step of a table in the sliced fingerprint: its next row, or on to `after` past its end.
  func tableStep<Rw>(w : C.Writer, run : FingerprintRun, store : RS.Store, decl : RS.Decl<Rw>, next : Nat, after : Nat) {
    if (run.cursor < next) { switch (RS.get(store, decl, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(decl.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := after
  };
  func tableHead(w : C.Writer, run : FingerprintRun, name : Text, next : Nat, rows : Nat) { w.text(name); w.nat(next); run.part := rows; run.cursor := 1 };
  /// The fingerprint in slices, for a book too large to fingerprint in one message: the same bytes as `fingerprint`,
  /// fed to the same hash under the same domain, a bounded number of rows per step. A run belongs to the log's length
  /// when it started (every change to the rows comes with a block); if a block is appended meanwhile, it starts again.
  public type FingerprintRun = { digest : Sha256.Digest; logLength : Nat; var part : Nat; var cursor : Nat };
  public type FingerprintStep = { #more : Nat; #done : Blob; #restart };
  public func startFingerprint(s : State) : FingerprintRun {
    let d = Sha256.Digest(#sha256);
    let w = C.Writer(); w.text(Fold.DOMAIN); d.writeArray(w.toArray());
    { digest = d; logLength = DL.length(s.log); var part = 0; var cursor = 0 }
  };
  public func stepFingerprint(s : State, run : FingerprintRun, rows : Nat) : FingerprintStep {
    if (DL.length(s.log) != run.logLength) return #restart;
    var left = Nat.max(1, rows);
    while (left > 0 and run.part < 90) {
      let w = C.Writer();
      switch (run.part) {
        case 0 { w.text("orders"); w.nat(s.nextOrder); run.part := 1; run.cursor := 1 };
        case 1 { if (run.cursor < s.nextOrder) { switch (RS.get(s.orderRows, orders, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(orders.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 2 };
        case 2 { w.text("balances"); w.nat(s.nextBalance); run.part := 3; run.cursor := 1 };
        case 3 { if (run.cursor < s.nextBalance) { switch (RS.get(s.balanceRows, balances, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(balances.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 4 };
        case 4 { w.text("depositrefs"); w.nat(s.nextRef); run.part := 5; run.cursor := 1 };
        case 5 { if (run.cursor < s.nextRef) { switch (RS.get(s.refRows, refs, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(refs.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 6 };
        case 6 { w.text("instruments"); for (i in s.instrumentList.vals()) { switch (RS.get(s.instrumentRows, instruments, i)) { case (?r) { w.nat(i); w.blob(instruments.encode(r)) }; case null {} } }; run.part := 7 };
        case 7 { w.text("due"); for (i in s.instrumentList.vals()) { switch (RS.get(s.dueRows, dues, i)) { case (?r) { if (r.due) w.nat(i) }; case null {} } }; run.part := 8 };
        case 8 { w.text("batch"); w.nat64(s.batchTime); run.part := 9 };
        case 9 { w.text("proposals"); run.part := 10; run.cursor := 0 };
        case 10 { if (run.cursor < run.logLength) { switch (RS.get(s.proposalRows, proposals, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(MC.encodeProposalRow(r)) }; case null {} }; run.cursor += 1 } else run.part := 11 };
        case 11 { w.text("kills"); w.nat(s.nextKill); run.part := 12; run.cursor := 1 };
        case 12 { if (run.cursor < s.nextKill) { switch (RS.get(s.killRows, kills, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(kills.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 13 };
        case 13 { w.text("limits"); w.nat(s.nextLimit); run.part := 14; run.cursor := 1 };
        case 14 { if (run.cursor < s.nextLimit) { switch (RS.get(s.limitStore, limitRows, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(limitRows.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 15 };
        case 15 { w.text("feed"); w.nat(s.feedNext); w.blobRaw(s.feedHead); run.part := 16 };
        case 16 { w.text("drops"); w.nat(s.nextDrop); run.part := 17; run.cursor := 1 };
        case 17 { if (run.cursor < s.nextDrop) { switch (RS.get(s.dropStore, dropRows, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(dropRows.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 18 };
        case 18 { w.text("stats"); for (i in s.instrumentList.vals()) { switch (RS.get(s.statStore, statRows, i)) { case (?r) { w.nat(i); w.blob(statRows.encode(r)) }; case null {} } }; run.part := 19 };
        case 19 { w.text("days"); w.nat(s.nextDayRow); run.part := 20; run.cursor := 1 };
        case 20 { if (run.cursor < s.nextDayRow) { switch (RS.get(s.dayStore, dayRows, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(dayRows.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 21 };
        case 21 { w.text("seals"); w.nat(s.nextSeal); run.part := 22; run.cursor := 1 };
        case 22 { if (run.cursor < s.nextSeal) { switch (RS.get(s.sealStore, sealRows, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(sealRows.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 23 };
        case 23 { w.text("blackouts"); w.nat(s.nextBlackout); run.part := 24; run.cursor := 1 };
        case 24 { if (run.cursor < s.nextBlackout) { switch (RS.get(s.blackoutStore, blackoutRows, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(blackoutRows.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 25 };
        case 25 { w.text("borrows"); w.nat(s.nextBorrow); run.part := 26; run.cursor := 1 };
        case 26 { if (run.cursor < s.nextBorrow) { switch (RS.get(s.borrowStore, borrowRows, run.cursor)) { case (?r) { w.nat(run.cursor); w.blob(borrowRows.encode(r)) }; case null {} }; run.cursor += 1 } else run.part := 27 };
        case 27 { w.text("clearing"); clearingScalars(s, w); run.part := 28 };
        case 28 tableHead(w, run, "clearingmembers", s.nextClearing, 29);
        case 29 tableStep<ClearingMember>(w, run, s.clearingStore, clearingRows, s.nextClearing, 30);
        case 30 tableHead(w, run, "designations", s.nextDesignation, 31);
        case 31 tableStep<Designation>(w, run, s.designationStore, designationRows, s.nextDesignation, 32);
        case 32 tableHead(w, run, "ccpcustody", s.nextCustody, 33);
        case 33 tableStep<CustodyRow>(w, run, s.custodyStore, custodyRows, s.nextCustody, 34);
        case 34 { w.text("margins"); margins(s, w); run.part := 35 };
        case 35 tableHead(w, run, "closeouts", s.nextCloseout, 36);
        case 36 tableStep<Closeout>(w, run, s.closeoutStore, closeoutRows, s.nextCloseout, 37);
        case 37 tableHead(w, run, "obligations", s.nextObligation, 38);
        case 38 tableStep<Obligation>(w, run, s.obligationStore, obligationRows, s.nextObligation, 39);
        case 39 tableHead(w, run, "bought", s.nextBought, 40);
        case 40 tableStep<Bought>(w, run, s.boughtStore, boughtRows, s.nextBought, 41);
        case 41 tableHead(w, run, "cycles", s.cycleNo, 42);
        case 42 tableStep<CycleRow>(w, run, s.cycleStore, cycleRows, s.cycleNo, 43);
        case 43 tableHead(w, run, "settlementlegs", s.nextLeg + 1, 44);
        case 44 tableStep<Leg>(w, run, s.legStore, legRows, s.nextLeg + 1, 45);
        case 45 tableHead(w, run, "settlementnodes", s.nextNode + 1, 46);
        case 46 tableStep<Blob>(w, run, s.nodeStore, nodeRows, s.nextNode + 1, 47);
        case 47 { w.text("fees"); feeScalars(s, w); run.part := 48 };
        case 48 tableHead(w, run, "levypayable", s.nextPayable, 49);
        case 49 tableStep<Payable>(w, run, s.payableStore, payableRows, s.nextPayable, 50);
        case 50 tableHead(w, run, "feetotals", s.nextFeeTotal, 51);
        case 51 tableStep<FeeTotal>(w, run, s.feeTotalStore, feeTotalRows, s.nextFeeTotal, 52);
        case 52 tableHead(w, run, "statements", s.nextStatement, 53);
        case 53 tableStep<Statement>(w, run, s.statementStore, statementRows, s.nextStatement, 54);
        case 54 tableHead(w, run, "statementseals", s.nextStatementSeal, 55);
        case 55 tableStep<StatementSeal>(w, run, s.statementSealStore, statementSealRows, s.nextStatementSeal, 56);
        case 56 tableHead(w, run, "memberrecons", s.nextRecon, 57);
        case 57 tableStep<Recon>(w, run, s.reconStore, reconRows, s.nextRecon, 58);
        case 58 tableHead(w, run, "makers", s.nextMaker, 59);
        case 59 tableStep<Maker>(w, run, s.makerStore, makerRows, s.nextMaker, 60);
        case 60 tableHead(w, run, "makerdays", s.nextMakerDay, 61);
        case 61 tableStep<MakerDay>(w, run, s.makerDayStore, makerDayRows, s.nextMakerDay, 62);
        case 62 tableHead(w, run, "indices", T.MAX_INDICES + 1, 63);
        case 63 tableStep<IndexRow>(w, run, s.indexStore, indexRows, T.MAX_INDICES + 1, 64);
        case 64 tableHead(w, run, "constituents", s.nextConstituent, 65);
        case 65 tableStep<ConstituentRow>(w, run, s.constituentStore, constituentRows, s.nextConstituent, 66);
        case 66 tableHead(w, run, "indexpath", s.nextPath, 67);
        case 67 tableStep<PathRow>(w, run, s.pathStore, pathRows, s.nextPath, 68);
        case 68 { w.text("breaker"); w.nat(s.breakerDue); w.nat64(s.suspendedAt); run.part := 69 };
        case 69 { w.text("classes"); classScalars(s, w); run.part := 70 };
        case 70 tableHead(w, run, "baskets", s.nextBasket, 71);
        case 71 tableStep<BasketRow>(w, run, s.basketStore, basketRows, s.nextBasket, 72);
        case 72 tableHead(w, run, "navpath", s.nextNavPath, 73);
        case 73 tableStep<PathRow>(w, run, s.navPathStore, navPathRows, s.nextNavPath, 74);
        case 74 tableHead(w, run, "receipts", s.nextReceipt, 75);
        case 75 tableStep<Receipt>(w, run, s.receiptStore, receiptRows, s.nextReceipt, 76);
        case 76 tableHead(w, run, "retirements", s.nextRetire, 77);
        case 77 tableStep<Retirement>(w, run, s.retireStore, retireRows, s.nextRetire, 78);
        case 78 tableHead(w, run, "entitlements", s.nextEntitlement, 79);
        case 79 tableStep<Entitlement>(w, run, s.entitlementStore, entitlementRows, s.nextEntitlement, 80);
        case 80 tableHead(w, run, "supply", s.nextSupply, 81);
        case 81 tableStep<Supply>(w, run, s.supplyStore, supplyRows, s.nextSupply, 82);
        case 82 { tableHead(w, run, "attestors", 4, 83) };
        case 83 tableStep<Attestor>(w, run, s.attestorStore, attestorRows, 4, 84);
        case 84 tableHead(w, run, "attestations", s.nextAttestation, 85);
        case 85 tableStep<Attestation>(w, run, s.attestationStore, attestationRows, s.nextAttestation, 86);
        case 86 tableHead(w, run, "positions", s.nextPosition, 87);
        case 87 tableStep<Position>(w, run, s.positionStore, positionRows, s.nextPosition, 88);
        case 88 { w.text("positionmargin"); positionMargins(s, w); run.part := 89 };
        case _ { w.text("log"); w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)); run.part := 90 };
      };
      run.digest.writeArray(w.toArray());
      left -= 1;
    };
    if (run.part >= 90) #done(run.digest.sum()) else #more(run.part)
  };
  public type Counts = { orders : Nat; balances : Nat; refs : Nat; blocks : Nat };
  public func counts(s : State) : Counts { { orders = RS.size(s.orderRows); balances = RS.size(s.balanceRows); refs = RS.size(s.refRows); blocks = DL.length(s.log) } };
  public func counters(s : State) : [Nat] {
    [s.nextOrder, s.nextBalance, s.nextRef, Nat64.toNat(s.batchTime), s.dueCount, Nat64.toNat(s.lastTime), s.nextKill, s.nextLimit,
     s.nextClearing, s.nextDesignation, s.nextCustody, s.nextCloseout, s.nextObligation, s.nextBought, s.cycleNo, s.settledThrough, s.ccpCommitted, s.skin, s.nextLeg, s.nextNode,
     s.nextPayable, s.nextFeeTotal, s.nextStatement, s.nextStatementSeal, s.lastStatementDay, s.nextRecon, s.nextMaker, s.nextMakerDay, s.lastMakerDay,
     s.nextConstituent, s.nextPath, s.breakerDue, Nat64.toNat(s.suspendedAt),
     s.nextBasket, s.nextNavPath, s.nextReceipt, s.nextRetire, s.nextEntitlement, s.nextSupply, s.nextAttestation, s.nextPosition]
  };
  /// The order indexes whose entries leave as orders change (the reference index's keys never move).
  public let churnIndexes : [Text] = ["book", "stops", "own", "day", "gtd", "immediate", "trailing", "member", "trader"];
  /// Storage upkeep, not a command: one order index rebuilt without the entries of rows that left it, in slices of
  /// `limit` and to the end within this one call (the row store does not carry writes into a rebuild left open across
  /// messages), then swapped in. Changes no row and no read; the marks stay valid, since the live entries are the same.
  /// Returns the entries examined, or null for an index the book does not hold.
  public func compactIndex(s : State, index : Text, limit : Nat) : ?Nat {
    switch (RS.startCompaction(s.orderRows, orders, index)) {
      case (?c) {
        var n = 0;
        while (not RS.compactionDone(c)) { n += RS.stepCompaction(c, orders, Nat.max(1, limit)) };
        s.orderRows := RS.finishCompaction(s.orderRows, orders, c);
        ?n
      };
      case null null;
    }
  };
  public func tombstones(s : State) : Nat { RS.tombstoneCount(s.orderRows) };
  public let UPKEEP_MIN_STALE = 2_048;
  /// Upkeep after a command: once the order indexes hold at least as many stale entries as live ones (and at least
  /// `UPKEEP_MIN_STALE`), every order index is compacted in this message. A walk across a range passes the stale
  /// entries between live rows (an order filled or cancelled at a price inside the range leaves one there), so they
  /// must go for an order's cost not to grow with the day's history; compacting when they equal the live entries
  /// makes each pass cost at most twice the entries it drops. Returns the entries examined when it compacted.
  /// The stale entries of the order indexes, and the live entries of the indexes that churn: every entry, less one
  /// primary row and one client-reference entry per order (those never go stale), less the stale ones.
  public func staleAndLive(s : State) : (Nat, Nat) {
    let c = RS.cost(s.orderRows);
    let fixed = 2 * RS.size(s.orderRows) + c.tombstones;
    (c.tombstones, if (c.entries > fixed) c.entries - fixed else 0)
  };
  public func upkeep(s : State) : Nat {
    let (stale, live) = staleAndLive(s);
    if (stale < UPKEEP_MIN_STALE or stale < live) return 0;
    var n = 0;
    for (ix in churnIndexes.vals()) { switch (compactIndex(s, ix, 256)) { case (?k) n += k; case null {} } };
    n
  };
  /// The instruments' upkeep: every phase change in or out of a call phase leaves a stale entry in "calling"; once they
  /// reach `UPKEEP_MIN_STALE` and the live rows, the index is rebuilt in this message (an exchange's instruments are a few
  /// thousand rows, so the rebuild is bounded by the instrument count). Returns the entries examined when it compacted.
  public func instrumentUpkeep(s : State) : Nat {
    let stale = RS.tombstoneCount(s.instrumentRows);
    if (stale < UPKEEP_MIN_STALE or stale < RS.size(s.instrumentRows)) return 0;
    switch (RS.startCompaction(s.instrumentRows, instruments, "calling")) {
      case (?c) {
        var n = 0;
        while (not RS.compactionDone(c)) n += RS.stepCompaction(c, instruments, 256);
        s.instrumentRows := RS.finishCompaction(s.instrumentRows, instruments, c);
        n
      };
      case null 0;
    }
  };

}
