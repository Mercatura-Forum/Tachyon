// Surv.test.mo: the surveillance desk's battery (surveillance/SPEC.md). On one traced book, each pattern of SPEC §2
// planted in its own time and among its own owners, every alert's evidence computed by hand; cases under four eyes;
// the day's report sealed; every refusal. Then clean books (random streams) scanned, the alerts they raise counted as
// false positives. Every book's log, the desk's alerts and its reports are printed for the Python oracle
// (surveillance/integration/surveillance_replay.py, run by Surv.verify.sh), which applies the rules again to the logs.
//
// engine: Region (the row stores and the logs live in stable memory).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";
import DL "mo:kernel/domain/DomainLog";
import Perm "mo:kernel/auth/Permissions";
import Auth "mo:kernel/auth/AuthTypes";
import R "mo:kernel/rows/StableRows";
import X "../../exchange/src/ExchangeCore";
import B "../../book/src/BookCore";
import ST "../src/SurvTypes";
import S "../src/SurvCore";
import SK "../src/SurvCanonical";
import TR "../../custody/test/support/Transcript";
import SV "support/Traced";
import W "../../book/test/support/World";

let w = W.World(true);
let { check; n; tick; advance; act; deposit; lim; placed; settle; cancel; cash; sharesA; sharesB; t1; t3; scheduler; operator; depository; stranger; xs } = w;
let analyst = Principal.fromText("3qubo-5aaaa-aaaaa-aab3q-cai");   // the surveillance analyst: no other role of the battery
var scenarios = 0;
func scenario(ok : Bool, what : Text) { check(ok, what); if (ok) scenarios += 1 };

// ─── the desk's authority: the scheduler scans and seals, the analyst opens and notes, four eyes for the rest ────────
func hasGrant(p : Principal, perm : Text) : Bool {
  if (Principal.equal(p, scheduler)) return perm == "surv.scan" or perm == "surv.report.seal";
  if (Principal.equal(p, analyst)) return perm == "surv.case.open" or perm == "surv.case.note";
  if (Principal.equal(p, operator)) return perm == "surv.params" or perm == "surv.case.close" or perm == "surv.case.report";
  if (Principal.equal(p, w.director1)) return perm == "command.approve" or perm == "command.reject";
  false
};
func holdsRole(p : Principal, role : Text) : Bool { role == "director" and Principal.equal(p, w.director1) };
let auth : S.Authority = { hasGrant; holdsRole };
func duals() : [Auth.DualPolicy] {
  // the harness's policy (World.dual), as the venue and the chain judge install it
  Array.map<Auth.Permission, Auth.DualPolicy>(Array.filter<Auth.Permission>(S.catalogue(), func(p) { p.dualByDefault }), func(p) { w.dual(p.id) })
};

