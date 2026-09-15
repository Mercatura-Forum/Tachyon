/// ICRC.mo - ICRC-1/ICRC-2 ledger interface types
///
/// Matches the official Candid definitions exactly:
///   ICRC-1: https://<reference>
///   ICRC-2: https://<reference>

import Principal "mo:core/Principal";

module {

  public type Account = {
    owner : Principal;
    subaccount : ?Blob;
  };

  // ═══════════════════════════════════════════════════════
  //  ICRC-1 (Transfer)
  // ═══════════════════════════════════════════════════════

  public type TransferArgs = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferResult = { #Ok : Nat; #Err : TransferError };

  // ═══════════════════════════════════════════════════════
  //  ICRC-2 (Approve + TransferFrom)
  // ═══════════════════════════════════════════════════════

  public type ApproveArgs = {
    from_subaccount : ?Blob;
    spender : Account;
    amount : Nat;
    expected_allowance : ?Nat;
    expires_at : ?Nat64;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type ApproveError = {
    #BadFee : { expected_fee : Nat };
    #InsufficientFunds : { balance : Nat };
    #AllowanceChanged : { current_allowance : Nat };
    #Expired : { ledger_time : Nat64 };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type ApproveResult = { #Ok : Nat; #Err : ApproveError };

  public type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferFromResult = { #Ok : Nat; #Err : TransferFromError };

  // ═══════════════════════════════════════════════════════
  //  ICRC-2 (Allowance query)
  // ═══════════════════════════════════════════════════════

  public type AllowanceArgs = {
    account : Account;
    spender : Account;
  };

  public type Allowance = {
    allowance : Nat;
    expires_at : ?Nat64;
  };

  // ═══════════════════════════════════════════════════════
  //  LEDGER ACTOR INTERFACE
  // ═══════════════════════════════════════════════════════

  // ═══ Two-phase transfer surface of a journal-backed ledger (thebes-ledger-core
  //     TokenLedger). Additive: a legacy ledger is never called with these.
  public type ReserveArgs = {
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
    expires_at : ?Nat64;
  };
  public type ReservationOutcome = { #posted : Nat; #voided : Nat };
  public type ReservationView = { reserver : Principal; from : Account; to : Account; amount : Nat; fee : Nat };

  // ICRC-3 block reads, used to verify that a #Duplicate really names this escrow
  public type Value = {
    #Nat : Nat;
    #Int : Int;
    #Text : Text;
    #Blob : Blob;
    #Array : [Value];
    #Map : [(Text, Value)];
  };
  public type GetBlocksArgs = { start : Nat; length : Nat };
  public type GetBlocksResult = { blocks : [{ id : Nat; block : Value }]; log_length : Nat };

  public type Ledger = actor {
    // ICRC-1
    icrc1_transfer : (TransferArgs) -> async TransferResult;
    icrc1_balance_of : (Account) -> async Nat;
    icrc1_fee : () -> async Nat;

    // ICRC-2
    icrc2_approve : (ApproveArgs) -> async ApproveResult;
    icrc2_transfer_from : (TransferFromArgs) -> async TransferFromResult;
    icrc2_allowance : (AllowanceArgs) -> async Allowance;

    // journal-backed two-phase transfers (TokenLedger above its activation height)
    reserve_transfer : (ReserveArgs) -> async TransferFromResult;
    post_transfer : (Nat) -> async TransferFromResult;
    void_transfer : (Nat) -> async TransferFromResult;
    reservation_outcome : shared query (Nat) -> async ?ReservationOutcome;
    journal_active : shared query () -> async Bool;
    journal_activation_height : shared query () -> async Nat64;
    journal_reservation : shared query (Nat) -> async ?ReservationView;

    // ICRC-3
    icrc3_get_blocks : shared query ([GetBlocksArgs]) -> async GetBlocksResult;
  };
};
