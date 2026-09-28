/// OfferingTypes.mo: the vocabulary of an initial public offering on the venue: the underwriting, the book of bids,
/// the allocation and the hand-off to the listing and the register.
///
///   * the offering's terms: the shares offered and the shares outstanding after it, a price range on a tick, the
///     lot, the public (retail) tranche's share of the offer and the institutional tranche's rest, the cap on
///     cornerstone commitments, the underwriter's fee and whether it commits firmly to take up what is unsold, the
///     minimum a best-efforts offering must sell, and the listing gate the offering must pass (the free float and
///     the number of holders), with its calendar: the book's opening and closing, the retail subscription's close
///     and the listing day;
///   * cornerstone investors commit before the book opens, at whatever price the offering is priced at, and are
///     allocated in full; institutional investors bid a price within the range for a number of lots while the book
///     is open, one live bid each (a revision is a withdrawal and a new bid); retail investors apply within the
///     retail period, once each, paying in full at the top of the range;
///   * the offering is priced after both close, within the range and never above the book's clearing price (the
///     highest price at which the institutional demand covers the institutional tranche); the tranches take each
///     other's unfilled lots when the other is oversubscribed; what is still unsold the underwriter takes up under a
///     firm commitment, and a best-efforts offering that sells less than its minimum fails;
///   * the allocation is a sweep in slices over the orders: cornerstones in full, the bids at or above the price and
///     the retail applications each pro rata by cumulative rounding (each within one lot of its exact share, the
///     tranche's lots exactly), the cash due and the retail refunds; the allocation file chained by hash, line by line;
///   * the hand-off checks the listing gate and gives the register its lines: every allocation and the underwriter's
///     take-up, delivered as issuance receipts to the custody register, the offer price the listing's reference.
///
/// Prices are piastres per share; cash is piastres; people appear only as commitments.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

module {

  public type Day = Nat;
  public type Commitment = Blob;

  public type Terms = {
    code : Text;
    name : Text;
    issuer : Commitment;
    underwriter : Commitment;
    sharesOffered : Nat;
    sharesOutstanding : Nat;
    priceLow : Nat;
    priceHigh : Nat;
    tick : Nat;
    lot : Nat;
    retailBps : Nat;
    cornerstoneMaxBps : Nat;
    underwritingBps : Nat;
    firmCommitment : Bool;
    minSoldBps : Nat;
    minFloatBps : Nat;
    minHolders : Nat;
    bookOpen : Day;
    bookClose : Day;
    retailClose : Day;
    listingDay : Day;
  };

  public type OrderKind = { #cornerstone; #bid; #retail };
  /// 1 open (the book), 2 priced, 3 allocated, 4 handed off to the listing, 5 withdrawn (every order void, every
  /// retail payment refunded in full).
  public type State = Nat;
  public let OPEN : Nat = 1;
  public let PRICED : Nat = 2;
  public let ALLOCATED : Nat = 3;
  public let LISTED : Nat = 4;
  public let WITHDRAWN : Nat = 5;

  public type Command = {
    #openOffering : { terms : Terms; day : Day };
    #commitCornerstone : { offering : Nat; investor : Commitment; lots : Nat; day : Day };
    #placeBid : { offering : Nat; investor : Commitment; price : Nat; lots : Nat; day : Day };
    #withdrawBid : { order : Nat; day : Day };
    #subscribeRetail : { offering : Nat; investor : Commitment; lots : Nat; paid : Nat; day : Day };
    #priceOffering : { offering : Nat; price : Nat; day : Day };
    #allocate : { offering : Nat; limit : Nat };
    #handOff : { offering : Nat; day : Day };
    #withdrawOffering : { offering : Nat; reason : Text; day : Day };
  };

  public type Error = {
    #InvalidText : { field : Text; reason : Text };
    #InvalidTerms : { field : Text; reason : Text };
    #DuplicateCode : Text;
    #UnknownOffering : Nat;
    #UnknownOrder : Nat;
    #DayBackwards : { day : Day; last : Day };
    #NotInState : { offering : Nat; state : Nat };
    #CornerstoneLate : { bookOpen : Day; day : Day };
    #CornerstoneCap : { cap : Nat; committed : Nat; wanted : Nat };
    #BookClosed : { opens : Day; closes : Day; day : Day };
    #PriceOffRange : { price : Nat; low : Nat; high : Nat; tick : Nat };
    #InvalidLots : { lots : Nat; max : Nat };
    #DuplicateInvestor : { offering : Nat };
    #PaymentMismatch : { paid : Nat; due : Nat };
    #NotABid : Nat;
    #BookStillOpen : { closes : Day; day : Day };
    #PriceAboveBook : { price : Nat; clearing : Nat };
    #InvalidLimit : Nat;
    #BeforeListing : { listingDay : Day; day : Day };
    #ListingGate : { floatBps : Nat; minFloatBps : Nat; holders : Nat; minHolders : Nat };
  };

  public type Effects = [Nat];

  public let CODE_BYTES : Nat = 12;
  public let NAME_BYTES : Nat = 48;
  public let REASON_BYTES : Nat = 64;
  /// The price ladder's rungs from the low to the high end of the range, on the tick.
  public let MAX_LEVELS : Nat = 400;
  public let MAX_SLICE : Nat = 1_000;
  public let FILE_DOMAIN : Text = "tachyon.offering.allocation.v1";

  public func levels(t : Terms) : Nat { if (t.tick == 0 or t.priceHigh < t.priceLow) 0 else (t.priceHigh - t.priceLow : Nat) / t.tick + 1 };
  /// The lots of the whole offer and of each tranche: the retail tranche its share of the lots floored, the
  /// institutional the rest.
  public func offerLots(t : Terms) : Nat { t.sharesOffered / t.lot };
  public func retailLots(t : Terms) : Nat { offerLots(t) * t.retailBps / 10_000 };
  public func institutionalLots(t : Terms) : Nat { offerLots(t) - retailLots(t) : Nat };
}