// ─── the catalogue and the encoding ────────────────────────────────────────────────────────────
let report = Perm.validate(S.catalogue(), S.commandNames, S.methodNames);
check(Perm.clean(report), "the desk's catalogue validates: " # debug_show(report.faults));
for ((id, reason) in S.singleActs().vals()) { switch (Perm.byId(S.catalogue(), id)) { case (?p) check(not p.dualByDefault and reason.size() > 40, "single act " # id # " has its reason"); case null check(false, "single act " # id # " exists") } };
let samples : [ST.Command] = [#scan({ limit = 500 }), #setParams(ST.DEFAULT_PARAMS), #openCase({ alert = 1 }), #noteCase({ caseId = 1; note = "the client was called" }),
  #closeCase({ caseId = 1; reason = "a hedge, documented" }), #reportCase({ caseId = 2; summary = "the pattern repeated on three days" }), #sealReport({ day = 20_514 })];
var roundTrips = 0;
for (c in samples.vals()) {
  switch (E.bytesAt(SK.registry, SK.registry.current, c)) {
    case (?b) { switch (E.readAt(SK.registry, SK.registry.current, C.Reader(Blob.toArray(b)))) { case (?back) { if (back == c) roundTrips += 1 else check(false, "round trip " # SK.familyOf(c)) }; case null check(false, "decodes " # SK.familyOf(c)) } };
    case null check(false, "encodes " # SK.familyOf(c));
  };
};
check(roundTrips == SK.families.size(), "every family encodes and decodes to itself");
check(E.readAt(SK.registry, SK.registry.current, C.Reader([99 : Nat8])) == null, "an unknown family byte decodes to nothing");

// ─── the planted book ──────────────────────────────────────────────────────────────────────────
let m = w.newRun(true);
for (a in Nat.range(1, 17)) { ignore tick(); deposit(m, a, cash, 500_000_000); deposit(m, a, sharesA, 5_000); deposit(m, a, sharesB, 500) };
ignore tick(); ignore act(m, scheduler, #setTrading({ instrument = 1; open = true })); ignore act(m, scheduler, #setTrading({ instrument = 2; open = true }));
let desk = S.newState(); S.setPolicies(desk, duals());
func sact(who : Principal, c : ST.Command) : S.Result<S.Outcome> { SV.ssub(desk, m.st, xs, auth, w.now, who, c, "") };
func sgovern(c : ST.Command) : S.Result<S.Outcome> {
  switch (sact(operator, c)) { case (#ok(#proposed(p))) SV.sapp(desk, m.st, xs, auth, w.now, w.director1, p.proposal); case (o) o }
};
func srefused(who : Principal, c : ST.Command, want : Text, what : Text) {
  let fp = S.fingerprint(desk);
  let got = SV.sOut(sact(who, c));
  check(got == want, what # ": wanted " # want # ", got " # got);
  check(S.fingerprint(desk) == fp, what # ": the desk unmoved");
};
func scanAll() { label s loop { switch (sact(scheduler, #scan({ limit = 500 }))) { case (#ok(#executed(_))) {}; case (_) break s } } };
func lastBlock() : Nat { DL.length(m.st.log) - 1 };

// the reportable position lowered to 50 under four eyes, the other thresholds as they are
ignore tick();
scenario(sgovern(#setParams({ ST.DEFAULT_PARAMS with positionLevel = 50 })) == #ok(#executed({ block = DL.length(desk.log) - 1; effects = [2] })), "the thresholds under four eyes");
srefused(analyst, #setParams(ST.DEFAULT_PARAMS), "e=NoGrant", "the analyst sets thresholds");
srefused(operator, #setParams({ ST.DEFAULT_PARAMS with paintCount = 1 }), "e=InvalidTerms", "a count of one");

// 1. a wash trade: account 2's investor opens an account at member 2 and trades with itself
w.xsingle(t3, #openAccount({ member = 2; kind = #client; client = w.clientOf(2) }), "the same investor at member 2");
Debug.print("H|account|18|1|2|" # TR.hex(w.clientOf(2)));
ignore tick(); deposit(m, 18, cash, 500_000_000); deposit(m, 18, sharesA, 5_000);
ignore tick();
let wb = placed(m, lim(2, 1, #buy, 10, 85_000, "w1")); let ws = placed(m, lim(18, 1, #sell, 10, 85_000, "w2"));
settle(m);
let washBlock = lastBlock();
// 2. painting the tape: the two members' house accounts trade three times within ten minutes
advance(700);
var paintFirst = 0;
for (k in Nat.range(0, 3)) {
  ignore tick();
  ignore placed(m, lim(1, 1, #buy, 10, 85_000, "p" # n(k) # "b")); ignore placed(m, lim(9, 1, #sell, 10, 85_000, "p" # n(k) # "s"));
  settle(m);
  if (k == 0) paintFirst := lastBlock();
};
let paintBlock = lastBlock();
// 3. quote stuffing: trader 3 places and cancels twenty-five orders within one second
advance(700); ignore tick();
let stuffFirst = DL.length(m.st.log);
for (k in Nat.range(0, 25)) { let o = placed(m, lim(10, 1, #buy, 10, 80_000 - 10 * k, "q" # n(k))); cancel(m, o) };
let stuffBlock = lastBlock();
// 4. spoofing: account 3 rests two sells of 50, buys 10, then cancels both sells unfilled within a minute
advance(700); ignore tick();
let sp1 = placed(m, lim(3, 1, #sell, 50, 86_000, "s1")); let sp2 = placed(m, lim(3, 1, #sell, 50, 86_100, "s2"));
ignore tick();
ignore placed(m, lim(3, 1, #buy, 10, 85_000, "s3")); ignore placed(m, lim(11, 1, #sell, 10, 85_000, "s4"));
settle(m);
ignore tick(); cancel(m, sp1); cancel(m, sp2);
let spoofBlock = lastBlock();
// 5. marking the close: in the closing auction account 4 buys all 80, at 87.000 against a last continuous price of 85.000
advance(700); ignore tick();
ignore act(m, scheduler, #setPhase({ instrument = 1; phase = #closingAuction; endFrom = 0; endTo = 0 }));
ignore placed(m, lim(4, 1, #buy, 80, 87_000, "m1")); ignore placed(m, lim(12, 1, #sell, 40, 86_900, "m2")); ignore placed(m, lim(13, 1, #sell, 40, 87_000, "m3"));
ignore tick();
ignore act(m, scheduler, #uncross({ instrument = 1; next = #tradeAtClose }));
let markBlock = lastBlock();

// the desk reads the book
ignore tick();
scanAll();
srefused(scheduler, #scan({ limit = 10 }), "e=NothingToScan", "a scan with nothing to read");
srefused(scheduler, #scan({ limit = 501 }), "e=InvalidTerms", "a scan beyond 500 blocks");
srefused(stranger, #scan({ limit = 10 }), "e=NoGrant", "a stranger scans");
func house(member : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>([1], Blob.toArray(R.key(member, 8)))) };
func traderId(t : Nat) : Blob { Blob.fromArray(Array.concat<Nat8>([2], Blob.toArray(R.key(t, 8)))) };
let want : [ST.Alert] = [
  { rule = 1; block = washBlock; instrument = 1; owner = w.clientOf(2); other = ""; e1 = wb; e2 = ws; e3 = 10; e4 = 85_000; caseId = 0 },
  { rule = 2; block = paintBlock; instrument = 1; owner = house(1); other = house(2); e1 = paintFirst; e2 = 3; e3 = 0; e4 = 0; caseId = 0 },
  { rule = 3; block = stuffBlock; instrument = 0; owner = traderId(3); other = ""; e1 = stuffFirst; e2 = 50; e3 = 0; e4 = 0; caseId = 0 },
  { rule = 4; block = spoofBlock; instrument = 1; owner = w.clientOf(3); other = ""; e1 = 2; e2 = 100; e3 = 10; e4 = 0; caseId = 0 },
  { rule = 5; block = markBlock; instrument = 1; owner = w.clientOf(4); other = ""; e1 = 87_000; e2 = 85_000; e3 = 80; e4 = 80; caseId = 0 },
];
scenario(S.counts(desk).alerts == 5, "five alerts, one for each pattern planted: " # n(S.counts(desk).alerts));
for (k in Nat.range(0, 5)) { scenario(S.alert(desk, k + 1) == ?want[k], "alert " # n(k + 1) # " (rule " # n(k + 1) # ") as computed by hand: " # debug_show(S.alert(desk, k + 1))) };

// cases
scenario(sact(analyst, #openCase({ alert = 1 })) == #ok(#executed({ block = DL.length(desk.log) - 1; effects = [3, 1] })), "a case for the wash trade");
srefused(analyst, #openCase({ alert = 1 }), "e=InvalidTerms", "an alert opened twice");
srefused(analyst, #openCase({ alert = 99 }), "e=UnknownAlert", "a case for no alert");
scenario(sact(analyst, #noteCase({ caseId = 1; note = "the investor's two brokers were asked" })) == #ok(#executed({ block = DL.length(desk.log) - 1; effects = [4, 1, 1] })), "a note");
srefused(analyst, #noteCase({ caseId = 9; note = "x" }), "e=UnknownCase", "a note on no case");
srefused(analyst, #noteCase({ caseId = 1; note = "" }), "e=InvalidTerms", "an empty note");
srefused(analyst, #closeCase({ caseId = 1; reason = "on my own" }), "e=NoGrant", "the analyst closes a case alone");
scenario(sgovern(#closeCase({ caseId = 1; reason = "a transfer between the investor's brokers, documented" })) == #ok(#executed({ block = DL.length(desk.log) - 1; effects = [5, 1] })), "closed under four eyes");
srefused(analyst, #noteCase({ caseId = 1; note = "late" }), "e=CaseClosed", "a note on a closed case");
ignore sact(analyst, #openCase({ alert = 4 }));
scenario(sgovern(#reportCase({ caseId = 2; summary = "orders placed to be cancelled, the other side traded" })) == #ok(#executed({ block = DL.length(desk.log) - 1; effects = [6, 2] })), "a suspicious transaction report filed under four eyes");
scenario((switch (S.alert(desk, 1), S.caseOf(desk, 2)) { case (?a, ?k) a.caseId == 1 and k.status == 3; case (_) false }), "the alert in its case, the case reported");

// the day's report: seven trade lines and one reportable position (account 4's 80)
ignore tick();
let day = w.today();
srefused(scheduler, #sealReport({ day = day + 1 }), "e=InvalidTerms", "a day other than the market day");
let seal = switch (sact(scheduler, #sealReport({ day }))) { case (#ok(#executed(x))) x.effects; case (_) [] };
scenario(seal.size() == 35 and seal[0] == 7 and seal[1] == day and seal[2] == 8, "the day sealed: eight lines, the chain's hash");
srefused(scheduler, #sealReport({ day }), "e=InvalidTerms", "a day sealed twice");
scenario(S.counts(desk).lines == 0 and (switch (S.report(desk, day)) { case (?r) r.lines == 8; case null false }), "the next day's chain begun");

// the desk refolded from its log over the book's log
let again = S.newStateOver(desk.log); S.setPolicies(again, duals());
let rp = S.replay(again, m.st, xs);
scenario(rp.faults.size() == 0 and S.fingerprint(again) == S.fingerprint(desk), "the desk's log replayed to the same fingerprint");

// for the oracle and the chain judge: the planted book's log, the desk's alerts and report
func printDesk(tag : Text, st : B.State, d : S.State) {
  Debug.print("SV|" # tag);
  let p = d.params;
  Debug.print("SP|" # n(p.paintCount) # "|" # n(p.paintSecs) # "|" # n(p.stuffCount) # "|" # n(p.stuffSecs) # "|" # n(p.spoofQty) # "|" # n(p.spoofSecs) # "|" # n(p.markShare) # "|" # n(p.markBps) # "|" # n(p.positionLevel));
  for (i in Nat.range(0, DL.length(st.log))) { switch (DL.rawBlock(st.log, i)) { case (?raw) w.line("L|" # n(i) # "|" # TR.hex(raw)); case null check(false, "a block reads") } };
  var k = 1;
  while (k <= S.counts(d).alerts) {
    switch (S.alert(d, k)) { case (?a) Debug.print("SA|" # n(k) # "|" # n(a.rule) # "|" # n(a.block) # "|" # n(a.instrument) # "|" # TR.hex(a.owner) # "|" # TR.hex(a.other) # "|" # n(a.e1) # "|" # n(a.e2) # "|" # n(a.e3) # "|" # n(a.e4)); case null {} };
    k += 1;
  };
  Debug.print("SC|" # n(d.cursor) # "|" # n(S.counts(d).lines) # "|" # TR.hex(d.head));
};
printDesk("planted", m.st, desk);
switch (S.report(desk, day)) { case (?r) Debug.print("SR|" # n(day) # "|" # n(r.lines) # "|" # TR.hex(r.hash)); case null {} };
TR.fingerprint("book", B.fingerprint(m.st));
TR.fingerprint("surveillance", S.fingerprint(desk));
TR.fingerprint("exchange", X.fingerprint(xs));

// ─── clean books: random streams, scanned; what they raise is counted ───────────────────────────
var cleanAlerts = [var 0, 0, 0, 0, 0, 0];
var cleanCommands = 0;
for (k in Nat.range(0, 3)) {
  w.seed := w.seed ^ Nat64.fromNat(0x5E_0000 + k);
  let r = w.newRun(false);
  for (a in Nat.range(1, 18)) { ignore tick(); deposit(r, a, cash, 300_000_000); deposit(r, a, sharesA, 3_000); deposit(r, a, sharesB, 300) };
  ignore tick(); ignore act(r, scheduler, #setTrading({ instrument = 1; open = true })); ignore act(r, scheduler, #setTrading({ instrument = 2; open = true }));
  w.randomStream(r, 1_500, 250, true); cleanCommands += 1_500;
  let d = S.newState(); S.setPolicies(d, duals());
  label s loop { switch (S.submit(d, r.st, xs, auth, w.now, scheduler, #scan({ limit = 500 }), null, "")) { case (#ok(#executed(_))) {}; case (_) break s } };
  var a = 1; while (a <= S.counts(d).alerts) { switch (S.alert(d, a)) { case (?x) cleanAlerts[x.rule] += 1; case null {} }; a += 1 };
  printDesk("clean " # n(k), r.st, d);
};
for (rule in Nat.range(1, 6)) Debug.print("false positives: rule " # n(rule) # " on " # n(cleanCommands) # " clean random commands: " # n(cleanAlerts[rule]));
Debug.print("count: random commands in the clean books = " # n(cleanCommands));
Debug.print("count: scenarios whose every alert matched the hand computation = " # n(scenarios));
if (w.failures > 0) { Debug.print("SURVEILLANCE FAILED: " # n(w.failures)); assert false } else Debug.print("SURVEILLANCE GREEN");
