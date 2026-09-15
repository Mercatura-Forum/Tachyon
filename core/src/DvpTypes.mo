/// DvpTypes.mo - types for the DvP atomic-swap core (BIS DvP Model 1).
///
/// Ledger-agnostic leg abstraction: a trade settles `legA` (the asset/delivery leg,
/// maker -> taker) against `legB` (the cash/payment leg, taker -> maker). Each leg
/// references an ICRC ledger and a kind. The `#icrc1` (fungible) kind is fully
/// implemented and proven on a throwaway chain; the `#icrc7`
/// (non-fungible) kind is part of the type for forward-compatibility - its on-chain
/// validation is the land-ledger phase (see docs/DESIGN.md). The
/// state machine never branches on kind; only the ledger-dispatch layer does, so adding
/// the ICRC-7 handler is additive and does not touch the lifecycle / invariant logic.

module {

  public type Account = { owner : Principal; subaccount : ?Blob };

  // ── Leg abstraction ─────────────────────────────────────────────────────────
  public type LegKind = {
    #icrc1 : { amount : Nat };   // fungible: deliver `amount` base units
    #icrc7 : { tokenId : Nat };  // non-fungible: deliver token `tokenId`
  };

  public type Leg = {
    ledger : Principal;          // the ICRC ledger canister
    kind : LegKind;
  };

  // ── Per-leg escrow / payout / refund tracking (idempotency state) ─────────────
  // `cat` = the created_at_time used for the ledger call. It is allocated once (stable,
  // strictly monotonic) and REUSED on every retry so the ledger's dedup window returns
  // #Duplicate on a true replay - this is what makes settlement idempotent even when a
  // ledger reply is lost after the ledger already committed (the double-pay hazard).
  public type LegState = {
    var escrowed : Bool;        // funds confirmed pulled into the core's own account
    var escrowCat : ?Nat64;     // created_at_time of the inbound transfer_from
    var escrowBlock : ?Nat;     // ledger block index of the inbound transfer_from
    var escrowedAmount : Nat;   // base units actually pulled in (for conservation)
    var payoutCat : ?Nat64;     // created_at_time of the outbound payout
    var payout : ?Nat;          // ledger block index of the payout (None = unpaid)
    var payoutAmount : Nat;     // base units paid out (net of fee)
    var refundCat : ?Nat64;     // created_at_time of the refund
    var refund : ?Nat;          // ledger block index of the refund (None = not refunded)
    var refundAmount : Nat;     // base units refunded (net of fee)
  };

  public func newLegState() : LegState {
    {
      var escrowed = false; var escrowCat = null; var escrowBlock = null;
      var escrowedAmount = 0;
      var payoutCat = null; var payout = null; var payoutAmount = 0;
      var refundCat = null; var refund = null; var refundAmount = 0;
    }
  };

  // ── Trade lifecycle ───────────────────────────────────────────────────────────
  // Open    : order created, awaiting both escrows (per-leg flags track which are in).
  // Funded  : BOTH legs escrowed - the DvP gate is open, settlement is now guaranteed.
  // Settled : both payouts done (asset->taker, cash->maker).
  // Aborted : funding deadline passed without both-escrowed; escrowed legs refunded.
  // Terminal states (Settled/Aborted) are mutually exclusive and absorbing (INV-DVP-3).
  public type TradeStatus = { #Open; #Funded; #Settled; #Aborted };

  public type Trade = {
    id : Nat;
    maker : Principal;          // delivers legA (asset), receives legB (cash)
    var taker : ?Principal;     // delivers legB (cash), receives legA (asset); null = open RFQ
    legA : Leg;                 // asset leg: owner = maker,  recipient = taker
    legB : Leg;                 // cash  leg: owner = taker,  recipient = maker
    legAState : LegState;
    legBState : LegState;
    deadline : Nat64;           // funding deadline (ns since epoch)
    var status : TradeStatus;
    createdAt : Nat64;
  };

  // ── Query views (immutable / shareable) ───────────────────────────────────────
  public type LegStateView = {
    escrowed : Bool;
    escrowBlock : ?Nat;
    escrowedAmount : Nat;
    payout : ?Nat;
    payoutAmount : Nat;
    refund : ?Nat;
    refundAmount : Nat;
  };

  public type TradeView = {
    id : Nat;
    maker : Principal;
    taker : ?Principal;
    legA : Leg;
    legB : Leg;
    legAState : LegStateView;
    legBState : LegStateView;
    deadline : Nat64;
    status : TradeStatus;
    createdAt : Nat64;
  };

  public func legStateView(s : LegState) : LegStateView {
    {
      escrowed = s.escrowed;
      escrowBlock = s.escrowBlock;
      escrowedAmount = s.escrowedAmount;
      payout = s.payout;
      payoutAmount = s.payoutAmount;
      refund = s.refund;
      refundAmount = s.refundAmount;
    }
  };

  public func tradeView(t : Trade) : TradeView {
    {
      id = t.id;
      maker = t.maker;
      taker = t.taker;
      legA = t.legA;
      legB = t.legB;
      legAState = legStateView(t.legAState);
      legBState = legStateView(t.legBState);
      deadline = t.deadline;
      status = t.status;
      createdAt = t.createdAt;
    }
  };

  // ── Delivery free of payment (one leg) ────────────────────────────────────────
  // A delivery moves one leg from the maker to a named taker with no cash against it: the
  // collateral pledge, the return, the transfer between two custody accounts. The maker
  // escrows the leg into the core; the leg moves only when the taker has accepted it, so a
  // delivery to the wrong account is refused by the account it reaches, never reversed. Past
  // the deadline an unaccepted delivery is reclaimed by the maker. The leg's escrow, payout
  // and refund are the trade's own helpers on the trade's own leg state, so a delivery's
  // receipt has the shape of a trade's, one leg short.
  //
  // Open      : awaiting the maker's escrow.
  // Escrowed  : the leg is in the core; awaiting the taker's acceptance.
  // Delivered : accepted and paid out to the taker.
  // Reclaimed : the deadline passed unaccepted; the escrowed leg returned to the maker.
  public type DeliveryStatus = { #Open; #Escrowed; #Delivered; #Reclaimed };

  public type Delivery = {
    id : Nat;                   // in the trades' own id space, so a leg key never collides
    maker : Principal;          // delivers the leg
    taker : Principal;          // receives it, by its own acceptance
    leg : Leg;
    legState : LegState;
    deadline : Nat64;
    var accepted : Bool;
    var status : DeliveryStatus;
    createdAt : Nat64;
  };

  public type DeliveryView = {
    id : Nat;
    maker : Principal;
    taker : Principal;
    leg : Leg;
    legState : LegStateView;
    deadline : Nat64;
    accepted : Bool;
    status : DeliveryStatus;
    createdAt : Nat64;
  };

  public func deliveryView(d : Delivery) : DeliveryView {
    { id = d.id; maker = d.maker; taker = d.taker; leg = d.leg; legState = legStateView(d.legState); deadline = d.deadline; accepted = d.accepted; status = d.status; createdAt = d.createdAt }
  };

  public type OpenDeliveryResult = {
    deliveryId : Nat;
    status : DeliveryStatus;
    makerEscrowed : Bool;
    note : Text;
  };

  public type DeliveryResult = {
    deliveryId : Nat;
    status : DeliveryStatus;
    escrowed : Bool;
    accepted : Bool;
    delivered : Bool;           // paid out to the taker
    reclaimed : Bool;           // refunded to the maker
    amount : Nat;               // the units paid out or refunded (net of the ledger fee)
    note : Text;
  };

  // ── Public call result types ───────────────────────────────────────────────────
  public type OpenResult = {
    tradeId : Nat;
    status : TradeStatus;
    makerEscrowed : Bool;       // true once legA is confirmed in the core's account
    note : Text;                // human-readable status of the inline maker-escrow attempt
  };

  public type FundResult = {
    tradeId : Nat;
    status : TradeStatus;
    legEscrowed : Bool;
    bothEscrowed : Bool;
    settleNote : Text;          // result of the auto-settle attempt (fundTaker only)
  };

  public type SettleResult = {
    tradeId : Nat;
    status : TradeStatus;
    legAPaid : Bool;
    legBPaid : Bool;
    legAPayoutAmount : Nat;
    legBPayoutAmount : Nat;
    note : Text;
  };

  public type ReclaimResult = {
    tradeId : Nat;
    status : TradeStatus;
    legARefunded : Bool;
    legBRefunded : Bool;
    note : Text;
  };

  // ── Audit event (MMR leaf) ──────────────────────────────────────────────────────
  public type AuditEvent = {
    seq : Nat;          // global append index
    tradeId : Nat;
    encoded : Text;     // canonical string that is hashed into the MMR leaf
    leafHex : Text;     // hex of the leaf hash (for external re-derivation)
  };
};
