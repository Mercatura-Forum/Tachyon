/// ExchangeTypes.mo: the vocabulary of the exchange's foundation: who may trade (members, their traders, their house
/// and client accounts, each trader's rights per segment), what is traded (instruments with their segment, tick
/// table, lot and reference price) and when (each segment's session windows on the market's calendar, the phase a
/// segment is in, changed only by the scheduler's act at the time the schedule says).
///
/// The reference data follows the established trading-system model: a business unit, user and account hierarchy, trading
/// phases per product and price-dependent tick tables; the EGX's sessions (a pre-open with a random end, continuous trading, a closing auction, trade at close) and its
/// tick table (0.01 at a price of 2.00 or more, 0.001 below). No person is in a block: a client account carries a
/// commitment to the client's identity, held by the member and the regulator.
///
/// Prices are in the cash ledger's smallest unit per share; quantities in shares; times of day in seconds after the
/// market's midnight; days are civil day numbers (kernel `num/CivilDate`).
///
/// Attribution: Thebes Core Team.

module {

  public type Day = Nat;
  public type MemberId = Nat;
  public type TraderId = Nat;
  public type AccountId = Nat;
  public type SegmentId = Nat;
  public type InstrumentId = Nat;
  public type TableId = Nat;

  public let CODE_BYTES = 8;      // a member's or a segment's code (the EGX's member codes are numbers of a few digits)
  public let NAME_BYTES = 48;
  public let ISIN_BYTES = 12;     // ISO 6166
  public let CURRENCY_BYTES = 3;  // ISO 4217
  public let REASON_BYTES = 120;
  public let MAX_WINDOWS = 8;     // a segment's day: closed, pre-open, auction, continuous, closing auction, trade at close, closed
  public let MAX_BANDS = 16;      // a tick table's price bands
  public let DAY_SECONDS = 86_400;

  public type MemberStatus = { #active; #suspended; #expelled };
  public type Member = {
    code : Text;
    name : Text;
    marketMaker : Bool;
    clearing : Bool;
    status : MemberStatus;
    admitted : Day;
  };

  public type TraderStatus = { #active; #revoked };
  public type Trader = { member : MemberId; principal : Principal; status : TraderStatus };

  public type AccountKind = { #house; #client };
  public type AccountStatus = { #open; #closed };
  /// A house account carries no client; a client account carries a 32-byte commitment to the client's identity.
  public type Account = { member : MemberId; kind : AccountKind; client : Blob; status : AccountStatus };

  /// A segment's phases. `#halted` is never in a schedule: a halt is a recorded act, never a scheduled phase.
  public type Phase = { #closed; #preOpen; #openingAuction; #continuous; #closingAuction; #tradeAtClose; #halted };
  /// One window of a segment's trading day: the phase from `startSec` (inclusive) to `endSec` (exclusive).
  public type Window = { phase : Phase; startSec : Nat; endSec : Nat };

  public type Segment = {
    code : Text;
    name : Text;
    windows : [Window];
    /// The phase the scheduler last moved the segment to, and the day and second it did.
    phase : Phase;
    phaseDay : Day;
    phaseSec : Nat;
  };

  /// A tick table's band: from `fromPrice` (inclusive) up to the next band's, prices step by `tick`.
  public type Band = { fromPrice : Nat; tick : Nat };

  public type InstrumentStatus = { #listed; #suspended; #delisted };
  public type Instrument = {
    isin : Text;
    name : Text;
    segment : SegmentId;
    currency : Text;
    assetLedger : Principal;
    cashLedger : Principal;
    tickTable : TableId;
    lot : Nat;
    referencePrice : Nat;
    referenceDay : Day;
    status : InstrumentStatus;
  };

  /// The market's clock: its UTC offset in minutes east (Egypt: +120, +180 in summer time), recorded as an act, so
  /// the chain's time converts to the market's day and second of the day the schedules are written in.
  public let MAX_OFFSET_MINUTES = 840;

  // ─── the commands, in the frozen family order (a family's tag is its position; append only) ───────────────────
  public type Command = {
    #admitMember : { code : Text; name : Text; marketMaker : Bool; clearing : Bool; day : Day };
    #setMemberStatus : { member : MemberId; status : MemberStatus; reason : Text };
    #registerTrader : { member : MemberId; principal : Principal };
    #revokeTrader : { trader : TraderId; reason : Text };
    #grantTradingRight : { trader : TraderId; segment : SegmentId };
    #withdrawTradingRight : { trader : TraderId; segment : SegmentId };
    #openAccount : { member : MemberId; kind : AccountKind; client : Blob };
    #closeAccount : { account : AccountId; reason : Text };
    #defineSegment : { code : Text; name : Text; windows : [Window] };
    #setSchedule : { segment : SegmentId; windows : [Window] };
    #setRestDays : { days : [Nat] };
    #declareHoliday : { day : Day; reason : Text };
    #defineTickTable : { bands : [Band] };
    #listInstrument : { isin : Text; name : Text; segment : SegmentId; currency : Text; assetLedger : Principal; cashLedger : Principal; tickTable : TableId; lot : Nat; referencePrice : Nat; day : Day };
    #setInstrumentStatus : { instrument : InstrumentId; status : InstrumentStatus; reason : Text };
    #setLot : { instrument : InstrumentId; lot : Nat };
    #setReferencePrice : { instrument : InstrumentId; price : Nat; day : Day };
    /// The scheduler's act: the segment moves to the phase its schedule names at (day, sec). The day and second are
    /// the chain's clock at submission, checked there; the caller chooses no time and no phase.
    #advancePhase : { segment : SegmentId; day : Day; sec : Nat };
    #setUtcOffset : { minutesEast : Int };
  };

  /// What a command did, as the log records it and a replay must reproduce: a flat list of numbers, the first the
  /// command's family tag, then the ids it created or changed (`ExchangeCore.apply` names the layout per family).
  public type Effects = [Nat];

  /// Every refusal, by name; each has a stable code and an Arabic and an English text (`ExchangeText`).
  public type Error = {
    #InvalidText : { field : Text; reason : Text };
    #DuplicateMemberCode : { code : Text };
    #UnknownMember : { member : MemberId };
    #MemberNotActive : { member : MemberId };
    #NoStatusChange;
    #ExpelledIsFinal : { member : MemberId };
    #DuplicateTrader : { principal : Principal };
    #UnknownTrader : { trader : TraderId };
    #TraderRevoked : { trader : TraderId };
    #RightHeld : { trader : TraderId; segment : SegmentId };
    #RightNotHeld : { trader : TraderId; segment : SegmentId };
    #InvalidClientCommitment;
    #UnknownAccount : { account : AccountId };
    #AccountClosed : { account : AccountId };
    #DuplicateSegmentCode : { code : Text };
    #UnknownSegment : { segment : SegmentId };
    #InvalidSchedule : { reason : Text };
    #InvalidRestDays;
    #DuplicateHoliday : { day : Day };
    #HolidayInPast : { day : Day };
    #InvalidTickTable : { reason : Text };
    #UnknownTickTable : { table : TableId };
    #DuplicateIsin : { isin : Text };
    #InvalidIsin : { isin : Text };
    #InvalidCurrency : { currency : Text };
    #UnknownInstrument : { instrument : InstrumentId };
    #InstrumentDelisted : { instrument : InstrumentId };
    #InvalidLot;
    #PriceOffTick : { price : Nat; tick : Nat };
    #InvalidPrice;
    #NotTheChainsClock : { day : Day; sec : Nat };
    #PhaseUnchanged : { segment : SegmentId; phase : Phase };
    #InvalidUtcOffset;
    #NotYourMember : { member : MemberId };
  };
};
