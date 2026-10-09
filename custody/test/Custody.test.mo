// Custody.test.mo: the custody register beside the venue: holders and positions as the fold of the venue's receipts,
// reconciliations, corporate actions struck at the record date and paid on the payment date in slices, the
// entitlement file certified by its hash; the figures dumped for the Python twin (`custody/integration/custody_twin.py`,
// run by `custody/test/Custody.verify.sh`).
//
// What is proved:
//   * the catalogue in both directions with a control; the single acts' reasons; every command round-tripped and
//     hashed twice; the row widths; the arithmetic's own vectors;
//   * holders and assets under four eyes (a holder twice, an asset code twice, a supply of nothing refused); the
//     issued supply opens in the issuer's position;
//   * a settlement recorded by the venue's receipt once (the same receipt twice refused), moving units from one
//     holder to another and never more than a holder has; none while an action struck on the asset awaits payment;
//   * a reconciliation of every holder's position to the ledger's attested balance and of the register's total to
//     the issued supply, with its hash;
//   * five corporate actions on the record-date positions: a cash dividend, a split with cash in lieu of fractions,
//     rights subscribed within the entitlement and by the deadline, a redemption, a bonus; each struck in slices of
//     two holders, paid in slices, its file certified by a hash the twin reproduces; the positions and the supply
//     after each; one action at a time per asset; every rule refused by name with the fingerprint unmoved;
//   * the replay: a fresh state folded from the log carries the same fingerprint and counts.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";

import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";
import Perm "mo:kernel/auth/Permissions";
import CivilDate "mo:kernel/num/CivilDate";

import CT "../src/CustodyTypes";
import M "../src/CustodyMath";
import K "../src/CustodyCanonical";
import Cu "../src/CustodyCore";
import TC "support/Traced";
import TR "support/Transcript";

