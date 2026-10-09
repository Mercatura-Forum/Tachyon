/// BookTypes.mo: the vocabulary of the book (book/SPEC.md): orders and their kinds, the funds each account holds at
/// the venue per ledger, the instruments as the book trades them, and the commands, in the frozen family order.
///
/// Prices are in the cash ledger's smallest unit per share; quantities in shares, a whole number of the instrument's
/// lots; amounts in each ledger's smallest unit; times are the chain's nanoseconds (a block's `now`).
///
/// Attribution: Thebes Core Team.

module {

  public type OrderId = Nat;
  public type AccountId = Nat;
  public type InstrumentId = Nat;
  public type Day = Nat;

  public let CLIENT_REF_BYTES = 20;
  public let MAX_BANDS = 16;
  public let MAX_SWEEP = 500;   // the most rows one sweep (a mass cancel, the end of day, an expiry) moves in one act
  /// The most trailing stops one instrument holds per side: every clear that trades moves each of them, so the cap bounds
  /// that work.
  public let MAX_TRAILING = 64;

  public type Side = { #buy; #sell };
  public type Kind = { #limit; #market; #ioc; #fok; #stop; #stopLimit; #trailingStop };
  public type Validity = { #day; #gtc; #gtd };
  public type SelfTrade = { #cancelIncoming; #cancelResting; #cancelBoth };
  public type Capacity = { #agency; #principal };
  /// `#waiting`: a stop not yet triggered. `#live`: in the book (or in the batch about to clear).
  public type Status = { #waiting; #live; #filled; #cancelled };
  public type Band = { fromPrice : Nat; tick : Nat };
  /// An instrument's phase in the book (SPEC §8). `#auction` is a call: the opening auction, a volatility
  /// interruption or the resumption after a halt.
  public type Phase = { #closed; #continuous; #auction; #closingAuction; #tradeAtClose; #halted };

  public type Order = {
    account : AccountId;
    instrument : InstrumentId;
    side : Side;
    kind : Kind;
    qty : Nat;
    remaining : Nat;
    /// The price it trades at or better: a limit, a market order's collar price, a stop-limit's limit.
    price : Nat;
    stopPrice : Nat;
    /// The displayed quantity of an iceberg; 0 for a fully displayed order.
    peak : Nat;
    validity : Validity;
    gtdDay : Day;
    selfTrade : SelfTrade;
    capacity : Capacity;
    shortSale : Bool;
    clientRef : Text;
    /// The order cancelled when this one fills or triggers (one-cancels-other); 0 for none.
    oco : OrderId;
    /// A trailing stop's distance from the last clear's price; 0 for every other order.
    trail : Nat;
    /// The member whose account it is and the trader that entered it (the exchange's ids, checked at entry).
    member : Nat;
    trader : Nat;
    /// The batch (a block's time) its priority dates from: entry, trigger or an iceberg's last refresh.
    prio : Nat64;
    /// SHA-256 of account, side, price, quantity and client reference: the tie-break no arrival order can change.
    key : Blob;
    status : Status;
    /// What the order still holds: cash (a buy, in the cash ledger) or shares (a sell, in the asset ledger).
    held : Nat;
    filled : Nat;
  };

  /// An instrument as the book trades it, opened by the operator from the exchange's instrument row.
  public type Instrument = {
    assetLedger : Principal;
    cashLedger : Principal;
    lot : Nat;
    referencePrice : Nat;
    bands : [Band];
    collarBps : Nat;
    phase : Phase;
    lastPrice : Nat;   // 0 before the first clear that crossed
    /// The static band around the reference price and the dynamic band around the last price, in basis points
    /// (dynamic 0 for none), and the length of a volatility interruption (SPEC §10).
    staticBps : Nat;
    dynamicBps : Nat;
    interruptSecs : Nat;
    /// A call phase's random end window and an interruption's end, chain times (0 for none); the closing price.
    endFrom : Nat64;
    endTo : Nat64;
    interruptUntil : Nat64;
    closePrice : Nat;
  };
  /// A kill switch (SPEC §11): a member, or one trader (the other 0); active until revived.
  public type Kill = { member : Nat; trader : Nat; active : Bool };
  /// A member's risk limits (0 for none) and its use: the value of its open orders (SPEC §11).
  public type Limits = { maxOrderQty : Nat; maxOrderValue : Nat; creditLimit : Nat; used : Nat };

  public type Balance = { account : AccountId; ledger : Principal; available : Nat; held : Nat };

  // ─── the commands, in the frozen family order (a family's tag is its position; append only) ───────────────────
  public type Command = {
    #openInstrument : { instrument : InstrumentId; assetLedger : Principal; cashLedger : Principal; lot : Nat; referencePrice : Nat; bands : [Band]; collarBps : Nat;
      staticBps : Nat; dynamicBps : Nat; interruptSecs : Nat };
    #setTrading : { instrument : InstrumentId; open : Bool };
    #setReference : { instrument : InstrumentId; price : Nat };
    /// The depository's attestation that `amount` reached the venue's account on `ledger` for `account`, by the
    /// reference of that transfer (32 bytes), recorded once.
    /// Funds and the mass cancel name the account's member (checked against the exchange's rows), so the log alone says
    /// which member every block concerns (the drop copy, SPEC §14).
    #deposit : { account : AccountId; member : Nat; ledger : Principal; amount : Nat; reference : Blob };
    #withdraw : { account : AccountId; member : Nat; ledger : Principal; amount : Nat };
    #placeOrder : {
      account : AccountId; instrument : InstrumentId; side : Side; kind : Kind; qty : Nat; price : Nat; stopPrice : Nat; peak : Nat;
      validity : Validity; gtdDay : Day; selfTrade : SelfTrade; capacity : Capacity; shortSale : Bool; clientRef : Text; oco : OrderId; trail : Nat;
      member : Nat; trader : Nat;
    };
    #cancelOrder : { order : OrderId };
    #amendOrder : { order : OrderId; qty : Nat; price : Nat };
    #massCancel : { account : AccountId; member : Nat; limit : Nat };
    /// The scheduler records a due clear when no other command arrives to do so.
    #flush;
    #endOfDay : { limit : Nat };
    #expireGtd : { day : Day; limit : Nat };
    /// The clear of the batch of `time`: recorded by the book itself (no principal submits it).
    #clear : { time : Nat64 };
    // phases, auctions, halts, the kill switch, risk limits (SPEC §8 to §11)
    #setPhase : { instrument : InstrumentId; phase : Phase; endFrom : Nat64; endTo : Nat64 };
    #uncross : { instrument : InstrumentId; next : Phase };
    #halt : { instrument : InstrumentId; reason : Text };
    #resume : { instrument : InstrumentId };
    /// A kill names its member; with a trader (not 0) it kills that trader of the member only.
    #kill : { member : Nat; trader : Nat; reason : Text };
    #killSweep : { kill : Nat; limit : Nat };
    #revive : { kill : Nat };
    #setLimits : { member : Nat; maxOrderQty : Nat; maxOrderValue : Nat; creditLimit : Nat };
    /// The scheduler seals the market day (SPEC §15): the day's file written, its hash recorded, a new session begun.
    #sealDay : { day : Nat };
    /// Compliance, under four eyes, blacks out a client code for an instrument until the end of a market day (0: until
    /// lifted), and lifts it (SPEC §16).
    #setBlackout : { instrument : InstrumentId; client : Blob; until : Nat; reason : Text };
    #liftBlackout : { blackout : Nat };
    /// The depository attests a securities loan: the shares credited and recorded owed; a trader returns them (§17).
    #borrow : { account : AccountId; member : Nat; instrument : InstrumentId; qty : Nat; reference : Blob };
    #returnBorrow : { account : AccountId; member : Nat; instrument : InstrumentId; qty : Nat };
    /// The central counterparty (SPEC §18 to §21): the market's clearing terms and an instrument's margin (four eyes). The
    /// CCP's account, its member and the clearing currency are fixed by the first; the parameters may change after.
    #setClearing : { ccpAccount : AccountId; ccpMember : Nat; cashLedger : Principal; cycleSecs : Nat; cycleDays : Nat; penaltyBps : Nat; deadlineCycles : Nat; fundBps : Nat; fundFloor : Nat };
    #setMargin : { instrument : InstrumentId; imBps : Nat };
    /// A clearing member admitted (its settlement account and credit line) and an account designated (four eyes).
    #admitClearing : { member : Nat; settlementAccount : AccountId; creditLine : Nat };
    #designateClearing : { account : AccountId; member : Nat };
    /// A member's collateral, posted from or withdrawn to its settlement account (a trader of the member).
    #postCollateral : { member : Nat; amount : Nat };
    #withdrawCollateral : { member : Nat; amount : Nat };
    /// The scheduler's cut of the open cycle, with the market day it settles on (0 when it settles at once, §19), the
    /// settlement of the oldest cut cycle, and the close-out of a failing member's shares in an instrument (§20).
    #cutCycle : { cycle : Nat; settleDay : Nat };
    #settleCycle : { cycle : Nat };
    #closeOut : { member : Nat; instrument : InstrumentId };
    /// The guarantee fund: the scheduler's call, a member's contribution, the venue's skin-in-the-game (§21).
    #callFund;
    #contributeFund : { member : Nat; amount : Nat };
    #fundSkin : { account : AccountId; amount : Nat };
    /// Default (four eyes): declared, then closed through the waterfall (§21).
    #declareDefault : { member : Nat; reason : Text };
    #closeDefault : { member : Nat };
    /// An instrument's fee schedule (SPEC §22; four eyes): each levy a recipient account and a rate in parts per million.
    #setFeeSchedule : { instrument : InstrumentId; levies : [Levy] };
    /// The scheduler seals every open member statement for the market day (§23).
    #sealStatements : { day : Day };
    /// A trader of the member attests its member's balances as of a market day (§24).
    #reconcileMember : { member : Nat; day : Day; balances : [Attested] };
    /// A market maker's registration for an instrument with its obligations and rebate (§25; four eyes).
    #registerMaker : { member : Nat; instrument : InstrumentId; maxSpreadBps : Nat; minQty : Nat; presenceBps : Nat; rebateBps : Nat };
    /// A registered maker's two-sided quote on one account, replacing its live quote on the instrument atomically, and
    /// several at once (§25).
    #quote : { account : AccountId; member : Nat; trader : Nat; side : QuoteSide };
    #massQuote : { account : AccountId; member : Nat; trader : Nat; sides : [QuoteSide] };
    /// The scheduler's close of the makers' period for the market day: presence recorded, rebates paid (§25).
    #settleMakers : { day : Day };
  };

  /// A levy of a fee schedule (SPEC §22): its recipient account and its rate in parts per million of a fill's value.
  public type Levy = { account : AccountId; ppm : Nat };
  /// A balance a member attests (§24): its account, the ledger, the amount (available and held together).
  public type Attested = { account : AccountId; ledger : Principal; amount : Nat };
  /// One instrument's quote (§25): the bid and the ask, the quantity each side, the client reference its sides take
  /// (the bid's with ".b", the ask's with ".a").
  public type QuoteSide = { instrument : InstrumentId; bidPrice : Nat; askPrice : Nat; qty : Nat; ref : Text };
  public let MAX_LEVIES = 4;
  public let MAX_ATTESTED = 64;
  public let MAX_MASS_QUOTE = 16;
  /// Effects: a flat list of numbers, the family tag first (`BookCore.apply` gives each family's layout).
  public type Effects = [Nat];

  public type Error = {
    #UnknownInstrument : { instrument : InstrumentId };
    #InstrumentOpenAlready : { instrument : InstrumentId };
    #InstrumentMismatch : { field : Text };
    #InvalidTerms : { reason : Text };
    #UnknownAccount : { account : AccountId };
    #NotYourAccount : { account : AccountId };
    #AccountClosed : { account : AccountId };
    #MayNotTrade : { code : Nat };
    #DuplicateReference;
    #InsufficientFunds : { ledger : Principal; available : Nat; wanted : Nat };
    #NotALot : { qty : Nat; lot : Nat };
    #PriceOffTick : { price : Nat; tick : Nat };
    #InvalidPrice : { reason : Text };
    #DuplicateClientRef : { clientRef : Text };
    #SelfTradePrevented : { resting : OrderId };
    #UnknownOrder : { order : OrderId };
    #NotYourOrder : { order : OrderId };
    #OrderClosed : { order : OrderId };
    #InvalidOco : { order : OrderId };
    #TrailingStopsFull : { instrument : InstrumentId; max : Nat };
    #NothingToClear;
    #NotTheChainsDay : { day : Day };
    #ClearNotSubmittable;
    #InstrumentHalted : { instrument : InstrumentId };
    #PriceOutsideBand : { price : Nat; low : Nat; high : Nat };
    #NotInAuction : { instrument : InstrumentId };
    #AuctionNotEnded : { until : Nat64 };
    #Killed : { kill : Nat };
    #UnknownKill : { kill : Nat };
    #OrdersStillOpen : { kill : Nat };
    #RiskLimit : { figure : Text; limit : Nat; wanted : Nat };
    #InsiderBlackout : { instrument : InstrumentId };
    #UnknownBlackout : { blackout : Nat };
    #ShortSaleNotFlagged : { free : Nat; wanted : Nat };
    #ShortSalePrice : { price : Nat; floor : Nat };
    #MarginShort : { required : Nat; available : Nat };
    #LiquidityShort : { needed : Nat; free : Nat };
    #NotClearing : { member : Nat };
    #CycleNotDue : { due : Nat };
    #FundShort : { required : Nat; paid : Nat };
    #NotAMaker : { member : Nat; instrument : InstrumentId };
  };
};
