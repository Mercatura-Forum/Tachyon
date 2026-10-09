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
    open : Bool;
    lastPrice : Nat;   // 0 before the first clear that crossed
  };

  public type Balance = { account : AccountId; ledger : Principal; available : Nat; held : Nat };

  // ─── the commands, in the frozen family order (a family's tag is its position; append only) ───────────────────
  public type Command = {
    #openInstrument : { instrument : InstrumentId; assetLedger : Principal; cashLedger : Principal; lot : Nat; referencePrice : Nat; bands : [Band]; collarBps : Nat };
    #setTrading : { instrument : InstrumentId; open : Bool };
    #setReference : { instrument : InstrumentId; price : Nat };
    /// The depository's attestation that `amount` reached the venue's account on `ledger` for `account`, by the
    /// reference of that transfer (32 bytes), recorded once.
    #deposit : { account : AccountId; ledger : Principal; amount : Nat; reference : Blob };
    #withdraw : { account : AccountId; ledger : Principal; amount : Nat };
    #placeOrder : {
      account : AccountId; instrument : InstrumentId; side : Side; kind : Kind; qty : Nat; price : Nat; stopPrice : Nat; peak : Nat;
      validity : Validity; gtdDay : Day; selfTrade : SelfTrade; capacity : Capacity; shortSale : Bool; clientRef : Text; oco : OrderId; trail : Nat;
    };
    #cancelOrder : { order : OrderId };
    #amendOrder : { order : OrderId; qty : Nat; price : Nat };
    #massCancel : { account : AccountId; limit : Nat };
    /// The scheduler records a due clear when no other command arrives to do so.
    #flush;
    #endOfDay : { limit : Nat };
    #expireGtd : { day : Day; limit : Nat };
    /// The clear of the batch of `time`: recorded by the book itself (no principal submits it).
    #clear : { time : Nat64 };
  };

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
  };
};
