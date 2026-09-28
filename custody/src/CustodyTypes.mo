/// CustodyTypes.mo: the vocabulary of custody over the venue's assets: holders and their settled positions as the
/// fold of the venue's receipts, the reconciliation of the register to the issued supply and to the ledgers, and
/// corporate actions — dividend, split, bonus, rights, redemption — as recorded events applied to the positions of
/// the record date and paid on the payment date, the entitlement file per holder certified by its hash.
///
/// The register lives beside Tachyon because Tachyon's receipts are the venue's certified record of every settled
/// movement (a trade's two legs, a delivery's one leg): a position here is nothing but the fold of the receipts
/// recorded against it, and a reconciliation is the check that the fold agrees with the supply the issuer
/// registered and with the balances the ledgers show. No person is in a block: a holder is an id and an identity
/// commitment; its ledger account is a principal the reconciliation reads balances for. Units are the asset's
/// smallest unit; cash is micro-units of the cash ledger; a rate per unit is micro-cash per unit; a ratio is a
/// numerator over a denominator, applied to a position as one exact fraction floored, the fraction paid in cash
/// in lieu at a declared price.

module {

  public type Day = Nat;
  public type Commitment = Blob;
  public type HolderId = Nat;
  public type AssetId = Nat;
  public type ActionId = Nat;

  public type Asset = { code : Text; name : Text; ledger : Principal; cashLedger : Principal; issuedSupply : Nat; issuer : HolderId };

  public type Holder = { commit : Commitment; account : Principal };

  /// A settled movement the venue receipted: a trade's asset leg or a delivery, from one holder to another, by the
  /// receipt's id and hash in the venue's Merkle mountain range.
  public type ReceiptKind = { #trade; #delivery; #issuance; #redemption };
  public type Receipt = { kind : ReceiptKind; id : Nat; block : Nat; hash : Blob };

  public type Kind = {
    #cashDividend : { perUnitMicro : Nat };
    /// New units for old: a position of `units` becomes `units × numerator / denominator`, floored; the fraction
    /// is paid in cash in lieu.
    #split : { numerator : Nat; denominator : Nat; cashInLieuMicro : Nat };
    /// Additional units: `units × numerator / denominator`, floored; the fraction in cash in lieu.
    #bonus : { numerator : Nat; denominator : Nat; cashInLieuMicro : Nat };
    /// Rights to subscribe new units at a price: `units × numerator / denominator` rights, floored; a holder takes
    /// up to its rights by the deadline and pays the price per unit.
    #rights : { numerator : Nat; denominator : Nat; subscriptionPriceMicro : Nat; subscriptionDeadline : Day };
    /// Units redeemed at a price: `units × ratioBps / 10000`, floored, against cash.
    #redemption : { ratioBps : Nat; pricePerUnitMicro : Nat };
  };

  public type ActionState = { #announced; #struck; #paid; #cancelled };

  public type Action = {
    asset : AssetId;
    kind : Kind;
    recordDate : Day;
    exDate : Day;
    paymentDate : Day;
    /// A commitment to the issuer's notice.
    source : Commitment;
    state : ActionState;
    /// The sweeps' cursor: the next holder while striking, the next entitlement while paying.
    holderCursor : Nat;
    /// The first entitlement row of the action: its rows are consecutive from it.
    firstEntitlement : Nat;
    entitlements : Nat;
    cashTotal : Nat;
    unitsTotal : Nat;
    fileHash : ?Blob;
    cancelReason : ?Text;
  };

  /// A holder's entitlement under an action: the units held at the record date, what is due in cash (a dividend,
  /// cash in lieu, the redemption proceeds) or payable by the holder (a subscription), the units to be delivered or
  /// taken, the rights and the take-up.
  public type Entitlement = {
    action : ActionId;
    holder : HolderId;
    unitsAtRecord : Nat;
    cashDue : Nat;
    cashPayable : Nat;
    unitsDue : Nat;
    unitsTaken : Nat;
    rights : Nat;
    rightsTaken : Nat;
    fractionUnits : Nat;
    paid : Bool;
  };

  public type Reconciliation = { asset : AssetId; day : Day; ledgerBlock : Nat; holders : Nat; positionsTotal : Nat; issuedSupply : Nat; matched : Nat; breaks : Nat; hash : Blob };

  public type Command = {
    #registerHolder : { holder : HolderId; commit : Commitment; account : Principal };
    #registerAsset : { code : Text; name : Text; ledger : Principal; cashLedger : Principal; issuedSupply : Nat; issuer : HolderId };
    /// A settled movement by the venue's receipt: the position moves from one holder to another.
    #recordSettlement : { asset : AssetId; receipt : Receipt; from : HolderId; to : HolderId; units : Nat; day : Day };
    /// The custodian's attestation of the ledger's balances as of a block: every holder's position is compared.
    #reconcile : { asset : AssetId; day : Day; ledgerBlock : Nat; balances : [(HolderId, Nat)] };
    #announceAction : { asset : AssetId; kind : Kind; recordDate : Day; exDate : Day; paymentDate : Day; source : Commitment };
    #cancelAction : { action : ActionId; day : Day; reason : Text };
    /// Strike the record date over the holders in slices: an entitlement per position.
    #strikeRecordDate : { action : ActionId; limit : Nat };
    #subscribeRights : { action : ActionId; holder : HolderId; rights : Nat; day : Day };
    /// Pay the action on its payment date over the entitlements in slices: the units delivered or taken, the file.
    #pay : { action : ActionId; day : Day; limit : Nat };
    #certifyEntitlementFile : { action : ActionId; day : Day };
  };

  public type Effects = [Nat];

  public type Error = {
    #InvalidText : { field : Text; reason : Text };
    #InvalidCommitment : { field : Text };
    #InvalidTerms : { reason : Text };
    #UnknownHolder : HolderId;
    #DuplicateHolder : HolderId;
    #UnknownAsset : AssetId;
    #DuplicateAsset : Text;
    #UnknownAction : ActionId;
    #ActionNotIn : { action : ActionId; state : ActionState };
    #ReceiptRecorded : { kind : ReceiptKind; id : Nat };
    #PositionShort : { asset : AssetId; holder : HolderId; held : Nat; wanted : Nat };
    #InvalidDay : { field : Text; reason : Text };
    #InvalidLimit : Nat;
    #NotRights : ActionId;
    #NoEntitlement : { action : ActionId; holder : HolderId };
    #ExceedsRights : { action : ActionId; holder : HolderId; rights : Nat; taken : Nat; wanted : Nat };
    #SubscriptionClosed : { action : ActionId; deadline : Day; day : Day };
    #ActionOpenOnAsset : { asset : AssetId; action : ActionId };
    #TooManyHolders : { max : Nat };
    #InvalidAmount : { field : Text };
  };

  public let CODE_BYTES : Nat = 12;
  public let NAME_BYTES : Nat = 48;
  public let MAX_SLICE : Nat = 1_000;
  public let MAX_RECONCILE : Nat = 4_096;
  public let FILE_DOMAIN : Text = "tachyon.custody.entitlements.v1";
  public let RECONCILIATION_DOMAIN : Text = "tachyon.custody.reconciliation.v1";

  public func kindText(k : Kind) : Text { switch (k) { case (#cashDividend(_)) "cashDividend"; case (#split(_)) "split"; case (#bonus(_)) "bonus"; case (#rights(_)) "rights"; case (#redemption(_)) "redemption" } };
  public func stateText(s : ActionState) : Text { switch (s) { case (#announced) "announced"; case (#struck) "struck"; case (#paid) "paid"; case (#cancelled) "cancelled" } };
  public func receiptKindText(k : ReceiptKind) : Text { switch (k) { case (#trade) "trade"; case (#delivery) "delivery"; case (#issuance) "issuance"; case (#redemption) "redemption" } };
}
