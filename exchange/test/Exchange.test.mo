// Exchange.test.mo: the exchange's foundation: members, traders, accounts and rights; segments, the calendar and the
// market's clock; tick tables and instruments; the scheduler's phases through a year. The computed figures are dumped
// for the Python twin (`exchange/integration/exchange_twin.py`, run by `exchange/test/Exchange.verify.sh`), which
// recomputes every one with its own code.
//
// What is proved:
//   * the catalogue in both directions with a control; the single acts' reasons; every command round-tripped and
//     hashed twice; the row widths; every refusal code with its English and Arabic text, with a control;
//   * the market built under four eyes (the maker cannot approve, a stranger cannot, a second approval finds nothing
//     awaiting): the clock's offset, rest days, holidays, a tick table, two segments, three members, four traders,
//     their rights, house and client accounts, instruments with valid ISINs;
//   * every rule refused by name, each refusal leaving every row count, every id counter, the log's length and the
//     fingerprint where they were (four dimensions: this domain keeps no arena);
//   * the scheduler through every day of 2026 at every window boundary, the market's offset moving to summer time and
//     back: each act executes when the schedule names a new phase at the chain's clock and is refused when it names
//     the same, and an act whose day or second is not the chain's clock is refused;
//   * who may trade what: an active trader of an active member, holding the segment's right, the instrument listed;
//   * the replay: a fresh state folded from the log carries the same fingerprint and counts.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";

import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";
import Perm "mo:kernel/auth/Permissions";
import Auth "mo:kernel/auth/AuthTypes";
import CivilDate "mo:kernel/num/CivilDate";

import T "../src/ExchangeTypes";
import L "../src/ExchangeLogic";
import K "../src/ExchangeCanonical";
import X "../src/ExchangeCore";
import XT "../src/ExchangeText";
import TC "support/Traced";
import TR "../../custody/test/support/Transcript";

