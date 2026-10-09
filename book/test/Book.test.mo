// Book.test.mo: the continuous book (book/SPEC.md) on the exchange's foundation. Every command the battery gives a book
// is printed with the chain's time, the role that gave it and the outcome; at checkpoints every block of the book's log,
// every order and every balance. The Python reference book (`book/integration/reference_book.py`, run by
// `book/test/Book.verify.sh`) replays every stream from the commands alone with its own code and requires every
// outcome, every block, every order and every balance equal.
//
// What is proved:
//   * the catalogue in both directions with a control; the single acts' reasons; every command round-tripped and
//     hashed twice; the row widths; an unknown family or vocabulary byte is a decode fault;
//   * every refusal by name, each leaving every row count, every id counter, the log's length and the fingerprint where
//     they were;
//   * scenarios with values computed by hand: a cross at one price, priority by batch, pro rata in lots, fill-or-kill,
//     market collars, stops, one-cancels-other, icebergs, self-trade at entry and at a stop's trigger, a closed
//     instrument, amendments, the day's and the dated sweeps;
//   * random streams, each on a fresh book, with properties checked as they run: no pair of one account, every pair at
//     the clear's price within both limits, every open book uncrossed after its clear, funds conserved per ledger and
//     every account's held funds equal to what its open orders hold;
//   * the order of arrival inside a block changes nothing for orders of different accounts (§1): the same block in
//     two orders on two fresh books, every outcome compared by the member's reference;
//   * the replay of every book's log reproduces its fingerprint; compaction of the book index changes no read.
//
// engine: Region (the row stores and the log live in stable memory).


import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";
import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";
import DL "mo:kernel/domain/DomainLog";
import Perm "mo:kernel/auth/Permissions";
import Auth "mo:kernel/auth/AuthTypes";
import CivilDate "mo:kernel/num/CivilDate";
import RS "mo:kernel/rows/RowStore";
import Page "mo:kernel/rows/Page";
import XT "../../exchange/src/ExchangeTypes";
import X "../../exchange/src/ExchangeCore";
import XText "../../exchange/src/ExchangeText";
import T "../src/BookTypes";
import L "../src/BookLogic";
import K "../src/BookCanonical";
import B "../src/BookCore";
import TR "../../custody/test/support/Transcript";
import W "support/World";

let w = W.World(true);
let { act; advance; govern; avail; bytes; cancel; cash; check; checkpoint; clearer; clientRef; day; depRef; deposit; depository; depthText; egxBands; executes; lastClear; lim; n; newRun; operator; order; pick; placed; printCoverage; randomStream; refusedAs; replayed; rnd; scheduler; seen; seenCount; settle; sharesA; sharesB; sharesC; sharesD; status; stranger; t1; t2; t3; t4; tick; today; uncrossed; xs } = w;

