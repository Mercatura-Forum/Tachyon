/// SurvCore.mo: the surveillance desk (surveillance/SPEC.md): a fold over the book's log, read in bounded scans, with
/// its own log of commands. The desk's projections and rules are functions of the book's blocks and the exchange's rows;
/// its cases and reports are its own commands. Replaying the desk's log over the same book log reproduces every row.
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
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import Fold "mo:kernel/domain/Fold";
import Cmd "mo:kernel/domain/Command";
import Auth "mo:kernel/auth/AuthTypes";
import Perm "mo:kernel/auth/Permissions";
import MC "mo:kernel/auth/MakerChecker";
import R "mo:kernel/rows/StableRows";
import RS "mo:kernel/rows/RowStore";
import Page "mo:kernel/rows/Page";

import X "../../exchange/src/ExchangeCore";
import B "../../book/src/BookCore";
import BK "../../book/src/BookCanonical";
import T "SurvTypes";
import K "SurvCanonical";

module {
  public type Error = { #surv : T.Error; #auth : Auth.Error; #encoding : Text };
  public type Result<A> = Result.Result<A, Error>;
  public type Authority = { hasGrant : (Principal, Auth.PermissionId) -> Bool; holdsRole : (Principal, Auth.RoleId) -> Bool };
  public type Outcome = { #executed : { block : Nat; effects : T.Effects }; #proposed : { proposal : Cmd.ProposalId; required : Nat } };

  // ═══════════════════════════════════════════════════════
  //  THE PERMISSION CATALOGUE
  // ═══════════════════════════════════════════════════════

  /// A scan and the day's seal are the scheduler's: they read the book's log and write what its rules and the report's
  /// chain derive from it. Opening a case and noting it are the analyst's. The rules' thresholds, closing a case and
  /// filing a report change what the desk says to the regulator: four eyes.
  public func catalogue() : Perm.Catalogue { [
    Perm.p("surv.scan", "scan", #update, #command("scan"), false, false, false),
    Perm.p("surv.params", "params", #update, #command("setParams"), false, false, true),
    Perm.p("surv.case.open", "case", #create, #command("openCase"), false, false, false),
    Perm.p("surv.case.note", "case", #update, #command("noteCase"), false, false, false),
    Perm.p("surv.case.close", "case", #close, #command("closeCase"), false, false, true),
    Perm.p("surv.case.report", "case", #close, #command("reportCase"), false, false, true),
    Perm.p("surv.report.seal", "report", #create, #command("sealReport"), false, false, false),
    Perm.p("command.approve", "command", #update, #method("approve"), false, false, false),
    Perm.p("command.reject", "command", #update, #method("reject"), false, false, false),
  ] };
  public func singleActs() : [(Text, Text)] { [
    ("surv.scan", "the scheduler reads the next blocks of the book's log into the desk's rules; what it writes is derived from the log alone"),
    ("surv.case.open", "the analyst opens a case for an alert not yet in one; it changes nothing the regulator is told"),
    ("surv.case.note", "the analyst adds a note to an open case; the note is recorded in the desk's log and changes no outcome"),
    ("surv.report.seal", "the scheduler seals the market day's report: the chain of lines derived from the book's log, recorded with its hash"),
    ("command.approve", "a checker's approval: four eyes is the core's own rule, judged against the policy"),
    ("command.reject", "a checker's rejection of a proposal; it executes nothing"),
  ] };
  public let commandNames : [Text] = K.families;
  public let methodNames : [Text] = ["approve", "reject"];
  public func permissionOf(c : T.Command) : Auth.Permission {
    switch (Perm.byCommand(catalogue(), K.familyOf(c))) { case (?p) p; case null Runtime.trap("catalogue: no permission guards " # K.familyOf(c)) }
  };

  // ═══════════════════════════════════════════════════════
  //  THE ROWS
  // ═══════════════════════════════════════════════════════

  func padded(b : R.Buf, width : Nat) : Blob { while (b.size() < width) R.putByte(b, 0); R.done(b, width) };
  /// An owner in a fixed field: its length, then its bytes, padded to 32.
  public let OWNER_BYTES = 33;
  func putOwner(b : R.Buf, o : Blob) { R.putNat(b, o.size(), 1); for (x in o.vals()) R.putByte(b, x); var k = o.size(); while (k < 32) { R.putByte(b, 0); k += 1 } };
  func getOwner(a : [Nat8], off : Nat) : Blob { R.getBlob(a, off + 1, R.getNat(a, off, 1)) };
  func ownerField(o : Blob) : Blob { let b = R.buf(); putOwner(b, o); R.done(b, OWNER_BYTES) };
  func cat(xs : [Blob]) : Blob { var out : [Nat8] = []; for (x in xs.vals()) out := Array.concat<Nat8>(out, Blob.toArray(x)); Blob.fromArray(out) };

  /// A placed order as the desk projects it.
  public type OrdRow = { account : Nat; member : Nat; owner : Blob; side : Nat; instrument : Nat; qty : Nat; short : Bool; placedAt : Nat64; filled : Nat; trader : Nat };
  public let ORD_ROW_BYTES = 99;
  public let orderRows : RS.Decl<OrdRow> = {
    table = "survorders"; idBytes = 8; rowBytes = ORD_ROW_BYTES;
    encode = func(x : OrdRow) : Blob {
      let b = R.buf(); R.putNat(b, x.account, 8); R.putNat(b, x.member, 8); putOwner(b, x.owner); R.putNat(b, x.side, 1); R.putNat(b, x.instrument, 8);
      R.putNat(b, x.qty, 8); R.putBool(b, x.short); R.putNat(b, Nat64.toNat(x.placedAt), 8); R.putNat(b, x.filled, 8); R.putNat(b, x.trader, 8); padded(b, ORD_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : OrdRow {
      { account = R.getNat(a, 0, 8); member = R.getNat(a, 8, 8); owner = getOwner(a, 16); side = R.getNat(a, 49, 1); instrument = R.getNat(a, 50, 8); qty = R.getNat(a, 58, 8);
        short = R.getBool(a, 66); placedAt = Nat64.fromNat(R.getNat(a, 67, 8)); filled = R.getNat(a, 75, 8); trader = R.getNat(a, 83, 8) }
    };
    indexes = [];
  };
  /// A counting window (painting the tape between two owners; quote stuffing by a trader).
  public type WindowRow = { key : Blob; start : Nat64; startBlock : Nat; count : Nat };
  public let WINDOW_ROW_BYTES = 90;   // key 66 (two owner fields), start 8, start block 8, count 8
  public let windowRows : RS.Decl<WindowRow> = {
    table = "survwindows"; idBytes = 8; rowBytes = WINDOW_ROW_BYTES;
    encode = func(x : WindowRow) : Blob { let b = R.buf(); R.putBlob(b, x.key, 66); R.putNat(b, Nat64.toNat(x.start), 8); R.putNat(b, x.startBlock, 8); R.putNat(b, x.count, 8); padded(b, WINDOW_ROW_BYTES) };
    decode = func(a : [Nat8]) : WindowRow { { key = R.getBlob(a, 0, 66); start = Nat64.fromNat(R.getNat(a, 66, 8)); startBlock = R.getNat(a, 74, 8); count = R.getNat(a, 82, 8) } };
    indexes = [{ name = "byKey"; keyBytes = 66; keyOf = func(_ : Nat, x : WindowRow) : ?Blob { ?x.key } }];
  };
  /// An owner's window in an instrument for spoofing: quantities cancelled unfilled and traded, per side.
  public type SpoofRow = { owner : Blob; instrument : Nat; start : Nat64; cancelledBuy : Nat; cancelledSell : Nat; tradedBuy : Nat; tradedSell : Nat; alerted : Bool };
  public let SPOOF_ROW_BYTES = 82;
  public let spoofRows : RS.Decl<SpoofRow> = {
    table = "survspoof"; idBytes = 8; rowBytes = SPOOF_ROW_BYTES;
    encode = func(x : SpoofRow) : Blob {
      let b = R.buf(); putOwner(b, x.owner); R.putNat(b, x.instrument, 8); R.putNat(b, Nat64.toNat(x.start), 8);
      for (v in [x.cancelledBuy, x.cancelledSell, x.tradedBuy, x.tradedSell].vals()) R.putNat(b, v, 8); R.putBool(b, x.alerted); padded(b, SPOOF_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : SpoofRow {
      { owner = getOwner(a, 0); instrument = R.getNat(a, 33, 8); start = Nat64.fromNat(R.getNat(a, 41, 8)); cancelledBuy = R.getNat(a, 49, 8); cancelledSell = R.getNat(a, 57, 8);
        tradedBuy = R.getNat(a, 65, 8); tradedSell = R.getNat(a, 73, 8); alerted = R.getBool(a, 81) }
    };
    indexes = [{ name = "byOwner"; keyBytes = 41; keyOf = func(_ : Nat, x : SpoofRow) : ?Blob { ?cat([ownerField(x.owner), R.key(x.instrument, 8)]) } }];
  };
  /// An owner's net quantity traded in an instrument in the report's day (its epoch: the seals before it).
  public type PosRow = { owner : Blob; instrument : Nat; epoch : Nat; bought : Nat; sold : Nat; reported : Bool };
  public let POS_ROW_BYTES = 74;
  public let posRows : RS.Decl<PosRow> = {
    table = "survpositions"; idBytes = 8; rowBytes = POS_ROW_BYTES;
    encode = func(x : PosRow) : Blob { let b = R.buf(); putOwner(b, x.owner); R.putNat(b, x.instrument, 8); R.putNat(b, x.epoch, 8); R.putNat(b, x.bought, 8); R.putNat(b, x.sold, 8); R.putBool(b, x.reported); padded(b, POS_ROW_BYTES) };
    decode = func(a : [Nat8]) : PosRow { { owner = getOwner(a, 0); instrument = R.getNat(a, 33, 8); epoch = R.getNat(a, 41, 8); bought = R.getNat(a, 49, 8); sold = R.getNat(a, 57, 8); reported = R.getBool(a, 65) } };
    indexes = [{ name = "byOwner"; keyBytes = 41; keyOf = func(_ : Nat, x : PosRow) : ?Blob { ?cat([ownerField(x.owner), R.key(x.instrument, 8)]) } }];
  };
  /// An instrument's phase (the book's codes) and its last continuous price, by instrument id.
  public type InstRow = { phase : Nat; lastContinuous : Nat };
  public let instRows : RS.Decl<InstRow> = {
    table = "survinstruments"; idBytes = 8; rowBytes = 16;
    encode = func(x : InstRow) : Blob { let b = R.buf(); R.putNat(b, x.phase, 8); R.putNat(b, x.lastContinuous, 8); padded(b, 16) };
    decode = func(a : [Nat8]) : InstRow { { phase = R.getNat(a, 0, 8); lastContinuous = R.getNat(a, 8, 8) } };
    indexes = [];
  };
  public let ALERT_ROW_BYTES = 123;
  public let alertRows : RS.Decl<T.Alert> = {
    table = "survalerts"; idBytes = 8; rowBytes = ALERT_ROW_BYTES;
    encode = func(x : T.Alert) : Blob {
      let b = R.buf(); R.putNat(b, x.rule, 1); R.putNat(b, x.block, 8); R.putNat(b, x.instrument, 8); putOwner(b, x.owner); putOwner(b, x.other);
      for (v in [x.e1, x.e2, x.e3, x.e4, x.caseId].vals()) R.putNat(b, v, 8); padded(b, ALERT_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : T.Alert {
      { rule = R.getNat(a, 0, 1); block = R.getNat(a, 1, 8); instrument = R.getNat(a, 9, 8); owner = getOwner(a, 17); other = getOwner(a, 50);
        e1 = R.getNat(a, 83, 8); e2 = R.getNat(a, 91, 8); e3 = R.getNat(a, 99, 8); e4 = R.getNat(a, 107, 8); caseId = R.getNat(a, 115, 8) }
    };
    indexes = [];
  };
  public let caseRows : RS.Decl<T.Case> = {
    table = "survcases"; idBytes = 8; rowBytes = 17;
    encode = func(x : T.Case) : Blob { let b = R.buf(); R.putNat(b, x.alert, 8); R.putNat(b, x.status, 1); R.putNat(b, x.notes, 8); padded(b, 17) };
    decode = func(a : [Nat8]) : T.Case { { alert = R.getNat(a, 0, 8); status = R.getNat(a, 8, 1); notes = R.getNat(a, 9, 8) } };
    indexes = [];
  };
  /// A sealed day's report: the day, its lines and the chain's hash; found by day.
  public type ReportRow = { day : Nat; lines : Nat; hash : Blob };
  public let reportRows : RS.Decl<ReportRow> = {
    table = "survreports"; idBytes = 8; rowBytes = 48;
    encode = func(x : ReportRow) : Blob { let b = R.buf(); R.putNat(b, x.day, 8); R.putNat(b, x.lines, 8); R.putBlob(b, x.hash, 32); padded(b, 48) };
    decode = func(a : [Nat8]) : ReportRow { { day = R.getNat(a, 0, 8); lines = R.getNat(a, 8, 8); hash = R.getBlob(a, 16, 32) } };
    indexes = [{ name = "byDay"; keyBytes = 8; keyOf = func(_ : Nat, x : ReportRow) : ?Blob { ?R.key(x.day, 8) } }];
  };
  public type ProposalRow = MC.ProposalRow;
  public let proposals : RS.Decl<ProposalRow> = {
    table = "survproposals"; idBytes = 8; rowBytes = MC.PROPOSAL_ROW_BYTES; encode = MC.encodeProposalRow;
    decode = func(a : [Nat8]) : ProposalRow { MC.decodeProposalRow(Blob.fromArray(a)) };
    indexes = [];
  };

  // ═══════════════════════════════════════════════════════
  //  THE STATE
  // ═══════════════════════════════════════════════════════

  public let REPORT_DOMAIN = "thebes.surveillance.report.v1";
  func genesis() : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })) };

  public type State = {
    log : DL.State;
    var cursor : Nat;            // the next block of the book's log to read
    var params : T.Params;
    orderStore : RS.Store; var maxOrder : Nat;
    windowStore : RS.Store; var nextWindow : Nat;
    spoofStore : RS.Store; var nextSpoof : Nat;
    posStore : RS.Store; var nextPos : Nat;
    instStore : RS.Store; var instIds : [Nat];
    alertStore : RS.Store; var nextAlert : Nat;
    caseStore : RS.Store; var nextCase : Nat;
    reportStore : RS.Store; var nextReport : Nat;
    proposalRows : RS.Store;
    var epoch : Nat; var head : Blob; var lines : Nat; var lastSealed : Nat;
    var policies : [Auth.DualPolicy];
  };
  public func newState() : State { newStateOver(DL.newState()) };
  public func newStateOver(log : DL.State) : State {
    { log; var cursor = 0; var params = T.DEFAULT_PARAMS; orderStore = RS.newStore(orderRows); var maxOrder = 0; windowStore = RS.newStore(windowRows); var nextWindow = 1;
      spoofStore = RS.newStore(spoofRows); var nextSpoof = 1; posStore = RS.newStore(posRows); var nextPos = 1; instStore = RS.newStore(instRows); var instIds = [];
      alertStore = RS.newStore(alertRows); var nextAlert = 1; caseStore = RS.newStore(caseRows); var nextCase = 1; reportStore = RS.newStore(reportRows); var nextReport = 1;
      proposalRows = RS.newStore(proposals); var epoch = 0; var head = genesis(); var lines = 0; var lastSealed = 0; var policies = [] }
  };
  public func setPolicies(s : State, ps : [Auth.DualPolicy]) { s.policies := ps };
  func policyFor(s : State, permission : Text) : ?Auth.DualPolicy { Array.find<Auth.DualPolicy>(s.policies, func(p) { p.permission == permission }) };

  func first<Rw>(store : RS.Store, decl : RS.Decl<Rw>, index : Text, lo : Blob, hi : Blob) : ?(Nat, Rw) {
    var cursor : ?Page.Cursor = null;
    loop {
      switch (RS.page(store, decl, index, lo, hi, cursor, 1)) {
        case (#ok(p)) { if (p.rows.size() > 0) return ?p.rows[0]; switch (p.next) { case (?n) cursor := ?n; case null return null } };
        case (#err(_)) return null;
      };
    };
  };
  func one<Rw>(store : RS.Store, decl : RS.Decl<Rw>, index : Text, key : Blob) : ?(Nat, Rw) { first(store, decl, index, key, key) };

  public func alert(s : State, id : Nat) : ?T.Alert { RS.get(s.alertStore, alertRows, id) };
  public func caseOf(s : State, id : Nat) : ?T.Case { RS.get(s.caseStore, caseRows, id) };
  public func report(s : State, day : Nat) : ?ReportRow { switch (one(s.reportStore, reportRows, "byDay", R.key(day, 8))) { case (?(_, r)) ?r; case null null } };
  public func counts(s : State) : { cursor : Nat; alerts : Nat; cases : Nat; reports : Nat; blocks : Nat; lines : Nat } {
    { cursor = s.cursor; alerts = s.nextAlert - 1; cases = s.nextCase - 1; reports = s.nextReport - 1; blocks = DL.length(s.log); lines = s.lines }
  };

  // ═══════════════════════════════════════════════════════
  //  THE PROJECTIONS AND THE RULES (SPEC §1, §2, §4)
  // ═══════════════════════════════════════════════════════

  let SEC : Nat64 = 1_000_000_000;
  /// The owner of an account (SPEC §1): its client code, or for a house account the byte 1 and its member.
  public func ownerOf(xs : X.State, account : Nat, member : Nat) : Blob {
    switch (X.account(xs, account)) {
      case (?a) { if (a.client.size() == 32) a.client else cat([Blob.fromArray([1 : Nat8]), R.key(member, 8)]) };
      case null cat([Blob.fromArray([1 : Nat8]), R.key(member, 8)]);
    }
  };
  func traderIdentity(t : Nat) : Blob { cat([Blob.fromArray([2 : Nat8]), R.key(t, 8)]) };

  func raise(s : State, out : List.List<Nat>, a : T.Alert) { let id = s.nextAlert; s.nextAlert += 1; RS.put(s.alertStore, alertRows, id, a); List.add(out, id) };
  func instRow(s : State, inst : Nat) : InstRow { switch (RS.get(s.instStore, instRows, inst)) { case (?r) r; case null ({ phase = 1; lastContinuous = 0 } : InstRow) } };
  func putInst(s : State, inst : Nat, r : InstRow) {
    if (RS.get(s.instStore, instRows, inst) == null) s.instIds := Array.sort<Nat>(Array.concat<Nat>(s.instIds, [inst]), Nat.compare);
    RS.put(s.instStore, instRows, inst, r)
  };
  /// A counting window: opened at `t` when none is open or the open one is older than `secs`; the count after this event.
  func tick(s : State, key : Blob, t : Nat64, block : Nat, secs : Nat) : WindowRow {
    let (id, row) = switch (one(s.windowStore, windowRows, "byKey", key)) {
      case (?(id, w)) (id, if (w.count == 0 or t - w.start > Nat64.fromNat(secs) * SEC) ({ key; start = t; startBlock = block; count = 1 } : WindowRow) else ({ w with count = w.count + 1 } : WindowRow));
      case null { let id = s.nextWindow; s.nextWindow += 1; (id, ({ key; start = t; startBlock = block; count = 1 } : WindowRow)) };
    };
    RS.put(s.windowStore, windowRows, id, row);
    row
  };
  func spoofRow(s : State, owner : Blob, inst : Nat, t : Nat64) : (Nat, SpoofRow) {
    let fresh : SpoofRow = { owner; instrument = inst; start = t; cancelledBuy = 0; cancelledSell = 0; tradedBuy = 0; tradedSell = 0; alerted = false };
    switch (one(s.spoofStore, spoofRows, "byOwner", cat([ownerField(owner), R.key(inst, 8)]))) {
      case (?(id, r)) (id, if (t - r.start > Nat64.fromNat(s.params.spoofSecs) * SEC) fresh else r);
      case null { let id = s.nextSpoof; s.nextSpoof += 1; (id, fresh) };
    }
  };
  func spoofCheck(s : State, id : Nat, r : SpoofRow, block : Nat, out : List.List<Nat>) {
    let q = s.params.spoofQty;
    if (not r.alerted and ((r.cancelledBuy >= q and r.tradedSell > 0) or (r.cancelledSell >= q and r.tradedBuy > 0))) {
      let buySide = r.cancelledBuy >= q and r.tradedSell > 0;
      raise(s, out, { rule = 4; block; instrument = r.instrument; owner = r.owner; other = ""; e1 = if (buySide) 1 else 2;
        e2 = if (buySide) r.cancelledBuy else r.cancelledSell; e3 = if (buySide) r.tradedSell else r.tradedBuy; e4 = 0; caseId = 0 });
      RS.put(s.spoofStore, spoofRows, id, { r with alerted = true });
    } else RS.put(s.spoofStore, spoofRows, id, r);
  };
  /// An order cancelled by its owner (a cancel or a mass cancel): spoofing counts it if it was unfilled and cancelled
  /// within `spoofSecs` of its placement.
  func ownerCancel(s : State, oid : Nat, t : Nat64, block : Nat, out : List.List<Nat>) {
    let ?o = RS.get(s.orderStore, orderRows, oid) else return;
    if (o.filled != 0 or t - o.placedAt > Nat64.fromNat(s.params.spoofSecs) * SEC) return;
    let (id, r) = spoofRow(s, o.owner, o.instrument, t);
    spoofCheck(s, id, if (o.side == 1) ({ r with cancelledBuy = r.cancelledBuy + o.qty } : SpoofRow) else ({ r with cancelledSell = r.cancelledSell + o.qty } : SpoofRow), block, out);
  };
  func chainLine(s : State, line : Blob) {
    let w = C.Writer(); w.text(REPORT_DOMAIN); w.blobRaw(s.head); w.blobRaw(line);
    s.head := Sha256.fromArray(#sha256, w.toArray()); s.lines += 1;
  };
  func position(s : State, owner : Blob, inst : Nat, bought : Nat, sold : Nat, block : Nat) {
    let (id, r0) = switch (one(s.posStore, posRows, "byOwner", cat([ownerField(owner), R.key(inst, 8)]))) {
      case (?(id, r)) (id, if (r.epoch == s.epoch) r else ({ owner; instrument = inst; epoch = s.epoch; bought = 0; sold = 0; reported = false } : PosRow));
      case null { let id = s.nextPos; s.nextPos += 1; (id, ({ owner; instrument = inst; epoch = s.epoch; bought = 0; sold = 0; reported = false } : PosRow)) };
    };
    let r = { r0 with bought = r0.bought + bought; sold = r0.sold + sold };
    let long = r.bought >= r.sold;
    let net = if (long) r.bought - r.sold else r.sold - r.bought;
    if (not r.reported and net >= s.params.positionLevel) {
      let w = C.Writer(); w.byte(2); w.nat(block); w.blob(owner); w.nat(inst); w.byte(if (long) 1 else 2); w.nat(net);
      chainLine(s, w.toBlob());
      RS.put(s.posStore, posRows, id, { r with reported = true });
    } else RS.put(s.posStore, posRows, id, r);
  };
  /// A pair of a clear or an uncross: wash, painting the tape, spoofing's traded side, the report's lines.
  func pair(s : State, block : Nat, t : Nat64, inst : Nat, b : Nat, a : Nat, q : Nat, p : Nat, out : List.List<Nat>) {
    let ?ob = RS.get(s.orderStore, orderRows, b) else Runtime.trap("surveillance: a pair names an order never placed");
    let ?oa = RS.get(s.orderStore, orderRows, a) else Runtime.trap("surveillance: a pair names an order never placed");
    if (ob.owner == oa.owner) {
      raise(s, out, { rule = 1; block; instrument = inst; owner = ob.owner; other = ""; e1 = b; e2 = a; e3 = q; e4 = p; caseId = 0 });
    } else {
      let (lo, hi) = if (Blob.compare(ob.owner, oa.owner) == #less) (ob.owner, oa.owner) else (oa.owner, ob.owner);
      let w = tick(s, cat([ownerField(lo), ownerField(hi)]), t, block, s.params.paintSecs);
      if (w.count == s.params.paintCount) raise(s, out, { rule = 2; block; instrument = inst; owner = lo; other = hi; e1 = w.startBlock; e2 = w.count; e3 = 0; e4 = 0; caseId = 0 });
    };
    // spoofing: what each owner traded, per side
    let (ib, rb) = spoofRow(s, ob.owner, inst, t);
    spoofCheck(s, ib, { rb with tradedBuy = rb.tradedBuy + q }, block, out);
    let (ia, ra) = spoofRow(s, oa.owner, inst, t);
    spoofCheck(s, ia, { ra with tradedSell = ra.tradedSell + q }, block, out);
    RS.put(s.orderStore, orderRows, b, { ob with filled = ob.filled + q });
    RS.put(s.orderStore, orderRows, a, { oa with filled = oa.filled + q });
    // the report: the trade line, then each owner's position
    let w = C.Writer(); w.byte(1); w.nat(block); w.nat(inst); w.nat(b); w.nat(a); w.nat(q); w.nat(p); w.nat(ob.member); w.nat(oa.member); w.nat(ob.account); w.nat(oa.account); w.bool(oa.short);
    chainLine(s, w.toBlob());
    position(s, ob.owner, inst, q, 0, block);
    position(s, oa.owner, inst, 0, q, block);
  };
  /// Marking the close (SPEC §2.5): one owner's share of an uncross out of the closing auction and the price's distance.
  func markClose(s : State, block : Nat, inst : Nat, price : Nat, volume : Nat, pairs : [(Nat, Nat, Nat)], lastContinuous : Nat, out : List.List<Nat>) {
    if (price == 0 or volume == 0 or lastContinuous == 0) return;
    let bought = Map.empty<Blob, Nat>(); let sold = Map.empty<Blob, Nat>();
    for ((b, a, q) in pairs.vals()) {
      switch (RS.get(s.orderStore, orderRows, b)) { case (?o) Map.add(bought, Blob.compare, o.owner, q + (switch (Map.get(bought, Blob.compare, o.owner)) { case (?v) v; case null 0 })); case null {} };
      switch (RS.get(s.orderStore, orderRows, a)) { case (?o) Map.add(sold, Blob.compare, o.owner, q + (switch (Map.get(sold, Blob.compare, o.owner)) { case (?v) v; case null 0 })); case null {} };
    };
    var best : ?(Blob, Nat) = null;
    for (m in [bought, sold].vals()) {
      for ((o, q) in Map.entries(m)) {
        switch (best) { case (?(bo, bq)) { if (q > bq or (q == bq and Blob.compare(o, bo) == #less)) best := ?(o, q) }; case null best := ?(o, q) };
      };
    };
    let ?(owner, q) = best else return;
    let dev = if (price >= lastContinuous) price - lastContinuous else lastContinuous - price;
    if (q * 100 >= s.params.markShare * volume and dev * 10_000 >= s.params.markBps * lastContinuous) {
      raise(s, out, { rule = 5; block; instrument = inst; owner; other = ""; e1 = price; e2 = lastContinuous; e3 = q; e4 = volume; caseId = 0 });
    };
  };
  func stuff(s : State, xs : X.State, caller : Principal, t : Nat64, block : Nat, out : List.List<Nat>) {
    let ?(tid, _) = X.traderByPrincipal(xs, caller) else return;
    let key = cat([ownerField(traderIdentity(tid)), ownerField("")]);
    let w = tick(s, key, t, block, s.params.stuffSecs);
    if (w.count == s.params.stuffCount) raise(s, out, { rule = 3; block; instrument = 0; owner = traderIdentity(tid); other = ""; e1 = w.startBlock; e2 = w.count; e3 = 0; e4 = 0; caseId = 0 });
  };
  /// One block of the book's log folded into the desk (SPEC §1).
  func readBlock(s : State, xs : X.State, b : DL.Block<BK.Event>, out : List.List<Nat>) {
    let #executed(x) = b.event else return;
    let t = b.timestamp; let i = b.index; let e = x.effects;
    switch (x.command) {
      case (#openInstrument(c)) putInst(s, c.instrument, { phase = 1; lastContinuous = 0 });
      case (#setTrading(c)) putInst(s, c.instrument, { instRow(s, c.instrument) with phase = if (c.open) 2 else 1 });
      case (#setPhase(c)) putInst(s, c.instrument, { instRow(s, c.instrument) with phase = Nat8.toNat(BK.phaseCode(c.phase)) });
      case (#halt(c)) putInst(s, c.instrument, { instRow(s, c.instrument) with phase = 6 });
      case (#resume(c)) putInst(s, c.instrument, { instRow(s, c.instrument) with phase = 3 });
      case (#placeOrder(c)) {
        RS.put(s.orderStore, orderRows, e[1], { account = c.account; member = c.member; owner = ownerOf(xs, c.account, c.member); side = if (c.side == #buy) 1 else 2;
          instrument = c.instrument; qty = c.qty; short = c.shortSale; placedAt = t; filled = 0; trader = c.trader });
        if (e[1] > s.maxOrder) s.maxOrder := e[1];
        stuff(s, xs, b.caller, t, i, out);
      };
      case (#cancelOrder(c)) { ownerCancel(s, c.order, t, i, out); stuff(s, xs, b.caller, t, i, out) };
      case (#amendOrder(c)) {
        switch (RS.get(s.orderStore, orderRows, c.order)) { case (?o) RS.put(s.orderStore, orderRows, c.order, { o with qty = o.filled + c.qty }); case null {} };
        stuff(s, xs, b.caller, t, i, out);
      };
      case (#massCancel(_)) { for (oid in Array.sliceToArray<Nat>(e, 2, 2 + e[1]).vals()) ownerCancel(s, oid, t, i, out); stuff(s, xs, b.caller, t, i, out) };
      case (#clear(_)) {
        var k = 1;
        while (k < e.size()) {
          let inst = e[k]; let price = e[k + 1]; let np = e[k + 3]; var p = k + 4;
          let before = instRow(s, inst);
          for (_ in Nat.range(0, np)) { pair(s, i, t, inst, e[p], e[p + 1], e[p + 2], price, out); p += 3 };
          p += 1 + e[p];          // removed
          p += 1 + 4 * e[p];      // revealed
          p += 1 + 2 * e[p];      // shown
          let interrupted = e[p] == 1;
          let r = instRow(s, inst);
          putInst(s, inst, { phase = if (interrupted) 3 else r.phase; lastContinuous = if (before.phase == 2 and price > 0) price else r.lastContinuous });
          k := p + 1;
        };
      };
      case (#uncross(c)) {
        let inst = c.instrument; let price = e[2]; let volume = e[3]; let np = e[4]; var p = 5;
        let before = instRow(s, inst);
        let prs = List.empty<(Nat, Nat, Nat)>();
        for (_ in Nat.range(0, np)) { pair(s, i, t, inst, e[p], e[p + 1], e[p + 2], price, out); List.add(prs, (e[p], e[p + 1], e[p + 2])); p += 3 };
        if (before.phase == 4) markClose(s, i, inst, price, volume, List.toArray(prs), before.lastContinuous, out);
        putInst(s, inst, { instRow(s, inst) with phase = e[e.size() - 1] });
      };
      case (_) {};
    };
  };
  func scanRange(s : State, book : B.State, xs : X.State, from : Nat, to : Nat) : [Nat] {
    let out = List.empty<Nat>();
    var i = from;
    while (i < to) {
      let ?b = DL.get(book.log, BK.codec, i) else Runtime.trap("surveillance: a block of the book's log does not read");
      readBlock(s, xs, b, out);
      i += 1;
    };
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════
  //  VALIDATION, APPLICATION
  // ═══════════════════════════════════════════════════════

  func textRefusal(t : Text) : ?T.Error { let n = Text.encodeUtf8(t).size(); if (n == 0 or n > T.TEXT_BYTES) ?#InvalidTerms({ reason = "a text of 1 to 1,024 bytes" }) else null };
  public func validate(s : State, book : B.State, xs : X.State, now : Nat64, c : T.Command) : ?T.Error {
    switch (c) {
      case (#scan(x)) {
        if (x.limit == 0 or x.limit > T.MAX_SCAN) return ?#InvalidTerms({ reason = "a scan of 1 to 500 blocks" });
        if (s.cursor >= DL.length(book.log)) return ?#NothingToScan;
        null
      };
      case (#setParams(p)) {
        if (p.paintCount < 2 or p.stuffCount < 2 or p.paintSecs == 0 or p.stuffSecs == 0 or p.spoofSecs == 0 or p.spoofQty == 0 or p.positionLevel == 0) return ?#InvalidTerms({ reason = "counts of at least 2, windows and quantities above zero" });
        if (p.markShare == 0 or p.markShare > 100 or p.markBps == 0) return ?#InvalidTerms({ reason = "a share of 1 to 100 per cent and a distance above zero" });
        null
      };
      case (#openCase(x)) {
        let ?a = alert(s, x.alert) else return ?#UnknownAlert({ alert = x.alert });
        if (a.caseId != 0) return ?#InvalidTerms({ reason = "the alert is in a case" });
        null
      };
      case (#noteCase(x)) { switch (openCase(s, x.caseId)) { case (?e) return ?e; case null {} }; textRefusal(x.note) };
      case (#closeCase(x)) { switch (openCase(s, x.caseId)) { case (?e) return ?e; case null {} }; textRefusal(x.reason) };
      case (#reportCase(x)) { switch (openCase(s, x.caseId)) { case (?e) return ?e; case null {} }; textRefusal(x.summary) };
      case (#sealReport(x)) {
        if (x.day != X.marketTime(xs, now).0) return ?#InvalidTerms({ reason = "the market day of the act" });
        if (x.day <= s.lastSealed) return ?#InvalidTerms({ reason = "a day later than the last sealed" });
        null
      };
    }
  };
  func openCase(s : State, id : Nat) : ?T.Error {
    let ?k = caseOf(s, id) else return ?#UnknownCase({ caseId = id });
    if (k.status != 1) ?#CaseClosed({ caseId = id }) else null
  };

  /// Effects: scan [1, from, to, alerts, alert ids...]; setParams [2]; openCase [3, case]; noteCase [4, case, notes];
  /// closeCase [5, case]; reportCase [6, case]; sealReport [7, day, lines, the hash, one byte an effect].
  public func apply(s : State, book : B.State, xs : X.State, c : T.Command) : T.Effects {
    switch (c) {
      case (#scan(x)) {
        let from = s.cursor; let to = Nat.min(DL.length(book.log), from + x.limit);
        let ids = scanRange(s, book, xs, from, to);
        s.cursor := to;
        Array.concat<Nat>([1, from, to, ids.size()], ids)
      };
      case (#setParams(p)) { s.params := p; [2] };
      case (#openCase(x)) {
        let ?a = alert(s, x.alert) else Runtime.trap("apply: alert vanished");
        let id = s.nextCase; s.nextCase += 1;
        RS.put(s.caseStore, caseRows, id, { alert = x.alert; status = 1; notes = 0 });
        RS.put(s.alertStore, alertRows, x.alert, { a with caseId = id });
        [3, id]
      };
      case (#noteCase(x)) {
        let ?k = caseOf(s, x.caseId) else Runtime.trap("apply: case vanished");
        RS.put(s.caseStore, caseRows, x.caseId, { k with notes = k.notes + 1 });
        [4, x.caseId, k.notes + 1]
      };
      case (#closeCase(x)) { let ?k = caseOf(s, x.caseId) else Runtime.trap("apply: case vanished"); RS.put(s.caseStore, caseRows, x.caseId, { k with status = 2 }); [5, x.caseId] };
      case (#reportCase(x)) { let ?k = caseOf(s, x.caseId) else Runtime.trap("apply: case vanished"); RS.put(s.caseStore, caseRows, x.caseId, { k with status = 3 }); [6, x.caseId] };
      case (#sealReport(x)) {
        let hash = s.head; let lines = s.lines;
        RS.put(s.reportStore, reportRows, s.nextReport, { day = x.day; lines; hash }); s.nextReport += 1;
        s.epoch += 1; s.head := genesis(); s.lines := 0; s.lastSealed := x.day;
        Array.concat<Nat>([7, x.day, lines], Array.map<Nat8, Nat>(Blob.toArray(hash), func(v) { Nat8.toNat(v) }))
      };
    }
  };

  func appendExecuted(s : State, book : B.State, xs : X.State, now : Nat64, caller : Principal, proposal : ?Cmd.ProposalId, version : Nat8, c : T.Command) : (Nat, T.Effects) {
    let effects = apply(s, book, xs, c);
    let b = DL.append(s.log, K.codec, now, caller, #executed({ proposal; version; command = c; effects }), null);
    (b.index, effects)
  };
  public func submit(s : State, book : B.State, xs : X.State, auth : Authority, now : Nat64, caller : Principal, c : T.Command, partition : ?Text, justification : Text) : Result<Outcome> {
    let perm = permissionOf(c);
    if (not auth.hasGrant(caller, perm.id)) return #err(#auth(#NoGrant({ permission = perm.id })));
    switch (validate(s, book, xs, now, c)) { case (?e) return #err(#surv(e)); case null {} };
    switch (MC.resolvePolicy(perm, policyFor(s, perm.id))) {
      case (#refuse(e)) #err(#auth(e));
      case (#single) { let (block, effects) = appendExecuted(s, book, xs, now, caller, null, K.registry.current, c); #ok(#executed({ block; effects })) };
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
  public func approve(s : State, book : B.State, xs : X.State, auth : Authority, now : Nat64, checker : Principal, id : Cmd.ProposalId) : Result<Outcome> {
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
    switch (validate(s, book, xs, now, c)) {
      case (?err) {
        let rb = DL.append(s.log, K.codec, now, checker, #rejected({ proposal = id; checker; reason = "no longer valid at execution: " # debug_show(err) }), null);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #rejected(rb.index) });
        #err(#surv(err))
      };
      case null {
        let (block, effects) = appendExecuted(s, book, xs, now, checker, ?id, p.commandEncoding, c);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #executed(block) });
        #ok(#executed({ block; effects }))
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  func applyBlock(s : State, book : B.State, xs : X.State, b : DL.Block<K.Event>) {
    switch (b.event) {
      case (#proposed(p)) RS.put(s.proposalRows, proposals, b.index, { expiresAt = p.expiresAt; status = #awaiting; approvalBlocks = [] });
      case (#approved(a)) { switch (RS.get(s.proposalRows, proposals, a.proposal)) { case (?row) RS.put(s.proposalRows, proposals, a.proposal, { row with approvalBlocks = Array.concat<Nat>(row.approvalBlocks, [b.index]) }); case null {} } };
      case (#rejected(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #rejected(b.index) }); case null {} } };
      case (#expired(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #expired(b.index) }); case null {} } };
      case (#executed(x)) {
        let effects = apply(s, book, xs, x.command);
        switch (x.proposal) { case (?id) { switch (RS.get(s.proposalRows, proposals, id)) { case (?row) RS.put(s.proposalRows, proposals, id, { row with status = #executed(b.index) }); case null {} } }; case null {} };
        if (effects != x.effects) Runtime.trap("replay: surveillance block " # Nat.toText(b.index) # " recorded effects " # debug_show(x.effects) # " but the fold produced " # debug_show(effects));
      };
    }
  };
  /// The desk refolded from its log over the book's log (and the exchange's rows).
  public func replay(fresh : State, book : B.State, xs : X.State) : Fold.Report {
    Fold.replay<K.Event, State>(fresh.log, K.codec, func(_ : Nat) : ?Blob { null }, fresh, func(s : State, b : DL.Block<K.Event>) { applyBlock(s, book, xs, b) })
  };
  public func fingerprint(s : State) : Blob {
    let f = Fold.newFingerprint();
    func table<Rw>(name : Text, store : RS.Store, decl : RS.Decl<Rw>, next : Nat) {
      Fold.section(f, name, func(w : C.Writer) { w.nat(next); var i = 1; while (i < next) { switch (RS.get(store, decl, i)) { case (?r) { w.nat(i); w.blob(decl.encode(r)) }; case null {} }; i += 1 } });
    };
    Fold.section(f, "desk", func(w : C.Writer) {
      w.nat(s.cursor); w.nat(s.epoch); w.blobRaw(s.head); w.nat(s.lines); w.nat(s.lastSealed);
      let p = s.params; for (v in [p.paintCount, p.paintSecs, p.stuffCount, p.stuffSecs, p.spoofQty, p.spoofSecs, p.markShare, p.markBps, p.positionLevel].vals()) w.nat(v);
    });
    table<OrdRow>("orders", s.orderStore, orderRows, s.maxOrder + 1);
    table<WindowRow>("windows", s.windowStore, windowRows, s.nextWindow);
    table<SpoofRow>("spoofing", s.spoofStore, spoofRows, s.nextSpoof);
    table<PosRow>("positions", s.posStore, posRows, s.nextPos);
    Fold.section(f, "instruments", func(w : C.Writer) { for (i in s.instIds.vals()) { switch (RS.get(s.instStore, instRows, i)) { case (?r) { w.nat(i); w.blob(instRows.encode(r)) }; case null {} } } });
    table<T.Alert>("alerts", s.alertStore, alertRows, s.nextAlert);
    table<T.Case>("cases", s.caseStore, caseRows, s.nextCase);
    table<ReportRow>("reports", s.reportStore, reportRows, s.nextReport);
    Fold.section(f, "proposals", func(w : C.Writer) { var i = 0; let n = DL.length(s.log); while (i < n) { switch (RS.get(s.proposalRows, proposals, i)) { case (?r) { w.nat(i); w.blob(MC.encodeProposalRow(r)) }; case null {} }; i += 1 } });
    Fold.section(f, "log", func(w : C.Writer) { w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)) });
    Fold.fingerprintHash(f)
  };
}