var failures = 0;
func check(cond : Bool, what : Text) { if (not cond) { failures += 1; Debug.print("FAIL: " # what) } };
func day(y : Nat, m : Nat, d : Nat) : Nat { switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { assert false; 0 } } };
func bytes(from : Nat, n : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(n, func(i) { Nat8.fromNat((from + i) % 256) })) };

let operator = Principal.fromText("2vxsx-fae");
let director1 = Principal.fromText("aaaaa-aa");
let director2 = Principal.fromText("ckbmq-yctyx-z6a2f-2xyya-pfg5n-jvgca-tye34-z7x4e-w6v53-cnjit-uae");
let stranger = Principal.fromText("pn3kh-726h2-5yyiw-u2lrd-wtubo-uttd2-cs4pa-l3xls-5zuwd-3wiii-zae");
let scheduler = Principal.fromText("6abng-3xbmm-zos2l-batfg-zytpv-vj2jv-3t7hk-3hh6q-6hugj-2q3bc-cqe");
let t1 = Principal.fromText("ktizj-ppt3n-t4gxw-lzckj-ghema-o6gli-zx5uq-eivp6-q5sun-c22gs-cqe");
let t2 = Principal.fromText("rwlgt-iiaaa-aaaaa-aaaaa-cai");
let t3 = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let t4 = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let shares = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");
let cash = Principal.fromText("rkp4c-7iaaa-aaaaa-aaaca-cai");
func isTrader(p : Principal) : Bool { Principal.equal(p, t1) or Principal.equal(p, t2) or Principal.equal(p, t3) or Principal.equal(p, t4) };
func hasGrant(p : Principal, perm : Text) : Bool {
  if (Principal.equal(p, operator)) return Text.startsWith(perm, #text "exchange.") and perm != "exchange.segment.advance" and perm != "exchange.instrument.reference";
  if (Principal.equal(p, scheduler)) return perm == "exchange.segment.advance" or perm == "exchange.instrument.reference";
  if (Principal.equal(p, director1) or Principal.equal(p, director2)) return perm == "command.approve" or perm == "command.reject";
  if (isTrader(p)) return perm == "exchange.account.open" or perm == "exchange.account.close";
  false
};
func holdsRole(p : Principal, role : Text) : Bool { role == "director" and (Principal.equal(p, director1) or Principal.equal(p, director2)) };
let auth : X.Authority = { hasGrant; holdsRole };
func dual(permission : Text) : { permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat } { { permission; required = 1; eligibleRole = "director"; ttlSeconds = 3_600 } };

// the chain's clock: 2026-01-01 00:00 UTC, moved by the test
let JAN1 = day(2026, 1, 1);
var now : Nat64 = Nat64.fromNat(JAN1 * 86_400 * 1_000_000_000);
func tick() : Nat64 { now += 1_000_000_000; now };

// ─── PART 1: the catalogue, the encoding, the texts ────────────────────────────────────────
let cat = X.catalogue();
let report = Perm.validate(cat, X.commandNames, X.methodNames);
check(Perm.clean(report), "catalogue validates: " # debug_show(report.faults));
let missingOne = Array.filter(cat, func(p : { id : Text }) : Bool { p.id != "exchange.segment.advance" });
check(not Perm.clean(Perm.validate(missingOne, X.commandNames, X.methodNames)), "control: a catalogue missing advancePhase fails validation");
for ((id, reason) in X.singleActs().vals()) { switch (Perm.byId(cat, id)) { case (?p) check(not p.dualByDefault and reason.size() > 40, "single act " # id # " has its reason"); case null check(false, "single act " # id # " exists") } };
for (p in cat.vals()) { if (not p.dualByDefault and Text.startsWith(p.id, #text "exchange.")) check(Array.find<(Text, Text)>(X.singleActs(), func(x) { x.0 == p.id }) != null, "single permission " # p.id # " has its reason recorded") };
check(X.checkSums(), "row widths hold their fields");
check(K.families.size() == 19, "nineteen command families");
Debug.print("count: catalogue rows validated in both directions = " # Nat.toText(report.checked));

let sampleCommands : [T.Command] = [
  #admitMember({ code = "1001"; name = "Nile Securities Brokerage"; marketMaker = true; clearing = true; day = JAN1 }),
  #setMemberStatus({ member = 1; status = #suspended; reason = "capital below the minimum" }),
  #registerTrader({ member = 1; principal = t1 }), #revokeTrader({ trader = 1; reason = "left the firm" }),
  #grantTradingRight({ trader = 1; segment = 1 }), #withdrawTradingRight({ trader = 1; segment = 1 }),
  #openAccount({ member = 1; kind = #client; client = bytes(0x51, 32) }), #openAccount({ member = 1; kind = #house; client = "" }),
  #closeAccount({ account = 1; reason = "client request" }),
  #defineSegment({ code = "MAIN"; name = "Main market"; windows = [{ phase = #closed; startSec = 0; endSec = 30_600 }, { phase = #continuous; startSec = 30_600; endSec = 86_400 }] }),
  #setSchedule({ segment = 1; windows = [{ phase = #closed; startSec = 0; endSec = 86_400 }] }),
  #setRestDays({ days = [4, 5] }), #declareHoliday({ day = JAN1 + 6; reason = "Coptic Christmas" }),
  #defineTickTable({ bands = [{ fromPrice = 0; tick = 1 }, { fromPrice = 2_000; tick = 10 }] }),
  #listInstrument({ isin = "US0378331005"; name = "x"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 10_000; day = JAN1 }),
  #setInstrumentStatus({ instrument = 1; status = #suspended; reason = "pending disclosure" }), #setLot({ instrument = 1; lot = 10 }),
  #setReferencePrice({ instrument = 1; price = 10_010; day = JAN1 + 1 }), #advancePhase({ segment = 1; day = JAN1; sec = 30_600 }),
  #setUtcOffset({ minutesEast = 120 }), #setUtcOffset({ minutesEast = -300 }), #setUtcOffset({ minutesEast = 0 }),
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
// an unknown family byte decodes to nothing, never to a default
check(E.readAt(K.registry, 1 : Nat8, C.Reader([20 : Nat8])) == null, "an unknown family tag is a decode fault");
check(K.phaseOf(8) == null and K.memberStatusOf(0) == null and K.instrumentStatusOf(4) == null, "an unknown vocabulary byte is a decode fault");
Debug.print("count: commands round-tripped through encoding v1 = " # Nat.toText(roundTrips));

func hasArabic(t : Text) : Bool { for (c in t.chars()) { let n = Nat32.toNat(Char.toNat32(c)); if (n >= 0x0600 and n <= 0x06FF) return true }; false };
var textsChecked = 0;
for (code in XT.codes.vals()) {
  switch (XT.texts(code)) {
    case (?t) { check(t.en.size() > 10 and hasArabic(t.ar) and not hasArabic(t.en), "code " # Nat.toText(code) # " has its English and Arabic texts"); textsChecked += 1 };
    case null check(false, "code " # Nat.toText(code) # " has texts");
  };
};
check(XT.texts(9_999) == null, "control: a code outside the catalogue has no text");
let sampleErrors : [T.Error] = [#InvalidText({ field = "x"; reason = "y" }), #DuplicateMemberCode({ code = "x" }), #UnknownMember({ member = 1 }), #MemberNotActive({ member = 1 }), #NoStatusChange,
  #ExpelledIsFinal({ member = 1 }), #DuplicateTrader({ principal = t1 }), #UnknownTrader({ trader = 1 }), #TraderRevoked({ trader = 1 }), #RightHeld({ trader = 1; segment = 1 }), #RightNotHeld({ trader = 1; segment = 1 }),
  #InvalidClientCommitment, #UnknownAccount({ account = 1 }), #AccountClosed({ account = 1 }), #DuplicateSegmentCode({ code = "x" }), #UnknownSegment({ segment = 1 }), #InvalidSchedule({ reason = "x" }),
  #InvalidRestDays, #DuplicateHoliday({ day = 1 }), #HolidayInPast({ day = 1 }), #InvalidTickTable({ reason = "x" }), #UnknownTickTable({ table = 1 }), #DuplicateIsin({ isin = "x" }), #InvalidIsin({ isin = "x" }),
  #InvalidCurrency({ currency = "x" }), #UnknownInstrument({ instrument = 1 }), #InstrumentDelisted({ instrument = 1 }), #InvalidLot, #PriceOffTick({ price = 1; tick = 1 }), #InvalidPrice,
  #NotTheChainsClock({ day = 1; sec = 1 }), #PhaseUnchanged({ segment = 1; phase = #closed }), #InvalidUtcOffset, #NotYourMember({ member = 1 })];
var codesSeen : [Nat] = [];
for (e in sampleErrors.vals()) {
  let c = XT.code(e);
  check(Array.find<Nat>(XT.codes, func(x) { x == c }) != null, "error " # debug_show(e) # " maps to a listed code");
  check(Array.find<Nat>(codesSeen, func(x) { x == c }) == null, "codes are unique: " # Nat.toText(c));
  codesSeen := Array.concat<Nat>(codesSeen, [c]);
};
check(codesSeen.size() == XT.codes.size(), "every listed code is an error's");
Debug.print("count: refusal codes with an English and an Arabic text = " # Nat.toText(textsChecked));

// ─── PART 2: the market, under four eyes ───────────────────────────────────────────────────
let s = X.newState();
X.setPolicies(s, Array.map<Auth.Permission, { permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat }>(Array.filter<Auth.Permission>(cat, func(p) { p.dualByDefault }), func(p) { dual(p.id) }));
type Dims = { counts : X.Counts; counters : [Nat]; blocks : Nat; fp : Blob };
func dims() : Dims { { counts = X.counts(s); counters = X.counters(s); blocks = X.counts(s).blocks; fp = X.fingerprint(s) } };
var refusals = 0;
func refused(r : X.Result<X.Outcome>, what : Text) {
  let d0 = dims();
  switch (r) {
    case (#err(_)) {
      refusals += 1;
      let d1 = dims();
      check(d1.counts == d0.counts, "refusal moved a row count: " # what);
      check(d1.counters == d0.counters, "refusal moved an id counter: " # what);
      check(d1.blocks == d0.blocks, "refusal moved the log: " # what);
      check(d1.fp == d0.fp, "refusal moved the fingerprint: " # what);
    };
    case (#ok(_)) check(false, "should refuse: " # what);
  }
};
func refusedAs(r : X.Result<X.Outcome>, want : Nat, what : Text) {
  switch (r) { case (#err(#exchange(e))) check(XT.code(e) == want, "refused " # what # " with code " # Nat.toText(want) # ", got " # Nat.toText(XT.code(e))); case (_) {} };
  refused(r, what)
};
func sub(who : Principal, c : T.Command) : X.Result<X.Outcome> { TC.xsub(s, auth, tick(), who, c, null, "test") };
var governed = 0;
func govern(c : T.Command, what : Text) : [Nat] {
  switch (sub(operator, c)) {
    case (#ok(#proposed(p))) {
      switch (TC.xapp(s, auth, tick(), operator, p.proposal)) { case (#err(#auth(#NoGrant(_)))) {}; case (_) check(false, "the maker holds no approval grant: " # what) };
      switch (TC.xapp(s, auth, tick(), stranger, p.proposal)) { case (#err(#auth(#NoGrant(_)))) {}; case (_) check(false, "stranger approval refused: " # what) };
      switch (TC.xapp(s, auth, tick(), director1, p.proposal)) {
        case (#ok(#executed(x))) { governed += 1; switch (TC.xapp(s, auth, tick(), director2, p.proposal)) { case (#err(#auth(#ProposalNotAwaiting(_)))) {}; case (_) check(false, "second approval refused: " # what) }; x.effects };
        case (other) { check(false, "approval executes " # what # ": " # debug_show(other)); [] };
      };
    };
    case (other) { check(false, "proposed " # what # ": " # debug_show(other)); [] };
  }
};
func single(who : Principal, c : T.Command, what : Text) : [Nat] { switch (sub(who, c)) { case (#ok(#executed(x))) x.effects; case (other) { check(false, "single act executes " # what # ": " # debug_show(other)); [] } } };

// the market's clock and calendar
refusedAs(sub(operator, #setUtcOffset({ minutesEast = 841 })), 1033, "an offset beyond fourteen hours");
check(govern(#setUtcOffset({ minutesEast = 120 }), "offset") == [19, 120, 0], "the market at UTC+2");
refusedAs(sub(operator, #setRestDays({ days = [4, 4] })), 1018, "a rest day twice");
refusedAs(sub(operator, #setRestDays({ days = [0, 1, 2, 3, 4, 5, 6] })), 1018, "no working day");
check(govern(#setRestDays({ days = [4, 5] }), "rest days") == [11, 2], "Friday and Saturday");
let holidaysOf2026 : [(Nat, Text)] = [(day(2026, 1, 7), "Coptic Christmas"), (day(2026, 1, 25), "Revolution Day"), (day(2026, 4, 13), "Sham El-Nessim"), (day(2026, 4, 25), "Sinai Liberation Day"),
  (day(2026, 5, 1), "Labour Day"), (day(2026, 6, 30), "June 30 Revolution"), (day(2026, 7, 23), "Revolution Day (July 23)"), (day(2026, 10, 6), "Armed Forces Day")];
for ((d, why) in holidaysOf2026.vals()) { check(govern(#declareHoliday({ day = d; reason = why }), "holiday").size() == 3, "holiday " # why) };
refusedAs(sub(operator, #declareHoliday({ day = day(2026, 10, 6); reason = "again" })), 1019, "a holiday twice");
// tick table: 0.001 below 2.00 and 0.01 from 2.00 (prices in thousandths of a pound)
refusedAs(sub(operator, #defineTickTable({ bands = [] })), 1021, "a table of no band");
refusedAs(sub(operator, #defineTickTable({ bands = [{ fromPrice = 1; tick = 1 }] })), 1021, "a table not starting at zero");
refusedAs(sub(operator, #defineTickTable({ bands = [{ fromPrice = 0; tick = 0 }] })), 1021, "a tick of zero");
refusedAs(sub(operator, #defineTickTable({ bands = [{ fromPrice = 0; tick = 3 }, { fromPrice = 2_000; tick = 10 }] })), 1021, "a band off the previous grid");
refusedAs(sub(operator, #defineTickTable({ bands = [{ fromPrice = 0; tick = 1 }, { fromPrice = 0; tick = 10 }] })), 1021, "bands not rising");
check(govern(#defineTickTable({ bands = [{ fromPrice = 0; tick = 1 }, { fromPrice = 2_000; tick = 10 }] }), "table") == [13, 1], "the EGX table");
// the EGX day: pre-open 08:30 to 10:00, continuous 10:00 to 14:15, closing auction 14:15 to 14:30, trade at close 14:30 to 14:40
let egxDay : [T.Window] = [
  { phase = #closed; startSec = 0; endSec = 30_600 }, { phase = #preOpen; startSec = 30_600; endSec = 36_000 }, { phase = #continuous; startSec = 36_000; endSec = 51_300 },
  { phase = #closingAuction; startSec = 51_300; endSec = 52_200 }, { phase = #tradeAtClose; startSec = 52_200; endSec = 52_800 }, { phase = #closed; startSec = 52_800; endSec = 86_400 }];
let nileDay : [T.Window] = [{ phase = #closed; startSec = 0; endSec = 36_000 }, { phase = #continuous; startSec = 36_000; endSec = 48_600 }, { phase = #closed; startSec = 48_600; endSec = 86_400 }];
refusedAs(sub(operator, #defineSegment({ code = "MAIN"; name = "Main market"; windows = [] })), 1017, "a schedule of no window");
refusedAs(sub(operator, #defineSegment({ code = "MAIN"; name = "Main market"; windows = [{ phase = #closed; startSec = 0; endSec = 100 }] })), 1017, "a schedule short of midnight");
refusedAs(sub(operator, #defineSegment({ code = "MAIN"; name = "Main market"; windows = [{ phase = #closed; startSec = 0; endSec = 100 }, { phase = #continuous; startSec = 101; endSec = 86_400 }] })), 1017, "a gap");
refusedAs(sub(operator, #defineSegment({ code = "MAIN"; name = "Main market"; windows = [{ phase = #closed; startSec = 0; endSec = 100 }, { phase = #halted; startSec = 100; endSec = 86_400 }] })), 1017, "a scheduled halt");
refusedAs(sub(operator, #defineSegment({ code = "TOOLONGCODE"; name = "x"; windows = egxDay })), 1001, "a code longer than eight bytes");
check(govern(#defineSegment({ code = "MAIN"; name = "Main market"; windows = egxDay }), "segment") == [9, 1], "segment MAIN");
check(govern(#defineSegment({ code = "NILE"; name = "Nile SME market"; windows = nileDay }), "segment") == [9, 2], "segment NILE");
refusedAs(sub(operator, #defineSegment({ code = "MAIN"; name = "again"; windows = egxDay })), 1015, "a segment code twice");
refusedAs(sub(operator, #setSchedule({ segment = 9; windows = egxDay })), 1016, "a schedule for no segment");
// members, traders, rights, accounts
check(govern(#admitMember({ code = "1001"; name = "Nile Securities Brokerage"; marketMaker = true; clearing = true; day = JAN1 }), "member") == [1, 1], "member 1");
check(govern(#admitMember({ code = "1002"; name = "Delta Brokerage"; marketMaker = false; clearing = true; day = JAN1 }), "member") == [1, 2], "member 2");
check(govern(#admitMember({ code = "1003"; name = "Sinai Securities"; marketMaker = false; clearing = false; day = JAN1 }), "member") == [1, 3], "member 3");
refusedAs(sub(operator, #admitMember({ code = "1001"; name = "again"; marketMaker = false; clearing = false; day = JAN1 })), 1002, "a member code twice");
check(govern(#registerTrader({ member = 1; principal = t1 }), "trader") == [3, 1], "trader 1 of member 1");
check(govern(#registerTrader({ member = 1; principal = t2 }), "trader") == [3, 2], "trader 2 of member 1");
check(govern(#registerTrader({ member = 2; principal = t3 }), "trader") == [3, 3], "trader 3 of member 2");
refusedAs(sub(operator, #registerTrader({ member = 2; principal = t1 })), 1007, "a principal as trader twice");
refusedAs(sub(operator, #registerTrader({ member = 9; principal = t4 })), 1003, "a trader of no member");
check(govern(#setMemberStatus({ member = 3; status = #suspended; reason = "capital below the minimum" }), "suspend") == [2, 3, 2], "member 3 suspended");
refusedAs(sub(operator, #registerTrader({ member = 3; principal = t4 })), 1004, "a trader of a suspended member");
refusedAs(sub(operator, #setMemberStatus({ member = 3; status = #suspended; reason = "again" })), 1005, "the same status");
check(govern(#setMemberStatus({ member = 3; status = #expelled; reason = "default on obligations" }), "expel") == [2, 3, 3], "member 3 expelled");
refusedAs(sub(operator, #setMemberStatus({ member = 3; status = #active; reason = "reinstate" })), 1006, "an expelled member reinstated");
check(govern(#grantTradingRight({ trader = 1; segment = 1 }), "right") == [5, 1], "t1 trades MAIN");
check(govern(#grantTradingRight({ trader = 1; segment = 2 }), "right") == [5, 2], "t1 trades NILE");
check(govern(#grantTradingRight({ trader = 3; segment = 1 }), "right") == [5, 3], "t3 trades MAIN");
refusedAs(sub(operator, #grantTradingRight({ trader = 1; segment = 1 })), 1010, "a right twice");
refusedAs(sub(operator, #grantTradingRight({ trader = 1; segment = 7 })), 1016, "a right in no segment");
check(govern(#withdrawTradingRight({ trader = 1; segment = 2 }), "withdraw") == [6, 2], "t1 no longer trades NILE");
refusedAs(sub(operator, #withdrawTradingRight({ trader = 1; segment = 2 })), 1011, "a right withdrawn twice");
check(single(t1, #openAccount({ member = 1; kind = #house; client = "" }), "house account") == [7, 1], "member 1's house account");
check(single(t1, #openAccount({ member = 1; kind = #client; client = bytes(0x61, 32) }), "client account") == [7, 2], "a client account of member 1");
check(single(t3, #openAccount({ member = 2; kind = #client; client = bytes(0x62, 32) }), "client account") == [7, 3], "a client account of member 2");
refusedAs(sub(t1, #openAccount({ member = 2; kind = #house; client = "" })), 1034, "a trader opening another member's account");
refusedAs(sub(t1, #openAccount({ member = 1; kind = #client; client = bytes(0x63, 31) })), 1012, "a client commitment of 31 bytes");
refusedAs(sub(t1, #openAccount({ member = 1; kind = #house; client = bytes(0x63, 32) })), 1012, "a house account naming a client");
refused(sub(stranger, #openAccount({ member = 1; kind = #house; client = "" })), "a stranger opening an account");
refusedAs(sub(t3, #closeAccount({ account = 2; reason = "x" })), 1034, "a trader closing another member's account");
check(single(t1, #closeAccount({ account = 2; reason = "the client moved to another broker" }), "close") == [8, 2], "account 2 closed");
refusedAs(sub(t1, #closeAccount({ account = 2; reason = "again" })), 1014, "an account closed twice");
check(govern(#revokeTrader({ trader = 2; reason = "left the firm" }), "revoke") == [4, 2], "trader 2 revoked");
refusedAs(sub(operator, #grantTradingRight({ trader = 2; segment = 1 })), 1009, "a right to a revoked trader");
refusedAs(sub(t2, #openAccount({ member = 1; kind = #house; client = "" })), 1009, "a revoked trader opening an account");
// instruments
// two fictional test issuers (XS0TEST...), their ISINs' check digits computed by the code under test and, in the
// twin, by the twin's own; no real company is listed or delisted in this battery
let isinA = "XS0TESTA0014";
let isinB = "XS0TESTB0021";
refusedAs(sub(operator, #listInstrument({ isin = "XS0TESTA0015"; name = "x"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 85_000; day = JAN1 })), 1024, "an ISIN with a wrong check digit");
refusedAs(sub(operator, #listInstrument({ isin = isinA; name = "x"; segment = 1; currency = "egp"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 85_000; day = JAN1 })), 1025, "a currency in lower case");
refusedAs(sub(operator, #listInstrument({ isin = isinA; name = "x"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 4; lot = 1; referencePrice = 85_000; day = JAN1 })), 1022, "no such tick table");
refusedAs(sub(operator, #listInstrument({ isin = isinA; name = "x"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 0; referencePrice = 85_000; day = JAN1 })), 1028, "a lot of zero");
refusedAs(sub(operator, #listInstrument({ isin = isinA; name = "x"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 85_005; day = JAN1 })), 1029, "a reference price off the 0.01 tick");
check(govern(#listInstrument({ isin = isinA; name = "Test Issuer A ordinary shares"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 85_000; day = JAN1 }), "listing") == [14, 1], "issuer A listed");
check(govern(#listInstrument({ isin = isinB; name = "Test Issuer B ordinary shares"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 1_995; day = JAN1 }), "listing") == [14, 2], "issuer B listed below 2.00, on the 0.001 tick");
refusedAs(sub(operator, #listInstrument({ isin = isinA; name = "again"; segment = 1; currency = "EGP"; assetLedger = shares; cashLedger = cash; tickTable = 1; lot = 1; referencePrice = 85_000; day = JAN1 })), 1023, "an ISIN twice");
refusedAs(sub(scheduler, #setReferencePrice({ instrument = 2; price = 2_005; day = JAN1 + 1 })), 1029, "a reference above 2.00 off the 0.01 tick");
check(single(scheduler, #setReferencePrice({ instrument = 2; price = 2_010; day = JAN1 + 1 }), "reference") == [17, 2, 2_010], "issuer B's reference crosses into the 0.01 band");
refused(sub(operator, #setReferencePrice({ instrument = 2; price = 2_020; day = JAN1 + 1 })), "the operator holds no reference grant");
check(govern(#setLot({ instrument = 1; lot = 10 }), "lot") == [16, 1, 10], "issuer A's lot");
check(govern(#setInstrumentStatus({ instrument = 2; status = #delisted; reason = "test: delisting" }), "delist") == [15, 2, 3], "issuer B delisted");
refusedAs(sub(operator, #setLot({ instrument = 2; lot = 5 })), 1027, "a lot on a delisted instrument");
refusedAs(sub(operator, #setInstrumentStatus({ instrument = 2; status = #listed; reason = "x" })), 1027, "a delisting undone");
Debug.print("count: acts executed under four eyes = " # Nat.toText(governed));

// who may trade what
check(X.mayTrade(s, t1, 1) == null, "t1 may trade issuer A");
check(X.mayTrade(s, t3, 1) == null, "t3 may trade issuer A");
check(X.mayTrade(s, t2, 1) == ?#TraderRevoked({ trader = 2 }), "a revoked trader may not");
check(X.mayTrade(s, t4, 1) == ?#UnknownTrader({ trader = 0 }), "an unregistered principal may not");
check(X.mayTrade(s, t1, 2) == ?#InstrumentDelisted({ instrument = 2 }), "a delisted instrument may not be traded");
check(X.mayTrade(s, t1, 9) == ?#UnknownInstrument({ instrument = 9 }), "an unknown instrument");

// ─── PART 3: the scheduler through 2026 ────────────────────────────────────────────────────
// Summer time in Egypt: from the last Friday of April (2026-04-24) to the last Thursday of October (2026-10-29).
let SUMMER_FROM = day(2026, 4, 24);
let SUMMER_TO = day(2026, 10, 29);
var executed = 0; var unchanged = 0; var clockRefused = 0; var offsetMoves = 0;
Debug.print("dump:offset|" # Nat.toText(JAN1) # "|120");
for ((d, _) in holidaysOf2026.vals()) Debug.print("dump:holiday|" # Nat.toText(d));
Debug.print("dump:restdays|4,5");
func dumpWindows(seg : Nat, ws : [T.Window]) { for (w in ws.vals()) Debug.print("dump:window|" # Nat.toText(seg) # "|" # Nat.toText(Nat8.toNat(K.phaseCode(w.phase))) # "|" # Nat.toText(w.startSec) # "|" # Nat.toText(w.endSec)) };
dumpWindows(1, egxDay); dumpWindows(2, nileDay);
let boundaries : [Nat] = [0, 30_600, 36_000, 48_600, 51_300, 52_200, 52_800];
var d = JAN1;
let DEC31 = day(2026, 12, 31);
while (d <= DEC31) {
  // the offset changes are acts at 00:00 local time of the day they take effect
  if (d == SUMMER_FROM or d == SUMMER_TO) {
    let m : Int = if (d == SUMMER_FROM) 180 else 120;
    let prev : Int = X.utcOffset(s);
    now := Nat64.fromNat(Int.abs(((d * 86_400 : Nat) : Int) - prev * 60) * 1_000_000_000);
    switch (sub(operator, #setUtcOffset({ minutesEast = m }))) {
      case (#ok(#proposed(p))) { switch (TC.xapp(s, auth, tick(), director1, p.proposal)) { case (#ok(#executed(_))) { offsetMoves += 1 }; case (o) check(false, "offset move: " # debug_show(o)) } };
      case (o) check(false, "offset proposed: " # debug_show(o));
    };
    Debug.print("dump:offset|" # Nat.toText(d) # "|" # Int.toText(m));
  };
  for (sec in boundaries.vals()) {
    for (seg in [1, 2].vals()) {
      let off = X.utcOffset(s);
      // the chain's clock at this market time
      now := Nat64.fromNat(Int.abs(((d * 86_400 + sec : Nat) : Int) - off * 60) * 1_000_000_000);
      let (md, ms) = X.marketTime(s, now);
      check(md == d and ms == sec, "the market time of the chain's clock round-trips");
      let before = switch (X.segment(s, seg)) { case (?g) g.phase; case null #closed };
      switch (TC.xsub(s, auth, now, scheduler, #advancePhase({ segment = seg; day = d; sec }), null, "schedule")) {
        case (#ok(#executed(x))) { executed += 1; Debug.print("dump:advance|" # Nat.toText(seg) # "|" # Nat.toText(d) # "|" # Nat.toText(sec) # "|" # Nat.toText(x.effects[2]) # ">" # Nat.toText(x.effects[3])) };
        case (#err(#exchange(#PhaseUnchanged(_)))) { unchanged += 1; Debug.print("dump:advance|" # Nat.toText(seg) # "|" # Nat.toText(d) # "|" # Nat.toText(sec) # "|=" # Nat.toText(Nat8.toNat(K.phaseCode(before)))) };
        case (o) check(false, "advance " # debug_show(o));
      };
    };
  };
  // once a day, an act claiming a second that is not the chain's: refused, nothing moved
  if (d % 17 == 0) {
    now := Nat64.fromNat(Int.abs(((d * 86_400 + 40_000 : Nat) : Int) - X.utcOffset(s) * 60) * 1_000_000_000);
    refusedAs(TC.xsub(s, auth, now, scheduler, #advancePhase({ segment = 1; day = d; sec = 30_600 }), null, "x"), 1031, "a claimed second that is not the chain's");
    clockRefused += 1;
  };
  d += 1;
};
check(offsetMoves == 2, "two offset moves in the year");
Debug.print("count: scheduler acts executed (a new phase at the chain's clock) = " # Nat.toText(executed));
Debug.print("count: scheduler acts refused because the schedule names the same phase = " # Nat.toText(unchanged));
Debug.print("count: scheduler acts refused because the second was not the chain's = " # Nat.toText(clockRefused));
refusedAs(sub(operator, #declareHoliday({ day = day(2026, 3, 1); reason = "a day already passed" })), 1020, "a holiday in the past");
refused(sub(operator, #advancePhase({ segment = 1; day = 0; sec = 0 })), "the operator holds no scheduler grant");

// the rows, dumped for the twin's recomputation
for (i in [1, 2].vals()) {
  switch (X.instrument(s, i)) { case (?r) Debug.print("dump:instrument|" # r.isin # "|" # Nat.toText(r.referencePrice) # "|" # Nat.toText(r.lot) # "|" # Nat.toText(Nat8.toNat(K.instrumentStatusCode(r.status)))); case null check(false, "instrument row") };
};
// check-digit vectors: EGS60121C018 (an EGX share, verified against a public listing), US0378331005, DE0007164600,
// GB0002634946 (well-known examples), the two test ISINs, and malformed or altered ones
for (x in ["EGS60121C018", "US0378331005", "DE0007164600", "GB0002634946", "XS0TESTA0014", "XS0TESTB0021", "XS0TESTA0015", "XX0000000000", "eGS60121C018", "EGS60121C01"].vals()) Debug.print("dump:isin|" # x # "|" # (if (L.isinValid(x)) "1" else "0"));
switch (X.tickTable(s, 1)) {
  case (?tbl) { for (p in [1, 5, 1_995, 1_999, 2_000, 2_005, 2_010, 85_000, 85_005].vals()) Debug.print("dump:tick|" # Nat.toText(p) # "|" # (if (L.onTick(tbl.bands, p)) "1" else "0")) };
  case null check(false, "the tick table row");
};
Debug.print("dump:tickbands|0:1,2000:10");

// ─── PART 4: the replay ────────────────────────────────────────────────────────────────────
let fresh = X.newStateOver(s.log);
X.setPolicies(fresh, s.policies);
let rp = X.replay(fresh);
check(rp.faults.size() == 0, "replay without faults: " # debug_show(rp.faults));
check(X.fingerprint(fresh) == X.fingerprint(s), "the replayed fingerprint equals the live one");
check(X.counts(fresh) == X.counts(s) and X.counters(fresh) == X.counters(s), "the replayed counts and counters equal the live ones");
Debug.print("count: blocks replayed onto a fresh state = " # Nat.toText(rp.blocks));
Debug.print("count: refusals that left every dimension where it was = " # Nat.toText(refusals));
TR.fingerprint("exchange", X.fingerprint(s));

if (failures > 0) { Debug.print("EXCHANGE FAILED: " # Nat.toText(failures)); assert false } else Debug.print("EXCHANGE GREEN");
