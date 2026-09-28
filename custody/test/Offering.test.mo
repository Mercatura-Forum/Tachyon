// Offering.test.mo: an initial public offering on the venue: the underwriting, the book of bids, the allocation and
// the hand-off to the listing and the custody register; the figures dumped for the Python twin
// (`custody/integration/offering_twin.py`, run by `custody/test/Offering.verify.sh`).
//
// What is proved:
//   * the catalogue in both directions with a control; the single acts' reasons; every command round-tripped; the row
//     widths; the arithmetic's own vectors (the fee half up, cumulative rounding, the tranches);
//   * a book-built offering: three cornerstones before the book (the cap and the calendar refused), 140 institutional
//     bids on a 21-rung ladder with revisions (a withdrawal and a new bid), 900 retail applications paid in full at
//     the top of the range (twice, short-paid, late and above the tranche refused); priced below the book's clearing
//     price (above it refused); the retail tranche oversubscribed and the institutional tranche covered; the
//     allocation swept in slices of 97 orders, each tranche's lots exactly, each order within a lot of its exact
//     share; the hand-off behind the listing gate, the underwriter's fee half up;
//   * a best-efforts offering that sells less than its minimum and fails at pricing, the retail refunded in full;
//   * a firm-commitment offering undersubscribed: the retail tranche takes the institutional tranche's unfilled lots
//     and the underwriter takes up the rest, listed with it;
//   * an offering that fails the listing gate's holder count at the hand-off and is withdrawn, every allocation void;
//   * the hand-off delivered to the custody register as issuance receipts, one per allocation and the underwriter's,
//     reconciled to the issued supply; every refusal named with the fingerprint unmoved; the replay.
//
// engine: Region (the row stores and the log live in stable memory).

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";
import List "mo:core/List";
import Text "mo:core/Text";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";

import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";
import Perm "mo:kernel/auth/Permissions";
import CivilDate "mo:kernel/num/CivilDate";
import Sha256 "mo:sha2/Sha256";

import OT "../src/OfferingTypes";
import M "../src/OfferingMath";
import K "../src/OfferingCanonical";
import Of "../src/OfferingCore";
import CT "../src/CustodyTypes";
import Cu "../src/CustodyCore";

