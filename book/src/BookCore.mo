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
        case (#err(_)) break w;
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
        if (x.amount == 0) return ?#InvalidTerms({ reason = "an amount above zero" });
        if (x.reference.size() != 32) return ?#InvalidTerms({ reason = "a 32-byte reference" });
        if (one(s.refRows, refs, "byRef", x.reference) != null) return ?#DuplicateReference;
        null
      };
      case (#withdraw(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        if (memberOf(xs, x.account) != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        if (x.amount == 0) return ?#InvalidTerms({ reason = "an amount above zero" });
        let b = balance(s, x.account, x.ledger);
        if (b.available < x.amount) return ?#InsufficientFunds({ ledger = x.ledger; available = b.available; wanted = x.amount });
        null
      };
      case (#placeOrder(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        // the order records its member and its trader: they must be the account's and the caller's
        switch (X.account(xs, x.account), X.traderByPrincipal(xs, caller)) {
          case (?a, ?(tid, _)) { if (a.member != x.member or tid != x.trader) return ?#NotYourAccount({ account = x.account }) };
          case (_) return ?#NotYourAccount({ account = x.account });
        };
        switch (X.mayTrade(xs, caller, x.instrument)) { case (?e) return ?#MayNotTrade({ code = XText.code(e) }); case null {} };
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.phase == #halted) return ?#InstrumentHalted({ instrument = x.instrument });
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
        if (x.side == #sell) {
          if (x.shortSale) {
            let limited = x.kind == #limit or x.kind == #ioc or x.kind == #fok or x.kind == #stopLimit;
            if (not limited or x.price < shortFloor(i)) return ?#ShortSalePrice({ price = x.price; floor = shortFloor(i) });
          } else {
            let free = ownedFree(s, x.account, i, x.instrument);
            if (x.qty > free) return ?#ShortSaleNotFlagged({ free; wanted = x.qty });
          };
        };
        let price = effectivePrice(i, x.side, x.kind, x.price);
        switch (riskRefusal(s, x.member, x.qty, price * x.qty, 0)) { case (?e) return ?e; case null {} };
        let need = holdingOf(x.side, price, x.qty);
        let ledger = holdingLedger(i, x.side);
        // self-trade prevention (§3.5), judged with the account's own live orders now: cancel-incoming refuses;
        // cancel-both cancels the incoming order too, so it holds nothing; cancel-resting cancels own orders on the
        // other side, which hold the other ledger, so this side's funds must cover the order in full
        let crossing = if (isStop(x.kind)) [] else crossingOwn(s, x.account, x.instrument, x.side, price, 1);
        if (crossing.size() > 0 and x.selfTrade == #cancelIncoming) return ?#SelfTradePrevented({ resting = crossing[0].0 });
        let incomingCancelled = crossing.size() > 0 and x.selfTrade == #cancelBoth;
        if (not incomingCancelled) {
          let b = balance(s, x.account, ledger);
          if (b.available < need) return ?#InsufficientFunds({ ledger; available = b.available; wanted = need });
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
          else if (x.qty > o.remaining) { let free = ownedFree(s, o.account, i, o.instrument); if (x.qty - o.remaining > free) return ?#ShortSaleNotFlagged({ free; wanted = x.qty - o.remaining }) };
        };
        switch (riskRefusal(s, o.member, x.qty, x.price * x.qty, openValue(o))) { case (?e) return ?e; case null {} };
        let need = holdingOf(o.side, x.price, x.qty);
        let ledger = holdingLedger(i, o.side);
        let b = balance(s, o.account, ledger);
        if (need > o.held and b.available < need - o.held) return ?#InsufficientFunds({ ledger; available = b.available; wanted = need - o.held });
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
        if (instrument(s, x.instrument) == null) return ?#UnknownInstrument({ instrument = x.instrument });
        if (x.qty == 0) return ?#InvalidTerms({ reason = "a quantity above zero" });
        if (x.reference.size() != 32) return ?#InvalidTerms({ reason = "a 32-byte reference" });
        if (one(s.refRows, refs, "byRef", x.reference) != null) return ?#DuplicateReference;
        null
      };
      case (#returnBorrow(x)) {
        switch (ownAccount(xs, caller, x.account)) { case (?e) return ?e; case null {} };
        if (memberOf(xs, x.account) != x.member) return ?#InvalidTerms({ reason = "the account's member" });
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
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
    }
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
  func openValue(o : T.Order) : Nat { if (isLiveish(o)) o.price * o.remaining else 0 };
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
    let before = switch (RS.get(s.orderRows, orders, id)) { case (?p) openValue(p); case null 0 };
    RS.put(s.orderRows, orders, id, o);
    // the member's use moves by the change in the order's open value
    let after = openValue(o);
    if (after != before) putLimits(s, o.member, func(l : T.Limits) : T.Limits { { l with used = l.used + after - before } });
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
    switch (instrument(s, o.instrument)) { case (?i) release(s, o.account, holdingLedger(i, o.side), o.held); case null Runtime.trap("close: instrument vanished") };
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
  public func apply(s : State, now : Nat64, c : T.Command) : T.Effects {
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
        [3, x.instrument]
      };
      case (#deposit(x)) {
        let id = s.nextRef; s.nextRef += 1;
        RS.put(s.refRows, refs, id, { reference = x.reference });
        credit(s, x.account, x.ledger, x.amount);
        [4, x.account, x.amount]
      };
      case (#withdraw(x)) {
        let b = balance(s, x.account, x.ledger);
        putBalance(s, { b with available = b.available - x.amount });
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
        let need = holdingOf(x.side, price, x.qty);
        let key = K.orderKey(x.account, x.side, price, x.qty, x.clientRef);
        let status : T.Status = if (incomingCancelled) #cancelled else if (stop) #waiting else #live;
        if (not incomingCancelled) hold(s, x.account, holdingLedger(i, x.side), need);
        putOrder(s, id, { account = x.account; instrument = x.instrument; side = x.side; kind = x.kind; qty = x.qty; remaining = x.qty; price; stopPrice = x.stopPrice;
          peak = x.peak; validity = x.validity; gtdDay = x.gtdDay; selfTrade = x.selfTrade; capacity = x.capacity; shortSale = x.shortSale; clientRef = x.clientRef;
          oco = x.oco; trail = x.trail; member = x.member; trader = x.trader; prio = now; key; status; held = if (incomingCancelled) 0 else need; filled = 0 });
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
        let need = holdingOf(o.side, x.price, x.qty);
        if (need > o.held) hold(s, o.account, ledger, need - o.held) else release(s, o.account, ledger, o.held - need);
        let qty = o.filled + x.qty;
        putOrder(s, x.order, { o with remaining = x.qty; qty; price = x.price; held = need; prio = if (keeps) o.prio else now;
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
        putOwed(s, x.account, x.instrument, owedOf(s, x.account, x.instrument) + x.qty);
        [25, x.account, x.qty]
      };
      case (#returnBorrow(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        let b = balance(s, x.account, i.assetLedger);
        putBalance(s, { b with available = b.available - x.qty });
        putOwed(s, x.account, x.instrument, owedOf(s, x.account, x.instrument) - x.qty);
        [26, x.account, x.qty]
      };
      case (#sealDay(x)) {
        let (rows, hash) = seal(s, x.day);
        Array.concat<Nat>([22, x.day, rows], Array.map<Nat8, Nat>(Blob.toArray(hash), func(b) { Nat8.toNat(b) }))
      };
    }
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
      // the buyer pays p x q out of what it holds at its own price; the difference returns to it
      spendHeld(s, bo.account, i0.cashLedger, bo.price * q);
      credit(s, bo.account, i0.cashLedger, (bo.price - p) * q);
      credit(s, ao.account, i0.cashLedger, p * q);
      spendHeld(s, ao.account, i0.assetLedger, q);
      credit(s, bo.account, i0.assetLedger, q);
      for ((oid, o0) in [(b, bo), (a, ao)].vals()) {
        let held = switch (o0.side) { case (#buy) o0.held - o0.price * q; case (#sell) o0.held - q };
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
    let effects = apply(s, now, c);
    let b = DL.append(s.log, K.codec, now, caller, #executed({ proposal; version; command = c; effects }), null);
    s.lastTime := now;
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
    Fold.section(f, "log", func(w : C.Writer) { w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)) });
    Fold.fingerprintHash(f)
  };
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
    while (left > 0 and run.part < 28) {
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
        case _ { w.text("log"); w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)); run.part := 28 };
      };
      run.digest.writeArray(w.toArray());
      left -= 1;
    };
    if (run.part >= 28) #done(run.digest.sum()) else #more(run.part)
  };
  public type Counts = { orders : Nat; balances : Nat; refs : Nat; blocks : Nat };
  public func counts(s : State) : Counts { { orders = RS.size(s.orderRows); balances = RS.size(s.balanceRows); refs = RS.size(s.refRows); blocks = DL.length(s.log) } };
  public func counters(s : State) : [Nat] { [s.nextOrder, s.nextBalance, s.nextRef, Nat64.toNat(s.batchTime), s.dueCount, Nat64.toNat(s.lastTime), s.nextKill, s.nextLimit] };
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
