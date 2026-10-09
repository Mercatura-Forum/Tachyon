/// ExchangeCore.mo: the exchange's foundation as commands on a certified log, folded into fixed-width rows in stable
/// memory: members and their traders, house and client accounts, each trader's right to trade per segment, segments
/// with their session windows and their current phase, tick tables, instruments, the market's calendar and its UTC
/// offset. A replay of the log onto a fresh state reproduces every row, compared by fingerprint.
///
/// Authority is a catalogue row per command, total in both directions; four eyes by comparing principals (the kernel's
/// maker-checker); who holds a grant and a role is answered by the contract that composes this core.
///
/// The scheduler's act (`#advancePhase`) carries the market's day and second of the day; `submit` refuses it unless
/// they are the chain's clock at submission (the market time of `now`), so the caller chooses neither the time nor the
/// phase: the phase is the segment's schedule at that time on the market's calendar.
///
/// Attribution: Thebes Core Team.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
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
import Cal "mo:kernel/time/Calendar";

import T "ExchangeTypes";
import K "ExchangeCanonical";
import L "ExchangeLogic";

module {

  public type Error = { #exchange : T.Error; #auth : Auth.Error; #encoding : Text };
  public type Result<A> = Result.Result<A, Error>;

  // ═══════════════════════════════════════════════════════
  //  THE PERMISSION CATALOGUE
  // ═══════════════════════════════════════════════════════

  /// Admitting, suspending or expelling a member, registering or revoking a trader, granting a right, defining a
  /// segment, a schedule, the calendar, a tick table, an instrument and its status, lot or offset bind the whole market:
  /// four eyes. An account is a member's own act over its own client: single, by a trader of that member. The reference
  /// price and the phase change are the operator's system acts whose values the rows fix: single, with the reason.
  public func catalogue() : Perm.Catalogue { [
    Perm.p("exchange.member.admit", "member", #create, #command("admitMember"), false, false, true),
    Perm.p("exchange.member.status", "member", #update, #command("setMemberStatus"), false, false, true),
    Perm.p("exchange.trader.register", "trader", #create, #command("registerTrader"), false, false, true),
    Perm.p("exchange.trader.revoke", "trader", #close, #command("revokeTrader"), false, false, true),
    Perm.p("exchange.right.grant", "right", #create, #command("grantTradingRight"), false, false, true),
    Perm.p("exchange.right.withdraw", "right", #close, #command("withdrawTradingRight"), false, false, true),
    Perm.p("exchange.account.open", "account", #create, #command("openAccount"), false, false, false),
    Perm.p("exchange.account.close", "account", #close, #command("closeAccount"), false, false, false),
    Perm.p("exchange.segment.define", "segment", #create, #command("defineSegment"), false, false, true),
    Perm.p("exchange.segment.schedule", "segment", #update, #command("setSchedule"), false, false, true),
    Perm.p("exchange.calendar.restdays", "calendar", #update, #command("setRestDays"), false, false, true),
    Perm.p("exchange.calendar.holiday", "calendar", #create, #command("declareHoliday"), false, false, true),
    Perm.p("exchange.ticktable.define", "ticktable", #create, #command("defineTickTable"), false, false, true),
    Perm.p("exchange.instrument.list", "instrument", #create, #command("listInstrument"), false, false, true),
    Perm.p("exchange.instrument.status", "instrument", #update, #command("setInstrumentStatus"), false, false, true),
    Perm.p("exchange.instrument.lot", "instrument", #update, #command("setLot"), false, false, true),
    Perm.p("exchange.instrument.reference", "instrument", #update, #command("setReferencePrice"), false, false, false),
    Perm.p("exchange.segment.advance", "segment", #update, #command("advancePhase"), false, false, false),
    Perm.p("exchange.clock.offset", "calendar", #update, #command("setUtcOffset"), false, false, true),
    Perm.p("command.approve", "command", #approve, #method("approve"), false, false, false),
    Perm.p("command.reject", "command", #reject, #method("reject"), false, false, false),
  ] };
  public func singleActs() : [(Text, Text)] { [
    ("exchange.account.open", "a member's trader opens an account of that member; a client account carries only a commitment to the client"),
    ("exchange.account.close", "a member's trader closes an account of that member"),
    ("exchange.instrument.reference", "the operator's system records an instrument's reference price on the tick, for a day; the price comes from the market's own close"),
    ("exchange.segment.advance", "the scheduler moves a segment to the phase its schedule names at the chain's clock; the caller chooses neither the time nor the phase"),
  ] };
  public let commandNames : [Text] = K.families;
  public let methodNames : [Text] = ["approve", "reject"];
  public func permissionOf(c : T.Command) : Auth.Permission {
    switch (Perm.byCommand(catalogue(), K.familyOf(c))) { case (?p) p; case null Runtime.trap("catalogue: no permission guards " # K.familyOf(c)) }
  };

  // ═══════════════════════════════════════════════════════
  //  THE ROWS (every width declared once, checked by checkSums)
  // ═══════════════════════════════════════════════════════

  func padded(b : R.Buf, width : Nat) : Blob { while (b.size() < width) R.putByte(b, 0); R.done(b, width) };
  let PRINCIPAL_BYTES = 30;   // a length byte and up to 29 bytes
  func putPrincipal(b : R.Buf, p : Principal) { let bs = Principal.toBlob(p); R.putNat(b, bs.size(), 1); for (x in bs.vals()) R.putByte(b, x); var k = bs.size(); while (k < 29) { R.putByte(b, 0); k += 1 } };
  func getPrincipal(a : [Nat8], off : Nat) : Principal { let n = R.getNat(a, off, 1); Principal.fromBlob(R.getBlob(a, off + 1, n)) };
  public func principalKey(p : Principal) : Blob { let b = R.buf(); putPrincipal(b, p); R.done(b, PRINCIPAL_BYTES) };

  public type MemberRow = T.Member;
  public let MEMBER_ROW_BYTES = 64;   // code 8, name 48, market maker 1, clearing 1, status 1, admitted 4, pad 1
  public let members : RS.Decl<MemberRow> = {
    table = "members"; idBytes = 8; rowBytes = MEMBER_ROW_BYTES;
    encode = func(m : MemberRow) : Blob { let b = R.buf(); R.putText(b, m.code, T.CODE_BYTES); R.putText(b, m.name, T.NAME_BYTES); R.putBool(b, m.marketMaker); R.putBool(b, m.clearing); R.putByte(b, K.memberStatusCode(m.status)); R.putNat(b, m.admitted, 4); padded(b, MEMBER_ROW_BYTES) };
    decode = func(a : [Nat8]) : MemberRow { let ?status = K.memberStatusOf(a[58]) else Runtime.trap("member row: bad status byte"); { code = R.getText(a, 0, 8); name = R.getText(a, 8, 48); marketMaker = R.getBool(a, 56); clearing = R.getBool(a, 57); status; admitted = R.getNat(a, 59, 4) } };
    indexes = [{ name = "byCode"; keyBytes = T.CODE_BYTES; keyOf = func(_ : Nat, m : MemberRow) : ?Blob { ?R.textKey(m.code, T.CODE_BYTES) } }];
  };
  public type TraderRow = T.Trader;
  public let TRADER_ROW_BYTES = 40;   // member 8, principal 30, status 1, pad 1
  public let traders : RS.Decl<TraderRow> = {
    table = "traders"; idBytes = 8; rowBytes = TRADER_ROW_BYTES;
    encode = func(t : TraderRow) : Blob { let b = R.buf(); R.putNat(b, t.member, 8); putPrincipal(b, t.principal); R.putByte(b, K.traderStatusCode(t.status)); padded(b, TRADER_ROW_BYTES) };
    decode = func(a : [Nat8]) : TraderRow { let ?status = K.traderStatusOf(a[38]) else Runtime.trap("trader row: bad status byte"); { member = R.getNat(a, 0, 8); principal = getPrincipal(a, 8); status } };
    indexes = [{ name = "byPrincipal"; keyBytes = PRINCIPAL_BYTES; keyOf = func(_ : Nat, t : TraderRow) : ?Blob { ?principalKey(t.principal) } }];
  };
  /// A trader's right in a segment, while held; withdrawing it closes the row (it leaves the index).
  public type RightRow = { trader : T.TraderId; segment : T.SegmentId; held : Bool };
  public let RIGHT_ROW_BYTES = 24;   // trader 8, segment 8, held 1, pad 7
  public let rights : RS.Decl<RightRow> = {
    table = "rights"; idBytes = 8; rowBytes = RIGHT_ROW_BYTES;
    encode = func(x : RightRow) : Blob { let b = R.buf(); R.putNat(b, x.trader, 8); R.putNat(b, x.segment, 8); R.putBool(b, x.held); padded(b, RIGHT_ROW_BYTES) };
    decode = func(a : [Nat8]) : RightRow { { trader = R.getNat(a, 0, 8); segment = R.getNat(a, 8, 8); held = R.getBool(a, 16) } };
    indexes = [{ name = "held"; keyBytes = 16; keyOf = func(_ : Nat, x : RightRow) : ?Blob { if (x.held) ?R.key2(x.trader, 8, x.segment, 8) else null } }];
  };
  public type AccountRow = T.Account;
  public let ACCOUNT_ROW_BYTES = 48;   // member 8, kind 1, client 32, status 1, pad 6
  public let accounts : RS.Decl<AccountRow> = {
    table = "accounts"; idBytes = 8; rowBytes = ACCOUNT_ROW_BYTES;
    encode = func(x : AccountRow) : Blob { let b = R.buf(); R.putNat(b, x.member, 8); R.putByte(b, K.accountKindCode(x.kind)); R.putBlob(b, if (x.client.size() == 32) x.client else zero32(), 32); R.putByte(b, K.accountStatusCode(x.status)); padded(b, ACCOUNT_ROW_BYTES) };
    decode = func(a : [Nat8]) : AccountRow {
      let ?kind = K.accountKindOf(a[8]) else Runtime.trap("account row: bad kind byte");
      let ?status = K.accountStatusOf(a[41]) else Runtime.trap("account row: bad status byte");
      { member = R.getNat(a, 0, 8); kind; client = if (kind == #client) R.getBlob(a, 9, 32) else ""; status }
    };
    indexes = [{ name = "byMember"; keyBytes = 16; keyOf = func(id : Nat, x : AccountRow) : ?Blob { ?R.key2(x.member, 8, id, 8) } }];
  };
  func zero32() : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })) };

  public type SegmentRow = T.Segment;
  public let WINDOW_BYTES = 9;      // phase 1, start 4, end 4
  public let SEGMENT_ROW_BYTES = 144;   // code 8, name 48, windows 1 + 8 x 9, phase 1, phase day 4, phase second 4, pad 6
  public let segments : RS.Decl<SegmentRow> = {
    table = "segments"; idBytes = 8; rowBytes = SEGMENT_ROW_BYTES;
    encode = func(x : SegmentRow) : Blob {
      let b = R.buf(); R.putText(b, x.code, T.CODE_BYTES); R.putText(b, x.name, T.NAME_BYTES); R.putNat(b, x.windows.size(), 1);
      var i = 0;
      while (i < T.MAX_WINDOWS) {
        if (i < x.windows.size()) { R.putByte(b, K.phaseCode(x.windows[i].phase)); R.putNat(b, x.windows[i].startSec, 4); R.putNat(b, x.windows[i].endSec, 4) }
        else { R.putByte(b, 0); R.putNat(b, 0, 4); R.putNat(b, 0, 4) };
        i += 1;
      };
      R.putByte(b, K.phaseCode(x.phase)); R.putNat(b, x.phaseDay, 4); R.putNat(b, x.phaseSec, 4);
      padded(b, SEGMENT_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : SegmentRow {
      let n = R.getNat(a, 56, 1);
      let windows = Array.tabulate<T.Window>(n, func(i) {
        let off = 57 + i * WINDOW_BYTES;
        let ?phase = K.phaseOf(a[off]) else Runtime.trap("segment row: bad window phase");
        { phase; startSec = R.getNat(a, off + 1, 4); endSec = R.getNat(a, off + 5, 4) }
      });
      let p = 57 + T.MAX_WINDOWS * WINDOW_BYTES;
      let ?phase = K.phaseOf(a[p]) else Runtime.trap("segment row: bad phase byte");
      { code = R.getText(a, 0, 8); name = R.getText(a, 8, 48); windows; phase; phaseDay = R.getNat(a, p + 1, 4); phaseSec = R.getNat(a, p + 5, 4) }
    };
    indexes = [{ name = "byCode"; keyBytes = T.CODE_BYTES; keyOf = func(_ : Nat, x : SegmentRow) : ?Blob { ?R.textKey(x.code, T.CODE_BYTES) } }];
  };
  public type TableRow = { bands : [T.Band] };
  public let TABLE_ROW_BYTES = 264;   // bands 1, then 16 x (from 8, tick 8), pad 7
  public let tables : RS.Decl<TableRow> = {
    table = "ticktables"; idBytes = 8; rowBytes = TABLE_ROW_BYTES;
    encode = func(x : TableRow) : Blob { let b = R.buf(); R.putNat(b, x.bands.size(), 1); var i = 0; while (i < T.MAX_BANDS) { if (i < x.bands.size()) { R.putNat(b, x.bands[i].fromPrice, 8); R.putNat(b, x.bands[i].tick, 8) } else { R.putNat(b, 0, 8); R.putNat(b, 0, 8) }; i += 1 }; padded(b, TABLE_ROW_BYTES) };
    decode = func(a : [Nat8]) : TableRow { let n = R.getNat(a, 0, 1); { bands = Array.tabulate<T.Band>(n, func(i) { { fromPrice = R.getNat(a, 1 + i * 16, 8); tick = R.getNat(a, 9 + i * 16, 8) } }) } };
    indexes = [];
  };
  public type InstrumentRow = T.Instrument;
  public let INSTRUMENT_ROW_BYTES = 160;   // isin 12, name 48, segment 8, currency 3, asset ledger 30, cash ledger 30, table 8, lot 8, reference 8, reference day 4, status 1
  public let instruments : RS.Decl<InstrumentRow> = {
    table = "instruments"; idBytes = 8; rowBytes = INSTRUMENT_ROW_BYTES;
    encode = func(x : InstrumentRow) : Blob {
      let b = R.buf(); R.putText(b, x.isin, T.ISIN_BYTES); R.putText(b, x.name, T.NAME_BYTES); R.putNat(b, x.segment, 8); R.putText(b, x.currency, T.CURRENCY_BYTES);
      putPrincipal(b, x.assetLedger); putPrincipal(b, x.cashLedger); R.putNat(b, x.tickTable, 8); R.putNat(b, x.lot, 8); R.putNat(b, x.referencePrice, 8); R.putNat(b, x.referenceDay, 4);
      R.putByte(b, K.instrumentStatusCode(x.status)); padded(b, INSTRUMENT_ROW_BYTES)
    };
    decode = func(a : [Nat8]) : InstrumentRow {
      let ?status = K.instrumentStatusOf(a[159]) else Runtime.trap("instrument row: bad status byte");
      { isin = R.getText(a, 0, 12); name = R.getText(a, 12, 48); segment = R.getNat(a, 60, 8); currency = R.getText(a, 68, 3); assetLedger = getPrincipal(a, 71); cashLedger = getPrincipal(a, 101);
        tickTable = R.getNat(a, 131, 8); lot = R.getNat(a, 139, 8); referencePrice = R.getNat(a, 147, 8); referenceDay = R.getNat(a, 155, 4); status }
    };
    indexes = [{ name = "byIsin"; keyBytes = T.ISIN_BYTES; keyOf = func(_ : Nat, x : InstrumentRow) : ?Blob { ?R.textKey(x.isin, T.ISIN_BYTES) } }];
  };
  public type HolidayRow = { day : T.Day };
  public let HOLIDAY_ROW_BYTES = 8;   // day 4, pad 4
  public let holidays : RS.Decl<HolidayRow> = {
    table = "holidays"; idBytes = 8; rowBytes = HOLIDAY_ROW_BYTES;
    encode = func(x : HolidayRow) : Blob { let b = R.buf(); R.putNat(b, x.day, 4); padded(b, HOLIDAY_ROW_BYTES) };
    decode = func(a : [Nat8]) : HolidayRow { { day = R.getNat(a, 0, 4) } };
    indexes = [{ name = "byDay"; keyBytes = 4; keyOf = func(_ : Nat, x : HolidayRow) : ?Blob { ?R.key(x.day, 4) } }];
  };
  public type ProposalRow = MC.ProposalRow;
  public let proposals : RS.Decl<ProposalRow> = {
    table = "proposals"; idBytes = 8; rowBytes = MC.PROPOSAL_ROW_BYTES; encode = MC.encodeProposalRow;
    decode = func(a : [Nat8]) : ProposalRow { MC.decodeProposalRow(Blob.fromArray(a)) };
    indexes = [{ name = "awaiting"; keyBytes = 8; keyOf = func(id : Nat, r : ProposalRow) : ?Blob { switch (r.status) { case (#awaiting) ?R.key(id, 8); case (_) null } } }];
  };

  /// Each row's declared width against the sum of its fields (kernel discipline, section 14).
  public func checkSums() : Bool {
    8 + 48 + 1 + 1 + 1 + 4 == 63 and 63 <= MEMBER_ROW_BYTES
    and 8 + PRINCIPAL_BYTES + 1 == 39 and 39 <= TRADER_ROW_BYTES
    and 8 + 8 + 1 == 17 and 17 <= RIGHT_ROW_BYTES
    and 8 + 1 + 32 + 1 == 42 and 42 <= ACCOUNT_ROW_BYTES
    and 1 + 4 + 4 == WINDOW_BYTES
    and 8 + 48 + 1 + T.MAX_WINDOWS * WINDOW_BYTES + 1 + 4 + 4 == 138 and 138 <= SEGMENT_ROW_BYTES
    and 1 + T.MAX_BANDS * 16 == 257 and 257 <= TABLE_ROW_BYTES
    and 12 + 48 + 8 + 3 + PRINCIPAL_BYTES + PRINCIPAL_BYTES + 8 + 8 + 8 + 4 + 1 == 160 and 160 <= INSTRUMENT_ROW_BYTES
    and 4 <= HOLIDAY_ROW_BYTES
  };

  // ═══════════════════════════════════════════════════════
  //  THE STATE
  // ═══════════════════════════════════════════════════════

  public type State = {
    log : DL.State;
    memberRows : RS.Store; traderRows : RS.Store; rightRows : RS.Store; accountRows : RS.Store; segmentRows : RS.Store; tableRows : RS.Store;
    instrumentRows : RS.Store; holidayRows : RS.Store; proposalRows : RS.Store;
    var nextMember : Nat; var nextTrader : Nat; var nextRight : Nat; var nextAccount : Nat; var nextSegment : Nat; var nextTable : Nat;
    var nextInstrument : Nat; var nextHoliday : Nat;
    var restDays : [Nat];
    var utcOffsetMinutes : Int;
    var policies : [Auth.DualPolicy];
  };
  public func newState() : State { newStateOver(DL.newState()) };
  public func newStateOver(log : DL.State) : State {
    { log; memberRows = RS.newStore(members); traderRows = RS.newStore(traders); rightRows = RS.newStore(rights); accountRows = RS.newStore(accounts);
      segmentRows = RS.newStore(segments); tableRows = RS.newStore(tables); instrumentRows = RS.newStore(instruments); holidayRows = RS.newStore(holidays);
      proposalRows = RS.newStore(proposals);
      var nextMember = 1; var nextTrader = 1; var nextRight = 1; var nextAccount = 1; var nextSegment = 1; var nextTable = 1; var nextInstrument = 1; var nextHoliday = 1;
      var restDays = []; var utcOffsetMinutes = 0; var policies = [] }
  };
  public func setPolicies(s : State, ps : [Auth.DualPolicy]) { s.policies := ps };
  func policyFor(s : State, permission : Text) : ?Auth.DualPolicy { Array.find<Auth.DualPolicy>(s.policies, func(p) { p.permission == permission }) };

  // ─── reads ──────────────────────────────────────────────────────────────────────────────
  func one<Rw>(store : RS.Store, decl : RS.Decl<Rw>, index : Text, key : Blob) : ?(Nat, Rw) {
    switch (RS.page(store, decl, index, key, key, null, 1)) { case (#ok(p)) { if (p.rows.size() == 0) null else ?p.rows[0] }; case (#err(_)) null }
  };
  public func member(s : State, id : T.MemberId) : ?MemberRow { RS.get(s.memberRows, members, id) };
  public func memberByCode(s : State, code : Text) : ?(T.MemberId, MemberRow) { if (not fits(code, T.CODE_BYTES)) null else one(s.memberRows, members, "byCode", R.textKey(code, T.CODE_BYTES)) };
  public func trader(s : State, id : T.TraderId) : ?TraderRow { RS.get(s.traderRows, traders, id) };
  public func traderByPrincipal(s : State, p : Principal) : ?(T.TraderId, TraderRow) { one(s.traderRows, traders, "byPrincipal", principalKey(p)) };
  public func rightHeld(s : State, t : T.TraderId, seg : T.SegmentId) : ?(Nat, RightRow) { one(s.rightRows, rights, "held", R.key2(t, 8, seg, 8)) };
  public func account(s : State, id : T.AccountId) : ?AccountRow { RS.get(s.accountRows, accounts, id) };
  public func accountsOf(s : State, m : T.MemberId, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, AccountRow)> { let (lo, hi) = R.prefixRange(m, 8, 8); RS.page(s.accountRows, accounts, "byMember", lo, hi, cursor, limit) };
  public func segment(s : State, id : T.SegmentId) : ?SegmentRow { RS.get(s.segmentRows, segments, id) };
  public func segmentByCode(s : State, code : Text) : ?(T.SegmentId, SegmentRow) { if (not fits(code, T.CODE_BYTES)) null else one(s.segmentRows, segments, "byCode", R.textKey(code, T.CODE_BYTES)) };
  public func tickTable(s : State, id : T.TableId) : ?TableRow { RS.get(s.tableRows, tables, id) };
  public func instrument(s : State, id : T.InstrumentId) : ?InstrumentRow { RS.get(s.instrumentRows, instruments, id) };
  public func instrumentByIsin(s : State, isin : Text) : ?(T.InstrumentId, InstrumentRow) { if (not fits(isin, T.ISIN_BYTES)) null else one(s.instrumentRows, instruments, "byIsin", R.textKey(isin, T.ISIN_BYTES)) };
  public func isHoliday(s : State, day : T.Day) : Bool { one(s.holidayRows, holidays, "byDay", R.key(day, 4)) != null };
  /// The market's calendar as the kernel's, for one day: the rest days, and that day if it is a holiday.
  public func calendarFor(s : State, day : T.Day) : Cal.Calendar { { restDays = s.restDays; holidays = if (isHoliday(s, day)) [day] else [] } };
  public func utcOffset(s : State) : Int { s.utcOffsetMinutes };
  /// The market's day and second of the day at the chain's time `now`.
  public func marketTime(s : State, now : Nat64) : (T.Day, Nat) { L.marketTime(Nat64.toNat(now), s.utcOffsetMinutes) };
  /// The phase the segment's schedule names at the chain's time `now`.
  public func scheduledPhase(s : State, seg : T.SegmentId, now : Nat64) : ?T.Phase {
    let ?g = segment(s, seg) else return null;
    let (day, sec) = marketTime(s, now);
    ?L.phaseAt(g.windows, calendarFor(s, day), day, sec)
  };
  /// Whether a principal may trade an instrument now: an active trader of an active member, holding the right in the
  /// instrument's segment, the instrument listed. (Whether the phase admits the order is the book's question.)
  public func mayTrade(s : State, p : Principal, inst : T.InstrumentId) : ?T.Error {
    let ?(tid, t) = traderByPrincipal(s, p) else return ?#UnknownTrader({ trader = 0 });
    if (t.status != #active) return ?#TraderRevoked({ trader = tid });
    let ?m = member(s, t.member) else return ?#UnknownMember({ member = t.member });
    if (m.status != #active) return ?#MemberNotActive({ member = t.member });
    let ?i = instrument(s, inst) else return ?#UnknownInstrument({ instrument = inst });
    if (i.status == #delisted) return ?#InstrumentDelisted({ instrument = inst });
    if (rightHeld(s, tid, i.segment) == null) return ?#RightNotHeld({ trader = tid; segment = i.segment });
    null
  };
  public func awaitingProposals(s : State, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, ProposalRow)> { let (lo, hi) = R.fullRange(8); RS.page(s.proposalRows, proposals, "awaiting", lo, hi, cursor, limit) };

  // ═══════════════════════════════════════════════════════
  //  VALIDATION (every field resolved here; apply writes only)
  // ═══════════════════════════════════════════════════════

  func fits(t : Text, max : Nat) : Bool { let n = Text.encodeUtf8(t).size(); n > 0 and n <= max };
  func textFits(field : Text, t : Text, max : Nat) : ?T.Error {
    let n = Text.encodeUtf8(t).size();
    if (n == 0) return ?#InvalidText({ field; reason = "empty" });
    if (n > max) return ?#InvalidText({ field; reason = "longer than " # Nat.toText(max) # " bytes" });
    null
  };
  func isCurrency(t : Text) : Bool {
    if (t.size() != 3) return false;
    for (c in t.chars()) { if (c < 'A' or c > 'Z') return false };
    true
  };
  func activeMember(s : State, id : T.MemberId) : ?T.Error {
    let ?m = member(s, id) else return ?#UnknownMember({ member = id });
    if (m.status != #active) return ?#MemberNotActive({ member = id });
    null
  };
  func activeTrader(s : State, id : T.TraderId) : ?T.Error {
    let ?t = trader(s, id) else return ?#UnknownTrader({ trader = id });
    if (t.status != #active) return ?#TraderRevoked({ trader = id });
    null
  };

  /// Every refusal the state can give a command. The scheduler's clock check is `submit`'s (it needs `now`).
  public func validate(s : State, c : T.Command) : ?T.Error {
    switch (c) {
      case (#admitMember(x)) {
        switch (textFits("code", x.code, T.CODE_BYTES)) { case (?e) return ?e; case null {} };
        switch (textFits("name", x.name, T.NAME_BYTES)) { case (?e) return ?e; case null {} };
        if (memberByCode(s, x.code) != null) return ?#DuplicateMemberCode({ code = x.code });
        null
      };
      case (#setMemberStatus(x)) {
        let ?m = member(s, x.member) else return ?#UnknownMember({ member = x.member });
        if (m.status == #expelled) return ?#ExpelledIsFinal({ member = x.member });
        if (m.status == x.status) return ?#NoStatusChange;
        textFits("reason", x.reason, T.REASON_BYTES)
      };
      case (#registerTrader(x)) {
        switch (activeMember(s, x.member)) { case (?e) return ?e; case null {} };
        if (traderByPrincipal(s, x.principal) != null) return ?#DuplicateTrader({ principal = x.principal });
        null
      };
      case (#revokeTrader(x)) {
        switch (activeTrader(s, x.trader)) { case (?e) return ?e; case null {} };
        textFits("reason", x.reason, T.REASON_BYTES)
      };
      case (#grantTradingRight(x)) {
        switch (activeTrader(s, x.trader)) { case (?e) return ?e; case null {} };
        if (segment(s, x.segment) == null) return ?#UnknownSegment({ segment = x.segment });
        if (rightHeld(s, x.trader, x.segment) != null) return ?#RightHeld({ trader = x.trader; segment = x.segment });
        null
      };
      case (#withdrawTradingRight(x)) {
        if (trader(s, x.trader) == null) return ?#UnknownTrader({ trader = x.trader });
        if (rightHeld(s, x.trader, x.segment) == null) return ?#RightNotHeld({ trader = x.trader; segment = x.segment });
        null
      };
      case (#openAccount(x)) {
        switch (activeMember(s, x.member)) { case (?e) return ?e; case null {} };
        switch (x.kind) {
          case (#house) { if (x.client.size() != 0) return ?#InvalidClientCommitment };
          case (#client) { if (x.client.size() != 32) return ?#InvalidClientCommitment };
        };
        null
      };
      case (#closeAccount(x)) {
        let ?a = account(s, x.account) else return ?#UnknownAccount({ account = x.account });
        if (a.status == #closed) return ?#AccountClosed({ account = x.account });
        textFits("reason", x.reason, T.REASON_BYTES)
      };
      case (#defineSegment(x)) {
        switch (textFits("code", x.code, T.CODE_BYTES)) { case (?e) return ?e; case null {} };
        switch (textFits("name", x.name, T.NAME_BYTES)) { case (?e) return ?e; case null {} };
        if (segmentByCode(s, x.code) != null) return ?#DuplicateSegmentCode({ code = x.code });
        switch (L.scheduleProblem(x.windows)) { case (?r) ?#InvalidSchedule({ reason = r }); case null null }
      };
      case (#setSchedule(x)) {
        if (segment(s, x.segment) == null) return ?#UnknownSegment({ segment = x.segment });
        switch (L.scheduleProblem(x.windows)) { case (?r) ?#InvalidSchedule({ reason = r }); case null null }
      };
      case (#setRestDays(x)) { switch (Cal.validate({ restDays = x.days; holidays = [] })) { case (?_) ?#InvalidRestDays; case null null } };
      case (#declareHoliday(x)) {
        if (isHoliday(s, x.day)) return ?#DuplicateHoliday({ day = x.day });
        textFits("reason", x.reason, T.REASON_BYTES)
      };
      case (#defineTickTable(x)) { switch (L.tableProblem(x.bands)) { case (?r) ?#InvalidTickTable({ reason = r }); case null null } };
      case (#listInstrument(x)) {
        if (not L.isinValid(x.isin)) return ?#InvalidIsin({ isin = x.isin });
        if (instrumentByIsin(s, x.isin) != null) return ?#DuplicateIsin({ isin = x.isin });
        switch (textFits("name", x.name, T.NAME_BYTES)) { case (?e) return ?e; case null {} };
        if (segment(s, x.segment) == null) return ?#UnknownSegment({ segment = x.segment });
        if (not isCurrency(x.currency)) return ?#InvalidCurrency({ currency = x.currency });
        let ?tbl = tickTable(s, x.tickTable) else return ?#UnknownTickTable({ table = x.tickTable });
        if (x.lot == 0) return ?#InvalidLot;
        if (x.referencePrice == 0) return ?#InvalidPrice;
        if (not L.onTick(tbl.bands, x.referencePrice)) return ?#PriceOffTick({ price = x.referencePrice; tick = L.tickAt(tbl.bands, x.referencePrice) });
        null
      };
      case (#setInstrumentStatus(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.status == #delisted) return ?#InstrumentDelisted({ instrument = x.instrument });
        if (i.status == x.status) return ?#NoStatusChange;
        textFits("reason", x.reason, T.REASON_BYTES)
      };
      case (#setLot(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.status == #delisted) return ?#InstrumentDelisted({ instrument = x.instrument });
        if (x.lot == 0) return ?#InvalidLot;
        null
      };
      case (#setReferencePrice(x)) {
        let ?i = instrument(s, x.instrument) else return ?#UnknownInstrument({ instrument = x.instrument });
        if (i.status == #delisted) return ?#InstrumentDelisted({ instrument = x.instrument });
        if (x.price == 0) return ?#InvalidPrice;
        let ?tbl = tickTable(s, i.tickTable) else return ?#UnknownTickTable({ table = i.tickTable });
        if (not L.onTick(tbl.bands, x.price)) return ?#PriceOffTick({ price = x.price; tick = L.tickAt(tbl.bands, x.price) });
        null
      };
      case (#advancePhase(x)) {
        let ?g = segment(s, x.segment) else return ?#UnknownSegment({ segment = x.segment });
        let to = L.phaseAt(g.windows, calendarFor(s, x.day), x.day, x.sec);
        if (to == g.phase) return ?#PhaseUnchanged({ segment = x.segment; phase = g.phase });
        null
      };
      case (#setUtcOffset(x)) { if (L.offsetValid(x.minutesEast)) null else ?#InvalidUtcOffset };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  APPLY (the fold's only writer)
  // ═══════════════════════════════════════════════════════

  /// Effects: [family tag, then the ids or values the command created or changed].
  public func apply(s : State, c : T.Command) : T.Effects {
    switch (c) {
      case (#admitMember(x)) {
        let id = s.nextMember; s.nextMember += 1;
        RS.put(s.memberRows, members, id, { code = x.code; name = x.name; marketMaker = x.marketMaker; clearing = x.clearing; status = #active; admitted = x.day });
        [1, id]
      };
      case (#setMemberStatus(x)) {
        let ?m = member(s, x.member) else Runtime.trap("apply: member vanished");
        RS.put(s.memberRows, members, x.member, { m with status = x.status });
        [2, x.member, Nat8.toNat(K.memberStatusCode(x.status))]
      };
      case (#registerTrader(x)) {
        let id = s.nextTrader; s.nextTrader += 1;
        RS.put(s.traderRows, traders, id, { member = x.member; principal = x.principal; status = #active });
        [3, id]
      };
      case (#revokeTrader(x)) {
        let ?t = trader(s, x.trader) else Runtime.trap("apply: trader vanished");
        RS.put(s.traderRows, traders, x.trader, { t with status = #revoked });
        [4, x.trader]
      };
      case (#grantTradingRight(x)) {
        let id = s.nextRight; s.nextRight += 1;
        RS.put(s.rightRows, rights, id, { trader = x.trader; segment = x.segment; held = true });
        [5, id]
      };
      case (#withdrawTradingRight(x)) {
        let ?(id, r) = rightHeld(s, x.trader, x.segment) else Runtime.trap("apply: right vanished");
        RS.put(s.rightRows, rights, id, { r with held = false });
        [6, id]
      };
      case (#openAccount(x)) {
        let id = s.nextAccount; s.nextAccount += 1;
        RS.put(s.accountRows, accounts, id, { member = x.member; kind = x.kind; client = x.client; status = #open });
        [7, id]
      };
      case (#closeAccount(x)) {
        let ?a = account(s, x.account) else Runtime.trap("apply: account vanished");
        RS.put(s.accountRows, accounts, x.account, { a with status = #closed });
        [8, x.account]
      };
      case (#defineSegment(x)) {
        let id = s.nextSegment; s.nextSegment += 1;
        RS.put(s.segmentRows, segments, id, { code = x.code; name = x.name; windows = x.windows; phase = #closed; phaseDay = 0; phaseSec = 0 });
        [9, id]
      };
      case (#setSchedule(x)) {
        let ?g = segment(s, x.segment) else Runtime.trap("apply: segment vanished");
        RS.put(s.segmentRows, segments, x.segment, { g with windows = x.windows });
        [10, x.segment]
      };
      case (#setRestDays(x)) { s.restDays := x.days; [11, x.days.size()] };
      case (#declareHoliday(x)) {
        let id = s.nextHoliday; s.nextHoliday += 1;
        RS.put(s.holidayRows, holidays, id, { day = x.day });
        [12, id, x.day]
      };
      case (#defineTickTable(x)) {
        let id = s.nextTable; s.nextTable += 1;
        RS.put(s.tableRows, tables, id, { bands = x.bands });
        [13, id]
      };
      case (#listInstrument(x)) {
        let id = s.nextInstrument; s.nextInstrument += 1;
        RS.put(s.instrumentRows, instruments, id, { isin = x.isin; name = x.name; segment = x.segment; currency = x.currency; assetLedger = x.assetLedger; cashLedger = x.cashLedger;
          tickTable = x.tickTable; lot = x.lot; referencePrice = x.referencePrice; referenceDay = x.day; status = #listed });
        [14, id]
      };
      case (#setInstrumentStatus(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put(s.instrumentRows, instruments, x.instrument, { i with status = x.status });
        [15, x.instrument, Nat8.toNat(K.instrumentStatusCode(x.status))]
      };
      case (#setLot(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put(s.instrumentRows, instruments, x.instrument, { i with lot = x.lot });
        [16, x.instrument, x.lot]
      };
      case (#setReferencePrice(x)) {
        let ?i = instrument(s, x.instrument) else Runtime.trap("apply: instrument vanished");
        RS.put(s.instrumentRows, instruments, x.instrument, { i with referencePrice = x.price; referenceDay = x.day });
        [17, x.instrument, x.price]
      };
      case (#advancePhase(x)) {
        let ?g = segment(s, x.segment) else Runtime.trap("apply: segment vanished");
        let to = L.phaseAt(g.windows, calendarFor(s, x.day), x.day, x.sec);
        RS.put(s.segmentRows, segments, x.segment, { g with phase = to; phaseDay = x.day; phaseSec = x.sec });
        [18, x.segment, Nat8.toNat(K.phaseCode(g.phase)), Nat8.toNat(K.phaseCode(to))]
      };
      case (#setUtcOffset(x)) { s.utcOffsetMinutes := x.minutesEast; [19, Int.abs(x.minutesEast), if (x.minutesEast < 0) 1 else 0] };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE LIFECYCLE
  // ═══════════════════════════════════════════════════════

  public type Authority = { hasGrant : (Principal, Auth.PermissionId) -> Bool; holdsRole : (Principal, Auth.RoleId) -> Bool };
  public type Outcome = { #executed : { block : Nat; effects : T.Effects }; #proposed : { proposal : Cmd.ProposalId; required : Nat } };

  /// The checks that need the caller or the chain's clock, beside the state's: an account is opened or closed by a
  /// trader of the account's member; the scheduler's day and second are the chain's clock at submission.
  func contextual(s : State, now : Nat64, caller : Principal, c : T.Command) : ?T.Error {
    switch (c) {
      case (#openAccount(x)) {
        let ?(tid, t) = traderByPrincipal(s, caller) else return ?#UnknownTrader({ trader = 0 });
        if (t.status != #active) return ?#TraderRevoked({ trader = tid });
        if (t.member != x.member) return ?#NotYourMember({ member = x.member });
        null
      };
      case (#closeAccount(x)) {
        let ?(tid, t) = traderByPrincipal(s, caller) else return ?#UnknownTrader({ trader = 0 });
        if (t.status != #active) return ?#TraderRevoked({ trader = tid });
        switch (account(s, x.account)) { case (?a) { if (a.member != t.member) return ?#NotYourMember({ member = a.member }) }; case null {} };
        null
      };
      case (#advancePhase(x)) {
        let (day, sec) = marketTime(s, now);
        if (x.day != day or x.sec != sec) return ?#NotTheChainsClock({ day; sec });
        null
      };
      case (#declareHoliday(x)) {
        let (today, _) = marketTime(s, now);
        if (x.day < today) return ?#HolidayInPast({ day = x.day });
        null
      };
      case (_) null;
    }
  };

  func appendExecuted(s : State, now : Nat64, caller : Principal, proposal : ?Cmd.ProposalId, version : Nat8, c : T.Command) : (Nat, T.Effects) {
    let effects = apply(s, c);
    let b = DL.append(s.log, K.codec, now, caller, #executed({ proposal; version; command = c; effects }), null);
    (b.index, effects)
  };
  public func submit(s : State, auth : Authority, now : Nat64, caller : Principal, c : T.Command, partition : ?Text, justification : Text) : Result<Outcome> {
    let perm = permissionOf(c);
    if (not auth.hasGrant(caller, perm.id)) return #err(#auth(#NoGrant({ permission = perm.id })));
    // the caller and the clock first: a command claiming a time that is not the chain's is not judged against the
    // state at all (the battery found the order reversed: a forged second on a rest day refused as "phase unchanged")
    switch (contextual(s, now, caller, c)) { case (?e) return #err(#exchange(e)); case null {} };
    switch (validate(s, c)) { case (?e) return #err(#exchange(e)); case null {} };
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
  public func proposedCommand(s : State, id : Cmd.ProposalId) : ?T.Command {
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
    // the state is checked again at execution (it may have moved since the proposal); the caller-and-clock checks
    // were the maker's and stay with the proposal
    switch (validate(s, c)) {
      case (?err) {
        let rb = DL.append(s.log, K.codec, now, checker, #rejected({ proposal = id; checker; reason = "no longer valid at execution: " # debug_show(err) }), null);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #rejected(rb.index) });
        #err(#exchange(err))
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
  //  THE FOLD
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
    table<MemberRow>("members", s.memberRows, members, s.nextMember);
    table<TraderRow>("traders", s.traderRows, traders, s.nextTrader);
    table<RightRow>("rights", s.rightRows, rights, s.nextRight);
    table<AccountRow>("accounts", s.accountRows, accounts, s.nextAccount);
    table<SegmentRow>("segments", s.segmentRows, segments, s.nextSegment);
    table<TableRow>("ticktables", s.tableRows, tables, s.nextTable);
    table<InstrumentRow>("instruments", s.instrumentRows, instruments, s.nextInstrument);
    table<HolidayRow>("holidays", s.holidayRows, holidays, s.nextHoliday);
    Fold.section(f, "calendar", func(w : C.Writer) { w.nats(s.restDays); K.writeInt(w, s.utcOffsetMinutes) });
    Fold.section(f, "proposals", func(w : C.Writer) { var i = 0; let n = DL.length(s.log); while (i < n) { switch (RS.get(s.proposalRows, proposals, i)) { case (?r) { w.nat(i); w.blob(MC.encodeProposalRow(r)) }; case null {} }; i += 1 } });
    Fold.section(f, "log", func(w : C.Writer) { w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)) });
    Fold.fingerprintHash(f)
  };
  public type Counts = { members : Nat; traders : Nat; rights : Nat; accounts : Nat; segments : Nat; tables : Nat; instruments : Nat; holidays : Nat; blocks : Nat };
  public func counts(s : State) : Counts {
    { members = RS.size(s.memberRows); traders = RS.size(s.traderRows); rights = RS.size(s.rightRows); accounts = RS.size(s.accountRows); segments = RS.size(s.segmentRows);
      tables = RS.size(s.tableRows); instruments = RS.size(s.instrumentRows); holidays = RS.size(s.holidayRows); blocks = DL.length(s.log) }
  };
  /// The id counters: the refusal battery requires a refused command to move none of them.
  public func counters(s : State) : [Nat] { [s.nextMember, s.nextTrader, s.nextRight, s.nextAccount, s.nextSegment, s.nextTable, s.nextInstrument, s.nextHoliday] };
}
