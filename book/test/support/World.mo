/// World.mo: test support for the book's batteries: the roles and their grants, the exchange the book reads (built
/// under four eyes, its facts printed for the reference), and the harness: a run is one book whose every command is
/// printed with its outcome, with checkpoints of every block, order and balance, properties checked as it runs, the
/// random stream generator, the permutation trial. With `traced`, the exchange's and the main book's calls are
/// written to the transcript the chain judge makes again.
///
/// Attribution: Thebes Core Team.

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
import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";
import DL "mo:kernel/domain/DomainLog";
import Perm "mo:kernel/auth/Permissions";
import Auth "mo:kernel/auth/AuthTypes";
import CivilDate "mo:kernel/num/CivilDate";
import RS "mo:kernel/rows/RowStore";
import Page "mo:kernel/rows/Page";
import Sha256 "mo:sha2/Sha256";
import MP "mo:kernel/proof/MmrProof";
import XT "../../../exchange/src/ExchangeTypes";
import X "../../../exchange/src/ExchangeCore";
import XText "../../../exchange/src/ExchangeText";
import XTC "../../../exchange/test/support/Traced";
import T "../../src/BookTypes";
import L "../../src/BookLogic";
import K "../../src/BookCanonical";
import B "../../src/BookCore";
import BTC "Traced";
import TR "../../../custody/test/support/Transcript";