var failures = 0;
func check(cond : Bool, what : Text) { if (not cond) { failures += 1; Debug.print("FAIL: " # what) } };
func day(y : Nat, m : Nat, d : Nat) : Nat { switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { assert false; 0 } } };
func bytes(from : Nat, n : Nat) : Blob { Blob.fromArray(Array.tabulate<Nat8>(n, func(i) { Nat8.fromNat((from + i) % 256) })) };
let D0 = day(2026, 9, 21);

let registrar = Principal.fromText("2vxsx-fae");
let director1 = Principal.fromText("aaaaa-aa");
let director2 = Principal.fromText("ckbmq-yctyx-z6a2f-2xyya-pfg5n-jvgca-tye34-z7x4e-w6v53-cnjit-uae");
let stranger = Principal.fromText("pn3kh-726h2-5yyiw-u2lrd-wtubo-uttd2-cs4pa-l3xls-5zuwd-3wiii-zae");
let shares = Principal.fromText("6abng-3xbmm-zos2l-batfg-zytpv-vj2jv-3t7hk-3hh6q-6hugj-2q3bc-cqe");
let cash = Principal.fromText("ktizj-ppt3n-t4gxw-lzckj-ghema-o6gli-zx5uq-eivp6-q5sun-c22gs-cqe");
func hasGrant(p : Principal, perm : Text) : Bool {
  if (Principal.equal(p, registrar)) return Text.startsWith(perm, #text "custody.");
  if (Principal.equal(p, director1) or Principal.equal(p, director2)) return perm == "command.approve" or perm == "command.reject";
  false
};
func holdsRole(p : Principal, role : Text) : Bool { role == "director" and (Principal.equal(p, director1) or Principal.equal(p, director2)) };
let auth : Cu.Authority = { hasGrant; holdsRole };
func dual(permission : Text) : { permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat } { { permission; required = 1; eligibleRole = "director"; ttlSeconds = 3_600 } };
var now : Nat64 = 1_758_400_000_000_000_000;
func tick() : Nat64 { now += 1_000_000_000; now };

// ─── PART 1: the catalogue, the encoding, the arithmetic ───────────────────────────────────
let cat = Cu.catalogue();
let report = Perm.validate(cat, Cu.commandNames, Cu.methodNames);
check(Perm.clean(report), "catalogue validates: " # debug_show(report.faults));
let missingOne = Array.filter(cat, func(p : { id : Text }) : Bool { p.id != "custody.action.announce" });
check(not Perm.clean(Perm.validate(missingOne, Cu.commandNames, Cu.methodNames)), "control: a catalogue missing announceAction fails validation");
for ((id, reason) in Cu.singleActs().vals()) { switch (Perm.byId(cat, id)) { case (?p) check(not p.dualByDefault and reason.size() > 40, "single act " # id # " has its reason"); case null check(false, "single act " # id # " exists") } };
for (p in cat.vals()) { if (not p.dualByDefault and Text.startsWith(p.id, #text "custody.")) check(Array.find<(Text, Text)>(Cu.singleActs(), func(x) { x.0 == p.id }) != null, "single permission " # p.id # " has its reason recorded") };
check(Cu.checkSums(), "row widths hold their fields");
check(M.checkArithmetic(), "the arithmetic's own vectors");
Debug.print("count: catalogue rows validated in both directions = " # Nat.toText(report.checked));
let receipt1 : CT.Receipt = { kind = #trade; id = 41; block = 7; hash = bytes(0x11, 32) };
let sampleCommands : [CT.Command] = [
  #registerHolder({ holder = 1; commit = bytes(0xA1, 32); account = shares }), #registerAsset({ code = "PHRS"; name = "Pharos Holdings ordinary shares"; ledger = shares; cashLedger = cash; issuedSupply = 1_000_000; issuer = 1 }),
  #recordSettlement({ asset = 1; receipt = receipt1; from = 1; to = 2; units = 100_000; day = D0 }), #reconcile({ asset = 1; day = D0 + 1; ledgerBlock = 99; balances = [(1, 900_000), (2, 100_000)] }),
  #announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 250 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = bytes(0xC1, 32) }),
  #announceAction({ asset = 1; kind = #rights({ numerator = 1; denominator = 4; subscriptionPriceMicro = 5; subscriptionDeadline = D0 + 15 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = bytes(0xC2, 32) }),
  #cancelAction({ action = 1; day = D0 + 2; reason = "withdrawn by the issuer" }), #strikeRecordDate({ action = 1; limit = 2 }), #subscribeRights({ action = 3; holder = 2; rights = 100; day = D0 + 12 }),
  #pay({ action = 1; day = D0 + 20; limit = 2 }), #certifyEntitlementFile({ action = 1; day = D0 + 21 }),
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
Debug.print("count: commands round-tripped through encoding v1 = " # Nat.toText(roundTrips));

// ─── PART 2: the register ──────────────────────────────────────────────────────────────────
let s = Cu.newState();
Cu.setPolicies(s, [dual("custody.holder.register"), dual("custody.asset.register"), dual("custody.reconcile"), dual("custody.action.announce"), dual("custody.action.cancel"), dual("custody.file.certify")]);
var refusals = 0;
func refused(r : Cu.Result<Cu.Outcome>, what : Text) {
  let f0 = Cu.fingerprint(s);
  switch (r) { case (#err(_)) { refusals += 1; check(Cu.fingerprint(s) == f0, "refusal left the state: " # what) }; case (#ok(_)) check(false, "should refuse: " # what) }
};
func sub(c : CT.Command) : Cu.Result<Cu.Outcome> { TC.csub(s, auth, tick(), registrar, c, null, "x") };
var governed = 0;
func govern(c : CT.Command, what : Text) : [Nat] {
  switch (sub(c)) {
    case (#ok(#proposed(p))) {
      switch (TC.capp(s, auth, tick(), registrar, p.proposal)) { case (#err(#auth(#NoGrant(_)))) {}; case (_) check(false, "the maker holds no approval grant: " # what) };
      switch (TC.capp(s, auth, tick(), stranger, p.proposal)) { case (#err(#auth(#NoGrant(_)))) {}; case (_) check(false, "stranger approval refused: " # what) };
      switch (TC.capp(s, auth, tick(), director1, p.proposal)) {
        case (#ok(#executed(x))) { governed += 1; switch (TC.capp(s, auth, tick(), director2, p.proposal)) { case (#err(#auth(#ProposalNotAwaiting(_)))) {}; case (_) check(false, "second approval refused: " # what) }; x.effects };
        case (other) { check(false, "approval executes " # what # ": " # debug_show(other)); [] };
      };
    };
    case (other) { check(false, "proposed " # what # ": " # debug_show(other)); [] };
  }
};
func single(c : CT.Command, what : Text) : [Nat] { switch (sub(c)) { case (#ok(#executed(x))) x.effects; case (other) { check(false, "single act executes " # what # ": " # debug_show(other)); [] } } };
func rcpt(id : Nat) : CT.Receipt { { kind = #trade; id; block = 100 + id; hash = bytes(id, 32) } };

refused(TC.csub(s, auth, tick(), stranger, #registerHolder({ holder = 1; commit = bytes(0xA1, 32); account = shares }), null, "x"), "stranger registers a holder");
refused(sub(#registerHolder({ holder = 0; commit = bytes(0xA1, 32); account = shares })), "holder zero");
refused(sub(#registerHolder({ holder = 1; commit = bytes(0xA1, 31); account = shares })), "a 31-byte commitment");
for (h in [1, 2, 3, 4].vals()) { check(govern(#registerHolder({ holder = h; commit = bytes(0xA0 + h, 32); account = if (h == 1) shares else Principal.fromText("aaaaa-aa") }), "holder") == [h], "holder " # Nat.toText(h)) };
refused(sub(#registerHolder({ holder = 2; commit = bytes(0xB2, 32); account = shares })), "a holder twice");
refused(sub(#registerAsset({ code = "PHRS"; name = "x"; ledger = shares; cashLedger = cash; issuedSupply = 0; issuer = 1 })), "an asset with no supply");
refused(sub(#registerAsset({ code = "PHRS"; name = "x"; ledger = shares; cashLedger = cash; issuedSupply = 1; issuer = 9 })), "an asset with an unknown issuer");
check(govern(#registerAsset({ code = "PHRS"; name = "Pharos Holdings ordinary shares"; ledger = shares; cashLedger = cash; issuedSupply = 1_000_000; issuer = 1 }), "asset") == [1], "asset 1");
refused(sub(#registerAsset({ code = "PHRS"; name = "again"; ledger = shares; cashLedger = cash; issuedSupply = 5; issuer = 1 })), "an asset code twice");
check(Cu.position(s, 1, 1) == 1_000_000 and Cu.positionsTotal(s, 1) == 1_000_000, "the issued supply opens in the issuer's position");
Debug.print("count: holders and assets registered under four eyes = 5");

// the venue's receipts fold into positions
refused(sub(#recordSettlement({ asset = 9; receipt = rcpt(1); from = 1; to = 2; units = 1; day = D0 })), "a settlement on an unknown asset");
refused(sub(#recordSettlement({ asset = 1; receipt = rcpt(1); from = 1; to = 9; units = 1; day = D0 })), "a settlement to an unknown holder");
refused(sub(#recordSettlement({ asset = 1; receipt = rcpt(1); from = 2; to = 3; units = 1; day = D0 })), "a settlement from an empty position");
refused(sub(#recordSettlement({ asset = 1; receipt = rcpt(1); from = 1; to = 2; units = 0; day = D0 })), "a settlement of nothing");
refused(sub(#recordSettlement({ asset = 1; receipt = { rcpt(1) with hash = bytes(1, 31) }; from = 1; to = 2; units = 1; day = D0 })), "a receipt with a 31-byte hash");
check(single(#recordSettlement({ asset = 1; receipt = rcpt(1); from = 1; to = 2; units = 100_000; day = D0 }), "settle 1") == [1], "receipt 1 recorded");
refused(sub(#recordSettlement({ asset = 1; receipt = rcpt(1); from = 1; to = 3; units = 1; day = D0 })), "the same receipt twice");
check(single(#recordSettlement({ asset = 1; receipt = rcpt(2); from = 1; to = 3; units = 50_000; day = D0 }), "settle 2") == [2], "receipt 2");
check(single(#recordSettlement({ asset = 1; receipt = rcpt(3); from = 1; to = 4; units = 7; day = D0 + 1 }), "settle 3") == [3], "receipt 3");
check(single(#recordSettlement({ asset = 1; receipt = { kind = #delivery; id = 5; block = 120; hash = bytes(0x55, 32) }; from = 2; to = 3; units = 10_000; day = D0 + 2 }), "deliver") == [4], "a delivery recorded");
refused(sub(#recordSettlement({ asset = 1; receipt = rcpt(9); from = 4; to = 2; units = 8; day = D0 + 2 })), "more than the holder has");
check(Cu.position(s, 1, 1) == 849_993 and Cu.position(s, 1, 2) == 90_000 and Cu.position(s, 1, 3) == 60_000 and Cu.position(s, 1, 4) == 7 and Cu.positionsTotal(s, 1) == 1_000_000, "the positions as the fold of the receipts");
Debug.print("count: receipts folded into positions = " # Nat.toText(Cu.counts(s).receipts));

// the reconciliation
refused(sub(#reconcile({ asset = 1; day = D0 + 3; ledgerBlock = 130; balances = [(1, 849_993), (9, 1)] })), "a balance for an unknown holder");
refused(sub(#reconcile({ asset = 1; day = D0 + 3; ledgerBlock = 130; balances = [(1, 849_993), (1, 849_993)] })), "a holder twice in the balances");
let r1 = govern(#reconcile({ asset = 1; day = D0 + 3; ledgerBlock = 130; balances = [(1, 849_993), (2, 90_000), (3, 60_000), (4, 7)] }), "reconcile 1");
check(r1 == [1, 0], "no break: " # debug_show(r1));
switch (Cu.reconciliation(s, 1)) { case (?r) check(r.matched == 4 and r.breaks == 0 and r.positionsTotal == 1_000_000 and r.issuedSupply == 1_000_000 and r.hash == K.reconciliationHash(K.reconciliationBytes(1, D0 + 3, 130, [(1, 849_993, 849_993), (2, 90_000, 90_000), (3, 60_000, 60_000), (4, 7, 7)])), "the reconciliation's figures and hash"); case null check(false, "reconciliation 1") };
let r2 = govern(#reconcile({ asset = 1; day = D0 + 4; ledgerBlock = 131; balances = [(1, 849_993), (2, 90_001), (3, 60_000)] }), "reconcile 2");
check(r2 == [2, 1], "one break: a ledger balance the register does not show");
Debug.print("count: reconciliations to the ledgers and the supply = 2");

// ─── PART 3: the corporate actions ─────────────────────────────────────────────────────────
let src = bytes(0xC1, 32);
refused(sub(#announceAction({ asset = 9; kind = #cashDividend({ perUnitMicro = 250 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = src })), "an action on an unknown asset");
refused(sub(#announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 0 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = src })), "a dividend of nothing");
refused(sub(#announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 250 }); recordDate = D0 + 10; exDate = D0 + 11; paymentDate = D0 + 20; source = src })), "an ex date after the record date");
refused(sub(#announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 250 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 9; source = src })), "a payment date before the record date");
refused(sub(#announceAction({ asset = 1; kind = #split({ numerator = 2; denominator = 2; cashInLieuMicro = 1 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = src })), "a split of one for one");
refused(sub(#announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 250 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = bytes(1, 31) })), "a 31-byte source");
// action 1: a cash dividend of 250 micro per unit
check(govern(#announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 250 }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = src }), "dividend") == [1], "action 1 announced");
refused(sub(#announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 1 }); recordDate = D0 + 30; exDate = D0 + 29; paymentDate = D0 + 40; source = src })), "a second action on the asset while one is open");
refused(sub(#pay({ action = 1; day = D0 + 20; limit = 2 })), "paying before the record date is struck");
refused(sub(#strikeRecordDate({ action = 1; limit = 0 })), "a slice of nothing");
refused(sub(#strikeRecordDate({ action = 9; limit = 2 })), "striking an unknown action");
check(single(#strikeRecordDate({ action = 1; limit = 2 }), "strike 1a") == [1, 2], "two holders struck");
switch (Cu.action(s, 1)) { case (?a) check(a.state == #announced and a.holderCursor == 3 and a.entitlements == 2, "half struck"); case null check(false, "action 1") };
check(single(#strikeRecordDate({ action = 1; limit = 2 }), "strike 1b") == [1, 2], "the other two struck");
let ?a1 = Cu.action(s, 1) else { check(false, "action 1"); assert false; loop {} };
check(a1.state == #struck and a1.entitlements == 4 and a1.cashTotal == 1_000_000 * 250 and a1.unitsTotal == 0, "action 1 struck over four positions: " # debug_show((a1.entitlements, a1.cashTotal)));
refused(sub(#strikeRecordDate({ action = 1; limit = 2 })), "striking twice");
refused(sub(#recordSettlement({ asset = 1; receipt = rcpt(10); from = 1; to = 2; units = 1; day = D0 + 12 })), "a settlement while a struck action awaits payment");
switch (Cu.entitlementOf(s, 1, 4)) { case (?(_, e)) check(e.unitsAtRecord == 7 and e.cashDue == 1_750 and e.unitsDue == 0, "holder 4's dividend: 7 units × 250"); case null check(false, "entitlement of 4") };
refused(sub(#pay({ action = 1; day = D0 + 19; limit = 2 })), "paying before the payment date");
refused(sub(#certifyEntitlementFile({ action = 1; day = D0 + 21 })), "certifying an unpaid action");
check(single(#pay({ action = 1; day = D0 + 20; limit = 3 }), "pay 1a") == [1, 3], "three entitlements paid");
switch (Cu.action(s, 1)) { case (?a) check(a.state == #struck and a.holderCursor == a.firstEntitlement + 3, "the pay cursor on the row"); case null check(false, "action 1") };
check(single(#pay({ action = 1; day = D0 + 20; limit = 3 }), "pay 1b") == [1, 1], "the last paid");
switch (Cu.action(s, 1)) { case (?a) check(a.state == #paid, "action 1 paid"); case null check(false, "action 1") };
refused(sub(#pay({ action = 1; day = D0 + 20; limit = 3 })), "paying a paid action");
refused(sub(#certifyEntitlementFile({ action = 1; day = D0 + 19 })), "certifying before the payment date");
check(govern(#certifyEntitlementFile({ action = 1; day = D0 + 21 }), "file 1") == [1], "file 1 certified");
switch (Cu.action(s, 1)) { case (?a) check(a.fileHash == ?K.fileHash(K.fileBytes(1, 1, a.kind, a.recordDate, a.paymentDate, Cu.fileLines(s, 1))), "the file sealed by its hash"); case null check(false, "action 1") };
refused(sub(#certifyEntitlementFile({ action = 1; day = D0 + 22 })), "certifying twice");
refused(sub(#cancelAction({ action = 1; day = D0 + 22; reason = "x" })), "cancelling a paid action");
check(Cu.position(s, 1, 4) == 7 and Cu.positionsTotal(s, 1) == 1_000_000, "a dividend moves no units");
Debug.print("count: cash dividends struck, paid and certified = 1");

// action 2: a split of three for two, cash in lieu 1,000 micro a unit: holder 4's 7 become 10 and half a unit in cash
check(govern(#announceAction({ asset = 1; kind = #split({ numerator = 3; denominator = 2; cashInLieuMicro = 1_000 }); recordDate = D0 + 30; exDate = D0 + 29; paymentDate = D0 + 31; source = bytes(0xC2, 32) }), "split") == [2], "action 2");
check(single(#strikeRecordDate({ action = 2; limit = 1_000 }), "strike 2") == [2, 4], "struck in one slice");
switch (Cu.entitlementOf(s, 2, 4)) { case (?(_, e)) check(e.unitsDue == 10 and e.fractionUnits == 1 and e.cashDue == 500, "holder 4: 7 × 3 / 2 = 10 and a half, 500 micro in lieu: " # debug_show(e)); case null check(false, "entitlement 2/4") };
switch (Cu.entitlementOf(s, 2, 1)) { case (?(_, e)) check(e.unitsDue == 1_274_989 and e.fractionUnits == 1 and e.cashDue == 500, "the issuer: 849,993 × 3 / 2 = 1,274,989 and a half"); case null check(false, "entitlement 2/1") };
check(single(#pay({ action = 2; day = D0 + 31; limit = 1_000 }), "pay 2") == [2, 4], "the split paid");
check(Cu.position(s, 1, 4) == 10 and Cu.position(s, 1, 2) == 135_000 and Cu.position(s, 1, 3) == 90_000 and Cu.position(s, 1, 1) == 1_274_989, "the positions after the split");
switch (Cu.asset(s, 1)) { case (?a) check(a.issuedSupply == 1_274_989 + 135_000 + 90_000 + 10 and a.issuedSupply == Cu.positionsTotal(s, 1), "the supply follows the split: " # Nat.toText(a.issuedSupply)); case null check(false, "asset 1") };
check(govern(#certifyEntitlementFile({ action = 2; day = D0 + 31 }), "file 2") == [2], "file 2 certified");
Debug.print("count: splits with cash in lieu of fractions = 1");

// action 3: rights of one for four at 5 micro, subscription by day 45, paid on day 50
refused(sub(#announceAction({ asset = 1; kind = #rights({ numerator = 1; denominator = 4; subscriptionPriceMicro = 5; subscriptionDeadline = D0 + 55 }); recordDate = D0 + 40; exDate = D0 + 39; paymentDate = D0 + 50; source = bytes(0xC3, 32) })), "a subscription deadline after the payment date");
refused(sub(#announceAction({ asset = 1; kind = #rights({ numerator = 1; denominator = 4; subscriptionPriceMicro = 0; subscriptionDeadline = D0 + 45 }); recordDate = D0 + 40; exDate = D0 + 39; paymentDate = D0 + 50; source = bytes(0xC3, 32) })), "rights without a price");
check(govern(#announceAction({ asset = 1; kind = #rights({ numerator = 1; denominator = 4; subscriptionPriceMicro = 5; subscriptionDeadline = D0 + 45 }); recordDate = D0 + 40; exDate = D0 + 39; paymentDate = D0 + 50; source = bytes(0xC3, 32) }), "rights") == [3], "action 3");
refused(sub(#subscribeRights({ action = 3; holder = 2; rights = 100; day = D0 + 41 })), "subscribing before the strike");
check(single(#strikeRecordDate({ action = 3; limit = 1_000 }), "strike 3") == [3, 4], "rights struck");
switch (Cu.entitlementOf(s, 3, 2)) { case (?(_, e)) check(e.rights == 33_750 and e.fractionUnits == 0, "holder 2: 135,000 / 4 = 33,750 rights"); case null check(false, "entitlement 3/2") };
switch (Cu.entitlementOf(s, 3, 4)) { case (?(_, e)) check(e.rights == 2 and e.fractionUnits == 2, "holder 4: 10 / 4 = 2 rights and a fraction"); case null check(false, "entitlement 3/4") };
refused(sub(#subscribeRights({ action = 1; holder = 2; rights = 1; day = D0 + 41 })), "subscribing on a dividend");
refused(sub(#subscribeRights({ action = 3; holder = 9; rights = 1; day = D0 + 41 })), "subscribing without an entitlement");
refused(sub(#subscribeRights({ action = 3; holder = 2; rights = 0; day = D0 + 41 })), "subscribing nothing");
refused(sub(#subscribeRights({ action = 3; holder = 2; rights = 33_751; day = D0 + 41 })), "subscribing above the rights");
check(single(#subscribeRights({ action = 3; holder = 2; rights = 20_000; day = D0 + 41 }), "subscribe 2a").size() == 2, "holder 2 takes 20,000");
refused(sub(#subscribeRights({ action = 3; holder = 2; rights = 13_751; day = D0 + 42 })), "the rest and one more refused");
check(single(#subscribeRights({ action = 3; holder = 2; rights = 13_750; day = D0 + 42 }), "subscribe 2b").size() == 2, "holder 2 takes the rest");
check(single(#subscribeRights({ action = 3; holder = 4; rights = 2; day = D0 + 45 }), "subscribe 4").size() == 2, "holder 4 takes both on the deadline");
refused(sub(#subscribeRights({ action = 3; holder = 3; rights = 1; day = D0 + 46 })), "subscribing after the deadline");
switch (Cu.entitlementOf(s, 3, 2)) { case (?(_, e)) check(e.rightsTaken == 33_750 and e.unitsDue == 33_750 and e.cashPayable == 168_750, "holder 2 pays 33,750 × 5"); case null check(false, "entitlement 3/2") };
check(single(#pay({ action = 3; day = D0 + 50; limit = 1_000 }), "pay 3") == [3, 4], "the rights paid");
check(Cu.position(s, 1, 2) == 168_750 and Cu.position(s, 1, 4) == 12 and Cu.position(s, 1, 3) == 90_000, "the subscribed units delivered, the rest lapsed");
switch (Cu.asset(s, 1)) { case (?a) check(a.issuedSupply == Cu.positionsTotal(s, 1), "the supply follows the rights taken"); case null check(false, "asset 1") };
check(govern(#certifyEntitlementFile({ action = 3; day = D0 + 50 }), "file 3") == [3], "file 3 certified");
Debug.print("count: rights issues subscribed within the entitlement = 1");

// action 4: a redemption of a quarter at 3 micro; action 5: a bonus of one for ten with 900 micro in lieu; a cancellation
refused(sub(#announceAction({ asset = 1; kind = #redemption({ ratioBps = 10_001; pricePerUnitMicro = 3 }); recordDate = D0 + 60; exDate = D0 + 59; paymentDate = D0 + 61; source = bytes(0xC4, 32) })), "a redemption above the whole");
check(govern(#announceAction({ asset = 1; kind = #redemption({ ratioBps = 2_500; pricePerUnitMicro = 3 }); recordDate = D0 + 60; exDate = D0 + 59; paymentDate = D0 + 61; source = bytes(0xC4, 32) }), "redemption") == [4], "action 4");
let before4 = Cu.positionsTotal(s, 1);
check(single(#strikeRecordDate({ action = 4; limit = 1_000 }), "strike 4") == [4, 4], "redemption struck");
switch (Cu.entitlementOf(s, 4, 4)) { case (?(_, e)) check(e.unitsDue == 3 and e.cashDue == 9 and e.fractionUnits == 0, "holder 4: 12 × 2500 / 10000 = 3 units at 3"); case null check(false, "entitlement 4/4") };
check(single(#pay({ action = 4; day = D0 + 61; limit = 1_000 }), "pay 4") == [4, 4], "the redemption paid");
check(Cu.position(s, 1, 4) == 9, "holder 4 keeps nine");
switch (Cu.asset(s, 1)) { case (?a) check(a.issuedSupply == Cu.positionsTotal(s, 1) and a.issuedSupply < before4, "the supply falls by the units redeemed"); case null check(false, "asset 1") };
check(govern(#certifyEntitlementFile({ action = 4; day = D0 + 61 }), "file 4") == [4], "file 4 certified");
check(govern(#announceAction({ asset = 1; kind = #bonus({ numerator = 1; denominator = 10; cashInLieuMicro = 900 }); recordDate = D0 + 70; exDate = D0 + 69; paymentDate = D0 + 71; source = bytes(0xC5, 32) }), "bonus") == [5], "action 5");
check(single(#strikeRecordDate({ action = 5; limit = 1_000 }), "strike 5") == [5, 4], "bonus struck");
switch (Cu.entitlementOf(s, 5, 4)) { case (?(_, e)) check(e.unitsDue == 0 and e.fractionUnits == 9 and e.cashDue == 810, "holder 4: 9 / 10 of a unit, 810 micro in lieu"); case null check(false, "entitlement 5/4") };
check(govern(#cancelAction({ action = 5; day = D0 + 70; reason = "withdrawn by the issuer before payment" }), "cancel 5") == [5], "action 5 cancelled after the strike");
switch (Cu.action(s, 5)) { case (?a) check(a.state == #cancelled, "cancelled"); case null check(false, "action 5") };
refused(sub(#pay({ action = 5; day = D0 + 71; limit = 1_000 })), "paying a cancelled action");
check(Cu.openActionOf(s, 1) == null, "no action open on the asset");
check(single(#recordSettlement({ asset = 1; receipt = rcpt(11); from = 1; to = 3; units = 1_000; day = D0 + 72 }), "settle after") == [5], "settlements resume");
check(refusals == 45, "forty-five refusals: " # Nat.toText(refusals));
Debug.print("count: illegal acts refused with the reason named, the state unchanged = " # Nat.toText(refusals));
Debug.print("count: governance commands executed through four eyes = " # Nat.toText(governed));
let c = Cu.counts(s);
check(c.holders == 4 and c.assets == 1 and c.positions == 4 and c.receipts == 5 and c.actions == 5 and c.entitlements == 20 and c.reconciliations == 2, "counts: " # debug_show(c));
Debug.print("count: corporate actions announced = " # Nat.toText(c.actions));

TR.fingerprint("custody", Cu.fingerprint(s));

// ─── PART 4: the replay ────────────────────────────────────────────────────────────────────
let fresh = Cu.newStateOver(s.log);
let rep = Cu.replay(fresh);
check(rep.faults.size() == 0 and rep.blocks == c.blocks and Cu.fingerprint(fresh) == Cu.fingerprint(s) and Cu.counts(fresh) == c, "replay without faults over " # Nat.toText(rep.blocks) # " blocks with the same fingerprint");
check(Cu.fingerprint(Cu.newState()) != Cu.fingerprint(s), "control: a different state fingerprints differently");
Debug.print("count: blocks replayed into a fresh state with the same fingerprint = " # Nat.toText(rep.blocks));

// ─── AU-10: the guard on one open action per asset holds after many actions closed ───────
// On a fresh register (not in the transcript or the twin's dump): twenty actions announced and cancelled on one asset,
// then one announced; a second is refused while it is open. The open action's index entry follows twenty stale ones,
// more than one page's scan budget.
let s10 = Cu.newState();
Cu.setPolicies(s10, [dual("custody.holder.register"), dual("custody.asset.register"), dual("custody.action.announce"), dual("custody.action.cancel")]);
func gov10(c : CT.Command) : [Nat] {
  switch (Cu.submit(s10, auth, tick(), registrar, c, null, "x")) {
    case (#ok(#proposed(p))) { switch (Cu.approve(s10, auth, tick(), director1, p.proposal)) { case (#ok(#executed(x))) x.effects; case (o) { check(false, "AU-10 approval: " # debug_show(o)); [] } } };
    case (o) { check(false, "AU-10 proposal: " # debug_show(o)); [] };
  }
};
ignore gov10(#registerHolder({ holder = 1; commit = bytes(0xE1, 32); account = shares }));
ignore gov10(#registerAsset({ code = "AUTEN"; name = "AU-10 regression"; ledger = shares; cashLedger = cash; issuedSupply = 1_000; issuer = 1 }));
func dividend(k : Nat) : CT.Command { #announceAction({ asset = 1; kind = #cashDividend({ perUnitMicro = 1 + k }); recordDate = D0 + 10; exDate = D0 + 9; paymentDate = D0 + 20; source = bytes(0xE0 + k, 32) }) };
for (k in Nat.range(1, 21)) {
  let fx = gov10(dividend(k));
  if (fx.size() == 1) ignore gov10(#cancelAction({ action = fx[0]; day = D0; reason = "withdrawn" })) else check(false, "AU-10 announce " # Nat.toText(k));
};
check(gov10(dividend(21)) == [21], "AU-10: the twenty-first action announced");
check(Cu.openActionOf(s10, 1) == ?21, "AU-10: the open action found behind twenty closed ones");
switch (Cu.submit(s10, auth, tick(), registrar, dividend(22), null, "x")) {
  case (#err(#custody(#ActionOpenOnAsset(_)))) Debug.print("count: AU-10 second actions refused while one is open behind twenty closed = 1");
  case (o) check(false, "AU-10: a second action while one is open: " # debug_show(o));
};

// ─── the dump for the twin ─────────────────────────────────────────────────────────────────
for (h in [1, 2, 3, 4].vals()) Debug.print("holder|" # Nat.toText(h) # "|" # Nat.toText(Cu.position(s, 1, h)));
switch (Cu.asset(s, 1)) { case (?a) Debug.print("asset|1|" # a.code # "|" # Nat.toText(a.issuedSupply) # "|1000000|" # Nat.toText(a.issuer)); case null {} };
for (rid in Nat.range(1, c.receipts + 1)) { let ?r = Cu.receiptById(s, rid) else { assert false; loop {} }; Debug.print("receipt|" # Nat.toText(rid) # "|" # CT.receiptKindText(r.kind) # "|" # Nat.toText(r.id) # "|" # Nat.toText(r.from) # "|" # Nat.toText(r.to) # "|" # Nat.toText(r.units) # "|" # Nat.toText(r.day)) };
for (aid in Nat.range(1, c.actions + 1)) {
  let ?a = Cu.action(s, aid) else { assert false; loop {} };
  let terms : Text = switch (a.kind) { case (#cashDividend(d)) Nat.toText(d.perUnitMicro); case (#split(x)) Nat.toText(x.numerator) # "," # Nat.toText(x.denominator) # "," # Nat.toText(x.cashInLieuMicro); case (#bonus(x)) Nat.toText(x.numerator) # "," # Nat.toText(x.denominator) # "," # Nat.toText(x.cashInLieuMicro); case (#rights(x)) Nat.toText(x.numerator) # "," # Nat.toText(x.denominator) # "," # Nat.toText(x.subscriptionPriceMicro) # "," # Nat.toText(x.subscriptionDeadline); case (#redemption(x)) Nat.toText(x.ratioBps) # "," # Nat.toText(x.pricePerUnitMicro) };
  Debug.print("action|" # Nat.toText(aid) # "|" # CT.kindText(a.kind) # "|" # terms # "|" # Nat.toText(a.recordDate) # "|" # Nat.toText(a.paymentDate) # "|" # CT.stateText(a.state) # "|" # Nat.toText(a.cashTotal) # "|" # Nat.toText(a.unitsTotal) # "|" # (switch (a.fileHash) { case (?h) C.hex(h); case null "" }));
  for (l in Cu.fileLines(s, aid).vals()) Debug.print("entitlement|" # Nat.toText(aid) # "|" # Nat.toText(l.holder) # "|" # Nat.toText(l.unitsAtRecord) # "|" # Nat.toText(l.cashDue) # "|" # Nat.toText(l.cashPayable) # "|" # Nat.toText(l.unitsDue) # "|" # Nat.toText(l.unitsTaken) # "|" # Nat.toText(l.rights) # "|" # Nat.toText(l.rightsTaken) # "|" # Nat.toText(l.fractionUnits));
};
for (rid in [1, 2].vals()) { let ?r = Cu.reconciliation(s, rid) else { assert false; loop {} }; Debug.print("reconciliation|" # Nat.toText(rid) # "|" # Nat.toText(r.day) # "|" # Nat.toText(r.ledgerBlock) # "|" # Nat.toText(r.holders) # "|" # Nat.toText(r.positionsTotal) # "|" # Nat.toText(r.issuedSupply) # "|" # Nat.toText(r.matched) # "|" # Nat.toText(r.breaks) # "|" # C.hex(r.hash)) };
Debug.print("reconciliationRows|1|1:849993:849993,2:90000:90000,3:60000:60000,4:7:7");
Debug.print("reconciliationRows|2|1:849993:849993,2:90000:90001,3:60000:60000");

if (failures == 0) Debug.print("CUSTODY TEST GREEN") else { Debug.print("FAILURES: " # Nat.toText(failures)); assert false };