var failures = 0;
func check(cond : Bool, what : Text) { if (not cond) { failures += 1; Debug.print("FAIL: " # what) } };
func day(y : Nat, m : Nat, d : Nat) : Nat { switch (CivilDate.fromCivil(y, m, d)) { case (?x) x; case null { assert false; 0 } } };
func t(n : Nat) : Text { Nat.toText(n) };
func h32(s : Text) : Blob { Sha256.fromBlob(#sha256, Text.encodeUtf8(s)) };
func hex(b : Blob) : Text { let d = "0123456789abcdef"; var o = ""; for (x in b.vals()) { let n = Nat8.toNat(x); o := o # Text.fromChar(Text.toArray(d)[n / 16]) # Text.fromChar(Text.toArray(d)[n % 16]) }; o };
func csv(xs : [Nat]) : Text { var o = ""; for (x in xs.vals()) o := o # (if (o == "") "" else ",") # t(x); o };

let officer = Principal.fromText("2vxsx-fae");
let director1 = Principal.fromText("aaaaa-aa");
func hasGrant(p : Principal, perm : Text) : Bool {
  if (Principal.equal(p, officer)) return Text.startsWith(perm, #text "offering.") or Text.startsWith(perm, #text "custody.");
  if (Principal.equal(p, director1)) return perm == "command.approve" or perm == "command.reject";
  false
};
func holdsRole(p : Principal, role : Text) : Bool { role == "director" and Principal.equal(p, director1) };
let auth : Of.Authority = { hasGrant; holdsRole };
func dual(permission : Text) : { permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat } { { permission; required = 1; eligibleRole = "director"; ttlSeconds = 3_600 } };
let policies = Array.map<Text, { permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat }>(["offering.open", "offering.cornerstone.commit", "offering.price", "offering.handoff", "offering.withdraw"], dual);
var now : Nat64 = 1_760_100_000_000_000_000;
func tick() : Nat64 { now += 1_000_000_000; now };

// ─── PART 1: the catalogue, the encoding, the arithmetic ───────────────────────────────────
let cat = Of.catalogue();
let report = Perm.validate(cat, Of.commandNames, Of.methodNames);
check(Perm.clean(report), "catalogue validates: " # debug_show(report.faults));
check(not Perm.clean(Perm.validate(Array.filter(cat, func(p : { id : Text }) : Bool { p.id != "offering.price" }), Of.commandNames, Of.methodNames)), "control: a catalogue missing priceOffering fails validation");
for ((id, reason) in Of.singleActs().vals()) { switch (Perm.byId(cat, id)) { case (?p) check(not p.dualByDefault and reason.size() > 40, "single act " # id # " has its reason"); case null check(false, "single act " # id # " exists") } };
for (p in cat.vals()) { if (not p.dualByDefault and Text.startsWith(p.id, #text "offering.")) check(Array.find<(Text, Text)>(Of.singleActs(), func(x) { x.0 == p.id }) != null, "single permission " # p.id # " has its reason recorded") };
check(Of.checkSums(), "row widths hold their fields");
check(M.checkArithmetic(), "the arithmetic's own vectors");
Debug.print("count: catalogue rows validated in both directions = " # t(report.checked));

let D0 = day(2026, 10, 11);
let base : OT.Terms = {
  code = "NVLG"; name = "Nile Valley Logistics ordinary shares"; issuer = h32("issuer: Nile Valley Logistics"); underwriter = h32("underwriter: Delta Capital");
  sharesOffered = 60_000_000; sharesOutstanding = 200_000_000; priceLow = 850; priceHigh = 950; tick = 5; lot = 100;
  retailBps = 1_000; cornerstoneMaxBps = 3_000; underwritingBps = 200; firmCommitment = true; minSoldBps = 0; minFloatBps = 1_500; minHolders = 300;
  bookOpen = D0 + 7; bookClose = D0 + 14; retailClose = D0 + 16; listingDay = D0 + 21;
};
let samples : [OT.Command] = [
  #openOffering({ terms = base; day = D0 }),
  #commitCornerstone({ offering = 1; investor = h32("sovereign fund"); lots = 50_000; day = D0 + 1 }),
  #placeBid({ offering = 1; investor = h32("inst 0"); price = 925; lots = 4_000; day = D0 + 7 }),
  #withdrawBid({ order = 4; day = D0 + 8 }),
  #subscribeRetail({ offering = 1; investor = h32("retail 0"); lots = 20; paid = 20 * 100 * 950; day = D0 + 9 }),
  #priceOffering({ offering = 1; price = 920; day = D0 + 17 }),
  #allocate({ offering = 1; limit = 97 }),
  #handOff({ offering = 1; day = D0 + 21 }),
  #withdrawOffering({ offering = 1; reason = "the listing gate"; day = D0 + 22 }),
];
var roundTrips = 0;
for (c in samples.vals()) {
  let ?bs = E.bytesAt(K.registry, 1 : Nat8, c) else { check(false, "encodes " # K.familyOf(c)); continue };
  let ?back = E.readAt(K.registry, 1 : Nat8, C.Reader(Blob.toArray(bs))) else { check(false, "decodes " # K.familyOf(c)); continue };
  check(back == c, "round trip " # K.familyOf(c)); roundTrips += 1;
};
check(OT.offerLots(base) == 600_000 and OT.retailLots(base) == 60_000 and OT.institutionalLots(base) == 540_000 and OT.levels(base) == 21, "the tranches and the ladder by hand");
Debug.print("count: commands round-tripped through encoding v1 = " # t(roundTrips));

// ─── PART 2: the acts and the refusals ──────────────────────────────────────────────────
let st = Of.newState();
Of.setPolicies(st, policies);
var acts = 0; var refusals = 0;
let NAMES = ["InvalidText", "InvalidTerms", "DuplicateCode", "UnknownOffering", "UnknownOrder", "DayBackwards", "NotInState", "CornerstoneLate", "CornerstoneCap", "BookClosed", "PriceOffRange", "InvalidLots",
  "DuplicateInvestor", "PaymentMismatch", "NotABid", "BookStillOpen", "PriceAboveBook", "InvalidLimit", "BeforeListing", "ListingGate"];
func nameOf(e : Text) : Text { for (n in NAMES.vals()) { if (Text.contains(e, #text ("#" # n))) return n }; e };
func attempt(c : OT.Command, what : Text) : { #ok : [Nat]; #err : Text } {
  let run = func(o : Of.Result<Of.Outcome>) : { #ok : [Nat]; #err : Text } {
    switch (o) { case (#ok(#executed(x))) { acts += 1; #ok(x.effects) }; case (other) #err(nameOf(debug_show(other))) }
  };
  switch (Of.submit(st, auth, tick(), officer, c, null, what)) {
    case (#ok(#proposed(p))) run(Of.approve(st, auth, tick(), director1, p.proposal));
    case (other) run(other);
  }
};
func act(c : OT.Command, what : Text) : [Nat] { switch (attempt(c, what)) { case (#ok(r)) r; case (#err(e)) { check(false, what # ": " # e); [] } } };
func refused(c : OT.Command, name : Text, what : Text) {
  let before = Of.fingerprint(st);
  let got = switch (Of.submit(st, auth, tick(), officer, c, null, what)) {
    case (#ok(#proposed(p))) debug_show(Of.approve(st, auth, tick(), director1, p.proposal));
    case (other) { check(Of.fingerprint(st) == before, "refused and unchanged: " # what); debug_show(other) };
  };
  if (nameOf(got) == name) { refusals += 1; Debug.print("refusal|" # what # "|" # name) } else check(false, "refused for " # name # " not " # got # ": " # what);
};
func dumpTerms(id : Nat, x : OT.Terms) {
  Debug.print("offer|" # t(id) # "|" # x.code # "|" # csv([x.sharesOffered, x.sharesOutstanding, x.priceLow, x.priceHigh, x.tick, x.lot, x.retailBps, x.cornerstoneMaxBps, x.underwritingBps, if (x.firmCommitment) 1 else 0, x.minSoldBps, x.minFloatBps, x.minHolders]) # "|" # hex(x.underwriter));
};

// ─── PART 3: the terms ──────────────────────────────────────────────────────────────────
refused(#openOffering({ terms = { base with priceHigh = 952 }; day = D0 }), "InvalidTerms", "a range off its tick");
refused(#openOffering({ terms = { base with retailBps = 10_001 }; day = D0 }), "InvalidTerms", "a retail tranche above the whole offer");
refused(#openOffering({ terms = { base with sharesOffered = 60_000_050 }; day = D0 }), "InvalidTerms", "an offer of part of a lot");
refused(#openOffering({ terms = { base with underwritingBps = 1_200 }; day = D0 }), "InvalidTerms", "an underwriting fee of 12%");
refused(#openOffering({ terms = { base with listingDay = D0 + 15 }; day = D0 }), "InvalidTerms", "a listing before the retail close");
refused(#openOffering({ terms = { base with tick = 1; priceHigh = 1_300 }; day = D0 }), "InvalidTerms", "a ladder of 451 rungs");
let O1 = act(#openOffering({ terms = base; day = D0 }), "the flagship offering")[0];
dumpTerms(O1, base);
refused(#openOffering({ terms = base; day = D0 }), "DuplicateCode", "the same code twice");
let t2 : OT.Terms = { base with code = "SNAI"; name = "Sinai Agritech ordinary shares"; issuer = h32("issuer: Sinai Agritech"); sharesOffered = 1_000_000; sharesOutstanding = 4_000_000; priceLow = 1_000; priceHigh = 1_200; tick = 10;
  retailBps = 2_000; firmCommitment = false; minSoldBps = 8_000; minFloatBps = 1_000; minHolders = 20 };
let O2 = act(#openOffering({ terms = t2; day = D0 }), "a best-efforts offering")[0];
dumpTerms(O2, t2);
let t3 : OT.Terms = { base with code = "DLTA"; name = "Delta Fresh Foods ordinary shares"; issuer = h32("issuer: Delta Fresh Foods"); sharesOffered = 2_000_000; sharesOutstanding = 8_000_000; priceLow = 500; priceHigh = 560; tick = 5;
  minFloatBps = 500; minHolders = 30 };
let O3 = act(#openOffering({ terms = t3; day = D0 }), "a firm commitment, undersubscribed")[0];
dumpTerms(O3, t3);
let t4 : OT.Terms = { base with code = "KMTR"; name = "Kom Ombo Textiles ordinary shares"; issuer = h32("issuer: Kom Ombo Textiles"); sharesOffered = 500_000; sharesOutstanding = 2_000_000; priceLow = 300; priceHigh = 320; tick = 5;
  minFloatBps = 500; minHolders = 50 };
let O4 = act(#openOffering({ terms = t4; day = D0 }), "an offering short of holders")[0];
dumpTerms(O4, t4);

// ─── PART 4: the cornerstones ───────────────────────────────────────────────────────────
ignore act(#commitCornerstone({ offering = O1; investor = h32("sovereign fund"); lots = 60_000; day = D0 + 1 }), "a sovereign fund");
ignore act(#commitCornerstone({ offering = O1; investor = h32("pension fund"); lots = 50_000; day = D0 + 2 }), "a pension fund");
refused(#commitCornerstone({ offering = O1; investor = h32("sovereign fund"); lots = 1_000; day = D0 + 2 }), "DuplicateInvestor", "a cornerstone twice");
refused(#commitCornerstone({ offering = O1; investor = h32("gulf fund"); lots = 60_000; day = D0 + 3 }), "CornerstoneCap", "cornerstones above 30% of the institutional tranche");
ignore act(#commitCornerstone({ offering = O1; investor = h32("gulf fund"); lots = 40_000; day = D0 + 3 }), "a gulf fund");
refused(#commitCornerstone({ offering = O1; investor = h32("late fund"); lots = 1_000; day = D0 + 7 }), "CornerstoneLate", "a cornerstone once the book is open");

// ─── PART 5: the book and the retail tranche ────────────────────────────────────────────
var seed = 20_261_011;
func rnd(n : Nat) : Nat { seed := (seed * 1_103_515_245 + 12_345) % 2_147_483_648; (seed / 65_536) % n };
refused(#placeBid({ offering = O1; investor = h32("inst early"); price = 900; lots = 1_000; day = D0 + 6 }), "BookClosed", "a bid before the book opens");
func bid(off : Nat, who : Text, price : Nat, lots : Nat, d : Nat) : Nat { let r = act(#placeBid({ offering = off; investor = h32(who); price; lots; day = d }), "a bid"); if (r.size() > 0) r[0] else 0 };
func retail(off : Nat, x : OT.Terms, who : Text, lots : Nat, d : Nat) { ignore act(#subscribeRetail({ offering = off; investor = h32(who); lots; paid = lots * x.lot * x.priceHigh; day = d }), "a retail application") };
let revisable = List.empty<(Nat, Text, Nat)>();
var dd = D0 + 7;
while (dd <= D0 + 16) {
  if (dd <= D0 + 14) {
    var k = 0;
    while (k < 20) {
      let n = (dd - (D0 + 7) : Nat) * 20 + k;
      let lvl = if (rnd(3) == 0) rnd(21) else 10 + rnd(11);
      let price = base.priceLow + lvl * base.tick;
      let id = bid(O1, "inst " # t(n), price, 2_000 + rnd(19) * 1_000, dd);
      if (n % 14 == 0) List.add(revisable, (id, "inst " # t(n), price));
      k += 1;
    };
    // a bid for O3 and O4 each day, and for O2
    ignore bid(O3, "dlta inst " # t(dd), t3.priceLow + rnd(13) * t3.tick, 1_000 + rnd(5) * 200, dd);
    ignore bid(O2, "snai inst " # t(dd), t2.priceLow + rnd(21) * t2.tick, 300 + rnd(3) * 50, dd);
    if (dd < D0 + 12) ignore bid(O4, "kmtr inst " # t(dd), t4.priceLow + rnd(5) * t4.tick, 400 + rnd(4) * 50, dd);
  };
  // the revisions: a withdrawal and a new bid at a higher price, on the book's fifth day
  if (dd == D0 + 11) {
    for ((id, who, price) in List.values(revisable)) {
      ignore act(#withdrawBid({ order = id; day = dd }), "a bid withdrawn to be revised");
      ignore bid(O1, who, Nat.min(price + 2 * base.tick, base.priceHigh), 4_000, dd);
    };
  };
  var r = 0;
  while (r < 90) { let n = (dd - (D0 + 7) : Nat) * 90 + r; retail(O1, base, "retail " # t(n), 1 + rnd(300), dd); r += 1 };
  if (dd <= D0 + 10) { retail(O2, t2, "snai retail " # t(dd), 100 + rnd(300), dd); retail(O4, t4, "kmtr retail " # t(dd), 10 + rnd(20), dd) };
  var q = 0;
  while (q < 4) { retail(O3, t3, "dlta retail " # t(dd) # "-" # t(q), 50 + rnd(60), dd); q += 1 };
  if (dd == D0 + 9) {
    refused(#placeBid({ offering = O1; investor = h32("inst 3"); price = 900; lots = 1_000; day = dd }), "DuplicateInvestor", "a second live bid from one investor");
    refused(#placeBid({ offering = O1; investor = h32("inst odd"); price = 902; lots = 1_000; day = dd }), "PriceOffRange", "a bid off the tick");
    refused(#placeBid({ offering = O1; investor = h32("inst high"); price = 955; lots = 1_000; day = dd }), "PriceOffRange", "a bid above the range");
    refused(#placeBid({ offering = O1; investor = h32("inst none"); price = 900; lots = 0; day = dd }), "InvalidLots", "a bid of nothing");
    refused(#subscribeRetail({ offering = O1; investor = h32("retail 3"); lots = 5; paid = 5 * 100 * 950; day = dd }), "DuplicateInvestor", "a second retail application");
    refused(#subscribeRetail({ offering = O1; investor = h32("retail short"); lots = 5; paid = 5 * 100 * 950 - 1; day = dd }), "PaymentMismatch", "a retail application a piastre short");
    refused(#subscribeRetail({ offering = O1; investor = h32("retail whale"); lots = 60_001; paid = 60_001 * 100 * 950; day = dd }), "InvalidLots", "a retail application above the tranche");
    refused(#withdrawBid({ order = 7_777_777; day = dd }), "UnknownOrder", "an unknown order");
    refused(#priceOffering({ offering = O1; price = 900; day = dd }), "BookStillOpen", "a price while the book is open");
  };
  if (dd == D0 + 15) refused(#placeBid({ offering = O1; investor = h32("inst late"); price = 900; lots = 1_000; day = dd }), "BookClosed", "a bid after the book closed");
  dd += 1;
};
let firstRetail = switch (Of.liveOrderOf(st, O1, h32("retail 0"))) { case (?(id, _)) id; case null 0 };
refused(#withdrawBid({ order = firstRetail; day = D0 + 16 }), "NotABid", "a retail application withdrawn as a bid");
refused(#subscribeRetail({ offering = O1; investor = h32("retail late"); lots = 5; paid = 5 * 100 * 950; day = D0 + 17 }), "BookClosed", "a retail application after the retail close");

// ─── PART 6: the pricing ────────────────────────────────────────────────────────────────
func dumpLadder(off : Nat) { var o = ""; for ((p, l) in Of.ladder(st, off).vals()) o := o # (if (o == "") "" else ";") # t(p) # ":" # t(l); Debug.print("ladder|" # t(off) # "|" # o) };
for (off in [O1, O2, O3, O4].vals()) dumpLadder(off);
let clearing1 = switch (Of.clearingPrice(st, O1)) { case (?p) p; case null 0 };
check(clearing1 > 850 and clearing1 < 950, "the flagship's book clears inside the range: " # t(clearing1));
refused(#priceOffering({ offering = O1; price = clearing1 + base.tick; day = D0 + 17 }), "PriceAboveBook", "a price above the book's clearing price");
refused(#priceOffering({ offering = O1; price = 917; day = D0 + 17 }), "PriceOffRange", "a price off the tick");
refused(#allocate({ offering = O1; limit = 97 }), "NotInState", "an allocation before the price");
let price1 = clearing1 - base.tick;
let p1 = act(#priceOffering({ offering = O1; price = price1; day = D0 + 17 }), "priced a tick below the clearing price");
Debug.print("priced|" # t(O1) # "|" # csv(p1));
check(p1.size() == 9 and p1[4] == 540_000 and p1[5] == 60_000 and p1[6] == 0 and p1[8] == 0, "the flagship: both tranches filled, nothing for the underwriter: " # debug_show(p1));
let p2 = act(#priceOffering({ offering = O2; price = t2.priceLow; day = D0 + 17 }), "the best-efforts offering priced");
Debug.print("priced|" # t(O2) # "|" # csv(p2));
check(p2.size() == 9 and p2[8] == 1, "the best-efforts offering sold less than its minimum and failed: " # debug_show(p2));
let clearing3 = switch (Of.clearingPrice(st, O3)) { case (?p) p; case null 0 };
check(clearing3 == 0, "the undersubscribed book covers at no price");
refused(#priceOffering({ offering = O3; price = t3.priceLow + t3.tick; day = D0 + 17 }), "PriceAboveBook", "an uncovered book priced above the low end");
let p3 = act(#priceOffering({ offering = O3; price = t3.priceLow; day = D0 + 17 }), "the undersubscribed offering at the low end");
Debug.print("priced|" # t(O3) # "|" # csv(p3));
check(p3.size() == 9 and p3[6] > 0 and p3[5] > OT.retailLots(t3), "the retail tranche took unfilled institutional lots and the underwriter the rest: " # debug_show(p3));
let p4 = act(#priceOffering({ offering = O4; price = t4.priceLow; day = D0 + 17 }), "the small offering priced");
Debug.print("priced|" # t(O4) # "|" # csv(p4));
refused(#allocate({ offering = O2; limit = 97 }), "NotInState", "an allocation of a failed offering");
refused(#allocate({ offering = O1; limit = 0 }), "InvalidLimit", "an allocation slice of nothing");

// ─── PART 7: the allocation, in slices ──────────────────────────────────────────────────
var slices = 0;
for (off in [O1, O3, O4].vals()) {
  var done = false;
  while (not done) {
    let r = act(#allocate({ offering = off; limit = 97 }), "a slice of the allocation");
    Debug.print("slice|" # t(off) # "|" # csv(r));
    slices += 1;
    done := r.size() < 4 or r[3] == 1;
    if (off == O1 and slices == 1) refused(#handOff({ offering = O1; day = D0 + 21 }), "NotInState", "a hand-off before the allocation is done");
  };
};
refused(#handOff({ offering = O1; day = D0 + 20 }), "BeforeListing", "a hand-off before the listing day");
func dumpOrders(off : Nat) {
  var cursor : ?Blob = null; var more = true;
  while (more) {
    switch (Of.ordersOf(st, off, cursor, 200)) {
      case (#ok(p)) {
        for ((id, r) in p.rows.vals()) Debug.print("order|" # t(id) # "|" # t(off) # "|" # t(Nat8.toNat(K.kindCode(r.kind))) # "|" # hex(r.investor) # "|" # csv([r.price, r.lots, r.paid, if (r.live) 1 else 0, r.allocLots, r.cashDue, r.refund]));
        cursor := p.next; more := p.next != null;
      };
      case (#err(_)) { check(false, "orders page"); more := false };
    };
  };
};
func dumpOffering(off : Nat) {
  let ?o = Of.offering(st, off) else return;
  Debug.print("offering|" # t(off) # "|" # csv([o.state, o.price, o.cornerLots, o.retailDemand, o.retailPaid, o.bidDemand, o.bidsAlloc, o.retailAlloc, o.unsold, o.underwriterLots, o.allocatedLots, o.holders, o.cashDue, o.refunds]) # "|" # hex(o.chain));
};

// ─── PART 8: the hand-off, the gate, the withdrawal ─────────────────────────────────────
let h1 = act(#handOff({ offering = O1; day = D0 + 21 }), "the flagship handed off to the listing");
Debug.print("handoff|" # t(O1) # "|" # csv(h1));
check(h1.size() == 8 and h1[2] == M.feeHalfUp(h1[1], 200) and h1[7] == price1, "the proceeds, the fee half up, the reference price");
let h3 = act(#handOff({ offering = O3; day = D0 + 21 }), "the underwritten offering handed off");
Debug.print("handoff|" # t(O3) # "|" # csv(h3));
refused(#handOff({ offering = O4; day = D0 + 21 }), "ListingGate", "too few holders for the listing");
let w4 = act(#withdrawOffering({ offering = O4; reason = "the listing gate: too few holders"; day = D0 + 22 }), "withdrawn after its allocation");
check(w4.size() == 2 and w4[1] > 0, "every retail payment refunded in full");
refused(#withdrawOffering({ offering = O1; reason = "late"; day = D0 + 22 }), "NotInState", "a listed offering withdrawn");
refused(#handOff({ offering = 99; day = D0 + 22 }), "UnknownOffering", "an unknown offering");
refused(#placeBid({ offering = O4; investor = h32("kmtr late"); price = 300; lots = 10; day = D0 + 20 }), "DayBackwards", "a command dated before the register's last day");
for (off in [O1, O2, O3, O4].vals()) { dumpOrders(off); dumpOffering(off) };

func allOrders(off : Nat) : [(Nat, Of.OrderRow)] {
  let out = List.empty<(Nat, Of.OrderRow)>();
  var cursor : ?Blob = null; var more = true;
  while (more) {
    switch (Of.ordersOf(st, off, cursor, 200)) {
      case (#ok(p)) { for (x in p.rows.vals()) List.add(out, x); cursor := p.next; more := p.next != null };
      case (#err(_)) { check(false, "orders page"); more := false };
    };
  };
  List.toArray(out)
};
// the allocation's own identities: each tranche's lots exactly, each order within a lot of its exact share
for (off in [O1, O3].vals()) {
  let ?o = Of.offering(st, off) else { check(false, "offering"); continue };
  var corner = 0; var bids = 0; var retailL = 0; var worst = 0;
  for ((_, r) in allOrders(off).vals()) {
      do {
        switch (r.kind) { case (#cornerstone) corner += r.allocLots; case (#bid) bids += r.allocLots; case (#retail) retailL += r.allocLots };
        // |alloc × demand − lots × supply| < demand: within a lot of the exact share
        let (supply, demand) = switch (r.kind) { case (#bid) (o.bidsAlloc, o.bidDemand); case (#retail) (o.retailAlloc, o.retailDemand); case (#cornerstone) (r.lots, r.lots) };
        let eligible = r.kind != #bid or (r.live and r.price >= o.price);
        if (eligible and demand > 0) { let a = r.allocLots * demand; let b = r.lots * Nat.min(supply, demand); let gap = if (a > b) a - b : Nat else b - a : Nat; if (gap >= demand) worst += 1 };
      };
  };
  check(corner == o.cornerLots and bids == o.bidsAlloc and retailL == o.retailAlloc and worst == 0, "offering " # t(off) # ": the tranches exactly and every order within a lot: " # debug_show((corner, bids, retailL, worst)));
};
Debug.print("count: offerings = 4");
Debug.print("count: orders = " # t(Of.counts(st).orders));
Debug.print("count: allocation slices = " # t(slices));

// ─── PART 9: the hand-off delivered to the custody register ─────────────────────────────
let cs = Cu.newState();
Cu.setPolicies(cs, Array.map<Text, { permission : Text; required : Nat; eligibleRole : Text; ttlSeconds : Nat }>(["custody.holder.register", "custody.asset.register", "custody.reconcile"], dual));
func custody(c : CT.Command, what : Text) : [Nat] {
  let o = switch (Cu.submit(cs, auth, tick(), officer, c, null, what)) { case (#ok(#proposed(p))) Cu.approve(cs, auth, tick(), director1, p.proposal); case (other) other };
  switch (o) { case (#ok(#executed(x))) x.effects; case (other) { check(false, what # ": " # debug_show(other)); [] } }
};
let shares = Principal.fromText("6abng-3xbmm-zos2l-batfg-zytpv-vj2jv-3t7hk-3hh6q-6hugj-2q3bc-cqe");
let cash = Principal.fromText("ktizj-ppt3n-t4gxw-lzckj-ghema-o6gli-zx5uq-eivp6-q5sun-c22gs-cqe");
var holderId = 0; var receipts = 0;
for ((off, x) in [(O1, base), (O3, t3)].vals()) {
  let ?o = Of.offering(st, off) else { check(false, "offering"); continue };
  holderId += 1; let issuerH = holderId;
  ignore custody(#registerHolder({ holder = issuerH; commit = x.issuer; account = shares }), "the issuer");
  // the shares in issue after the offer: those outstanding less what the offer did not sell
  let supply = x.sharesOutstanding - o.unsold * x.lot : Nat;
  let asset = custody(#registerAsset({ code = x.code; name = x.name; ledger = shares; cashLedger = cash; issuedSupply = supply; issuer = issuerH }), "the listed asset")[0];
  let balances = List.empty<(Nat, Nat)>();
  var delivered = 0;
  var cursor : ?Blob = null; var more = true;
  while (more) {
    switch (Of.handOffLines(st, off, cursor, 200)) {
      case (#ok(p)) {
        for ((id, r) in p.rows.vals()) {
          if (r.allocLots > 0) {
            holderId += 1;
            ignore custody(#registerHolder({ holder = holderId; commit = r.investor; account = shares }), "an allottee");
            let units = r.allocLots * x.lot;
            ignore custody(#recordSettlement({ asset; receipt = { kind = #issuance; id = id; block = off; hash = h32("allocation " # t(id)) }; from = issuerH; to = holderId; units; day = x.listingDay }), "an allotment delivered");
            List.add(balances, (holderId, units)); delivered += units; receipts += 1;
          };
        };
        cursor := p.next; more := p.next != null;
      };
      case (#err(_)) { check(false, "hand-off page"); more := false };
    };
  };
  if (o.underwriterLots > 0) {
    holderId += 1;
    ignore custody(#registerHolder({ holder = holderId; commit = x.underwriter; account = shares }), "the underwriter");
    ignore custody(#recordSettlement({ asset; receipt = { kind = #issuance; id = 1_000_000 + off; block = off; hash = h32("take-up " # t(off)) }; from = issuerH; to = holderId; units = o.underwriterLots * x.lot; day = x.listingDay }), "the underwriter's take-up delivered");
    List.add(balances, (holderId, o.underwriterLots * x.lot)); delivered += o.underwriterLots * x.lot; receipts += 1;
  };
  List.add(balances, (issuerH, supply - delivered : Nat));
  let rc = custody(#reconcile({ asset; day = x.listingDay; ledgerBlock = 1; balances = List.toArray(balances) }), "the register reconciled to the ledger at listing");
  check(Cu.positionsTotal(cs, asset) == supply and delivered == (o.allocatedLots + o.underwriterLots) * x.lot and Cu.position(cs, asset, issuerH) == x.sharesOutstanding - x.sharesOffered, "offering " # t(off) # ": the register holds the allocation, the issuer its retained shares");
  Debug.print("custody|" # t(off) # "|" # csv([supply, delivered, Cu.position(cs, asset, issuerH), List.size(balances)]) # "|" # csv(rc));
};
Debug.print("count: allotments delivered to the custody register as issuance receipts = " # t(receipts));
Debug.print("count: refusals named with the state unchanged = " # t(refusals));
Debug.print("count: acts recorded = " # t(acts));

// ─── PART 10: the replay ────────────────────────────────────────────────────────────────
let fresh = Of.newStateOver(st.log);
Of.setPolicies(fresh, policies);
let rp = Of.replay(fresh);
check(rp.faults.size() == 0 and Of.fingerprint(fresh) == Of.fingerprint(st), "the log replays to the same fingerprint: " # debug_show(rp.faults));
Debug.print("count: blocks replayed = " # t(rp.blocks));
if (failures > 0) { Debug.print("OFFERING FAILED: " # t(failures)); assert false } else Debug.print("OFFERING GREEN");