module {
  public class World(tracedWorld : Bool) {
    public var failures = 0;
    public func check(cond : Bool, what : Text) { if (not cond) { failures += 1; if (failures < 60) Debug.print("FAIL: " # what) } };
    public func day(y : Nat, m : Nat, d : Nat) : Nat { switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { assert false; 0 } } };
    public func bytes(from : Nat, n : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(n, func(i) { Nat8.fromNat((from + i) % 256) })) };
    public func peq(a : Principal, b : Principal) : Bool { Principal.equal(a, b) };

    // ─── the roles and their grants ─────────────────────────────────────────────────────────────
    public let operator = Principal.fromText("2vxsx-fae");
    public let director1 = Principal.fromText("aaaaa-aa");
    public let director2 = Principal.fromText("ckbmq-yctyx-z6a2f-2xyya-pfg5n-jvgca-tye34-z7x4e-w6v53-cnjit-uae");
    public let stranger = Principal.fromText("pn3kh-726h2-5yyiw-u2lrd-wtubo-uttd2-cs4pa-l3xls-5zuwd-3wiii-zae");
    public let scheduler = Principal.fromText("6abng-3xbmm-zos2l-batfg-zytpv-vj2jv-3t7hk-3hh6q-6hugj-2q3bc-cqe");
    public let t1 = Principal.fromText("ktizj-ppt3n-t4gxw-lzckj-ghema-o6gli-zx5uq-eivp6-q5sun-c22gs-cqe");
    public let t2 = Principal.fromText("rwlgt-iiaaa-aaaaa-aaaaa-cai");
    public let t3 = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
    public let t4 = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
    public let depository = Principal.fromText("renrk-eyaaa-aaaaa-aaada-cai");
    public let clearer = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
    public let sharesA = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");
    public let sharesB = Principal.fromText("rno2w-sqaaa-aaaaa-aaacq-cai");
    public let sharesC = Principal.fromText("qoctq-giaaa-aaaaa-aaaea-cai");
    public let cash = Principal.fromText("rkp4c-7iaaa-aaaaa-aaaca-cai");
    /// The trader of the venue's central counterparty (member 3, made by `openClearing`).
    public let t5 = Principal.fromBlob(Blob.fromArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x01, 0x01]));
    /// The trader of a third clearing firm (member 4, made by `openClearing`).
    public let t6 = Principal.fromBlob(Blob.fromArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x01, 0x01]));

    public let roles : [(Text, Principal)] = [("operator", operator), ("director1", director1), ("director2", director2), ("stranger", stranger), ("scheduler", scheduler),
      ("t1", t1), ("t2", t2), ("t3", t3), ("t4", t4), ("depository", depository), ("clearer", clearer), ("t5", t5), ("t6", t6)];
    public func roleName(p : Principal) : Text { for ((n, q) in roles.vals()) { if (peq(p, q)) return n }; Principal.toText(p) };
    public func ledgerName(p : Principal) : Text { if (peq(p, cash)) "cash" else if (peq(p, sharesA)) "sharesA" else if (peq(p, sharesB)) "sharesB" else if (peq(p, sharesC)) "sharesC" else if (Principal.toText(p) == "qjdve-lqaaa-aaaaa-aaaeq-cai") "sharesD" else Principal.toText(p) };
    public func isTrader(p : Principal) : Bool { peq(p, t1) or peq(p, t2) or peq(p, t3) or peq(p, t4) or peq(p, t5) or peq(p, t6) };

    public let schedulerActs = ["exchange.segment.advance", "exchange.instrument.reference", "book.instrument.trading", "book.instrument.reference", "book.batch.flush", "book.sweep.endofday", "book.sweep.expire",
      "book.instrument.phase", "book.auction.uncross", "book.kill.sweep", "book.day.seal", "book.cycle.cut", "book.cycle.settle", "book.cycle.closeout", "book.fund.call"];
    public let traderActs = ["exchange.account.open", "exchange.account.close", "book.funds.withdraw", "book.order.place", "book.order.cancel", "book.order.amend", "book.order.masscancel", "book.kill.set", "book.borrow.return",
      "book.collateral.post", "book.collateral.withdraw", "book.fund.contribute"];
    public let operatorBookActs = ["book.instrument.open", "book.instrument.halt", "book.instrument.resume", "book.kill.set", "book.kill.revive", "book.risk.limits", "book.insider.blackout", "book.insider.lift",
      "book.clearing.terms", "book.clearing.margin", "book.clearing.admit", "book.clearing.designate", "book.fund.skin", "book.default.declare", "book.default.close"];
    public func among(xs : [Text], x : Text) : Bool { Array.find<Text>(xs, func(y) { y == x }) != null };
    public func hasGrant(p : Principal, perm : Text) : Bool {
      if (peq(p, operator)) return (Text.startsWith(perm, #text "exchange.") and perm != "exchange.segment.advance" and perm != "exchange.instrument.reference") or among(operatorBookActs, perm);
      if (peq(p, scheduler)) return among(schedulerActs, perm);
      if (peq(p, director1) or peq(p, director2)) return perm == "command.approve" or perm == "command.reject";
      if (peq(p, depository)) return perm == "book.funds.deposit" or perm == "book.borrow.record";
      // the clear is granted to no principal in the product; this role holds it to show the grant alone admits nothing
      if (peq(p, clearer)) return perm == "book.batch.clear";
      if (isTrader(p)) return among(traderActs, perm);
      false
    };
    /// The book's dual policies: one for every permission that is four eyes by default.
    public func bookDuals() : [Auth.DualPolicy] { Array.map<Auth.Permission, Auth.DualPolicy>(Array.filter<Auth.Permission>(B.catalogue(), func(p) { p.dualByDefault }), func(p) { dual(p.id) }) };
    public func holdsRole(p : Principal, role : Text) : Bool { role == "director" and (peq(p, director1) or peq(p, director2)) };
    public let xauth : X.Authority = { hasGrant; holdsRole };
    public let bauth : B.Authority = { hasGrant; holdsRole };
    public func dual(permission : Text) : Auth.DualPolicy { { permission; required = 1; eligibleRole = "director"; ttlSeconds = 3_600 } };

    // the chain's clock: 2026-03-02 10:00 UTC (12:00 in the market, UTC+2), moved by the battery
    public var now : Nat64 = Nat64.fromNat((day(2026, 3, 2) * 86_400 + 36_000) * 1_000_000_000);
    public func tick() : Nat64 { now += 1_000_000_000; now };
    public func advance(seconds : Nat) { now += Nat64.fromNat(seconds) * 1_000_000_000 };

    public let egxBands : [T.Band] = [{ fromPrice = 0; tick = 1 }, { fromPrice = 2_000; tick = 10 }];
    // ─── PART 2: the exchange the book reads ──────────────────────────────────────────────────────
    public let xs = X.newState();
    X.setPolicies(xs, Array.map<Auth.Permission, Auth.DualPolicy>(Array.filter<Auth.Permission>(X.catalogue(), func(p) { p.dualByDefault }), func(p) { dual(p.id) }));
    public func xsub(who : Principal, c : XT.Command) : X.Result<X.Outcome> { let at = tick(); if (tracedWorld) XTC.xsub(xs, xauth, at, who, c, null, "setup") else X.submit(xs, xauth, at, who, c, null, "setup") };
    func xapp(who : Principal, id : Nat) : X.Result<X.Outcome> { let at = tick(); if (tracedWorld) XTC.xapp(xs, xauth, at, who, id) else X.approve(xs, xauth, at, who, id) };
    public func xgovern(c : XT.Command, what : Text) {
      switch (xsub(operator, c)) {
        case (#ok(#proposed(p))) { switch (xapp(director1, p.proposal)) { case (#ok(#executed(_))) {}; case (o) check(false, "approved " # what # ": " # debug_show(o)) } };
        case (o) check(false, "proposed " # what # ": " # debug_show(o));
      }
    };
    public func xsingle(who : Principal, c : XT.Command, what : Text) { switch (xsub(who, c)) { case (#ok(#executed(_))) {}; case (o) check(false, what # ": " # debug_show(o)) } };
    public func today() : Nat { X.marketTime(xs, now).0 };
    /// The venue's central counterparty (SPEC §18), made once and only for the batteries that clear: member 3 with its
    /// trader t5, the CCP's account (18) and the venue's own account (19); a third clearing firm, member 4, with its trader
    /// t6 and its house account (20); the settlement calendar's rest days (Friday and Saturday) and one holiday
    /// (2026-03-04). Every fact the reference reads about them is printed again.
    public var clearingOpen = false;
    public let holiday = day(2026, 3, 4);
    public func openClearing() {
      if (clearingOpen) return;
      clearingOpen := true;
      xgovern(#admitMember({ code = "1003"; name = "Venue Central Counterparty"; marketMaker = false; clearing = true; day = today() }), "member 3");
      xgovern(#registerTrader({ member = 3; principal = t5 }), "t5");
      xsingle(t5, #openAccount({ member = 3; kind = #house; client = "" }), "account 18");
      xsingle(t5, #openAccount({ member = 3; kind = #house; client = "" }), "account 19");
      xgovern(#admitMember({ code = "1004"; name = "Third Clearing Firm"; marketMaker = false; clearing = true; day = today() }), "member 4");
      xgovern(#registerTrader({ member = 4; principal = t6 }), "t6");
      xsingle(t6, #openAccount({ member = 4; kind = #house; client = "" }), "account 20");
      xgovern(#grantTradingRight({ trader = 5; segment = 1 }), "t5 right");
      xgovern(#grantTradingRight({ trader = 6; segment = 1 }), "t6 right");
      xgovern(#setRestDays({ days = [4, 5] }), "rest days");
      xgovern(#declareHoliday({ day = holiday; reason = "test: a holiday inside a settlement cycle" }), "holiday");
      for (a in Nat.range(18, 21)) { switch (X.account(xs, a)) { case (?r) Debug.print("H|account|" # Nat.toText(a) # "|1|" # Nat.toText(r.member) # "|"); case null check(false, "the clearing accounts") } };
      Debug.print("H|member|3"); Debug.print("H|member|4");
      for ((tid, nm) in [(5, "t5"), (6, "t6")].vals()) {
        switch (X.trader(xs, tid)) { case (?row) Debug.print("H|trader|" # Nat.toText(tid) # "|" # Nat.toText(row.member) # "|1|" # nm # "|" # Principal.toText(row.principal)); case null check(false, "the clearing traders") };
      };
      for ((nm, p) in roles.vals()) {
        for (a in Nat.range(1, 21)) {
          let owns = switch (X.account(xs, a), X.traderByPrincipal(xs, p)) { case (?acc, ?(_, t)) t.status == #active and t.member == acc.member; case (_) false };
          Debug.print("H|owns|" # nm # "|" # Nat.toText(a) # "|" # (if (owns) "1" else "0"));
        };
        for (i in Nat.range(1, 5)) Debug.print("H|may|" # nm # "|" # Nat.toText(i) # "|" # (switch (X.mayTrade(xs, p, i)) { case (?e) Nat.toText(XText.code(e)); case null "0" }));
      };
      Debug.print("H|restdays|4,5");
      Debug.print("H|holiday|" # Nat.toText(holiday));
    };

    xgovern(#setUtcOffset({ minutesEast = 120 }), "offset");
    xgovern(#defineTickTable({ bands = [{ fromPrice = 0; tick = 1 }, { fromPrice = 2_000; tick = 10 }] }), "tick table");
    xgovern(#defineSegment({ code = "MAIN"; name = "Main market"; windows = [
      { phase = #closed; startSec = 0; endSec = 30_600 }, { phase = #preOpen; startSec = 30_600; endSec = 36_000 }, { phase = #continuous; startSec = 36_000; endSec = 51_300 },
      { phase = #closingAuction; startSec = 51_300; endSec = 52_200 }, { phase = #tradeAtClose; startSec = 52_200; endSec = 52_800 }, { phase = #closed; startSec = 52_800; endSec = 86_400 }] }), "segment");
    xgovern(#admitMember({ code = "1001"; name = "Nile Securities Brokerage"; marketMaker = true; clearing = true; day = today() }), "member 1");
    xgovern(#admitMember({ code = "1002"; name = "Delta Brokerage"; marketMaker = false; clearing = true; day = today() }), "member 2");
    xgovern(#registerTrader({ member = 1; principal = t1 }), "t1");
    xgovern(#registerTrader({ member = 1; principal = t2 }), "t2");
    xgovern(#registerTrader({ member = 2; principal = t3 }), "t3");
    xgovern(#registerTrader({ member = 2; principal = t4 }), "t4");
    xgovern(#grantTradingRight({ trader = 1; segment = 1 }), "t1 right");
    xgovern(#grantTradingRight({ trader = 3; segment = 1 }), "t3 right");
    xgovern(#grantTradingRight({ trader = 4; segment = 1 }), "t4 right");
    xgovern(#revokeTrader({ trader = 4; reason = "left the firm" }), "t4 revoked");
    // member 1: accounts 1 (house) to 8; member 2: 9 (house) to 17, of which 17 is closed; 18 does not exist
    xsingle(t1, #openAccount({ member = 1; kind = #house; client = "" }), "account 1");
    for (k in Nat.range(2, 9)) xsingle(t1, #openAccount({ member = 1; kind = #client; client = bytes(0x40 + k, 32) }), "account " # Nat.toText(k));
    xsingle(t3, #openAccount({ member = 2; kind = #house; client = "" }), "account 9");
    for (k in Nat.range(10, 18)) xsingle(t3, #openAccount({ member = 2; kind = #client; client = bytes(0x40 + k, 32) }), "account " # Nat.toText(k));
    xsingle(t3, #closeAccount({ account = 17; reason = "the client moved to another broker" }), "account 17 closed");
    xgovern(#listInstrument({ isin = "XS0TESTA0014"; name = "Test Issuer A ordinary shares"; segment = 1; currency = "EGP"; assetLedger = sharesA; cashLedger = cash; tickTable = 1; lot = 10; referencePrice = 85_000; day = today() }), "instrument 1");
    xgovern(#listInstrument({ isin = "XS0TESTB0021"; name = "Test Issuer B ordinary shares"; segment = 1; currency = "EGP"; assetLedger = sharesB; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 1_995; day = today() }), "instrument 2");
    xgovern(#listInstrument({ isin = "XS0TESTC0038"; name = "Test Issuer C ordinary shares"; segment = 1; currency = "EGP"; assetLedger = sharesC; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 50_000; day = today() }), "instrument 3");
    xgovern(#setInstrumentStatus({ instrument = 3; status = #delisted; reason = "test: delisting" }), "instrument 3 delisted");
    // listed and never opened in the book: what an opening must match
    public let sharesD = Principal.fromText("qjdve-lqaaa-aaaaa-aaaeq-cai");
    xgovern(#listInstrument({ isin = "XS0TESTD0045"; name = "Test Issuer D ordinary shares"; segment = 1; currency = "EGP"; assetLedger = sharesD; cashLedger = cash; tickTable = 1; lot = 5; referencePrice = 12_340; day = today() }), "instrument 4");

    // the facts the reference reads: who owns which account, who may trade what, the grants, the instruments
    Debug.print("H|offset|120");
    for (a in Nat.range(1, 19)) { switch (X.account(xs, a)) { case (?r) Debug.print("H|account|" # Nat.toText(a) # "|" # (if (r.status == #open) "1" else "0") # "|" # Nat.toText(r.member) # "|" # TR.hex(r.client)); case null {} } };
    for (m in Nat.range(1, 6)) { if (X.member(xs, m) != null) Debug.print("H|member|" # Nat.toText(m)) };
    for (t in Nat.range(1, 9)) { switch (X.trader(xs, t)) { case (?row) Debug.print("H|trader|" # Nat.toText(t) # "|" # Nat.toText(row.member) # "|" # (if (row.status == #active) "1" else "0") # "|" # roleName(row.principal) # "|" # Principal.toText(row.principal)); case null {} } };
    for ((n, p) in roles.vals()) {
      for (a in Nat.range(1, 19)) {
        let owns = switch (X.account(xs, a), X.traderByPrincipal(xs, p)) { case (?acc, ?(_, t)) t.status == #active and t.member == acc.member; case (_) false };
        Debug.print("H|owns|" # n # "|" # Nat.toText(a) # "|" # (if (owns) "1" else "0"));
      };
      for (i in Nat.range(1, 5)) Debug.print("H|may|" # n # "|" # Nat.toText(i) # "|" # (switch (X.mayTrade(xs, p, i)) { case (?e) Nat.toText(XText.code(e)); case null "0" }));
      for (f in K.families.vals()) { switch (Perm.byCommand(B.catalogue(), f)) { case (?perm) { if (hasGrant(p, perm.id)) Debug.print("H|grant|" # n # "|" # f) }; case null check(false, "a permission guards " # f) } };
    };
    public func bandsText(bs : [T.Band]) : Text { var o = ""; for (b in bs.vals()) o := o # (if (o == "") "" else ",") # Nat.toText(b.fromPrice) # ":" # Nat.toText(b.tick); o };
    for ((name, l) in [("cash", cash), ("sharesA", sharesA), ("sharesB", sharesB)].vals()) Debug.print("H|ledger|" # name # "|" # TR.hex(Principal.toBlob(l)));
    Debug.print("H|instrument|1|10|85000|500|" # bandsText(egxBands) # "|sharesA|cash");
    Debug.print("H|instrument|2|1|1995|500|" # bandsText(egxBands) # "|sharesB|cash");
    /// The member of an account (0 for none) and the exchange's id of a role's trader (0 for none).
    public func memberOf(account : Nat) : Nat { switch (X.account(xs, account)) { case (?a) a.member; case null 0 } };
    public func traderIdOf(p : Principal) : Nat { switch (X.traderByPrincipal(xs, p)) { case (?(t, _)) t; case null 0 } };
    public func memberOfTrader(t : Nat) : Nat { switch (X.trader(xs, t)) { case (?row) row.member; case null 0 } };
    /// The terms a run opens its two instruments with: (collar, static band, dynamic band, interruption seconds). Wide
    /// for the main book (its scenarios trade across 1.2 per cent); random streams set tight ones to interrupt.
    public var terms : [(Nat, Nat, Nat, Nat)] = [(500, 2_000, 0, 600), (500, 2_000, 0, 600)];
    /// Tight terms for random streams: bands a random price can break, interruptions of a minute.
    public let tightTerms : [(Nat, Nat, Nat, Nat)] = [(150, 200, 20, 60), (150, 300, 50, 60)];
    switch (X.tickTable(xs, 1)) { case (?tbl) Debug.print("H|xbands|" # bandsText(Array.map<XT.Band, T.Band>(tbl.bands, func(b) { { fromPrice = b.fromPrice; tick = b.tick } }))); case null check(false, "the tick table") };
    for (i in Nat.range(1, 5)) { switch (X.instrument(xs, i)) { case (?r) Debug.print("H|xinstrument|" # Nat.toText(i) # "|" # (if (r.status == #delisted) "0" else "1") # "|" # ledgerName(r.assetLedger) # "|" # ledgerName(r.cashLedger) # "|" # Nat.toText(r.lot) # "|" # Nat.toText(r.referencePrice)); case null {} } };

    // ─── the harness: a run is one book, its commands printed for the reference ──────────────────
    public func phaseT(p : T.Phase) : Text { switch (p) { case (#closed) "closed"; case (#continuous) "continuous"; case (#auction) "auction"; case (#closingAuction) "closingAuction"; case (#tradeAtClose) "tradeAtClose"; case (#halted) "halted" } };
    public func sideT(s : T.Side) : Text { switch (s) { case (#buy) "buy"; case (#sell) "sell" } };
    public func kindT(k : T.Kind) : Text { switch (k) { case (#limit) "limit"; case (#market) "market"; case (#ioc) "ioc"; case (#fok) "fok"; case (#stop) "stop"; case (#stopLimit) "stopLimit"; case (#trailingStop) "trailingStop" } };
    public func validityT(v : T.Validity) : Text { switch (v) { case (#day) "day"; case (#gtc) "gtc"; case (#gtd) "gtd" } };
    public func smpT(x : T.SelfTrade) : Text { switch (x) { case (#cancelIncoming) "cancelIncoming"; case (#cancelResting) "cancelResting"; case (#cancelBoth) "cancelBoth" } };
    public func n(x : Nat) : Text { Nat.toText(x) };
    public func cmdText(c : T.Command) : Text {
      switch (c) {
        case (#openInstrument(x)) "k=openInstrument;instrument=" # n(x.instrument) # ";asset=" # ledgerName(x.assetLedger) # ";cash=" # ledgerName(x.cashLedger) # ";lot=" # n(x.lot) # ";price=" # n(x.referencePrice) # ";bands=" # bandsText(x.bands) # ";collar=" # n(x.collarBps) # ";static=" # n(x.staticBps) # ";dynamic=" # n(x.dynamicBps) # ";secs=" # n(x.interruptSecs);
        case (#setTrading(x)) "k=setTrading;instrument=" # n(x.instrument) # ";open=" # (if (x.open) "1" else "0");
        case (#setReference(x)) "k=setReference;instrument=" # n(x.instrument) # ";price=" # n(x.price);
        case (#deposit(x)) "k=deposit;account=" # n(x.account) # ";member=" # n(x.member) # ";ledger=" # ledgerName(x.ledger) # ";amount=" # n(x.amount) # ";reference=" # TR.hex(x.reference);
        case (#withdraw(x)) "k=withdraw;account=" # n(x.account) # ";member=" # n(x.member) # ";ledger=" # ledgerName(x.ledger) # ";amount=" # n(x.amount);
        case (#placeOrder(x)) "k=placeOrder;account=" # n(x.account) # ";instrument=" # n(x.instrument) # ";side=" # sideT(x.side) # ";kind=" # kindT(x.kind) # ";qty=" # n(x.qty) # ";price=" # n(x.price) # ";stop=" # n(x.stopPrice) # ";peak=" # n(x.peak) # ";validity=" # validityT(x.validity) # ";gtd=" # n(x.gtdDay) # ";smp=" # smpT(x.selfTrade) # ";oco=" # n(x.oco) # ";capacity=" # (switch (x.capacity) { case (#agency) "agency"; case (#principal) "principal" }) # ";short=" # (if (x.shortSale) "1" else "0") # ";trail=" # n(x.trail) # ";member=" # n(x.member) # ";trader=" # n(x.trader) # ";ref=" # x.clientRef;
        case (#cancelOrder(x)) "k=cancelOrder;order=" # n(x.order);
        case (#amendOrder(x)) "k=amendOrder;order=" # n(x.order) # ";qty=" # n(x.qty) # ";price=" # n(x.price);
        case (#massCancel(x)) "k=massCancel;account=" # n(x.account) # ";member=" # n(x.member) # ";limit=" # n(x.limit);
        case (#flush) "k=flush";
        case (#endOfDay(x)) "k=endOfDay;limit=" # n(x.limit);
        case (#expireGtd(x)) "k=expireGtd;day=" # n(x.day) # ";limit=" # n(x.limit);
        case (#clear(x)) "k=clear;time=" # Nat64.toText(x.time);
        case (#setPhase(x)) "k=setPhase;instrument=" # n(x.instrument) # ";phase=" # phaseT(x.phase) # ";from=" # Nat64.toText(x.endFrom) # ";to=" # Nat64.toText(x.endTo);
        case (#uncross(x)) "k=uncross;instrument=" # n(x.instrument) # ";next=" # phaseT(x.next);
        case (#halt(x)) "k=halt;instrument=" # n(x.instrument) # ";reason=" # x.reason;
        case (#resume(x)) "k=resume;instrument=" # n(x.instrument);
        case (#kill(x)) "k=kill;member=" # n(x.member) # ";trader=" # n(x.trader) # ";reason=" # x.reason;
        case (#sealDay(x)) "k=sealDay;day=" # n(x.day);
        case (#setBlackout(x)) "k=setBlackout;instrument=" # n(x.instrument) # ";client=" # TR.hex(x.client) # ";until=" # n(x.until) # ";reason=" # x.reason;
        case (#liftBlackout(x)) "k=liftBlackout;blackout=" # n(x.blackout);
        case (#borrow(x)) "k=borrow;account=" # n(x.account) # ";member=" # n(x.member) # ";instrument=" # n(x.instrument) # ";qty=" # n(x.qty) # ";reference=" # TR.hex(x.reference);
        case (#returnBorrow(x)) "k=returnBorrow;account=" # n(x.account) # ";member=" # n(x.member) # ";instrument=" # n(x.instrument) # ";qty=" # n(x.qty);
        case (#killSweep(x)) "k=killSweep;kill=" # n(x.kill) # ";limit=" # n(x.limit);
        case (#revive(x)) "k=revive;kill=" # n(x.kill);
        case (#setLimits(x)) "k=setLimits;member=" # n(x.member) # ";qty=" # n(x.maxOrderQty) # ";value=" # n(x.maxOrderValue) # ";credit=" # n(x.creditLimit);
        case (#setClearing(x)) "k=setClearing;ccp=" # n(x.ccpAccount) # ";ccpMember=" # n(x.ccpMember) # ";cash=" # ledgerName(x.cashLedger) # ";secs=" # n(x.cycleSecs) # ";days=" # n(x.cycleDays) # ";penalty=" # n(x.penaltyBps) # ";deadline=" # n(x.deadlineCycles) # ";fundBps=" # n(x.fundBps) # ";floor=" # n(x.fundFloor);
        case (#setMargin(x)) "k=setMargin;instrument=" # n(x.instrument) # ";bps=" # n(x.imBps);
        case (#admitClearing(x)) "k=admitClearing;member=" # n(x.member) # ";settle=" # n(x.settlementAccount) # ";credit=" # n(x.creditLine);
        case (#designateClearing(x)) "k=designateClearing;account=" # n(x.account) # ";member=" # n(x.member);
        case (#postCollateral(x)) "k=postCollateral;member=" # n(x.member) # ";amount=" # n(x.amount);
        case (#withdrawCollateral(x)) "k=withdrawCollateral;member=" # n(x.member) # ";amount=" # n(x.amount);
        case (#cutCycle(x)) "k=cutCycle;cycle=" # n(x.cycle) # ";settleDay=" # n(x.settleDay);
        case (#settleCycle(x)) "k=settleCycle;cycle=" # n(x.cycle);
        case (#closeOut(x)) "k=closeOut;member=" # n(x.member) # ";instrument=" # n(x.instrument);
        case (#callFund) "k=callFund";
        case (#contributeFund(x)) "k=contributeFund;member=" # n(x.member) # ";amount=" # n(x.amount);
        case (#fundSkin(x)) "k=fundSkin;account=" # n(x.account) # ";amount=" # n(x.amount);
        case (#declareDefault(x)) "k=declareDefault;member=" # n(x.member) # ";reason=" # x.reason;
        case (#closeDefault(x)) "k=closeDefault;member=" # n(x.member);
      }
    };
    public func outText(r : B.Result<B.Outcome>) : Text {
      switch (r) {
        case (#ok(#executed(x))) "x:" # TR.csv(x.effects);
        case (#ok(#proposed(p))) "p:" # n(p.proposal);
        case (#err(#auth(_))) "a:" # TR.errName(debug_show(r));
        case (#err(_)) "e:" # TR.errName(debug_show(r));
      }
    };

    public type Run = {
      st : B.State;
      traced : Bool;
      var dumped : Nat;       // the log's blocks printed so far
      var fed : Nat;          // the feed's messages printed so far (SPEC §13)
      var scanned : Nat;      // the log's blocks whose clears the properties have examined
      var refSeq : Nat;       // client references handed out
      var depSeq : Nat;       // deposit references handed out
      var printedTo : Nat;    // every order below this was closed when last printed: it never changes again
      totals : Map.Map<Text, Int>;   // per ledger: deposits less withdrawals executed
      /// Per instrument, as the scanned blocks leave it: the reference price, the last and closing prices, the phase.
      track : Map.Map<Nat, Track>;
      runTerms : [(Nat, Nat, Nat, Nat)];
    };
    public type Track = { var ref : Nat; var last : Nat; var close : Nat; var phase : T.Phase };
    public var streams = 0;
    public func bsub(r : Run, who : Principal, c : T.Command) : B.Result<B.Outcome> {
      if (r.traced) BTC.bsub(r.st, xs, bauth, now, who, c, null, "battery") else B.submit(r.st, xs, bauth, now, who, c, null, "battery")
    };
    public func bapp(r : Run, who : Principal, id : Nat) : B.Result<B.Outcome> {
      if (r.traced) BTC.bapp(r.st, xs, bauth, now, who, id) else B.approve(r.st, xs, bauth, now, who, id)
    };
    /// A fresh book with instruments 1 and 2 opened under four eyes, and its stream begun for the reference.
    public func newRun(traced : Bool) : Run {
      let st = B.newState();
      B.setPolicies(st, bookDuals());
      let r : Run = { st; traced; var dumped = 0; var fed = 0; var scanned = 0; var refSeq = 0; var depSeq = 0; var printedTo = 1; totals = Map.empty<Text, Int>();
        track = Map.empty<Nat, Track>(); runTerms = terms };
      Map.add(r.track, Nat.compare, 1, { var ref = 85_000; var last = 0; var close = 0; var phase = #closed : T.Phase });
      Map.add(r.track, Nat.compare, 2, { var ref = 1_995; var last = 0; var close = 0; var phase = #closed : T.Phase });
      for ((i, asset, lot, ref) in [(1, sharesA, 10, 85_000), (2, sharesB, 1, 1_995)].vals()) {
        ignore tick();
        let (collar, static_, dynamic, secs) = terms[i - 1];
        switch (bsub(r, operator, #openInstrument({ instrument = i; assetLedger = asset; cashLedger = cash; lot; referencePrice = ref; bands = egxBands; collarBps = collar;
            staticBps = static_; dynamicBps = dynamic; interruptSecs = secs }))) {
          case (#ok(#proposed(p))) {
            switch (bapp(r, operator, p.proposal)) { case (#err(#auth(#NoGrant(_)))) {}; case (o) check(false, "the maker cannot approve: " # debug_show(o)) };
            switch (bapp(r, director1, p.proposal)) { case (#ok(#executed(x))) check(x.effects == [1, i], "instrument opened"); case (o) check(false, "open approved: " # debug_show(o)) };
          };
          case (o) check(false, "open proposed: " # debug_show(o));
        };
      };
      r.dumped := DL.length(st.log); r.scanned := r.dumped;
      streams += 1;
      var t = "";
      for (k in Nat.range(0, 2)) { let (c, a, d, x) = terms[k]; t := t # (if (t == "") "" else ",") # n(k + 1) # ":" # n(c) # ":" # n(a) # ":" # n(d) # ":" # n(x) };
      Debug.print("S|" # Nat64.toText(now) # "|1,2|" # t);
      r
    };

    // coverage, across every run: what the streams reached
    public let seen = Map.empty<Text, Nat>();
    public func saw(what : Text) { Map.add(seen, Text.compare, what, (switch (Map.get(seen, Text.compare, what)) { case (?k) k; case null 0 }) + 1) };
    public func seenCount(what : Text) : Nat { switch (Map.get(seen, Text.compare, what)) { case (?k) k; case null 0 } };

    public func ledgerOf(i : Nat, side : T.Side) : Principal { switch (side) { case (#buy) cash; case (#sell) (if (i == 1) sharesA else sharesB) } };
    public func addTotal(r : Run, l : Principal, d : Int) { let k = ledgerName(l); Map.add(r.totals, Text.compare, k, (switch (Map.get(r.totals, Text.compare, k)) { case (?v) v; case null 0 }) + d) };

    /// The clears recorded since the last look, examined: no pair of one account; every pair at the clear's price, within
    /// the buy's and the sell's limits.
    func trackOf(r : Run, inst : Nat) : Track {
      switch (Map.get(r.track, Nat.compare, inst)) { case (?t) t; case null { let t : Track = { var ref = 0; var last = 0; var close = 0; var phase = #closed }; Map.add(r.track, Nat.compare, inst, t); t } }
    };
    /// The pairs recorded from `at` in a block's effects: no pair of one account; each at the price, within both limits.
    func checkPairs(r : Run, b : DL.Block<K.Event>, effects : [Nat], at : Nat, pairs : Nat, price : Nat) {
      var j = 0;
      while (j < pairs) {
        let bo = B.order(r.st, effects[at + j * 3]); let so = B.order(r.st, effects[at + 1 + j * 3]);
        switch (bo, so) {
          case (?bb, ?ss) {
            check(bb.account != ss.account, "no pair of one account");
            // the rows are read now: an order amended after this clear (in the command whose submission recorded it)
            // carries the block's time as its priority and its new price, so it is not judged here
            let changed = bb.prio >= b.timestamp or ss.prio >= b.timestamp;
            check(bb.side == #buy and ss.side == #sell and (changed or (bb.price >= price and ss.price <= price)), "the pair trades within both limits at the clear's price");
            saw("pairs");
          };
          case (_) check(false, "a pair's orders exist");
        };
        j += 1;
      };
    };
    /// The blocks recorded since the last look, examined in order, each instrument's reference, last price and phase
    /// followed as they go: no trade outside continuous trading and trade at close; a continuous trade within the static
    /// band around the reference and the dynamic band around the last price; a trade at close at the closing price; an
    /// uncross within the static band; an interruption only from continuous trading.
    public func scanClears(r : Run) {
      let len = DL.length(r.st.log);
      while (r.scanned < len) {
        switch (DL.get(r.st.log, K.codec, r.scanned)) {
          case (?b) {
            switch (b.event) {
              case (#executed({ command; effects })) {
                switch (command) {
                  case (#clear(_)) {
                    saw("clears");
                    var k = 1;
                    while (k < effects.size()) {
                      let inst = effects[k]; let price = effects[k + 1]; let pairs = effects[k + 3];
                      let t = trackOf(r, inst);
                      let (_, stat, dyn, _) = r.runTerms[if (inst >= 1 and inst <= 2) inst - 1 else 0];
                      if (price > 0) {
                        saw("clears that traded");
                        switch (t.phase) {
                          case (#continuous) {
                            check(L.within(price, t.ref, stat), "a continuous trade within the static band: " # n(price) # " around " # n(t.ref));
                            check(dyn == 0 or L.within(price, if (t.last != 0) t.last else t.ref, dyn), "a continuous trade within the dynamic band: " # n(price) # " after " # n(t.last));
                            saw("continuous trades checked within the bands");
                          };
                          case (#tradeAtClose) { check(price == t.close, "a trade at close at the closing price"); saw("trades at close") };
                          case (_) check(false, "no trade outside continuous trading and trade at close (" # phaseT(t.phase) # ")");
                        };
                        t.last := price;
                      };
                      checkPairs(r, b, effects, k + 4, pairs, price);
                      let at = k + 4 + pairs * 3;
                      let nc = effects[at]; let tp = at + 1 + nc; let nt = effects[tp];
                      let sp = tp + 1 + 4 * nt; let ns = effects[sp];
                      for (_ in Nat.range(0, nc)) saw("orders cancelled at a clear");
                      for (_ in Nat.range(0, nt)) saw("stops triggered");
                      // a revealed stop shows a positive quantity on its side; an iceberg after the clear at most its peak
                      for (j in Nat.range(0, nt)) check((effects[tp + 2 + 4 * j] == 1 or effects[tp + 2 + 4 * j] == 2) and effects[tp + 4 + 4 * j] > 0, "a revealed stop shows its side and a quantity");
                      for (j in Nat.range(0, ns)) {
                        switch (B.order(r.st, effects[sp + 1 + 2 * j])) { case (?o) check(o.peak != 0 and effects[sp + 2 + 2 * j] <= o.peak and effects[sp + 2 + 2 * j] > 0, "an iceberg shows at most its peak"); case null check(false, "a shown iceberg exists") };
                        saw("icebergs shown after a clear");
                      };
                      let fp = sp + 1 + 2 * ns;
                      if (effects[fp] == 1) { check(t.phase == #continuous, "an interruption only from continuous trading"); t.phase := #auction; saw("volatility interruptions") };
                      k := fp + 1;
                    };
                  };
                  case (#uncross(x)) {
                    let t = trackOf(r, x.instrument);
                    let price = effects[2]; let pairs = effects[4];
                    check(t.phase == #auction or t.phase == #closingAuction, "an uncross only in a call phase");
                    checkPairs(r, b, effects, 5, pairs, price);
                    let phaseAfter = effects[effects.size() - 1];
                    if (phaseAfter == Nat8.toNat(K.phaseCode(t.phase))) { saw("uncrosses outside the static band, the auction continuing") }
                    else {
                      let (_, stat, _, _) = r.runTerms[if (x.instrument >= 1 and x.instrument <= 2) x.instrument - 1 else 0];
                      if (price > 0) { check(L.within(price, t.ref, stat), "an uncross within the static band"); t.last := price; saw("uncrosses that traded") };
                      if (t.phase == #closingAuction) t.close := (if (t.last != 0) t.last else t.ref);
                      t.phase := x.next;
                      saw("uncrosses");
                    };
                  };
                  case (#setReference(x)) { trackOf(r, x.instrument).ref := x.price };
                  case (#setTrading(x)) { trackOf(r, x.instrument).phase := (if (x.open) #continuous else #closed) };
                  case (#setPhase(x)) { trackOf(r, x.instrument).phase := x.phase };
                  case (#halt(x)) { trackOf(r, x.instrument).phase := #halted; saw("halts") };
                  case (#resume(x)) { trackOf(r, x.instrument).phase := #auction; saw("resumptions") };
                  case (#kill(_)) saw("kills");
                  case (#killSweep(_)) saw("kill sweeps");
                  case (#revive(_)) saw("revivals");
                  case (#setLimits(_)) saw("limits set");
                  case (#sealDay(_)) saw("days sealed");
                  case (_) {};
                };
              };
              case (_) {};
            };
          };
          case null check(false, "a block of the log reads");
        };
        r.scanned += 1;
      };
    };
    /// The best live order of a side among the batches already cleared (priority before the current block's time): the
    /// orders of the current block wait for their own clear.
    public func bestCleared(r : Run, i : Nat, side : T.Side) : ?T.Order {
      var cursor : ?Page.Cursor = null;
      loop {
        switch (B.depth(r.st, i, side, cursor, 4)) {
          case (#ok(p)) {
            for ((_, o) in p.rows.vals()) { if (o.prio < now) return ?o };
            switch (p.next) { case (?c) cursor := ?c; case null return null };
          };
          case (#err(_)) return null;
        };
      };
    };
    /// After the due clear: every open book on which no clear waits (an instrument opened in this block waits for the next)
    /// uncrossed among the orders of the batches it cleared.
    public func uncrossed(r : Run) {
      for (i in [1, 2].vals()) {
        switch (B.instrument(r.st, i)) {
          case (?ins) {
            let due = switch (RS.get(r.st.dueRows, B.dues, i)) { case (?d) d.due; case null false };
            if (ins.phase == #continuous and not due) {
              switch (bestCleared(r, i, #buy), bestCleared(r, i, #sell)) {
                case (?bb, ?ba) { check(bb.price < ba.price, "an open book is uncrossed after its clear: " # n(bb.price) # " >= " # n(ba.price)); saw("uncrossed books checked") };
                case (_) {};
              };
            };
          };
          case null {};
        };
      };
    };
    /// One command on a run: given, printed with its outcome, and its effects on the funds recorded.
    /// A line for the reference: a WASI print holds 512 bytes, so a longer line goes out in pieces of 400 characters,
    /// each after the first on a `+|` line the reference joins to the one before.
    public func line(t : Text) {
      if (t.size() <= 400) { Debug.print(t); return };
      let cs = Text.toArray(t);
      var k = 0;
      while (k < cs.size()) {
        let e = Nat.min(cs.size(), k + 400);
        Debug.print((if (k == 0) "" else "+|") # Text.fromArray(Array.sliceToArray<Char>(cs, k, e)));
        k := e;
      };
    };
    /// A stream's step: an act under four eyes given by the operator is proposed and approved; any other, given.
    public func step(r : Run, who : Principal, c : T.Command) : B.Result<B.Outcome> { if (underFourEyes(c) and peq(who, operator)) govern(r, c) else act(r, who, c) };
    /// The visible book (SPEC §13) as the book's state holds it: for every open instrument, its phase and every live
    /// order with its side, price and shown quantity, in order number order; hashed. The feed's consumer
    /// (`integration/feed_book.py`) computes the same from the feed alone.
    public func visibleDigest(r : Run) : Blob {
      let w = C.Writer(); w.text("thebes.book.visible.v1");
      for (i in Nat.range(1, 9)) {
        switch (B.instrument(r.st, i)) {
          case (?x) {
            let live = Map.empty<Nat, T.Order>();
            for (side in [#buy, #sell].vals()) {
              var cursor : ?Page.Cursor = null;
              label pages loop {
                switch (B.depth(r.st, i, side, cursor, 500)) {
                  case (#ok(p)) { for ((id, o) in p.rows.vals()) { if (o.status == #live) Map.add(live, Nat.compare, id, o) }; switch (p.next) { case (?nx) cursor := ?nx; case null break pages } };
                  case (#err(_)) { check(false, "the depth reads"); break pages };
                };
              };
            };
            w.nat(i); w.byte(K.phaseCode(x.phase)); w.len16(Map.size(live));
            for ((id, o) in Map.entries(live)) { w.nat(id); w.byte(if (o.side == #buy) 1 else 2); w.nat(o.price); w.nat(B.shownOf(o)) };
          };
          case null {};
        };
      };
      Sha256.fromArray(#sha256, w.toArray())
    };
    /// The feed's new messages since the last call, each with its feed hash, then the visible book's digest after them.
    public func feedOut(r : Run) {
      let (next, _) = B.feedHeadOf(r.st);
      // after every act the feed holds every block of the log: no block waits for a later act to be published
      check(next == DL.length(r.st.log), "the feed holds the log's every block after an act: " # n(next) # " of " # n(DL.length(r.st.log)));
      if (r.fed == next) return;
      while (r.fed < next) {
        switch (B.feedEntry(r.st, r.fed)) { case (?e) line("F|" # n(r.fed) # "|" # TR.hex(e.message) # "|" # TR.hex(e.hash)); case null check(false, "a feed entry reads") };
        r.fed += 1;
      };
      line("V|" # n(next - 1) # "|" # TR.hex(visibleDigest(r)));
      saw("feed digests printed");
    };
    public func act(r : Run, who : Principal, c : T.Command) : B.Result<B.Outcome> {
      // the indicative auction price read just before an uncross, after the clears due before it (the command records them
      // first, SPEC §1, and one may open an interruption the uncross then ends): the uncross must trade exactly it
      let ind = switch (c) { case (#uncross(x)) { ignore B.flushDue(r.st, now, who); B.indicative(r.st, x.instrument) }; case (_) null };
      let res = bsub(r, who, c);
      line("C|" # Nat64.toText(now) # "|" # roleName(who) # "|" # cmdText(c) # "|" # outText(res));
      switch (res) {
        case (#ok(#executed(x))) {
          saw("executed " # K.familyOf(c));
          switch (c) {
            case (#deposit(d)) addTotal(r, d.ledger, d.amount);
            case (#withdraw(w)) addTotal(r, w.ledger, -w.amount);
            // a securities loan brings shares in and its return takes them out (SPEC §17)
            case (#borrow(x)) { switch (B.instrument(r.st, x.instrument)) { case (?i) addTotal(r, i.assetLedger, x.qty); case null {} } };
            case (#returnBorrow(x)) { switch (B.instrument(r.st, x.instrument)) { case (?i) addTotal(r, i.assetLedger, -x.qty); case null {} } };
            case (#placeOrder(_)) { if (x.effects.size() > 5) saw("own orders cancelled at entry"); if (x.effects[2] == 4) saw("incoming orders cancelled with the resting") };
            case (#settleCycle(_)) { for (j in Nat.range(0, x.effects[2])) { if (x.effects[4 + 3 * j] == 2) saw("cycle fails") } };
            case (#amendOrder(_)) saw(if (x.effects[2] == 1) "amendments keeping priority" else "amendments taking a new priority");
            case (#uncross(_)) {
              switch (ind) {
                case (?v) {
                  if (v.withinBand) check(x.effects[2] == v.price and x.effects[3] == v.volume, "the uncross trades its indicative price and volume: " # debug_show(v) # " " # TR.csv(x.effects))
                  else check(x.effects[2] == 0, "an indicative price outside the static band: the uncross trades nothing");
                  saw("uncrosses equal to their indicative price");
                };
                case null check(x.effects[2] == 0, "no indicative price: the uncross trades nothing");
              };
            };
            case (_) {};
          };
        };
        case (#err(_)) saw("refused " # TR.errName(debug_show(res)));
        case (_) {};
      };
      feedOut(r);
      scanClears(r);
      res
    };
    /// A command under four eyes: the operator proposes it, a director approves; the approval printed as an `A|` line,
    /// which the reference applies at its time.
    public func govern(r : Run, c : T.Command) : B.Result<B.Outcome> {
      let res = act(r, operator, c);
      switch (res) {
        case (#ok(#proposed(p))) {
          let a = bapp(r, director1, p.proposal);
          line("A|" # Nat64.toText(now) # "|director1|" # n(p.proposal) # "|" # outText(a));
          switch (a) { case (#ok(#executed(_))) saw("executed " # K.familyOf(c)); case (#err(_)) saw("refused at approval " # TR.errName(debug_show(a))); case (_) {} };
          feedOut(r);
          scanClears(r);
          a
        };
        case (_) res;
      }
    };

    public type Dims = { counts : B.Counts; counters : [Nat]; fp : Blob };
    public func dims(st : B.State) : Dims { { counts = B.counts(st); counters = B.counters(st); fp = B.fingerprint(st) } };
    public var refusalsUnmoved = 0;
    /// A command that must be refused, by name, leaving every dimension where it was. The due clear is recorded first, as
    /// the command's own submission would record it (§6), so that what is compared is the refusal alone.
    /// A placement as the caller enters it: its trader is the caller's.
    public func asCaller(c : T.Command, who : Principal) : T.Command { switch (c) { case (#placeOrder(x)) #placeOrder({ x with trader = traderIdOf(who) }); case (_) c } };
    public func refusedAs(r : Run, who : Principal, c0 : T.Command, want : Text, what : Text) {
      let c = asCaller(c0, who);
      ignore B.flushDue(r.st, now, who);
      feedOut(r);
      scanClears(r);
      let d0 = dims(r.st);
      let res = act(r, who, c);
      let got = outText(res);
      check(got == want, what # ": wanted " # want # ", got " # got);
      let d1 = dims(r.st);
      if (d1.counts == d0.counts and d1.counters == d0.counters and d1.fp == d0.fp) refusalsUnmoved += 1 else check(false, "a refusal moved the book: " # what);
    };
    public func executes(r : Run, who : Principal, c : T.Command, what : Text) : [Nat] {
      switch (act(r, who, c)) { case (#ok(#executed(x))) x.effects; case (o) { check(false, what # ": " # debug_show(o)); [] } }
    };

    /// A checkpoint: the log's blocks since the last, every order, every balance; and the funds' properties.
    public func checkpoint(r : Run) {
      // the "calling" index answers exactly the instruments whose rows are in a call phase, from any starting id
      for (from in [0, 2].vals()) {
        let want = Array.filter<Nat>([1, 2], func(i) { i >= from and (switch (B.instrument(r.st, i)) { case (?x) x.phase == #auction or x.phase == #closingAuction; case null false }) });
        let got = Array.map<(Nat, T.Instrument), Nat>(B.inCallPhase(r.st, from, B.MAX_CALLING), func((id, _)) { id });
        check(got == want, "the instruments in a call phase from " # n(from) # ": " # debug_show(got) # " = " # debug_show(want));
        if (want.size() > 0) saw("call-phase reads checked");
      };
      let len = DL.length(r.st.log);
      while (r.dumped < len) {
        switch (DL.get(r.st.log, K.codec, r.dumped)) {
          case (?b) { switch (b.event) { case (#executed(x)) line("B|" # n(r.dumped) # "|" # Nat64.toText(b.timestamp) # "|" # K.familyOf(x.command) # "|" # TR.csv(x.effects)); case (_) {} } };
          case null check(false, "a block of the log reads");
        };
        r.dumped += 1;
      };
      // what each account's open orders hold, per ledger; each member's use, recounted from its open orders
      let heldByOrders = Map.empty<Text, Nat>();
      let useByMember = Map.empty<Nat, Nat>();
      let imByMember = Map.empty<Text, Nat>(); let custodyHeld = Map.empty<Text, Nat>(); let committedBy = Map.empty<Text, Nat>();
      func addTo(m : Map.Map<Text, Nat>, k : Text, v : Nat) { Map.add(m, Text.compare, k, (switch (Map.get(m, Text.compare, k)) { case (?x) x; case null 0 }) + v) };
      func got(m : Map.Map<Text, Nat>, k : Text) : Nat { switch (Map.get(m, Text.compare, k)) { case (?x) x; case null 0 } };
      // the orders below `printedTo` were closed when last printed; a clearing order's figures are recounted from every
      // open order, so the walk starts at the first open one
      var id = r.printedTo;
      var firstOpen = r.st.nextOrder;
      while (id < r.st.nextOrder) {
        switch (B.order(r.st, id)) {
          case (?o) {
            if ((o.status == #live or o.status == #waiting) and id < firstOpen) firstOpen := id;
            Debug.print("O|" # n(id) # "|" # n(Nat8.toNat(K.statusCode(o.status))) # "|" # n(o.remaining) # "|" # n(o.filled) # "|" # n(o.held) # "|" # Nat64.toText(o.prio) # "|" # n(o.price) # "|" # n(o.stopPrice) # "|" # n(Nat8.toNat(K.capacityCode(o.capacity))) # "|" # (if (o.shortSale) "1" else "0") # "|" # n(o.trail) # "|" # n(o.member) # "|" # n(o.trader));
            if (o.status == #live or o.status == #waiting) Map.add(useByMember, Nat.compare, o.member, (switch (Map.get(useByMember, Nat.compare, o.member)) { case (?v) v; case null 0 }) + o.price * o.remaining);
            if (o.status == #live or o.status == #waiting) {
              // a clearing order holds nothing on its account: a buy's margin is its member's, a sale's shares the custody's
              switch (B.clearingOf(r.st, o.account)) {
                case (?m) {
                  if (o.side == #buy) { addTo(imByMember, n(m), o.held); addTo(committedBy, "all", o.price * o.remaining) }
                  else addTo(custodyHeld, n(m) # "/" # n(o.instrument), o.held);
                };
                case null {
                  let k = n(o.account) # "/" # ledgerName(ledgerOf(o.instrument, o.side)); addTo(heldByOrders, k, o.held);
                  switch (B.closeoutOf(r.st, id)) { case (?m) addTo(custodyHeld, n(m) # "/" # n(o.instrument), o.held); case null {} };
                };
              };
            } else check(o.held == 0, "a closed order holds nothing");
          };
          case null check(false, "order " # n(id) # " exists");
        };
        id += 1;
      };
      let sums = Map.empty<Text, Int>();
      var bid = 1;
      while (bid < r.st.nextBalance) {
        switch (RS.get(r.st.balanceRows, B.balances, bid)) {
          case (?b) {
            let l = ledgerName(b.ledger);
            Debug.print("Q|" # n(b.account) # "|" # l # "|" # n(b.available) # "|" # n(b.held));
            Map.add(sums, Text.compare, l, (switch (Map.get(sums, Text.compare, l)) { case (?v) v; case null 0 }) + b.available + b.held);
            let want = switch (Map.get(heldByOrders, Text.compare, n(b.account) # "/" # l)) { case (?v) v; case null 0 };
            check(b.held == want, "account " # n(b.account) # " holds on " # l # " what its open orders hold: " # n(b.held) # " vs " # n(want));
          };
          case null check(false, "balance row " # n(bid) # " exists");
        };
        bid += 1;
      };
      for ((l, t) in Map.entries(r.totals)) { check((switch (Map.get(sums, Text.compare, l)) { case (?v) v; case null 0 }) == t, "funds conserved on " # l) };
      // upkeep: after a command the order indexes never hold more stale entries than the larger of the threshold and
      // their live ones (the book compacts when they reach it)
      let (stale, liveEntries) = B.staleAndLive(r.st);
      check(stale <= Nat.max(B.UPKEEP_MIN_STALE, liveEntries), "stale index entries bounded by upkeep: " # n(stale) # " stale, " # n(liveEntries) # " live");
      // the instruments, the risk limits with their use (recounted above), the kill switches
      for (i in [1, 2].vals()) {
        switch (B.instrument(r.st, i)) {
          case (?x) Debug.print("I|" # n(i) # "|" # phaseT(x.phase) # "|" # n(x.lastPrice) # "|" # n(x.closePrice) # "|" # Nat64.toText(x.interruptUntil) # "|" # Nat64.toText(x.endFrom) # "|" # Nat64.toText(x.endTo) # "|" # n(x.referencePrice));
          case null {};
        };
      };
      var lid = 1;
      while (lid < r.st.nextLimit) {
        switch (RS.get(r.st.limitStore, B.limitRows, lid)) {
          case (?row) {
            let l = row.limits;
            Debug.print("U|" # n(row.member) # "|" # n(l.maxOrderQty) # "|" # n(l.maxOrderValue) # "|" # n(l.creditLimit) # "|" # n(l.used));
            check(l.used == (switch (Map.get(useByMember, Nat.compare, row.member)) { case (?v) v; case null 0 }), "member " # n(row.member) # "'s use is the value of its open orders");
          };
          case null check(false, "limit row " # n(lid) # " exists");
        };
        lid += 1;
      };
      for ((m, v) in Map.entries(useByMember)) { if (v > 0) check(B.limitsOf(r.st, m) != null, "member " # n(m) # " with open orders has its use kept") };
      var kid = 1;
      while (kid < r.st.nextKill) { switch (B.kill(r.st, kid)) { case (?k) Debug.print("K|" # n(kid) # "|" # n(k.member) # "|" # n(k.trader) # "|" # (if (k.active) "1" else "0")); case null {} }; kid += 1 };
      // the central counterparty (SPEC §18 to §21): its members' rows, its custody, its figures, the settlement range
      switch (B.clearingTerms(r.st)) {
        case (?t) {
          var coll = 0; var fund = 0; var to = 0; var by = 0; var debt = 0;
          for (x in B.clearingMembers(r.st).vals()) {
            Debug.print("G|" # n(x.member) # "|" # n(x.settlementAccount) # "|" # n(x.creditLine) # "|" # n(x.collateral) # "|" # n(x.fund) # "|" # n(x.fundRequired) # "|" # n(x.imOrders) # "|" # n(x.owedTo) # "|" # n(x.owedBy) # "|" # n(x.debt) # "|" # n(x.fails) # "|" # n(x.peak) # "|" # n(x.status));
            check(x.imOrders == got(imByMember, n(x.member)), "member " # n(x.member) # "'s initial margin is its open buys' margin");
            coll += x.collateral; fund += x.fund; to += x.owedTo; by += x.owedBy; debt += x.debt;
            for (c in B.custodyRowsOf(r.st, x.member).vals()) {
              Debug.print("J|" # n(c.member) # "|" # n(c.instrument) # "|" # n(c.qty) # "|" # n(c.held));
              check(c.held == got(custodyHeld, n(c.member) # "/" # n(c.instrument)) and c.held <= c.qty, "custody " # n(c.member) # "/" # n(c.instrument) # " holds what its sales and close-outs hold");
            };
          };
          let (committed, skin, cycleNo, settled, lastCut) = B.clearingFigures(r.st);
          Debug.print("W|" # n(committed) # "|" # n(skin) # "|" # n(cycleNo) # "|" # n(settled) # "|" # Nat64.toText(lastCut));
          check(committed == got(committedBy, "all"), "the CCP's commitment is its open clearing buys' value");
          // the CCP's cash is what it holds for the members and the venue, plus what it is owed, less what it owes
          let have : Int = B.balance(r.st, t.ccpAccount, t.cashLedger).available + B.balance(r.st, t.ccpAccount, t.cashLedger).held;
          check(have == coll + fund + skin + to - by - debt, "the CCP's cash: " # debug_show(have) # " against its resources and obligations " # debug_show((coll + fund + skin + to : Int) - by - debt));
          for ((i, l) in [(1, sharesA), (2, sharesB)].vals()) {
            var q = 0;
            for (x in B.clearingMembers(r.st).vals()) q += B.custodyOf(r.st, x.member, i).qty;
            let b = B.balance(r.st, t.ccpAccount, l);
            check(b.available + b.held == q, "the CCP holds instrument " # n(i) # "'s custody: " # n(b.available + b.held) # " against " # n(q));
          };
          saw("clearing checkpoints");
        };
        case null {};
      };
      let (legs, root) = B.settlementRoot(r.st);
      Debug.print("M|" # n(legs) # "|" # TR.hex(root));
      // inclusion proofs of the range's first and last legs verify against the root; a proof against another leg does not
      for (i in [0, 1, 2, legs / 2, legs - Nat.min(legs, 2), legs - Nat.min(legs, 1)].vals()) {
        if (i < legs) {
          switch (B.settlementProof(r.st, i)) {
            case (?p) {
              check(MP.verify(B.legRows.encode(p.leg), i, p.proof, root), "leg " # n(i) # "'s proof verifies against the range's root");
              check(not MP.verify(B.legRows.encode({ p.leg with units = p.leg.units + 1 }), i, p.proof, root), "an altered leg does not verify");
              saw("settlement proofs verified");
            };
            case null check(false, "leg " # n(i) # " has a proof");
          };
        };
      };
      saw("checkpoints");
      r.printedTo := firstOpen;
      Debug.print("E|" # n(r.st.nextOrder - 1));
    };

    // ─── PART 3: the main book: every refusal, then scenarios computed by hand ───────────────────
    public func order(account : Nat, inst : Nat, side : T.Side, kind : T.Kind, qty : Nat, price : Nat, stopPrice : Nat, peak : Nat, validity : T.Validity, gtdDay : Nat, selfTrade : T.SelfTrade, clientRef : Text, oco : Nat) : T.Command {
      #placeOrder({ account; instrument = inst; side; kind; qty; price; stopPrice; peak; validity; gtdDay; selfTrade; capacity = #agency; shortSale = false; clientRef; oco; trail = 0;
        member = memberOf(account); trader = traderIdOf(traderOf(account)) })
    };
    public func lim(account : Nat, inst : Nat, side : T.Side, qty : Nat, price : Nat, clientRef : Text) : T.Command { order(account, inst, side, #limit, qty, price, 0, 0, #gtc, 0, #cancelResting, clientRef, 0) };
    /// The trader a battery acts through for an account: its member's (member 1 t1, 2 t3, 3 t5, 4 t6); for an account
    /// that does not exist, t1 below 9 and t3 from 9, as the batteries refer to such accounts.
    public func traderOf(account : Nat) : Principal {
      switch (memberOf(account)) { case 1 t1; case 2 t3; case 3 t5; case 4 t6; case _ (if (account <= 8) t1 else t3) }
    };
    public func depRef(k : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { if (i < 24) 0xD0 else Nat8.fromNat((k / (256 ** (31 - i : Nat))) % 256) })) };
    public func deposit(r : Run, account : Nat, ledger : Principal, amount : Nat) {
      r.depSeq += 1;
      ignore executes(r, depository, #deposit({ account; member = memberOf(account); ledger; amount; reference = depRef(r.depSeq + streams * 1_000_000) }), "deposit");
    };
    /// The order number a placement executed with, or 0.
    public func placed(r : Run, c : T.Command) : Nat { switch (act(r, switch (c) { case (#placeOrder(x)) traderOf(x.account); case (_) operator }, c)) { case (#ok(#executed(x))) x.effects[1]; case (o) { check(false, "placed: " # debug_show(o)); 0 } } };
    public func status(r : Run, id : Nat) : ?T.Status { switch (B.order(r.st, id)) { case (?o) ?o.status; case null null } };
    public func avail(r : Run, account : Nat, ledger : Principal) : Nat { B.balance(r.st, account, ledger).available };
    /// The effects of the log's last clear.
    public func lastClear(r : Run) : [Nat] {
      var i = DL.length(r.st.log);
      while (i > 0) { i -= 1; switch (DL.get(r.st.log, K.codec, i)) { case (?b) { switch (b.event) { case (#executed({ command = #clear(_); effects })) return effects; case (_) {} } }; case null {} } };
      []
    };

    public func settle(r : Run) { ignore tick(); ignore act(r, scheduler, #flush) };
    public func cancel(r : Run, id : Nat) { switch (B.order(r.st, id)) { case (?o) ignore executes(r, traderOf(o.account), #cancelOrder({ order = id }), "cancel"); case null check(false, "order to cancel") } };
    // ─── PART 4: random streams, each on a fresh book (the main book continues as stream one) ───
    public var seed : Nat64 = 0x9E37_79B9_7F4A_7C15;
    public func rnd(k : Nat) : Nat { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; Nat64.toNat(seed % Nat64.fromNat(k)) };
    public func pick<A>(xs : [A]) : A { xs[rnd(xs.size())] };
    public func refOf(r : Run, i : Nat) : Nat { switch (B.instrument(r.st, i)) { case (?x) x.referencePrice; case null 1_995 } };
    /// A price near the instrument's reference: instrument 1 on the 0.01 tick; instrument 2 mostly below 2.00, on the 0.001
    /// tick, sometimes above it where only the 0.01 tick is valid; now and then one off the tick.
    /// In trade at close, half the prices are the closing price, so trades at close occur.
    public func nearPrice(r : Run, i : Nat) : Nat {
      switch (B.instrument(r.st, i)) { case (?x) { if (x.phase == #tradeAtClose and x.closePrice != 0 and rnd(2) == 0) return x.closePrice }; case null {} };
      nearAt(refOf(r, i), i)
    };
    /// A reference moved 3 per cent up or down, on the 0.01 tick: orders resting near the old reference may then lie
    /// outside the static band, so an uncross can fall outside it (SPEC §9) and leave the auction continuing.
    public func jumpPrice(r : Run, i : Nat) : Nat { let ref = refOf(r, i); (if (rnd(2) == 0) ref * 103 / 100 else ref * 97 / 100) / 10 * 10 };
    public func nearAt(ref : Nat, i : Nat) : Nat {
      if (i == 1) { let p = ref + 10 * rnd(31) - 150 : Int; Int.abs(p) + (if (rnd(40) == 0) 3 else 0) }
      else { let p = (ref : Int) - rnd(20) + (if (rnd(5) == 0) rnd(20) else 0); Int.abs(p) }
    };
    public func pickTrader() : Principal { let x = rnd(40); if (x < 18) t1 else if (x < 37) t3 else if (x < 39) t2 else t4 };
    /// Set by the clearing streams: half the orders go to the member's clearing accounts.
    public var clearingBias = false;
    public func accountFor(p : Principal) : Nat {
      if (clearingBias and rnd(2) == 0) return if (peq(p, t1) or peq(p, t2)) 5 + rnd(2) else 13 + rnd(2);
      if (rnd(25) == 0) 1 + rnd(18) else if (peq(p, t1) or peq(p, t2)) 1 + rnd(8) else 9 + rnd(9)
    };
    public func clientRef(r : Run) : Text {
      let x = rnd(100);
      if (x == 0) return "";
      if (x == 1) return "abcdefghijklmnopqrstu";
      if (x < 4 and r.refSeq > 0) return "q" # n(r.refSeq - 1);
      r.refSeq += 1; "q" # n(r.refSeq)
    };
    public func randomOrder(r : Run, who : Principal) : T.Command {
      let account = accountFor(who);
      let ix = rnd(100);
      let inst = if (ix < 55) 1 else if (ix < 97) 2 else 3 + rnd(2);
      let lot = if (inst == 1) 10 else 1;
      let side : T.Side = if (rnd(2) == 0) #buy else #sell;
      let k = rnd(100);
      let kind : T.Kind = if (k < 50) #limit else if (k < 58) #market else if (k < 67) #ioc else if (k < 74) #fok else if (k < 84) #stop else if (k < 93) #stopLimit else #trailingStop;
      let qty = lot * (1 + rnd(30)) + (if (rnd(40) == 0) 1 else 0);
      // now and then a price five per cent away, outside a tight static band
      let p = if (rnd(30) == 0) nearPrice(r, if (inst > 2) 2 else inst) * 105 / 100 else nearPrice(r, if (inst > 2) 2 else inst);
      let price = switch (kind) { case (#market or #stop or #trailingStop) (if (rnd(50) == 0) p else 0); case (_) p };
      let stopPrice = switch (kind) { case (#stop or #stopLimit or #trailingStop) nearPrice(r, if (inst > 2) 2 else inst); case (_) (if (rnd(60) == 0) p else 0) };
      let peak = if (kind == #limit and qty >= 3 * lot and rnd(6) == 0) lot * (1 + rnd(qty / lot - 1)) else if (rnd(80) == 0) lot else 0;
      let immediate = kind == #market or kind == #ioc or kind == #fok or kind == #stop or kind == #trailingStop;
      let v = rnd(100);
      let validity : T.Validity = if (immediate) (if (v < 97) #day else #gtc) else if (v < 45) #day else if (v < 80) #gtc else #gtd;
      let gtdDay = if (validity == #gtd) (if (rnd(20) == 0) today() - 1 else today() + rnd(3)) else if (rnd(80) == 0) today() else 0;
      let selfTrade : T.SelfTrade = pick<T.SelfTrade>([#cancelIncoming, #cancelResting, #cancelBoth]);
      let oco = if (rnd(10) == 0 and r.st.nextOrder > 1) r.st.nextOrder - 1 - rnd(Nat.min(5, r.st.nextOrder - 1)) else 0;
      // a trail of whole ticks at its stop price (one in thirty off the tick); now and then a trail on another kind
      let tick = if (inst == 1 or stopPrice >= 2_000) 10 else 1;
      let trail = if (kind == #trailingStop) (tick * (1 + rnd(12)) + (if (rnd(30) == 0) 1 else 0)) else if (rnd(120) == 0) tick else 0;
      let capacity : T.Capacity = if (rnd(3) == 0) #principal else #agency;
      #placeOrder({ account; instrument = inst; side; kind; qty; price; stopPrice; peak; validity; gtdDay; selfTrade; capacity; shortSale = side == #sell and rnd(8) == 0; clientRef = clientRef(r); oco; trail;
        member = memberOf(account) + (if (rnd(60) == 0) 1 else 0); trader = traderIdOf(who) + (if (rnd(60) == 0) 1 else 0) })
    };
    /// The acts under four eyes a stream may give: the operator proposes, a director approves (`govern`).
    public func underFourEyes(c : T.Command) : Bool {
      // (the clearing's four-eyes acts are listed with the book's)
      switch (c) {
        case (#halt(_) or #resume(_) or #revive(_) or #setLimits(_) or #setBlackout(_) or #liftBlackout(_) or #setClearing(_) or #setMargin(_) or #admitClearing(_)
          or #designateClearing(_) or #fundSkin(_) or #declareDefault(_) or #closeDefault(_)) true;
        case (_) false
      }
    };
    public func randomPhase() : T.Phase { let x = rnd(100); if (x < 55) #continuous else if (x < 75) #auction else if (x < 85) #closingAuction else if (x < 93) #tradeAtClose else #closed };
    /// An account's client code in the exchange's rows ("" for a house account or none).
    public func clientOf(account : Nat) : Blob { switch (X.account(xs, account)) { case (?a) a.client; case null "" } };
    public func randomCommand(r : Run) : (Principal, T.Command) {
      // the clearing's acts (SPEC §18 to §21), on a run that clears, one command in five
      if (B.clearingTerms(r.st) != null and rnd(5) == 0) return randomClearing(r);
      // securities loans and insider blackouts (SPEC §16, §17), now and then
      if (rnd(60) == 0) {
        let account = 1 + rnd(18); let inst = 1 + rnd(2);
        r.depSeq += 1;
        return (depository, #borrow({ account; member = memberOf(account); instrument = inst; qty = if (inst == 1) 10 * (1 + rnd(20)) else 1 + rnd(20); reference = depRef(r.depSeq + streams * 1_000_000) }));
      };
      if (rnd(60) == 0) { let who = pickTrader(); let account = accountFor(who); let inst = 1 + rnd(2); return (who, #returnBorrow({ account; member = memberOf(account); instrument = inst; qty = if (inst == 1) 10 * (1 + rnd(5)) else 1 + rnd(5) })) };
      if (rnd(200) == 0) { let account = 2 + rnd(7); return (operator, #setBlackout({ instrument = 1 + rnd(2); client = clientOf(account); until = if (rnd(2) == 0) 0 else today() + rnd(3); reason = "on the insider list" })) };
      if (rnd(8) == 0) {
        var bid = r.st.nextBlackout;
        while (bid > 1) { bid -= 1; switch (RS.get(r.st.blackoutStore, B.blackoutRows, bid)) { case (?b) { if (b.active) return (operator, #liftBlackout({ blackout = bid })) }; case null {} } };
      };
      // the day's seal, now and then; one time in four for a day other than the market day (refused)
      if (rnd(150) == 0) return (scheduler, #sealDay({ day = if (rnd(4) == 0) today() + 1 else today() }));
      // recovery first, now and then: an active kill swept until its target holds nothing open, then revived; a halted
      // instrument resumed. A block then lasts a few commands, not the stream.
      if (rnd(4) == 0) {
        var kid = r.st.nextKill;
        while (kid > 1) {
          kid -= 1;
          switch (B.kill(r.st, kid)) {
            case (?k) { if (k.active) return if (rnd(3) == 0) (operator, #revive({ kill = kid })) else (scheduler, #killSweep({ kill = kid; limit = 500 })) };
            case null {};
          };
        };
      };
      if (rnd(5) == 0) {
        for (i in [1, 2].vals()) { switch (B.instrument(r.st, i)) { case (?x) { if (x.phase == #halted) return (operator, #resume({ instrument = i })) }; case null {} } };
      };
      let x = rnd(1_000);
      if (x < 70) {
        let ledger = pick<Principal>([cash, sharesA, sharesB]);
        let amount = if (peq(ledger, cash)) 1 + rnd(80_000_000) else if (peq(ledger, sharesA)) 10 * (1 + rnd(300)) else 1 + rnd(200);
        r.depSeq += 1;
        let reference = if (rnd(60) == 0) depRef(r.depSeq - 1 + streams * 1_000_000) else if (rnd(80) == 0) bytes(r.depSeq, 31) else depRef(r.depSeq + streams * 1_000_000);
        let account = 1 + rnd(18);
        // now and then the wrong member: refused (the log's member must be the account's)
        return (depository, #deposit({ account; member = if (rnd(60) == 0) 3 - Nat.min(2, memberOf(account)) else memberOf(account); ledger; amount = if (rnd(80) == 0) 0 else amount; reference }));
      };
      if (x < 100) { let who = pickTrader(); let account = accountFor(who); return (who, #withdraw({ account; member = memberOf(account); ledger = pick<Principal>([cash, sharesA, sharesB]); amount = rnd(3_000_000) })) };
      if (x < 680) { let who = pickTrader(); return (who, randomOrder(r, who)) };
      let recent = if (r.st.nextOrder > 1) r.st.nextOrder - 1 - rnd(Nat.min(40, r.st.nextOrder - 1)) + (if (rnd(30) == 0) 50 else 0) else 1;
      let owner = switch (B.order(r.st, recent)) { case (?o) (if (rnd(15) == 0) pickTrader() else traderOf(o.account)); case null pickTrader() };
      if (x < 760) return (owner, #cancelOrder({ order = recent }));
      if (x < 840) {
        let (q, p) = switch (B.order(r.st, recent)) {
          case (?o) {
            let lot = if (o.instrument == 1) 10 else 1;
            let base : Int = o.remaining + lot * rnd(5) - lot * rnd(5);
            (if (base < lot) lot else Int.abs(base), if (rnd(2) == 0) o.price else nearPrice(r, o.instrument))
          };
          case null (10, 85_000);
        };
        return (owner, #amendOrder({ order = recent; qty = q; price = p }));
      };
      if (x < 855) { let who = pickTrader(); let account = accountFor(who); return (who, #massCancel({ account; member = memberOf(account); limit = 1 + rnd(30) })) };
      if (x < 870) { let i = 1 + rnd(2); return (scheduler, #setReference({ instrument = i; price = if (rnd(6) == 0) jumpPrice(r, i) else nearPrice(r, i) })) };
      if (x < 885) { let i = 1 + rnd(2); return (scheduler, #setTrading({ instrument = i; open = rnd(5) != 0 })) };
      if (x < 905) return (scheduler, #flush);
      if (x < 912) return (scheduler, #endOfDay({ limit = 1 + rnd(60) }));
      if (x < 922) return (scheduler, #expireGtd({ day = if (rnd(10) == 0) today() + 1 else today(); limit = 1 + rnd(60) }));
      if (x < 927) return (pick<Principal>([stranger, clearer, operator]), #clear({ time = now }));
      let i = 1 + rnd(2);
      if (x < 945) {
        let phase = randomPhase();
        let (from, to) = if ((phase == #auction or phase == #closingAuction) and rnd(5) == 0) { let f = now + Nat64.fromNat(rnd(5)) * 1_000_000_000; (f, f + Nat64.fromNat(rnd(10)) * 1_000_000_000) } else (0 : Nat64, 0 : Nat64);
        return (scheduler, #setPhase({ instrument = i; phase; endFrom = from; endTo = to }));
      };
      if (x < 965) {
        // a closing auction goes on, mostly, to trade at close (the session's order, §8); any auction may go anywhere
        let closing = switch (B.instrument(r.st, i)) { case (?y) y.phase == #closingAuction; case null false };
        let y = rnd(10);
        return (scheduler, #uncross({ instrument = i; next = if (closing and y < 8) #tradeAtClose else if (y < 7) #continuous else if (y < 9) #tradeAtClose else #closed }))
      };
      if (x < 968) return (operator, #halt({ instrument = i; reason = "a regulatory halt" }));
      if (x < 978) return (operator, #resume({ instrument = i }));
      // kills are rare and their sweeps and revivals aim at the latest, so a block does not last the stream
      let latest = if (r.st.nextKill > 1) r.st.nextKill - 1 - (if (rnd(4) == 0) rnd(r.st.nextKill - 1) else 0) else 1;
      if (x < 980) {
        let target = rnd(3);
        let who = if (rnd(5) < 3) operator else pickTrader();
        // a member's kill, or one trader's naming its member (now and then another member: refused)
        let trader = if (target == 0) 0 else 1 + rnd(4);
        let member = if (trader == 0) 1 + rnd(2) else if (rnd(30) == 0) 3 - Nat.min(2, memberOfTrader(trader)) else memberOfTrader(trader);
        return (who, #kill({ member; trader; reason = "the member's risk desk" }));
      };
      if (x < 990) return (scheduler, #killSweep({ kill = latest + (if (rnd(20) == 0) 50 else 0); limit = 1 + rnd(40) }));
      if (x < 994) return (operator, #revive({ kill = latest }));
      if (x < 1_000) {
        let m = if (rnd(10) == 0) 3 else 1 + rnd(2);
        return (operator, #setLimits({ member = m; maxOrderQty = if (rnd(4) == 0) 100 + rnd(200) else 0; maxOrderValue = if (rnd(4) == 0) 5_000_000 + rnd(25_000_000) else 0;
          creditLimit = if (rnd(4) == 0) 200_000_000 + rnd(800_000_000) else 0 }));
      };
      (stranger, randomOrder(r, t1))
    };
    /// A run that clears (SPEC §18 to §21): the CCP's terms (cycles of 900 seconds), both instruments' margins, members 1,
    /// 2 and 4 admitted, accounts 5, 6, 13 and 14 designated, the venue's skin, collateral and the fund's first call paid.
    /// Every act given as a stream's command, so the reference judges it.
    public func clearingRun(r : Run) {
      openClearing();
      ignore tick();
      // settlement accounts with little cash beyond their collateral and fund: cycles fail now and then
      for (a in [1, 9, 20].vals()) { deposit(r, a, cash, 3_000_000 + rnd(6_000_000)); deposit(r, a, sharesA, 1_000 * (1 + rnd(5))); deposit(r, a, sharesB, 100 * (1 + rnd(20))) };
      deposit(r, 19, cash, 5_000_000);
      // resources small against the orders' values, so margins and the CCP's free cash refuse some of them
      ignore govern(r, #setClearing({ ccpAccount = 18; ccpMember = 3; cashLedger = cash; cycleSecs = 900; cycleDays = 0; penaltyBps = 50 + rnd(200); deadlineCycles = 1 + rnd(3); fundBps = 500 + rnd(2_000); fundFloor = 3_000_000 }));
      ignore govern(r, #setMargin({ instrument = 1; imBps = 500 + rnd(2_000) }));
      ignore govern(r, #setMargin({ instrument = 2; imBps = 500 + rnd(2_000) }));
      for ((mem, settle_) in [(1, 1), (2, 9), (4, 20)].vals()) ignore govern(r, #admitClearing({ member = mem; settlementAccount = settle_; creditLine = rnd(2) * 1_000_000 }));
      for ((a, mem) in [(5, 1), (6, 1), (13, 2), (14, 2)].vals()) ignore govern(r, #designateClearing({ account = a; member = mem }));
      ignore govern(r, #fundSkin({ account = 19; amount = 500_000 + rnd(1_000_000) }));
      for ((who, mem) in [(t1, 1), (t3, 2), (t6, 4)].vals()) ignore act(r, who, #postCollateral({ member = mem; amount = 500_000 + rnd(3_000_000) }));
      ignore act(r, scheduler, #callFund);
      for ((who, mem) in [(t1, 1), (t3, 2), (t6, 4)].vals()) ignore act(r, who, #contributeFund({ member = mem; amount = 1_000_000 }));
    };
    /// A random act of the clearing: collateral in and out, the fund's call and contributions, the cycle's cut and
    /// settlement (time moved past the cycle's length now and then), close-outs, and, rarely, a default and its waterfall.
    public func randomClearing(r : Run) : (Principal, T.Command) {
      let (who, mem) = pick<(Principal, Nat)>([(t1, 1), (t3, 2), (t6, 4)]);
      let x = rnd(100);
      if (x < 12) return (who, #postCollateral({ member = mem; amount = 1 + rnd(2_000_000) }));
      if (x < 22) return (who, #withdrawCollateral({ member = mem; amount = if (rnd(10) == 0) 0 else 1 + rnd(15_000_000) }));
      if (x < 27) return (scheduler, #callFund);
      if (x < 37) {
        let need = switch (B.clearingMember(r.st, mem)) { case (?(_, row)) (if (row.fundRequired > row.fund) row.fundRequired - row.fund else 0); case null 0 };
        return (who, #contributeFund({ member = mem; amount = if (need == 0 or rnd(8) == 0) 1 + rnd(1_000_000) else need }));
      };
      let (_, _, cycleNo, settled, _) = B.clearingFigures(r.st);
      if (x < 57) { if (rnd(3) != 0) advance(900); return (scheduler, #cutCycle({ cycle = if (rnd(15) == 0) cycleNo + 1 else cycleNo; settleDay = if (rnd(20) == 0) today() else 0 })) };
      if (x < 80) return (scheduler, #settleCycle({ cycle = if (rnd(15) == 0) settled + 2 else settled + 1 }));
      if (x < 90) return (scheduler, #closeOut({ member = if (rnd(10) == 0) 3 else mem; instrument = 1 + rnd(2) }));
      if (x < 92) return (operator, #setMargin({ instrument = 1 + rnd(2); imBps = 300 + rnd(3_000) }));
      if (x < 93) return (operator, #declareDefault({ member = mem; reason = "a fail past the deadline" }));
      if (x < 96) return (operator, #closeDefault({ member = mem }));
      (who, #postCollateral({ member = if (rnd(2) == 0) 3 else mem; amount = 1 }))
    };
    /// `count` random streams on fresh books that clear (`clearingRun`), each `steps` commands, the due clear recorded
    /// before each so every open book is seen uncrossed. Returns the commands and the books replayed.
    public func clearingStreams(first : Nat, count : Nat, steps : Nat) : (Nat, Nat) {
      var commands = 0; var replays = 0;
      for (k in Nat.range(first, first + count)) {
        seed := seed ^ Nat64.fromNat(0xC1_0000 + k);
        let r = newRun(false);
        clearingBias := true;
        for (a in [2 + rnd(2), 5, 6, 10 + rnd(2), 13, 14].vals()) { ignore tick(); deposit(r, a, cash, 50_000_000 + rnd(200_000_000)); deposit(r, a, sharesA, 100 * (1 + rnd(30))); deposit(r, a, sharesB, 10 * (1 + rnd(40))) };
        clearingRun(r);
        ignore tick(); ignore act(r, scheduler, #setTrading({ instrument = 1; open = true })); ignore act(r, scheduler, #setTrading({ instrument = 2; open = true }));
        randomStream(r, steps, 250, true); commands += steps;
        clearingBias := false;
        if (replayed(r)) replays += 1 else check(false, "clearing stream " # n(k) # " replay");
      };
      (commands, replays)
    };
    /// A stream of `steps` random commands on a run, a checkpoint every `every`; with `explicit`, the due clear is recorded
    /// before each command (as the command's own submission would) so that every open book can be seen uncrossed, and a
    /// sample of refusals is held to every dimension.
    public func randomStream(r : Run, steps : Nat, every : Nat, explicit : Bool) {
      for (k in Nat.range(0, steps)) {
        let a = rnd(100);
        if (a < 30) ignore tick() else if (a == 30) advance(70_000 + rnd(30_000));
        let (who, c) = randomCommand(r);
        if (explicit) {
          ignore B.flushDue(r.st, now, who);
          feedOut(r);
          scanClears(r);
          uncrossed(r);
          if (k % 97 == 0) {
            let d0 = dims(r.st);
            switch (step(r, who, c)) { case (#err(_)) { let d1 = dims(r.st); if (d1.counts == d0.counts and d1.counters == d0.counters and d1.fp == d0.fp) refusalsUnmoved += 1 else check(false, "a random refusal moved the book: " # cmdText(c)) }; case (_) {} };
          } else ignore step(r, who, c);
        } else ignore step(r, who, c);
        if (k % every == every - 1) checkpoint(r);
      };
      checkpoint(r);
    };
    public func replayed(r : Run) : Bool {
      let fresh = B.newStateOver(r.st.log);
      B.setPolicies(fresh, bookDuals());
      let rp = B.replay(fresh);
      rp.faults.size() == 0 and B.fingerprint(fresh) == B.fingerprint(r.st) and B.counts(fresh) == B.counts(r.st) and B.counters(fresh) == B.counters(r.st)
    };
    // ─── PART 5: the order of arrival inside a block changes nothing across accounts (§1) ─────
    /// One book through a setup, a resting book, then one batch of orders each from a different account, given in `order`;
    /// the clock starts from `t0` so that both books carry the same times.
    public func trialRun(t0 : Nat64, deposits : [(Nat, Principal, Nat)], resting : [T.Command], batch : [T.Command], order_ : [Nat]) : Run {
      now := t0;
      let r = newRun(false);
      ignore tick();
      for ((a, l, x) in deposits.vals()) deposit(r, a, l, x);
      ignore act(r, scheduler, #setTrading({ instrument = 1; open = true })); ignore act(r, scheduler, #setTrading({ instrument = 2; open = true }));
      ignore tick();
      for (c in resting.vals()) ignore act(r, switch (c) { case (#placeOrder(x)) traderOf(x.account); case (_) operator }, c);
      ignore tick();
      for (i in order_.vals()) ignore act(r, switch (batch[i]) { case (#placeOrder(x)) traderOf(x.account); case (_) operator }, batch[i]);
      settle(r); settle(r);
      checkpoint(r);
      r
    };
    /// What a book holds, named by the member's references instead of the book's order numbers: every order's state,
    /// every balance, and the batch's clear (price, volume, pairs, cancelled and triggered as sets).
    public func summary(r : Run) : [Text] {
      let out = List.empty<Text>();
      func nameOf(id : Nat) : Text { switch (B.order(r.st, id)) { case (?o) n(o.account) # "/" # o.clientRef; case null "?" # n(id) } };
      var id = 1;
      while (id < r.st.nextOrder) {
        switch (B.order(r.st, id)) { case (?o) List.add(out, "order " # nameOf(id) # " " # debug_show((o.status, o.remaining, o.filled, o.held, o.price, o.prio))); case null {} };
        id += 1;
      };
      var bid = 1;
      while (bid < r.st.nextBalance) { switch (RS.get(r.st.balanceRows, B.balances, bid)) { case (?b) List.add(out, "balance " # n(b.account) # " " # ledgerName(b.ledger) # " " # n(b.available) # " " # n(b.held)); case null {} }; bid += 1 };
      var i = 0;
      while (i < DL.length(r.st.log)) {
        switch (DL.get(r.st.log, K.codec, i)) {
          case (?b) {
            switch (b.event) {
              case (#executed({ command = #clear(_); effects })) {
                var k = 1;
                while (k < effects.size()) {
                  List.add(out, "clear " # Nat64.toText(b.timestamp) # " instrument " # n(effects[k]) # " at " # n(effects[k + 1]) # " volume " # n(effects[k + 2]));
                  let pairs = effects[k + 3];
                  for (j in Nat.range(0, pairs)) List.add(out, "pair " # Nat64.toText(b.timestamp) # " " # nameOf(effects[k + 4 + j * 3]) # " " # nameOf(effects[k + 5 + j * 3]) # " " # n(effects[k + 6 + j * 3]));
                  let at = k + 4 + pairs * 3; let nc = effects[at]; let tp = at + 1 + nc; let nt = effects[tp]; let sp = tp + 1 + 4 * nt; let ns = effects[sp];
                  for (j in Nat.range(0, nc)) List.add(out, "cancelled " # Nat64.toText(b.timestamp) # " " # nameOf(effects[at + 1 + j]));
                  for (j in Nat.range(0, nt)) List.add(out, "triggered " # Nat64.toText(b.timestamp) # " " # nameOf(effects[tp + 1 + 4 * j]) # " shows " # n(effects[tp + 4 + 4 * j]));
                  for (j in Nat.range(0, ns)) List.add(out, "shows " # Nat64.toText(b.timestamp) # " " # nameOf(effects[sp + 1 + 2 * j]) # " " # n(effects[sp + 2 + 2 * j]));
                  if (effects[sp + 1 + 2 * ns] == 1) List.add(out, "interrupted " # Nat64.toText(b.timestamp) # " instrument " # n(effects[k]));
                  k := sp + 2 + 2 * ns;
                };
              };
              case (#executed({ command = #uncross(_); effects })) {
                if (effects[2] > 0) {
                  List.add(out, "uncross " # Nat64.toText(b.timestamp) # " instrument " # n(effects[1]) # " at " # n(effects[2]) # " volume " # n(effects[3]));
                  for (j in Nat.range(0, effects[4])) List.add(out, "pair " # Nat64.toText(b.timestamp) # " " # nameOf(effects[5 + j * 3]) # " " # nameOf(effects[6 + j * 3]) # " " # n(effects[7 + j * 3]));
                };
              };
              case (_) {};
            };
          };
          case null {};
        };
        i += 1;
      };
      Array.sort<Text>(List.toArray(out), Text.compare)
    };
    public func depthText(r : Run) : Text {
      var o = "";
      for (i in [1, 2].vals()) { for (side in [#buy, #sell].vals()) { switch (B.depth(r.st, i, side, null, 500)) { case (#ok(p)) { for ((id, _) in p.rows.vals()) o := o # n(id) # "," }; case (#err(_)) o := o # "err" }; o := o # "|" } };
      o
    };

    /// `trials` blocks, each given in two orders on two fresh books (§1): every outcome compared by the member's
    /// reference. Returns (trials equal, trials in which orders traded, the control red: a block missing an order
    /// compares unequal).
    public func permutationTrials(trials : Nat) : (Nat, Nat, Bool) {
      var permutationsEqual = 0;
      var permutationTrades = 0;
      var permutationControl = false;
      for (t in Nat.range(0, trials)) {
        seed := seed ^ Nat64.fromNat(0x5000 + t);
        let deposits = List.empty<(Nat, Principal, Nat)>();
        for (a in Nat.range(1, 17)) { List.add(deposits, (a, cash, 100_000_000 + rnd(300_000_000))); List.add(deposits, (a, sharesA, 100 * (1 + rnd(40)))); List.add(deposits, (a, sharesB, 10 * (1 + rnd(30)))) };
        let resting = List.empty<T.Command>();
        for (k in Nat.range(0, 14)) {
          let a = 1 + rnd(16); let i = 1 + rnd(2); let lot = if (i == 1) 10 else 1;
          List.add(resting, order(a, i, if (rnd(2) == 0) #buy else #sell, #limit, lot * (1 + rnd(20)), nearAt(if (i == 1) 85_000 else 1_995, i), 0, 0, #gtc, 0, #cancelResting, "rest" # n(k), 0));
        };
        let batch = List.empty<T.Command>();
        for (a in Nat.range(1, 17)) {
          if (rnd(10) < 8) {
            let i = 1 + rnd(2); let lot = if (i == 1) 10 else 1; let q = lot * (1 + rnd(20));
            let k = rnd(10);
            let kind : T.Kind = if (k < 5) #limit else if (k < 7) #ioc else if (k < 8) #fok else #market;
            let peak = if (kind == #limit and q >= 3 * lot and rnd(4) == 0) lot else 0;
            List.add(batch, order(a, i, if (rnd(2) == 0) #buy else #sell, kind, q, if (kind == #market) 0 else nearAt(if (i == 1) 85_000 else 1_995, i), 0, peak, if (kind == #limit and rnd(2) == 0) #gtc else #day, 0, pick<T.SelfTrade>([#cancelIncoming, #cancelResting, #cancelBoth]), "b" # n(a), 0));
          };
        };
        let bs = List.toArray(batch);
        let forward = Array.tabulate<Nat>(bs.size(), func(i) { i });
        // a shuffle drawn from the generator (Fisher-Yates)
        let shuffled = Array.toVarArray<Nat>(forward);
        var i = shuffled.size();
        while (i > 1) { let j = rnd(i); i -= 1; let x = shuffled[i]; shuffled[i] := shuffled[j]; shuffled[j] := x };
        let t0 = now + 1_000_000_000;
        let ra = trialRun(t0, List.toArray(deposits), List.toArray(resting), bs, forward);
        let sa = summary(ra);
        let rb = trialRun(t0, List.toArray(deposits), List.toArray(resting), bs, Array.fromVarArray<Nat>(shuffled));
        let sb = summary(rb);
        if (sa == sb) permutationsEqual += 1 else check(false, "trial " # n(t) # ": the order of arrival changed the outcome");
        if (Array.find<Text>(sa, func(x) { Text.startsWith(x, #text "pair ") }) != null) permutationTrades += 1;
        // the control: the same block missing its last order must not compare equal
        if (t == 0 and bs.size() > 1) {
          let rc = trialRun(t0, List.toArray(deposits), List.toArray(resting), bs, Array.tabulate<Nat>(bs.size() - 1, func(i) { i }));
          permutationControl := summary(rc) != sa;
        };
        now := now + 60_000_000_000;
      };

      (permutationsEqual, permutationTrades, permutationControl)
    };

    /// `count` random streams of `steps` commands, each on a fresh book with funds deposited and both instruments open;
    /// the even ones record the due clear before each command and check the uncrossed books and sampled refusals. Each
    /// book's log replayed. Returns (commands, books replayed to the same fingerprint).
    public func randomStreams(first : Nat, count : Nat, steps : Nat) : (Nat, Nat) {
      var commands = 0; var replays = 0;
      let keep = terms;
      terms := tightTerms;
      for (s in Nat.range(first, first + count)) {
        seed := seed ^ Nat64.fromNat(0x1000 + s);
        let r = newRun(false);
        for (a in Nat.range(1, 17)) { if (rnd(3) != 0) { ignore tick(); deposit(r, a, cash, 50_000_000 + rnd(400_000_000)); deposit(r, a, sharesA, 100 * (1 + rnd(50))); deposit(r, a, sharesB, 10 * (1 + rnd(40))) } };
        ignore tick(); ignore act(r, scheduler, #setTrading({ instrument = 1; open = true })); ignore act(r, scheduler, #setTrading({ instrument = 2; open = true }));
        // half the stream, then both instruments into the closing auction (the session's last stretch), then the rest:
        // the closing price and trade at close occur in every stream
        randomStream(r, steps / 2, 250, s % 2 == 0);
        ignore tick(); for (i in [1, 2].vals()) ignore act(r, scheduler, #setPhase({ instrument = i; phase = #closingAuction; endFrom = 0; endTo = 0 }));
        randomStream(r, steps - steps / 2, 250, s % 2 == 0); commands += steps;
        if (replayed(r)) replays += 1 else check(false, "stream " # n(s) # " replay");
      };
      terms := keep;
      (commands, replays)
    };

    /// `count` short streams of `steps` commands, each on a fresh book: a few accounts funded, both instruments open,
    /// the due clear recorded before each command and the open books checked uncrossed, a checkpoint at the end, the
    /// log replayed for every tenth. Returns (commands, books replayed to the same fingerprint).
    public func shortStreams(first : Nat, count : Nat, steps : Nat) : (Nat, Nat) {
      var commands = 0; var replays = 0;
      for (s in Nat.range(first, first + count)) {
        seed := seed ^ Nat64.fromNat(0x5_0000 + s);
        let r = newRun(false);
        for (a in [1 + rnd(8), 1 + rnd(8), 9 + rnd(8), 9 + rnd(8)].vals()) { ignore tick(); deposit(r, a, cash, 50_000_000 + rnd(400_000_000)); deposit(r, a, sharesA, 100 * (1 + rnd(50))); deposit(r, a, sharesB, 10 * (1 + rnd(40))) };
        ignore tick(); ignore act(r, scheduler, #setTrading({ instrument = 1; open = true })); ignore act(r, scheduler, #setTrading({ instrument = 2; open = true }));
        randomStream(r, steps, steps + 1, true); commands += steps;
        if (s % 10 == 0) { if (replayed(r)) replays += 1 else check(false, "short stream " # n(s) # " replay") };
      };
      (commands, replays)
    };

    /// `count` episodes of `steps` random commands on one book, each from an empty book: after an episode every account
    /// with an open order cancels them all and a closed instrument is opened again. The due clear is recorded and the
    /// open books checked uncrossed before every fifth command; a checkpoint every `every` episodes. Returns commands.
    public func episodes(count : Nat, steps : Nat, every : Nat) : Nat {
      let keep = terms;
      terms := tightTerms;
      let r = newRun(false);
      terms := keep;
      for (a in Nat.range(1, 17)) { ignore tick(); deposit(r, a, cash, 2_000_000_000); deposit(r, a, sharesA, 20_000); deposit(r, a, sharesB, 2_000) };
      ignore tick(); ignore act(r, scheduler, #setTrading({ instrument = 1; open = true })); ignore act(r, scheduler, #setTrading({ instrument = 2; open = true }));
      var commands = 0;
      for (e in Nat.range(0, count)) {
        let from = r.st.nextOrder;
        for (k in Nat.range(0, steps)) {
          let a = rnd(100);
          if (a < 30) ignore tick() else if (a == 30) advance(70_000 + rnd(30_000));
          let (who, c) = randomCommand(r);
          if (k % 5 == 0) { ignore B.flushDue(r.st, now, who); feedOut(r); scanClears(r); uncrossed(r) };
          ignore step(r, who, c);
        };
        commands += steps;
        // the reset: every instrument back to continuous trading, every kill swept and revived, every limit lifted, then
        // the accounts holding open orders cancel them; the book is then empty for the next episode
        ignore tick();
        for (i in [1, 2].vals()) {
          switch (B.instrument(r.st, i)) {
            case (?x) {
              if (x.phase == #halted) ignore govern(r, #resume({ instrument = i }));
              switch (B.instrument(r.st, i)) {
                case (?y) {
                  if (y.phase == #auction or y.phase == #closingAuction) {
                    let until = Nat64.max(y.endFrom, y.interruptUntil);
                    if (until > now) now := until;
                    ignore tick();
                    ignore act(r, scheduler, #uncross({ instrument = i; next = #continuous }));
                  } else if (y.phase != #continuous) ignore act(r, scheduler, #setPhase({ instrument = i; phase = #continuous; endFrom = 0; endTo = 0 }));
                };
                case null {};
              };
            };
            case null {};
          };
        };
        var kid = 1;
        while (kid < r.st.nextKill) {
          switch (B.kill(r.st, kid)) {
            case (?k) { if (k.active) { label sweeping loop { switch (act(r, scheduler, #killSweep({ kill = kid; limit = 500 }))) { case (#ok(#executed(x))) { if (x.effects[2] == 0) break sweeping }; case (_) break sweeping } }; ignore govern(r, #revive({ kill = kid })) } };
            case null {};
          };
          kid += 1;
        };
        var bid = 1;
        while (bid < r.st.nextBlackout) { switch (RS.get(r.st.blackoutStore, B.blackoutRows, bid)) { case (?b) { if (b.active) ignore govern(r, #liftBlackout({ blackout = bid })) }; case null {} }; bid += 1 };
        var lid = 1;
        while (lid < r.st.nextLimit) {
          switch (RS.get(r.st.limitStore, B.limitRows, lid)) {
            case (?row) { let l = row.limits; if (l.maxOrderQty != 0 or l.maxOrderValue != 0 or l.creditLimit != 0) ignore govern(r, #setLimits({ member = row.member; maxOrderQty = 0; maxOrderValue = 0; creditLimit = 0 })) };
            case null {};
          };
          lid += 1;
        };
        let open = Map.empty<Nat, Bool>();
        var id = from;
        while (id < r.st.nextOrder) { switch (B.order(r.st, id)) { case (?o) { if (o.status == #live or o.status == #waiting) Map.add(open, Nat.compare, o.account, true) }; case null {} }; id += 1 };
        for ((acct, _) in Map.entries(open)) ignore act(r, traderOf(acct), #massCancel({ account = acct; member = memberOf(acct); limit = 500 }));
        var stillOpen = 0;
        id := from;
        while (id < r.st.nextOrder) { switch (B.order(r.st, id)) { case (?o) { if (o.status == #live or o.status == #waiting) stillOpen += 1 }; case null {} }; id += 1 };
        check(stillOpen == 0, "episode " # n(e) # " leaves an empty book");
        saw("episodes");
        // one episode in six begins in the closing auction, the session's last stretch, so the closing price and trade at
        // close occur within an episode's commands
        if (e % 6 == 5) { ignore tick(); for (i in [1, 2].vals()) ignore act(r, scheduler, #setPhase({ instrument = i; phase = #closingAuction; endFrom = 0; endTo = 0 })) };
        if (e % every == every - 1) checkpoint(r);
      };
      checkpoint(r);
      commands
    };

    /// Coverage: how often each named event happened in this process.
    public func printCoverage(names : [Text]) { for (what in names.vals()) Debug.print("count: " # what # " = " # n(seenCount(what))) };
  };
}