// ─── PART 1: the catalogue, the encoding ─────────────────────────────────────────────────────
let cat = B.catalogue();
let report = Perm.validate(cat, B.commandNames, B.methodNames);
check(Perm.clean(report), "catalogue validates: " # debug_show(report.faults));
let missingOne = Array.filter<Auth.Permission>(cat, func(p) { p.id != "book.order.amend" });
check(not Perm.clean(Perm.validate(missingOne, B.commandNames, B.methodNames)), "control: a catalogue missing amendOrder fails validation");
for ((id, reason) in B.singleActs().vals()) { switch (Perm.byId(cat, id)) { case (?p) check(not p.dualByDefault and reason.size() > 40, "single act " # id # " has its reason"); case null check(false, "single act " # id # " exists") } };
for (p in cat.vals()) { if (not p.dualByDefault and Text.startsWith(p.id, #text "book.")) check(Array.find<(Text, Text)>(B.singleActs(), func(x) { x.0 == p.id }) != null, "single permission " # p.id # " has its reason recorded") };
check(B.checkSums(), "row widths hold their fields");
check(K.families.size() == 67, "sixty-seven command families");
Debug.print("count: catalogue rows validated in both directions = " # Nat.toText(report.checked));

let sampleCommands : [T.Command] = [
  #openInstrument({ instrument = 1; assetLedger = sharesA; cashLedger = cash; lot = 10; referencePrice = 85_000; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }),
  #setTrading({ instrument = 1; open = true }), #setTrading({ instrument = 1; open = false }), #setReference({ instrument = 1; price = 85_010 }),
  #deposit({ account = 1; member = 1; ledger = cash; amount = 5_000_000; reference = bytes(7, 32) }), #withdraw({ account = 1; member = 1; ledger = sharesA; amount = 10 }),
  #placeOrder({ account = 1; instrument = 1; side = #buy; kind = #limit; qty = 100; price = 85_000; stopPrice = 0; peak = 20; validity = #gtd; gtdDay = 20_514; selfTrade = #cancelResting; capacity = #agency; shortSale = false; clientRef = "c-1"; oco = 0; trail = 0; member = w.memberOf(1); trader = w.traderIdOf(w.traderOf(1)) }),
  #placeOrder({ account = 3; instrument = 1; side = #sell; kind = #trailingStop; qty = 20; price = 0; stopPrice = 84_500; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #principal; shortSale = false; clientRef = "c-3"; oco = 0; trail = 300; member = w.memberOf(3); trader = w.traderIdOf(w.traderOf(3)) }),
  #placeOrder({ account = 2; instrument = 2; side = #sell; kind = #stopLimit; qty = 7; price = 1_990; stopPrice = 1_985; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelBoth; capacity = #principal; shortSale = true; clientRef = "طلب-٢"; oco = 9; trail = 0; member = w.memberOf(2); trader = w.traderIdOf(w.traderOf(2)) }),
  #cancelOrder({ order = 3 }), #amendOrder({ order = 3; qty = 50; price = 84_990 }), #massCancel({ account = 4; member = 1; limit = 100 }), #flush,
  #endOfDay({ limit = 500 }), #expireGtd({ day = 20_514; limit = 50 }), #clear({ time = 1_772_445_600_000_000_000 }),
  #setPhase({ instrument = 1; phase = #auction; endFrom = 1_772_445_600_000_000_000; endTo = 1_772_446_200_000_000_000 }), #setPhase({ instrument = 2; phase = #tradeAtClose; endFrom = 0; endTo = 0 }),
  #uncross({ instrument = 1; next = #continuous }), #halt({ instrument = 1; reason = "pending disclosure" }), #resume({ instrument = 1 }),
  #kill({ member = 2; trader = 0; reason = "the member's risk desk" }), #kill({ member = 2; trader = 3; reason = "a runaway algorithm" }), #killSweep({ kill = 1; limit = 500 }), #sealDay({ day = 20_514 }),
  #setBlackout({ instrument = 1; client = bytes(0x42, 32); until = 0; reason = "a director of the issuer" }), #liftBlackout({ blackout = 1 }),
  #borrow({ account = 4; member = 1; instrument = 1; qty = 100; reference = bytes(9, 32) }), #returnBorrow({ account = 4; member = 1; instrument = 1; qty = 100 }),
  #revive({ kill = 1 }), #setLimits({ member = 1; maxOrderQty = 1_000; maxOrderValue = 90_000_000; creditLimit = 2_000_000_000 }),
  // the central counterparty (SPEC §18 to §21)
  #setClearing({ ccpAccount = 18; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 2; penaltyBps = 50; deadlineCycles = 3; fundBps = 500; fundFloor = 10_000_000 }),
  #setMargin({ instrument = 1; imBps = 1_000 }), #admitClearing({ member = 1; settlementAccount = 1; creditLine = 50_000_000 }), #designateClearing({ account = 6; member = 1 }),
  #postCollateral({ member = 1; amount = 20_000_000 }), #withdrawCollateral({ member = 1; amount = 1 }), #cutCycle({ cycle = 7; settleDay = 20_516 }), #settleCycle({ cycle = 7 }),
  #closeOut({ member = 2; instrument = 2 }), #callFund, #contributeFund({ member = 2; amount = 3 }), #fundSkin({ account = 19; amount = 4_000_000 }),
  #declareDefault({ member = 2; reason = "a missed payment past the deadline" }), #closeDefault({ member = 2 }),
  // fees, statements, reconciliation, market makers (SPEC §22 to §25)
  #setFeeSchedule({ instrument = 1; levies = [{ account = 21; ppm = 125 }, { account = 22; ppm = 50 }, { account = 23; ppm = 25 }] }), #sealStatements({ day = 20_514 }),
  #reconcileMember({ member = 2; day = 20_514; balances = [{ account = 9; ledger = cash; amount = 5_000 }, { account = 10; ledger = sharesA; amount = 30 }] }),
  #registerMaker({ member = 1; instrument = 2; maxSpreadBps = 100; minQty = 50; presenceBps = 5_000; rebateBps = 2_000 }),
  #quote({ account = 3; member = 1; trader = 1; side = { instrument = 2; bidPrice = 1_990; askPrice = 2_000; qty = 100; ref = "q-1" } }),
  #massQuote({ account = 3; member = 1; trader = 1; sides = [{ instrument = 2; bidPrice = 1_990; askPrice = 2_000; qty = 100; ref = "m-2" }, { instrument = 1; bidPrice = 84_990; askPrice = 85_010; qty = 10; ref = "m-1" }] }),
  #settleMakers({ day = 20_514 }),
  // the index and the market-wide breaker (SPEC §26, §27)
  #defineIndex({ index = 1; base = 1_000; capBps = 6_000; haltBps = 1_000; suspendBps = 2_000; constituents = [{ instrument = 1; shares = 1_000_000 }, { instrument = 2; shares = 20_000_000 }] }),
  #reviewIndex({ index = 1; constituents = [{ instrument = 2; shares = 25_000_000 }] }),
  #corporateAction({ instrument = 2; action = #split({ num = 3; den = 2 }); reference = bytes(0x43, 32) }), #corporateAction({ instrument = 1; action = #dividend({ amount = 5_000 }); reference = bytes(0x44, 32) }),
  #tripBreaker({ index = 1 }),
  // the instrument classes (SPEC §28 to §32)
  #setTerms({ instrument = 5; terms = #bond({ couponBps = 1_850; perYear = 2; basis = #act365; maturity = 21_564; settleDays = 1 }) }),
  #setTerms({ instrument = 7; terms = #receipt({ warehouses = [3, 7] }) }), #setTerms({ instrument = 8; terms = #certificate({ registry = bytes(0x20, 32) }) }),
  #setTerms({ instrument = 9; terms = #right({ underlying = 1; price = 70_000; num = 1; den = 5; deadline = 20_516; issuer = 9; issuerMember = 2 }) }),
  #setTerms({ instrument = 10; terms = #bond({ couponBps = 1_175; perYear = 1; basis = #thirty360; maturity = 22_157; settleDays = 1 }) }),
  #setTerms({ instrument = 11; terms = #bond({ couponBps = 2_000; perYear = 4; basis = #actActIcma; maturity = 21_335; settleDays = 0 }) }),
  #defineNav({ instrument = 6; units = 1_000; cash = 500_500; basket = [{ instrument = 1; shares = 100 }, { instrument = 2; shares = 2_000 }] }),
  #issueReceipt({ warehouse = 3; instrument = 7; account = 10; member = 2; qty = 50; reference = bytes(0x10, 32) }), #cancelReceipt({ receipt = 1; account = 2; member = 1 }),
  #retire({ account = 10; member = 2; trader = 3; instrument = 8; qty = 40; beneficiary = bytes(0x21, 32) }),
  #exercise({ account = 2; member = 1; trader = 1; instrument = 9; qty = 120 }), #valueDate({ instrument = 5; day = 20_515 }),
  // derivatives (SPEC §33 to §35)
  #setTerms({ instrument = 12; terms = #future({ index = 1; multiplier = 10; expiry = 20_517; imBps = 1_000 }) }),
  #setTerms({ instrument = 13; terms = #option({ index = 1; strike = 100_000; call = true; multiplier = 10; expiry = 20_517; aBps = 1_500; bBps = 1_000 }) }),
  #setAttestors({ attestors = [w.at1, w.at2, w.at3] }), #attestPrice({ attestor = 2; instrument = 12; day = 20_514; price = 101_200 }),
  #settleDerivatives({ instrument = 12; day = 20_514; limit = 500 }),
  // the cash leg's bridge (SPEC §36)
  #registerBridge({ ledger = w.claimsL; rtgs = w.rtgs }), #earmark({ ledger = w.claimsL; account = 2; member = 1; amount = 2_000_000; reference = bytes(0x10, 32) }),
  #redeem({ account = 10; member = 2; trader = 3; ledger = w.claimsL; amount = 850_000 }),
  #rtgsSettle({ redemption = 2; reference = bytes(0x22, 32) }), #rtgsReject({ redemption = 1; reference = bytes(0x20, 32) }),
  // the cancel/replace (SPEC §37)
  #replaceOrder({ order = 3; qty = 20; price = 84_990; clientRef = "طلب-٣" }),
];
var roundTrips = 0;
for (c in sampleCommands.vals()) {
  let ?bs = E.bytesAt(K.registry, 1 : Nat8, c) else { check(false, "encodes " # K.familyOf(c)); continue };
  let ?back = E.readAt(K.registry, 1 : Nat8, C.Reader(Blob.toArray(bs))) else { check(false, "decodes " # K.familyOf(c)); continue };
  check(back == c, "round trip " # K.familyOf(c));
  let ?h1 = E.hashAt(K.registry, 1 : Nat8, c) else { check(false, "hashes"); continue };
  let ?h2 = E.hashAt(K.registry, 1 : Nat8, back) else { check(false, "hashes twice"); continue };
  check(h1 == h2, "hash stable " # K.familyOf(c));
  roundTrips += 1;
};
var familiesCovered = 0;
for (f in K.families.vals()) { if (Array.find<T.Command>(sampleCommands, func(c) { K.familyOf(c) == f }) != null) familiesCovered += 1 };
check(familiesCovered == K.families.size(), "every family has a sample command");
check(E.readAt(K.registry, 1 : Nat8, C.Reader([14 : Nat8])) == null, "an unknown family tag is a decode fault");
check(E.readAt(K.registry, 1 : Nat8, C.Reader([48 : Nat8])) == null and E.readAt(K.registry, 1 : Nat8, C.Reader([36 : Nat8])) != null, "tag 48 is past the last family; 36 is the fund's call");
check(K.phaseOf(7) == null and K.sideOf(3) == null and K.kindOf(8) == null and K.validityOf(0) == null and K.selfTradeOf(4) == null and K.statusOf(5) == null and K.capacityOf(3) == null, "an unknown vocabulary byte decodes to nothing");
Debug.print("count: commands round-tripped through encoding v1 = " # Nat.toText(roundTrips));

let m = newRun(true);
for (a in Nat.range(1, 17)) { ignore tick(); deposit(m, a, cash, 500_000_000); deposit(m, a, sharesA, 5_000); deposit(m, a, sharesB, 500) };
ignore tick();
// who may act
refusedAs(m, stranger, lim(1, 1, #buy, 10, 85_000, "x"), "a:NoGrant", "a stranger places an order");
refusedAs(m, t1, #clear({ time = w.now }), "a:NoGrant", "a trader submits a clear");
refusedAs(m, clearer, #clear({ time = w.now }), "e:ClearNotSubmittable", "even a principal granted the clear cannot submit one");
refusedAs(m, scheduler, lim(1, 1, #buy, 10, 85_000, "x"), "a:NoGrant", "the scheduler places an order");
// the instruments
refusedAs(m, operator, #openInstrument({ instrument = 1; assetLedger = sharesA; cashLedger = cash; lot = 10; referencePrice = 85_000; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InstrumentOpenAlready", "an instrument opened twice");
refusedAs(m, operator, #openInstrument({ instrument = 3; assetLedger = sharesC; cashLedger = cash; lot = 1; referencePrice = 50_000; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:UnknownInstrument", "a delisted instrument opened");
refusedAs(m, operator, #openInstrument({ instrument = 9; assetLedger = sharesC; cashLedger = cash; lot = 1; referencePrice = 50_000; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:UnknownInstrument", "an instrument the exchange never listed");
refusedAs(m, operator, #openInstrument({ instrument = 4; assetLedger = sharesC; cashLedger = cash; lot = 5; referencePrice = 12_340; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InstrumentMismatch", "an opening naming another asset ledger");
refusedAs(m, operator, #openInstrument({ instrument = 4; assetLedger = sharesD; cashLedger = sharesA; lot = 5; referencePrice = 12_340; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InstrumentMismatch", "an opening naming another cash ledger");
refusedAs(m, operator, #openInstrument({ instrument = 4; assetLedger = sharesD; cashLedger = cash; lot = 10; referencePrice = 12_340; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InstrumentMismatch", "an opening naming another lot");
refusedAs(m, operator, #openInstrument({ instrument = 4; assetLedger = sharesD; cashLedger = cash; lot = 5; referencePrice = 12_340; bands = [{ fromPrice = 0; tick = 1 }]; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InstrumentMismatch", "an opening naming other bands");
refusedAs(m, operator, #openInstrument({ instrument = 4; assetLedger = sharesD; cashLedger = cash; lot = 5; referencePrice = 12_340; bands = egxBands; collarBps = 0; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InvalidTerms", "a collar of nothing");
refusedAs(m, operator, #openInstrument({ instrument = 4; assetLedger = sharesD; cashLedger = cash; lot = 5; referencePrice = 12_340; bands = egxBands; collarBps = 10_000; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InvalidTerms", "a collar of the whole price");
refusedAs(m, operator, #openInstrument({ instrument = 4; assetLedger = sharesD; cashLedger = cash; lot = 5; referencePrice = 12_350; bands = egxBands; collarBps = 500; staticBps = 2_000; dynamicBps = 0; interruptSecs = 600 }), "e:InstrumentMismatch", "an opening with a reference other than the exchange's (the first day's, SPEC §12)");
refusedAs(m, scheduler, #setTrading({ instrument = 9; open = true }), "e:UnknownInstrument", "trading an instrument the book does not hold");
refusedAs(m, scheduler, #setTrading({ instrument = 1; open = false }), "e:InvalidTerms", "closing a closed instrument");
refusedAs(m, scheduler, #setReference({ instrument = 1; price = 85_005 }), "e:PriceOffTick", "a reference off the 0.01 tick");
refusedAs(m, scheduler, #setReference({ instrument = 7; price = 85_000 }), "e:UnknownInstrument", "a reference for no instrument");
// funds
refusedAs(m, depository, #deposit({ account = 18; member = 2; ledger = cash; amount = 1; reference = depRef(900_001) }), "e:UnknownAccount", "a deposit to no account");
refusedAs(m, depository, #deposit({ account = 1; member = 1; ledger = cash; amount = 0; reference = depRef(900_002) }), "e:InvalidTerms", "a deposit of nothing");
refusedAs(m, depository, #deposit({ account = 1; member = 1; ledger = cash; amount = 1; reference = bytes(3, 31) }), "e:InvalidTerms", "a reference of 31 bytes");
refusedAs(m, depository, #deposit({ account = 2; member = 1; ledger = cash; amount = 9; reference = depRef(1_000_001) }), "e:DuplicateReference", "a transfer attested twice");
refusedAs(m, depository, #deposit({ account = 9; member = 1; ledger = cash; amount = 9; reference = depRef(900_003) }), "e:InvalidTerms", "a deposit naming another member than the account's");
refusedAs(m, t3, #withdraw({ account = 1; member = 1; ledger = cash; amount = 1 }), "e:NotYourAccount", "a withdrawal from another member's account");
refusedAs(m, t4, #withdraw({ account = 9; member = 2; ledger = cash; amount = 1 }), "e:NotYourAccount", "a revoked trader withdraws");
refusedAs(m, t3, #withdraw({ account = 17; member = 2; ledger = cash; amount = 1 }), "e:AccountClosed", "a withdrawal from a closed account");
refusedAs(m, t3, #withdraw({ account = 18; member = 2; ledger = cash; amount = 1 }), "e:UnknownAccount", "a withdrawal from no account");
refusedAs(m, t1, #withdraw({ account = 1; member = 1; ledger = cash; amount = 0 }), "e:InvalidTerms", "a withdrawal of nothing");
refusedAs(m, t1, #withdraw({ account = 1; member = 1; ledger = cash; amount = 500_000_001 }), "e:InsufficientFunds", "a withdrawal beyond the available");
ignore tick();
refusedAs(m, t1, #withdraw({ account = 1; member = 2; ledger = cash; amount = 1 }), "e:InvalidTerms", "a withdrawal naming another member than the account's");
check(executes(m, t1, #withdraw({ account = 1; member = 1; ledger = cash; amount = 1_000 }), "withdraw") == [5, 1, 1_000], "a withdrawal within the available");
check(avail(m, 1, cash) == 499_999_000, "the withdrawal left the account");
// orders
refusedAs(m, t2, lim(1, 1, #buy, 10, 85_000, "x"), "e:MayNotTrade", "a trader without the segment's right");
refusedAs(m, t1, lim(1, 3, #buy, 10, 50_000, "x"), "e:MayNotTrade", "a delisted instrument");
refusedAs(m, t1, lim(1, 4, #buy, 10, 12_340, "x"), "e:UnknownInstrument", "an instrument the book has not opened");
refusedAs(m, t1, lim(1, 1, #buy, 15, 85_000, "x"), "e:NotALot", "a quantity off the lot");
refusedAs(m, t1, order(1, 1, #buy, #limit, 100, 85_000, 0, 15, #gtc, 0, #cancelResting, "x", 0), "e:NotALot", "a peak off the lot");
refusedAs(m, t1, order(1, 1, #buy, #limit, 100, 85_000, 0, 100, #gtc, 0, #cancelResting, "x", 0), "e:NotALot", "a peak of the whole order");
refusedAs(m, t1, lim(1, 1, #buy, 10, 85_000, ""), "e:InvalidTerms", "an empty client reference");
refusedAs(m, t1, lim(1, 1, #buy, 10, 85_000, "abcdefghijklmnopqrstu"), "e:InvalidTerms", "a client reference of 21 bytes");
refusedAs(m, t1, order(1, 1, #buy, #market, 10, 85_000, 0, 0, #day, 0, #cancelResting, "x", 0), "e:InvalidPrice", "a market order naming a price");
refusedAs(m, t1, order(1, 1, #buy, #stop, 10, 85_000, 85_100, 0, #day, 0, #cancelResting, "x", 0), "e:InvalidPrice", "a stop naming a limit");
refusedAs(m, t1, order(1, 1, #buy, #stop, 10, 0, 85_105, 0, #day, 0, #cancelResting, "x", 0), "e:PriceOffTick", "a stop price off the tick");
refusedAs(m, t1, order(1, 1, #buy, #stopLimit, 10, 85_101, 85_100, 0, #gtc, 0, #cancelResting, "x", 0), "e:PriceOffTick", "a stop-limit's limit off the tick");
refusedAs(m, t1, order(1, 1, #buy, #limit, 10, 85_000, 85_100, 0, #gtc, 0, #cancelResting, "x", 0), "e:InvalidPrice", "a limit naming a stop price");
refusedAs(m, t1, lim(1, 1, #buy, 10, 85_005, "x"), "e:PriceOffTick", "a limit off the 0.01 tick");
refusedAs(m, t1, lim(1, 2, #buy, 1, 2_005, "x"), "e:PriceOffTick", "a price above 2.00 off its band's tick");
refusedAs(m, t1, order(1, 1, #buy, #ioc, 10, 85_000, 0, 0, #gtc, 0, #cancelResting, "x", 0), "e:InvalidTerms", "an immediate order good till cancelled");
refusedAs(m, t1, order(1, 1, #buy, #ioc, 100, 85_000, 0, 10, #day, 0, #cancelResting, "x", 0), "e:InvalidTerms", "an immediate iceberg");
refusedAs(m, t1, order(1, 1, #buy, #limit, 10, 85_000, 0, 0, #gtd, today() - 1, #cancelResting, "x", 0), "e:NotTheChainsDay", "a date already past");
refusedAs(m, t1, order(1, 1, #buy, #limit, 10, 85_000, 0, 0, #gtc, today(), #cancelResting, "x", 0), "e:InvalidTerms", "a date on an order not good till a date");
refusedAs(m, t1, order(1, 1, #buy, #limit, 10, 85_000, 0, 0, #gtc, 0, #cancelResting, "x", 999), "e:InvalidOco", "a link to no order");
refusedAs(m, t1, lim(1, 1, #buy, 10_000, 85_000, "x"), "e:InsufficientFunds", "a buy beyond the cash");
refusedAs(m, t1, lim(1, 1, #sell, 5_010, 85_000, "x"), "e:ShortSaleNotFlagged", "a sell beyond the shares, not flagged short (SPEC §17)");
refusedAs(m, t1, switch (lim(1, 1, #sell, 5_010, 86_000, "x")) { case (#placeOrder(o)) #placeOrder({ o with shortSale = true }); case (c) c }, "e:InsufficientFunds", "a short sale with no shares to deliver");
ignore tick();
let r1 = placed(m, lim(1, 1, #buy, 100, 84_000, "r1"));
let r2 = placed(m, lim(2, 1, #sell, 100, 86_000, "r2"));
check(r1 == 1 and r2 == 2 and status(m, r1) == ?#live, "two resting orders");
check(B.balance(m.st, 1, cash).held == 8_400_000, "a buy holds its price times its quantity");
refusedAs(m, t1, lim(1, 1, #buy, 10, 84_000, "r1"), "e:DuplicateClientRef", "a client reference twice");
refusedAs(m, t1, order(1, 1, #sell, #limit, 10, 84_000, 0, 0, #gtc, 0, #cancelIncoming, "x", 0), "e:SelfTradePrevented", "a sell crossing the account's own buy");
refusedAs(m, t1, order(1, 1, #sell, #limit, 10, 87_000, 0, 0, #gtc, 0, #cancelResting, "x", r2), "e:InvalidOco", "a link to another account's order");
refusedAs(m, t3, #cancelOrder({ order = r1 }), "e:NotYourOrder", "a cancel of another member's order");
refusedAs(m, t1, #cancelOrder({ order = 999 }), "e:UnknownOrder", "a cancel of no order");
refusedAs(m, t1, #amendOrder({ order = r1; qty = 100; price = 84_000 }), "e:InvalidTerms", "an amendment changing nothing");
refusedAs(m, t1, #amendOrder({ order = r1; qty = 105; price = 84_000 }), "e:NotALot", "an amendment off the lot");
refusedAs(m, t1, #amendOrder({ order = r1; qty = 100; price = 84_005 }), "e:PriceOffTick", "an amendment off the tick");
refusedAs(m, t1, #amendOrder({ order = r1; qty = 10_000; price = 84_000 }), "e:InsufficientFunds", "an amendment beyond the cash");
let r5 = placed(m, lim(1, 1, #sell, 10, 86_000, "r5"));
refusedAs(m, t1, #amendOrder({ order = r1; qty = 100; price = 86_000 }), "e:SelfTradePrevented", "an amendment crossing the account's own sell");
let r3 = placed(m, order(1, 1, #buy, #stop, 10, 0, 86_500, 0, #day, 0, #cancelResting, "r3", 0));
check(status(m, r3) == ?#waiting, "a stop waits");
refusedAs(m, t1, #amendOrder({ order = r3; qty = 20; price = 86_000 }), "e:InvalidTerms", "an amendment of a stop");
let r4 = placed(m, order(1, 1, #buy, #limit, 100, 83_000, 0, 20, #gtc, 0, #cancelResting, "r4", 0));
refusedAs(m, t1, #amendOrder({ order = r4; qty = 20; price = 83_000 }), "e:NotALot", "an iceberg amended to its peak");
check(executes(m, t1, #cancelOrder({ order = r4 }), "cancel") == [7, r4], "a cancel");
refusedAs(m, t1, #cancelOrder({ order = r4 }), "e:OrderClosed", "a cancel of a cancelled order");
refusedAs(m, t3, #massCancel({ account = 1; member = 1; limit = 10 }), "e:NotYourAccount", "a mass cancel of another member's account");
refusedAs(m, scheduler, #expireGtd({ day = today() + 1; limit = 10 }), "e:NotTheChainsDay", "an expiry for a day that is not the chain's");
// the orders so far, closed: nothing is due, so a flush finds nothing
check(executes(m, t1, #massCancel({ account = 1; member = 1; limit = 500 }), "mass cancel") == [9, 3, r3, r1, r5], "the account's open orders cancelled, in the book's order: buys from the highest (the stop at its collar price) then sells");
check(executes(m, t1, #massCancel({ account = 2; member = 1; limit = 500 }), "mass cancel") == [9, 1, r2], "account 2's order cancelled");
// the batch of those orders clears when the time moves (instrument 1 closed: nothing trades), and then nothing waits
ignore tick();
refusedAs(m, scheduler, #flush, "e:NothingToClear", "a flush with no batch waiting");
check(B.balance(m.st, 1, cash).held == 0 and B.balance(m.st, 2, sharesA).held == 0, "the cancels returned what the orders held");
Debug.print("count: refusals that left every dimension where it was = " # n(w.refusalsUnmoved));

// the scenarios: every expected effect computed by hand from the specification
var scenarios = 0;
func scenario(ok : Bool, what : Text) { check(ok, what); if (ok) scenarios += 1 };
ignore tick();
check(executes(m, scheduler, #setTrading({ instrument = 1; open = true }), "open 1") == [2, 1], "instrument 1 open for clearing");
check(executes(m, scheduler, #setTrading({ instrument = 2; open = true }), "open 2") == [2, 2], "instrument 2 open for clearing");
// a cross: buy 100 at 85.000 against sell 100 at 84.990; both prices execute 100 with no imbalance, so the lower
ignore tick();
let c1 = avail(m, 1, cash); let c9 = avail(m, 9, cash); let a1 = avail(m, 1, sharesA); let a9 = avail(m, 9, sharesA);
let s1b = placed(m, lim(1, 1, #buy, 100, 85_000, "s1b"));
let s1s = placed(m, lim(9, 1, #sell, 100, 84_990, "s1s"));
settle(m);
scenario(lastClear(m) == [13, 1, 84_990, 100, 1, s1b, s1s, 100, 0, 0, 0, 0], "one price for the batch: " # debug_show(lastClear(m)));
scenario(avail(m, 1, cash) == c1 - 8_499_000 and avail(m, 9, cash) == c9 + 8_499_000 and avail(m, 1, sharesA) == a1 + 100 and avail(m, 9, sharesA) == a9 - 100, "the buyer pays the clear's price, the difference to its limit returned");
scenario(status(m, s1b) == ?#filled and status(m, s1s) == ?#filled, "both filled");
// priority by batch: two sells at one price in two batches; the buy takes the earlier
ignore tick(); let s2a = placed(m, lim(9, 1, #sell, 100, 85_000, "s2a"));
ignore tick(); let s2b = placed(m, lim(10, 1, #sell, 100, 85_000, "s2b"));
ignore tick(); let s2c = placed(m, lim(1, 1, #buy, 100, 85_000, "s2c"));
settle(m);
scenario(lastClear(m) == [13, 1, 85_000, 100, 1, s2c, s2a, 100, 0, 0, 0, 0] and status(m, s2b) == ?#live, "the earlier batch fills first");
cancel(m, s2b);
// pro rata in lots: three sells of one lot in one batch, a buy of two lots: two lots go by the largest remainders
// (all equal), ties by key: the sell with the greatest key gets nothing
ignore tick();
let p1 = placed(m, lim(9, 1, #sell, 10, 85_000, "s3a")); let p2 = placed(m, lim(10, 1, #sell, 10, 85_000, "s3b")); let p3 = placed(m, lim(11, 1, #sell, 10, 85_000, "s3c"));
let pb = placed(m, lim(1, 1, #buy, 20, 85_000, "s3d"));
settle(m);
let keys = [(p1, K.orderKey(9, #sell, 85_000, 10, "s3a")), (p2, K.orderKey(10, #sell, 85_000, 10, "s3b")), (p3, K.orderKey(11, #sell, 85_000, 10, "s3c"))];
var greatest = keys[0]; for (k in keys.vals()) { if (Blob.compare(k.1, greatest.1) == #greater) greatest := k };
var proRataOk = status(m, pb) == ?#filled and lastClear(m)[3] == 20;
for ((id, _) in keys.vals()) { proRataOk := proRataOk and (if (id == greatest.0) status(m, id) == ?#live else status(m, id) == ?#filled) };
scenario(proRataOk, "pro rata: the two smaller keys fill");
cancel(m, greatest.0);
// fill-or-kill: a buy of 200 against 100 offered is removed and nothing trades
ignore tick();
let f1 = placed(m, lim(9, 1, #sell, 100, 85_000, "s4a"));
let f2 = placed(m, order(1, 1, #buy, #fok, 200, 85_000, 0, 0, #day, 0, #cancelResting, "s4b", 0));
settle(m);
scenario(lastClear(m) == [13, 1, 0, 0, 0, 1, f2, 0, 0, 0] and status(m, f1) == ?#live and B.balance(m.st, 1, cash).held == 0, "fill-or-kill removed, nothing traded");
cancel(m, f1);
// a market buy at its collar: 85.000 x 1.05 = 89.250, on the 0.01 tick; it holds 10 x 89.250 and pays 86.000
ignore tick();
let ms = placed(m, lim(10, 1, #sell, 10, 86_000, "s5a"));
let mb = placed(m, order(2, 1, #buy, #market, 10, 0, 0, 0, #day, 0, #cancelResting, "s5b", 0));
scenario((switch (B.order(m.st, mb)) { case (?o) o.price == 89_250 and o.held == 892_500; case null false }), "the market order's collar price and holding");
let c2 = avail(m, 2, cash);
settle(m);
scenario(lastClear(m) == [13, 1, 86_000, 10, 1, mb, ms, 10, 0, 0, 0, 0] and avail(m, 2, cash) == c2 + 32_500, "the market order trades at the clear's price, the rest of its holding returned");
// a stop-limit triggered by a clear's price is judged for self-trade then: its cancel-resting instruction cancels the
// account's own sell it w.now crosses
ignore tick();
let s6r = placed(m, lim(2, 1, #sell, 10, 86_150, "s6r"));
let s6s = placed(m, order(2, 1, #buy, #stopLimit, 10, 86_200, 86_100, 0, #gtc, 0, #cancelResting, "s6s", 0));
let s6b = placed(m, lim(9, 1, #buy, 10, 86_100, "s6b")); let s6c = placed(m, lim(10, 1, #sell, 10, 86_100, "s6c"));
settle(m);
scenario(lastClear(m) == [13, 1, 86_100, 10, 1, s6b, s6c, 10, 0, 0, 0, 0] and status(m, s6s) == ?#waiting, "the trade at 86.100; the stop waits for the next clear");
settle(m);
scenario(lastClear(m) == [13, 1, 0, 0, 0, 1, s6r, 1, s6s, 1, 86_200, 10, 0, 0] and status(m, s6r) == ?#cancelled and status(m, s6s) == ?#live, "triggered, the stop cancels the account's own crossing sell");
cancel(m, s6s);
// one-cancels-other: the limit sell fills, its linked stop is cancelled in the same clear
ignore tick();
let o1 = placed(m, lim(3, 1, #sell, 10, 86_000, "s7l"));
let o2 = placed(m, order(3, 1, #sell, #stop, 10, 0, 84_000, 0, #day, 0, #cancelResting, "s7s", o1));
scenario((switch (B.order(m.st, o1)) { case (?o) o.oco == o2; case null false }), "the pair linked both ways");
let o3 = placed(m, lim(9, 1, #buy, 10, 86_000, "s7b"));
settle(m);
scenario(lastClear(m) == [13, 1, 86_000, 10, 1, o3, o1, 10, 1, o2, 0, 0, 0] and status(m, o2) == ?#cancelled, "the fill cancels the linked stop");
// an iceberg: its whole peak filled, it takes the clear's batch as its priority, behind an order entered after it
ignore tick(); let ice = placed(m, order(4, 1, #sell, #limit, 50, 85_500, 0, 10, #gtc, 0, #cancelResting, "s8i", 0));
ignore tick(); let pl = placed(m, lim(5, 1, #sell, 10, 85_500, "s8p"));
ignore tick(); let b1 = placed(m, lim(9, 1, #buy, 10, 85_500, "s8b1"));
let tb1 = w.now;
settle(m);
scenario(lastClear(m) == [13, 1, 85_500, 10, 1, b1, ice, 10, 0, 0, 1, ice, 10, 0] and (switch (B.order(m.st, ice)) { case (?o) o.remaining == 40 and o.prio == tb1; case null false }), "the iceberg fills its peak first and its priority moves to that batch");
ignore tick(); let b2 = placed(m, lim(9, 1, #buy, 10, 85_500, "s8b2"));
settle(m);
scenario(lastClear(m) == [13, 1, 85_500, 10, 1, b2, pl, 10, 0, 0, 0, 0], "the plain order now ahead of the refreshed iceberg");
cancel(m, ice);
// a closed instrument: nothing trades, the immediate order ends, the resting ones wait and trade when it opens
ignore tick(); ignore executes(m, scheduler, #setTrading({ instrument = 2; open = false }), "close 2");
ignore tick();
let q1 = placed(m, lim(9, 2, #sell, 1, 1_990, "s9s")); let q2 = placed(m, lim(1, 2, #buy, 1, 1_995, "s9b"));
let q3 = placed(m, order(2, 2, #buy, #ioc, 1, 1_995, 0, 0, #day, 0, #cancelResting, "s9i", 0));
settle(m);
scenario(lastClear(m) == [13, 2, 0, 0, 0, 1, q3, 0, 0, 0] and status(m, q1) == ?#live and status(m, q2) == ?#live, "closed: the immediate order cancelled, the limits wait");
ignore tick(); ignore executes(m, scheduler, #setTrading({ instrument = 2; open = true }), "open 2");
settle(m);
scenario(lastClear(m) == [13, 2, 1_990, 1, 1, q2, q1, 1, 0, 0, 0, 0], "open again: the waiting orders trade");
// amendments: a smaller quantity at the same price keeps the priority, a new price takes the batch's
ignore tick(); let am = placed(m, lim(1, 1, #buy, 100, 84_000, "s10")); let pa = switch (B.order(m.st, am)) { case (?o) o.prio; case null 0 };
ignore tick();
scenario(executes(m, t1, #amendOrder({ order = am; qty = 50; price = 84_000 }), "amend") == [8, am, 1, 50] and (switch (B.order(m.st, am)) { case (?o) o.prio == pa and o.held == 4_200_000; case null false }), "a smaller quantity keeps the priority, the rest of the holding returned");
ignore tick();
scenario(executes(m, t1, #amendOrder({ order = am; qty = 60; price = 84_000 }), "amend") == [8, am, 0, 60] and (switch (B.order(m.st, am)) { case (?o) o.prio == w.now; case null false }), "a larger quantity at the same price takes the batch's priority");
ignore tick();
scenario(executes(m, t1, #amendOrder({ order = am; qty = 50; price = 84_010 }), "amend") == [8, am, 0, 50] and (switch (B.order(m.st, am)) { case (?o) o.prio == w.now; case null false }), "a new price takes the batch's priority");
cancel(m, am);
// the sweeps: the day's orders after the close; dated orders past their day
ignore tick();
let d1 = placed(m, order(1, 1, #buy, #limit, 10, 80_000, 0, 0, #day, 0, #cancelResting, "s11d", 0));
let g1 = placed(m, order(2, 1, #buy, #limit, 10, 80_000, 0, 0, #gtd, today(), #cancelResting, "s11g", 0));
let g2 = placed(m, order(3, 1, #buy, #limit, 10, 80_000, 0, 0, #gtd, today() + 1, #cancelResting, "s11h", 0));
ignore tick();
scenario(executes(m, scheduler, #endOfDay({ limit = 500 }), "end of day") == [11, 1, d1], "the end of day cancels the day's order");
advance(86_400);
scenario(executes(m, scheduler, #expireGtd({ day = today(); limit = 500 }), "expire") == [12, 1, g1] and status(m, g2) == ?#live, "the expiry cancels the order dated yesterday, not today's");
cancel(m, g2);
// the day's sweep across pages: 150 day orders, more than one page of the index, all cancelled by one sweep
ignore tick();
var dayOrders = 0;
for (k in Nat.range(0, 150)) { if (placed(m, order(1 + k % 8, 1, #buy, #limit, 10, 80_000 - 10 * (k / 8), 0, 0, #day, 0, #cancelResting, "s13-" # n(k), 0)) > 0) dayOrders += 1 };
ignore tick();
let eod = executes(m, scheduler, #endOfDay({ limit = 500 }), "end of day");
scenario(dayOrders == 150 and eod.size() == 152 and eod[1] == 150, "the end of day sweeps all 150 day orders across pages");
// a trailing stop: a sell trailing 3.00 below the price, from a stop of 84.000; a trade at 86.000 moves it to 85.700, a
// trade at 85.600 does not move it and reaches it, so it triggers at the next clear: a market sell with no buyer, ended
let ts = placed(m, #placeOrder({ account = 4; instrument = 1; side = #sell; kind = #trailingStop; qty = 10; price = 0; stopPrice = 84_000; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #principal; shortSale = false; clientRef = "s12t"; oco = 0; trail = 300; member = w.memberOf(4); trader = w.traderIdOf(w.traderOf(4)) }));
ignore tick(); ignore placed(m, lim(9, 1, #buy, 10, 86_000, "s12a")); ignore placed(m, lim(10, 1, #sell, 10, 86_000, "s12b"));
settle(m);
scenario((switch (B.order(m.st, ts)) { case (?o) o.stopPrice == 85_700 and o.status == #waiting; case null false }), "the trade at 86.000 moves the trailing stop to 85.700");
ignore tick(); ignore placed(m, lim(9, 1, #buy, 10, 85_600, "s12c")); ignore placed(m, lim(10, 1, #sell, 10, 85_600, "s12d"));
settle(m);
scenario((switch (B.order(m.st, ts)) { case (?o) o.stopPrice == 85_700 and o.status == #waiting; case null false }), "a lower trade does not move it");
settle(m);
scenario(lastClear(m) == [13, 1, 0, 0, 0, 1, ts, 1, ts, 2, 80_750, 10, 0, 0] and status(m, ts) == ?#cancelled, "reached, it triggers at the next clear and ends unfilled: " # debug_show(lastClear(m)));
refusedAs(m, t1, #placeOrder({ account = 4; instrument = 1; side = #sell; kind = #trailingStop; qty = 10; price = 0; stopPrice = 84_000; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #agency; shortSale = false; clientRef = "s12x"; oco = 0; trail = 305; member = w.memberOf(4); trader = w.traderIdOf(w.traderOf(4)) }), "e:InvalidPrice", "a trail off the tick");
refusedAs(m, t1, #placeOrder({ account = 4; instrument = 1; side = #sell; kind = #limit; qty = 10; price = 90_000; stopPrice = 0; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #agency; shortSale = false; clientRef = "s12y"; oco = 0; trail = 300; member = w.memberOf(4); trader = w.traderIdOf(w.traderOf(4)) }), "e:InvalidTerms", "a trail on a limit order");
// the cap on trailing stops: an instrument holds 64 per side; the 65th is refused, then the 64 are cancelled
var trailingPlaced = 0;
for (k in Nat.range(0, 64)) { if (placed(m, #placeOrder({ account = 5; instrument = 2; side = #sell; kind = #trailingStop; qty = 1; price = 0; stopPrice = 1_900 - k; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #agency; shortSale = false; clientRef = "s14-" # n(k); oco = 0; trail = 20; member = w.memberOf(5); trader = w.traderIdOf(w.traderOf(5)) })) > 0) trailingPlaced += 1 };
refusedAs(m, t1, #placeOrder({ account = 5; instrument = 2; side = #sell; kind = #trailingStop; qty = 1; price = 0; stopPrice = 1_800; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #agency; shortSale = false; clientRef = "s14-x"; oco = 0; trail = 20; member = w.memberOf(5); trader = w.traderIdOf(w.traderOf(5)) }), "e:TrailingStopsFull", "a 65th trailing stop on one side");
scenario(trailingPlaced == 64 and executes(m, t1, #massCancel({ account = 5; member = 1; limit = 500 }), "mass cancel")[1] == 64, "64 trailing stops held and cancelled");
// ─── Phases, auctions, bands, halts, the kill switch, risk limits (SPEC §8 to §12) ───────
// the opening auction (§9): a buy at 85.700 and a sell at 85.500 execute 100 at either price with no surplus; the rule
// takes the reference (the last price, 85.600), a price no order named
ignore tick(); ignore executes(m, scheduler, #setPhase({ instrument = 1; phase = #auction; endFrom = 0; endTo = 0 }), "auction");
refusedAs(m, t1, order(1, 1, #buy, #ioc, 10, 85_000, 0, 0, #day, 0, #cancelResting, "s15x", 0), "e:InvalidTerms", "no immediate-or-cancel order in an auction");
let ob = placed(m, lim(1, 1, #buy, 100, 85_700, "s15b")); let os = placed(m, lim(9, 1, #sell, 100, 85_500, "s15s"));
settle(m);
scenario(lastClear(m) == [13, 1, 0, 0, 0, 0, 0, 0, 0] and status(m, ob) == ?#live, "in the auction nothing trades");
scenario(B.indicative(m.st, 1) == ?{ price = 85_600; volume = 100; surplus = 0; withinBand = true } and B.indicative(m.st, 2) == null, "the indicative price: 85.600 for 100, no surplus; none for an instrument not in a call phase");
ignore tick();
scenario(executes(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "uncross") == [15, 1, 85_600, 100, 1, ob, os, 100, 0, 0, 2], "the uncross at the reference, 85.600, between the two");
// market pressure: a buy surplus at both prices of the most volume takes the higher
ignore tick(); ignore executes(m, scheduler, #setPhase({ instrument = 1; phase = #auction; endFrom = 0; endTo = 0 }), "auction");
let mpb = placed(m, lim(1, 1, #buy, 300, 85_700, "s15c")); let ps1 = placed(m, lim(9, 1, #sell, 100, 85_500, "s15d")); let ps2 = placed(m, lim(10, 1, #sell, 100, 85_650, "s15e"));
ignore tick();
let u2 = executes(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "uncross");
scenario(u2.size() > 4 and u2[2] == 85_700 and u2[3] == 200 and status(m, ps1) == ?#filled and status(m, ps2) == ?#filled and (switch (B.order(m.st, mpb)) { case (?o) o.remaining == 100; case null false }), "a buy surplus takes the higher price, 85.700");
cancel(m, mpb);
// the closing auction sets the closing price; trade at close then trades at it only
ignore tick(); ignore executes(m, scheduler, #setPhase({ instrument = 1; phase = #closingAuction; endFrom = 0; endTo = 0 }), "closing auction");
let cb = placed(m, lim(2, 1, #buy, 50, 85_800, "s16a")); let cs = placed(m, lim(10, 1, #sell, 50, 85_800, "s16b"));
ignore tick();
scenario(executes(m, scheduler, #uncross({ instrument = 1; next = #tradeAtClose }), "uncross") == [15, 1, 85_800, 50, 1, cb, cs, 50, 0, 0, 5]
  and (switch (B.instrument(m.st, 1)) { case (?x) x.closePrice == 85_800 and x.phase == #tradeAtClose; case null false }), "the closing price 85.800, then trade at close");
ignore tick();
let tb = placed(m, lim(2, 1, #buy, 30, 86_000, "s16c")); let ts1 = placed(m, lim(10, 1, #sell, 30, 85_800, "s16d")); let ts2 = placed(m, lim(11, 1, #sell, 30, 85_700, "s16e"));
settle(m);
scenario(lastClear(m) == [13, 1, 85_800, 30, 1, tb, ts2, 30, 0, 0, 0, 0] and status(m, ts1) == ?#live, "trade at close at 85.800 only, the earlier batch's lower sell first by price");
cancel(m, ts1);
// an uncross outside the static band: the orders entered inside it; the reference then moved to 80.000, whose band
// (64.000 to 96.000) excludes the price the rule fixes (100.000, the lower of the two): nothing trades, the auction goes on
ignore tick(); ignore executes(m, scheduler, #setPhase({ instrument = 1; phase = #auction; endFrom = 0; endTo = 0 }), "auction");
let xb = placed(m, lim(1, 1, #buy, 10, 101_000, "s16f")); let xs9 = placed(m, lim(9, 1, #sell, 10, 100_000, "s16g"));
ignore tick(); ignore executes(m, scheduler, #setReference({ instrument = 1; price = 80_000 }), "reference");
ignore tick();
scenario((switch (B.indicative(m.st, 1)) { case (?v) v.price == 100_000 and not v.withinBand; case null false }), "the indicative price 100.000 lies outside the static band around 80.000");
scenario(executes(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "uncross") == [15, 1, 0, 0, 0, 0, 0, 3]
  and status(m, xb) == ?#live and status(m, xs9) == ?#live, "an uncross outside the static band trades nothing, the auction continuing");
cancel(m, xb); cancel(m, xs9);
ignore tick(); ignore executes(m, scheduler, #setReference({ instrument = 1; price = 85_000 }), "reference");
ignore tick(); ignore executes(m, scheduler, #setPhase({ instrument = 1; phase = #continuous; endFrom = 0; endTo = 0 }), "continuous");
// a volatility interruption (§10): two orders at 100.000 in one batch, the reference moved to 80.000 in the same block;
// the clear's price lies outside the static band, so nothing trades and the instrument goes to an auction for 600 s
ignore tick();
let vb = placed(m, lim(1, 1, #buy, 10, 100_000, "s16h")); let vs = placed(m, lim(9, 1, #sell, 10, 100_000, "s16i"));
ignore executes(m, scheduler, #setReference({ instrument = 1; price = 80_000 }), "reference");
settle(m);
scenario(lastClear(m) == [13, 1, 0, 0, 0, 0, 0, 0, 1] and status(m, vb) == ?#live
  and (switch (B.instrument(m.st, 1)) { case (?x) x.phase == #auction and x.interruptUntil == w.now - 1_000_000_000 + 600_000_000_000; case null false }), "a clear outside the static band interrupts: an auction until 600 s on");
refusedAs(m, scheduler, #setPhase({ instrument = 1; phase = #continuous; endFrom = 0; endTo = 0 }), "e:InvalidTerms", "a phase set during an interruption");
refusedAs(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "e:AuctionNotEnded", "an uncross before the interruption ends");
advance(600);
ignore tick(); ignore executes(m, scheduler, #setReference({ instrument = 1; price = 85_000 }), "reference");
scenario(executes(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "uncross") == [15, 1, 100_000, 10, 1, vb, vs, 10, 0, 0, 2], "the interruption's uncross at 100.000, back to continuous");
// The reference-price rule, surpluses on both sides: 99.800, 99.900 (buy surplus 100), 99.950 and 101.000 (sell surplus
// 100) tie on volume 100 and surplus 100; the reference, the last price 100.000, is held against the highest price with a
// buy surplus and the lowest with a sell surplus (99.900 to 99.950), not the whole range: the price is 99.950
ignore tick(); ignore executes(m, scheduler, #setPhase({ instrument = 1; phase = #auction; endFrom = 0; endTo = 0 }), "auction");
let gtb1 = placed(m, lim(1, 1, #buy, 100, 99_900, "s16j")); let gtb2 = placed(m, lim(2, 1, #buy, 100, 101_000, "s16k"));
let gts9 = placed(m, lim(9, 1, #sell, 50, 99_000, "s16l")); let gts10 = placed(m, lim(10, 1, #sell, 50, 99_800, "s16m")); let gts11 = placed(m, lim(11, 1, #sell, 100, 99_950, "s16n"));
ignore tick();
scenario(B.indicative(m.st, 1) == ?{ price = 99_950; volume = 100; surplus = -100; withinBand = true }, "the indicative price 99.950 for 100, a sell surplus of 100");
let u3 = executes(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "uncross");
scenario(u3.size() > 4 and u3[2] == 99_950 and u3[3] == 100 and status(m, gts9) == ?#filled and status(m, gts10) == ?#filled and status(m, gtb2) == ?#filled
  and status(m, gtb1) == ?#live and status(m, gts11) == ?#live, "surpluses on both sides: the reference held against 99.900 to 99.950, the price 99.950");
cancel(m, gtb1); cancel(m, gts11);
// refusals of the phases and the bands
refusedAs(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "e:NotInAuction", "an uncross in continuous trading");
refusedAs(m, scheduler, #setPhase({ instrument = 1; phase = #continuous; endFrom = 0; endTo = 0 }), "e:InvalidTerms", "a phase the instrument is in");
refusedAs(m, scheduler, #setPhase({ instrument = 1; phase = #tradeAtClose; endFrom = 5; endTo = 9 }), "e:InvalidTerms", "a random end for trade at close");
refusedAs(m, t1, lim(1, 1, #buy, 10, 106_000, "s17x"), "e:PriceOutsideBand", "a buy above the static band (20 per cent of 85.000)");
let an = placed(m, lim(1, 1, #buy, 10, 85_000, "s17a"));
refusedAs(m, t1, #amendOrder({ order = an; qty = 10; price = 60_000 }), "e:PriceOutsideBand", "an amendment below the static band");
cancel(m, an);
ignore tick(); ignore executes(m, scheduler, #setPhase({ instrument = 1; phase = #auction; endFrom = w.now + 10_000_000_000; endTo = w.now + 20_000_000_000 }), "auction with a random end");
refusedAs(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "e:AuctionNotEnded", "an uncross before the random end's window");
advance(11);
scenario(executes(m, scheduler, #uncross({ instrument = 1; next = #continuous }), "uncross") == [15, 1, 0, 0, 0, 0, 0, 2], "an uncross in its window, nothing to trade");
// a halt (four eyes): no order accepted, none amended; a cancel is; the resumption is an auction
let hb = placed(m, lim(9, 2, #buy, 5, 1_990, "s18a"));
ignore tick();
scenario(govern(m, #halt({ instrument = 2; reason = "pending disclosure" })) == #ok(#executed({ block = DL.length(m.st.log) - 1; effects = [16, 2] })), "halted under four eyes");
refusedAs(m, t3, lim(10, 2, #sell, 5, 1_990, "s18b"), "e:InstrumentHalted", "an order on a halted instrument");
refusedAs(m, t3, #amendOrder({ order = hb; qty = 4; price = 1_990 }), "e:InstrumentHalted", "an amendment on a halted instrument");
refusedAs(m, scheduler, #setPhase({ instrument = 2; phase = #continuous; endFrom = 0; endTo = 0 }), "e:InstrumentHalted", "a scheduled phase on a halted instrument");
refusedAs(m, operator, #halt({ instrument = 2; reason = "again" }), "e:InstrumentHalted", "a halt of a halted instrument");
cancel(m, hb);
ignore tick();
scenario(govern(m, #resume({ instrument = 2 })) == #ok(#executed({ block = DL.length(m.st.log) - 1; effects = [17, 2] })) and (switch (B.instrument(m.st, 2)) { case (?x) x.phase == #auction; case null false }), "resumed into an auction");
refusedAs(m, operator, #resume({ instrument = 2 }), "e:InvalidTerms", "a resumption of an instrument not halted");
ignore tick(); ignore executes(m, scheduler, #uncross({ instrument = 2; next = #continuous }), "uncross");
// the kill switch: member 2 blocked, its open orders swept in slices, revived under four eyes once none is open
let kb1 = placed(m, lim(9, 2, #buy, 3, 1_980, "s19a")); let kb2 = placed(m, lim(10, 2, #buy, 3, 1_981, "s19b")); let kb3 = placed(m, lim(11, 2, #buy, 3, 1_982, "s19c"));
ignore tick();
let k1 = executes(m, operator, #kill({ member = 2; trader = 0; reason = "the member's risk desk" }), "kill");
scenario(k1.size() == 2 and k1[0] == 18, "member 2 killed");
let killId = k1[1];
refusedAs(m, t3, lim(12, 2, #buy, 3, 1_983, "s19d"), "e:Killed", "an order of a killed member");
refusedAs(m, t3, #amendOrder({ order = kb1; qty = 2; price = 1_980 }), "e:Killed", "an amendment of a killed member's order");
refusedAs(m, operator, #kill({ member = 2; trader = 0; reason = "again" }), "e:InvalidTerms", "a member killed twice");
refusedAs(m, t1, #kill({ member = 2; trader = 3; reason = "not mine" }), "e:InvalidTerms", "a trader killing outside its member");
refusedAs(m, operator, #kill({ member = 1; trader = 3; reason = "the wrong member" }), "e:InvalidTerms", "a trader named with another member");
refusedAs(m, operator, #kill({ member = 0; trader = 3; reason = "no member" }), "e:InvalidTerms", "a kill naming no member");
refusedAs(m, operator, #revive({ kill = killId }), "e:OrdersStillOpen", "a revival while the member's orders are open");
scenario(executes(m, scheduler, #killSweep({ kill = killId; limit = 2 }), "sweep") == [19, killId, 2, kb1, kb2], "the first slice: two orders");
scenario(executes(m, scheduler, #killSweep({ kill = killId; limit = 2 }), "sweep") == [19, killId, 1, kb3], "the second slice: the last");
refusedAs(m, scheduler, #killSweep({ kill = 999; limit = 2 }), "e:UnknownKill", "a sweep of no kill");
ignore tick();
scenario(govern(m, #revive({ kill = killId })) == #ok(#executed({ block = DL.length(m.st.log) - 1; effects = [20, killId] })), "revived under four eyes");
ignore placed(m, lim(9, 2, #buy, 3, 1_980, "s19e"));
// a trader's kill: trader 3 of member 2 blocked by a kill that names it (its own key), swept, revived under four eyes
ignore tick();
let tk = executes(m, operator, #kill({ member = 2; trader = 3; reason = "a runaway algorithm" }), "kill a trader");
scenario(tk.size() == 2 and tk[0] == 18, "trader 3 killed");
refusedAs(m, t3, lim(10, 2, #buy, 3, 1_981, "s19f"), "e:Killed", "an order of the killed trader");
refusedAs(m, operator, #kill({ member = 2; trader = 3; reason = "again" }), "e:InvalidTerms", "a trader killed twice");
ignore executes(m, scheduler, #killSweep({ kill = tk[1]; limit = 500 }), "sweep the trader");
ignore tick();
scenario(govern(m, #revive({ kill = tk[1] })) == #ok(#executed({ block = DL.length(m.st.log) - 1; effects = [20, tk[1]] })), "the trader revived under four eyes");
ignore placed(m, lim(10, 2, #buy, 3, 1_981, "s19g"));
// risk limits: quantity, value and credit, the use the value of the member's open orders
ignore tick();
scenario(govern(m, #setLimits({ member = 1; maxOrderQty = 100; maxOrderValue = 9_000_000; creditLimit = 12_000_000 })) == #ok(#executed({ block = DL.length(m.st.log) - 1; effects = [21, 1] })), "member 1's limits");
refusedAs(m, t1, lim(1, 1, #buy, 110, 80_000, "s20a"), "e:RiskLimit", "a quantity above the limit");
refusedAs(m, t1, lim(1, 1, #buy, 100, 95_000, "s20b"), "e:RiskLimit", "a value above the limit (9,500,000)");
let r1a = placed(m, lim(1, 1, #buy, 100, 80_000, "s20c"));
scenario((switch (B.limitsOf(m.st, 1)) { case (?(_, row)) row.limits.used == 8_000_000; case null false }), "the use is the open order's value, 8,000,000");
refusedAs(m, t1, lim(2, 1, #buy, 60, 80_000, "s20d"), "e:RiskLimit", "the credit (8,000,000 + 4,800,000 above 12,000,000)");
refusedAs(m, t1, #amendOrder({ order = r1a; qty = 100; price = 95_000 }), "e:RiskLimit", "an amendment judged on its new value");
cancel(m, r1a);
scenario((switch (B.limitsOf(m.st, 1)) { case (?(_, row)) row.limits.used == 0; case null false }), "the cancel returns the use");
ignore tick();
ignore govern(m, #setLimits({ member = 1; maxOrderQty = 0; maxOrderValue = 0; creditLimit = 0 }));
// the day's statistics and its sealed file (SPEC §15): the day sealed as it stands, which begins a new session; then, the
// next market day, three trades on instrument 1 (10 at 85.100, 20 at 85.300, 10 at 84.900) and none on instrument 2, the session's figures and the file by hand
ignore tick();
let day1 = today();
let seal1 = executes(m, scheduler, #sealDay({ day = day1 }), "seal");
scenario(seal1.size() == 35 and seal1[0] == 22 and seal1[1] == day1 and seal1[2] == 2 and B.statsOf(m.st, 1) == B.NO_STATS, "the day sealed: two rows, the file's hash, a new session");
refusedAs(m, scheduler, #sealDay({ day = day1 }), "e:InvalidTerms", "a day sealed twice");
refusedAs(m, scheduler, #sealDay({ day = day1 + 1 }), "e:InvalidTerms", "a day other than the market day");
advance(86_400); ignore tick();
let day2 = today();
for ((qty, price, refA, refB) in [(10, 85_100, "s21a", "s21b"), (20, 85_300, "s21c", "s21d"), (10, 84_900, "s21e", "s21f")].vals()) {
  ignore placed(m, lim(1, 1, #buy, qty, price, refA)); ignore placed(m, lim(9, 1, #sell, qty, price, refB)); settle(m);
};
let want1 : B.Stats = { first = 85_100; high = 85_300; low = 84_900; last = 84_900; closing = 0; volume = 40; value = 3_406_000; trades = 3 };
scenario(B.statsOf(m.st, 1) == want1 and B.statsOf(m.st, 2) == B.NO_STATS, "the session: first 85.100, high 85.300, low 84.900, last 84.900, 40 for 3,406,000 in 3 trades");
ignore tick();
let seal2 = executes(m, scheduler, #sealDay({ day = day2 }), "seal");
// the file written here from the figures above, field by field (SPEC §15), and its hash
let ref1 = switch (B.instrument(m.st, 1)) { case (?x) x.referencePrice; case null 0 };
let ref2 = switch (B.instrument(m.st, 2)) { case (?x) x.referencePrice; case null 0 };
let fw = C.Writer(); fw.text("thebes.book.day.v1"); fw.nat(day2); fw.len16(2);
fw.nat(1); for (v in [85_100, 85_300, 84_900, 84_900, 0, 40, 3_406_000, 3, ref1].vals()) fw.nat(v);
fw.nat(2); for (v in [0, 0, 0, 0, 0, 0, 0, 0, ref2].vals()) fw.nat(v);
let byHand = Array.map<Nat8, Nat>(Blob.toArray(Sha256.fromArray(#sha256, fw.toArray())), func(b) { Nat8.toNat(b) });
scenario(seal2 == Array.concat<Nat>([22, day2, 2], byHand) and B.dayFile(m.st, day2) == ?fw.toBlob(), "the day's file is the one written by hand, its hash the seal's");
scenario(B.dayFile(m.st, day2 + 1) == null and (switch (B.dayFile(m.st, day1)) { case (?f) Sha256.fromBlob(#sha256, f) == Blob.fromArray(Array.map<Nat, Nat8>(Array.sliceToArray<Nat>(seal1, 3, 35), Nat8.fromNat)); case null false }), "an earlier day's file kept, its hash its seal's; no file for a day not sealed");
for (d in [day1, day2].vals()) { switch (B.dayFile(m.st, d)) { case (?f) w.line("Y|" # n(d) # "|" # TR.hex(f)); case null {} } };
// insider blackouts (SPEC §16): account 2's client blacked out for instrument 1 until lifted, under four eyes
ignore tick();
let boId = switch (govern(m, #setBlackout({ instrument = 1; client = w.clientOf(2); until = 0; reason = "a director of the issuer" }))) { case (#ok(#executed(x))) x.effects[1]; case (_) 0 };
scenario(boId > 0, "the blackout recorded under four eyes");
refusedAs(m, t1, lim(2, 1, #buy, 10, 85_000, "s22a"), "e:InsiderBlackout", "an order of a blacked-out client");
let bo3 = placed(m, lim(3, 1, #buy, 10, 85_000, "s22b"));
let bo2 = placed(m, lim(2, 2, #buy, 1, 1_990, "s22c"));
scenario(bo3 > 0 and bo2 > 0, "another client of the member, and the same client in another instrument, trade");
refusedAs(m, operator, #setBlackout({ instrument = 1; client = w.clientOf(2); until = 0; reason = "again" }), "e:InvalidTerms", "a client blacked out twice");
refusedAs(m, operator, #setBlackout({ instrument = 1; client = bytes(1, 31); until = 0; reason = "a short code" }), "e:InvalidTerms", "a client code not of 32 bytes");
ignore tick();
scenario(govern(m, #liftBlackout({ blackout = boId })) == #ok(#executed({ block = DL.length(m.st.log) - 1; effects = [24, boId] })), "lifted under four eyes");
refusedAs(m, operator, #liftBlackout({ blackout = boId }), "e:UnknownBlackout", "a blackout lifted twice");
let bo4 = placed(m, lim(2, 1, #buy, 10, 85_000, "s22d"));
scenario(bo4 > 0, "lifted, the client trades");
cancel(m, bo3); cancel(m, bo2); cancel(m, bo4);
// short sales (SPEC §17): account 4 sells beyond the shares it owns only flagged short, at or above the last price, and
// only with borrowed shares to deliver
func shortSell(account : Nat, qty : Nat, price : Nat, ref : Text) : T.Command {
  switch (lim(account, 1, #sell, qty, price, ref)) { case (#placeOrder(x)) #placeOrder({ x with shortSale = true }); case (c) c }
};
ignore tick();
let free4 = avail(m, 4, sharesA);
let over = (free4 / 10 + 1) * 10;
refusedAs(m, t1, lim(4, 1, #sell, over, 86_000, "s23a"), "e:ShortSaleNotFlagged", "a sale beyond the shares owned, not flagged");
ignore executes(m, depository, #borrow({ account = 4; member = 1; instrument = 1; qty = 100; reference = depRef(900_100) }), "borrow");
scenario(B.owedOf(m.st, 4, 1) == 100 and avail(m, 4, sharesA) == free4 + 100, "100 borrowed: credited and owed");
refusedAs(m, t1, lim(4, 1, #sell, over, 86_000, "s23b"), "e:ShortSaleNotFlagged", "borrowed shares are not owned: not flagged, still refused");
let floor = switch (B.instrument(m.st, 1)) { case (?x) (if (x.lastPrice != 0) x.lastPrice else x.referencePrice); case null 0 };
refusedAs(m, t1, shortSell(4, over, floor - 10, "s23c"), "e:ShortSalePrice", "a short sale below the last price");
refusedAs(m, t1, #placeOrder({ account = 4; instrument = 1; side = #sell; kind = #market; qty = over; price = 0; stopPrice = 0; peak = 0; validity = #day; gtdDay = 0; selfTrade = #cancelResting; capacity = #agency; shortSale = true; clientRef = "s23m"; oco = 0; trail = 0; member = 1; trader = 1 }), "e:ShortSalePrice", "a short sale with no limit");
refusedAs(m, t1, #placeOrder({ account = 4; instrument = 1; side = #buy; kind = #limit; qty = 10; price = 80_000; stopPrice = 0; peak = 0; validity = #gtc; gtdDay = 0; selfTrade = #cancelResting; capacity = #agency; shortSale = true; clientRef = "s23n"; oco = 0; trail = 0; member = 1; trader = 1 }), "e:InvalidTerms", "a buy flagged short");
let sh = placed(m, shortSell(4, over, floor, "s23d"));
scenario(sh > 0 and status(m, sh) == ?#live, "a short sale at the last price, delivered from the borrowed shares");
refusedAs(m, t1, #amendOrder({ order = sh; qty = over; price = floor - 10 }), "e:ShortSalePrice", "an amendment of a short sale below the floor");
cancel(m, sh);
refusedAs(m, t1, #returnBorrow({ account = 4; member = 1; instrument = 1; qty = 110 }), "e:InvalidTerms", "a return beyond what is owed");
scenario(executes(m, t1, #returnBorrow({ account = 4; member = 1; instrument = 1; qty = 100 }), "return") == [26, 4, 100] and B.owedOf(m.st, 4, 1) == 0 and avail(m, 4, sharesA) == free4, "returned: nothing owed, the account's own shares as before");
checkpoint(m);
Debug.print("count: scenarios whose every effect matched the hand computation = " # n(scenarios));

// the main book's random stream: the chain judge makes it again
var commandsRandom = 0;
var replays = 0;
for (k in Nat.range(0, 4)) { ignore tick(); deposit(m, 1 + rnd(16), pick<Principal>([cash, sharesA, sharesB]), 50_000_000) };
randomStream(m, 2_400, 300, true); commandsRandom += 2_400;
if (replayed(m)) replays += 1 else check(false, "the main book's replay");
Debug.print("count: random commands judged by the book and the reference = " # n(commandsRandom));
Debug.print("count: books whose log replayed to the same fingerprint = " # n(replays));

// compaction: every order index rebuilt without the entries of rows that left it; no row and no read changes, and the
// book goes on: the main stream continues on the compacted indexes (the chain judge, which never compacts, must still
// get every outcome and the same fingerprint)
let fpBefore = B.fingerprint(m.st); let depthBefore = depthText(m);
let tombsBefore = B.tombstones(m.st);
var examined = 0;
for (ix in B.churnIndexes.vals()) { switch (B.compactIndex(m.st, ix, 64)) { case (?k) examined += k; case null check(false, "the book holds index " # ix) } };
check(tombsBefore > 0 and B.tombstones(m.st) == 0, "compaction drops every stale entry: " # n(tombsBefore) # " before, " # n(B.tombstones(m.st)) # " after");
check(B.fingerprint(m.st) == fpBefore and depthText(m) == depthBefore, "compaction changes no row and no read");
Debug.print("count: stale index entries dropped by compaction with every row and read the same = " # n(tombsBefore));
randomStream(m, 300, 300, true);
if (not replayed(m)) check(false, "the main book's replay after compaction");
Debug.print("count: random commands on the compacted indexes judged by the book and the reference = 300");
var ocoCancelled = 0; var icebergsFilled = 0;
var oid = 1;
while (oid < m.st.nextOrder) { switch (B.order(m.st, oid)) { case (?o) { if (o.oco != 0 and o.status == #cancelled) ocoCancelled += 1; if (o.peak != 0 and o.filled > 0) icebergsFilled += 1 }; case null {} }; oid += 1 };
Debug.print("count: linked orders cancelled on the main book = " # n(ocoCancelled));
Debug.print("count: icebergs that traded on the main book = " # n(icebergsFilled));
printCoverage(["pairs", "clears that traded", "stops triggered", "orders cancelled at a clear", "own orders cancelled at entry", "incoming orders cancelled with the resting",
  "amendments keeping priority", "amendments taking a new priority", "uncrossed books checked", "checkpoints", "call-phase reads checked", "continuous trades checked within the bands", "trades at close", "volatility interruptions", "uncrosses", "uncrosses that traded", "uncrosses equal to their indicative price", "uncrosses outside the static band, the auction continuing", "feed digests printed", "icebergs shown after a clear", "days sealed"]);
// the clearing's families (SPEC §18 to §21, tags 27 to 40) are the clearing battery's, §22 to §25's (41 to 47) the markets
// battery's, §26 to §27's (48 to 51) the index battery's, §28 to §32's (52 to 58) the instruments battery's, §33 to
// §35's (59 to 61) the derivatives battery's, §36's (62 to 66) the cash leg battery's, and §37's (67) the gateway's
for (f in Array.sliceToArray<Text>(K.families, 0, 26).vals()) { if (f != "openInstrument" and f != "clear") Debug.print("count: executed " # f # " = " # n(seenCount("executed " # f))) };
var refusalNames = 0;
for ((k, _) in Map.entries(seen)) { if (Text.startsWith(k, #text "refused ")) refusalNames += 1 };
Debug.print("count: refusal names reached = " # n(refusalNames));
Debug.print("count: refusals that left every dimension where it was, in all = " # n(w.refusalsUnmoved));
// the fingerprint in slices equals the fingerprint in one, whatever the slice; a run a block interrupts starts again
let whole = B.fingerprint(m.st);
var sliced = 0;
for (rows in [1, 7, 997].vals()) {
  let run = B.startFingerprint(m.st);
  var result : ?Blob = null; var steps = 0;
  label stepping loop { switch (B.stepFingerprint(m.st, run, rows)) { case (#done(h)) { result := ?h; break stepping }; case (#more(_)) { steps += 1 }; case (#restart) break stepping } };
  if (result == ?whole and steps > 0) sliced += 1 else check(false, "the fingerprint in slices of " # n(rows) # " is the fingerprint");
};
let other = newRun(false);
ignore tick(); deposit(other, 1, cash, 1_000);
let interrupted = B.startFingerprint(other.st);
ignore B.stepFingerprint(other.st, interrupted, 3);
ignore tick(); deposit(other, 2, cash, 1_000);
check(B.stepFingerprint(other.st, interrupted, 3) == #restart, "control: a run a block interrupts starts again");
Debug.print("count: slice sizes whose fingerprint is the fingerprint = " # n(sliced));
TR.fingerprint("exchange", X.fingerprint(xs));
TR.fingerprint("book", whole);
// the book's certified log as stored, block by block, for the regulator's replay (book/integration/regulator_replay.py),
// which reads nothing else but the fingerprint above
var logBlocks = 0;
for (i in Nat.range(0, DL.length(m.st.log))) {
  switch (DL.rawBlock(m.st.log, i)) { case (?raw) { w.line("L|" # n(i) # "|" # TR.hex(raw)); logBlocks += 1 }; case null check(false, "block " # n(i) # " is stored") };
};
Debug.print("count: blocks of the book's log given to the regulator's replay = " # n(logBlocks));
// the drop copies (SPEC §14), read as a member reads them, seven entries a page: the regulator's replay requires each to
// be exactly the member's blocks in the log, its own as stored and the others as their public messages
var dropEntries = 0; var dropPages = 0;
for (member in [1, 2].vals()) {
  var from = 0;
  label pages loop {
    let page = B.dropCopy(m.st, member, from, 7);
    dropPages += 1;
    for ((blk, own, bytes) in page.entries.vals()) { w.line("D|" # n(member) # "|" # n(blk) # "|" # (if own "1" else "0") # "|" # TR.hex(Sha256.fromBlob(#sha256, bytes))); dropEntries += 1 };
    switch (page.next) { case (?nx) { check(nx > from, "a drop copy's next page starts further on"); from := nx }; case null break pages };
  };
};
Debug.print("count: drop-copy entries read in pages = " # n(dropEntries));
Debug.print("count: drop-copy pages read = " # n(dropPages));


if (w.failures > 0) { Debug.print("BOOK FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("BOOK GREEN");
