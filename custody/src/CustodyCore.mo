/// CustodyCore.mo: the custody register as commands on a certified log, folded into fixed-width rows: holders,
/// assets, positions as the fold of the venue's receipts (each receipt recorded once), reconciliations,
/// corporate actions with their entitlements struck at the record date in slices and paid on the payment date in
/// slices, the entitlement file certified by its hash. A replay of the log onto a fresh state reproduces every row.
///
/// Authorisation inputs are parameters: who holds a role and who holds a permission are answered by the contract
/// that composes this core over its grant rows.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";

import C "mo:kernel/codec/Canonical";
import DL "mo:kernel/domain/DomainLog";
import Fold "mo:kernel/domain/Fold";
import Cmd "mo:kernel/domain/Command";
import Auth "mo:kernel/auth/AuthTypes";
import Perm "mo:kernel/auth/Permissions";
import MC "mo:kernel/auth/MakerChecker";
import RS "mo:kernel/rows/RowStore";
import Page "mo:kernel/rows/Page";
import R "mo:kernel/rows/StableRows";

import CT "CustodyTypes";
import K "CustodyCanonical";
import M "CustodyMath";

module {

  public type Error = { #custody : CT.Error; #auth : Auth.Error; #encoding : Text };
  public type Result<A> = Result.Result<A, Error>;

  // ═══════════════════════════════════════════════════════
  //  THE PERMISSION CATALOGUE
  // ═══════════════════════════════════════════════════════

  /// A holder is a person's record: dual. An asset and a corporate action bind every holder: dual; a cancellation
  /// and a reconciliation are the custodian's attestations: dual. A settlement is the venue's receipt, recorded
  /// once by its id and hash: single, with the reason recorded. The record date's strike and the payment are sweeps
  /// over rows two roles already signed: single. A subscription is the holder's own act within its rights: single.
  public func catalogue() : Perm.Catalogue { [
    Perm.p("custody.holder.register", "holder", #create, #command("registerHolder"), false, true, true),
    Perm.p("custody.asset.register", "asset", #create, #command("registerAsset"), false, false, true),
    Perm.p("custody.settlement.record", "position", #update, #command("recordSettlement"), false, false, false),
    Perm.p("custody.reconcile", "asset", #approve, #command("reconcile"), false, false, true),
    Perm.p("custody.action.announce", "action", #create, #command("announceAction"), false, false, true),
    Perm.p("custody.action.cancel", "action", #close, #command("cancelAction"), false, false, true),
    Perm.p("custody.action.strike", "action", #update, #command("strikeRecordDate"), false, false, false),
    Perm.p("custody.rights.subscribe", "entitlement", #update, #command("subscribeRights"), false, false, false),
    Perm.p("custody.action.pay", "action", #update, #command("pay"), false, false, false),
    Perm.p("custody.file.certify", "action", #approve, #command("certifyEntitlementFile"), false, false, true),
    Perm.p("command.approve", "command", #approve, #method("approve"), false, false, false),
    Perm.p("command.reject", "command", #reject, #method("reject"), false, false, false),
  ] };
  public func singleActs() : [(Text, Text)] { [
    ("custody.settlement.record", "records a settled movement the venue receipted, by the receipt's id and hash, once; the units and the holders are the receipt's and the caller chooses nothing"),
    ("custody.action.strike", "strikes an announced action's record date over the next slice of holders; every entitlement is computed from the positions and the terms two roles announced"),
    ("custody.rights.subscribe", "takes up rights a holder is entitled to, within them and by the deadline; the holder's own act, paid at the announced price"),
    ("custody.action.pay", "pays a struck action on its payment date over the next slice of entitlements; the units and the cash are the entitlements' and the caller chooses nothing"),
  ] };
  public let commandNames : [Text] = ["registerHolder", "registerAsset", "recordSettlement", "reconcile", "announceAction", "cancelAction", "strikeRecordDate", "subscribeRights", "pay", "certifyEntitlementFile"];
  public let methodNames : [Text] = ["approve", "reject"];
  public func permissionOf(c : CT.Command) : Auth.Permission {
    switch (Perm.byCommand(catalogue(), K.familyOf(c))) { case (?p) p; case null Runtime.trap("catalogue: no permission guards " # K.familyOf(c)) }
  };

  // ═══════════════════════════════════════════════════════
  //  THE ROWS
  // ═══════════════════════════════════════════════════════

  func padded(b : R.Buf, width : Nat) : Blob { while (b.size() < width) R.putByte(b, 0); R.done(b, width) };
  func zero32() : Blob { Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0 })) };
  func putPrincipal(b : R.Buf, p : Principal) { let bs = Principal.toBlob(p); R.putNat(b, bs.size(), 1); for (x in bs.vals()) R.putByte(b, x); var k = bs.size(); while (k < 29) { R.putByte(b, 0); k += 1 } };
  func getPrincipal(a : [Nat8], off : Nat) : Principal { let n = R.getNat(a, off, 1); Principal.fromBlob(R.getBlob(a, off + 1, n)) };

  public type HolderRow = CT.Holder;
  public let HOLDER_ROW_BYTES = 64;   // commit 32, account 1 + 29, pad
  public let holders : RS.Decl<HolderRow> = {
    table = "holders"; idBytes = 8; rowBytes = HOLDER_ROW_BYTES;
    encode = func(h : HolderRow) : Blob { let b = R.buf(); R.putBlob(b, h.commit, 32); putPrincipal(b, h.account); padded(b, HOLDER_ROW_BYTES) };
    decode = func(a : [Nat8]) : HolderRow { { commit = R.getBlob(a, 0, 32); account = getPrincipal(a, 32) } };
    indexes = [];
  };
  public type AssetRow = CT.Asset;
  public let ASSET_ROW_BYTES = 144;   // code 12, name 48, ledger 30, cash 30, supply 8, issuer 8, pad
  public let assets : RS.Decl<AssetRow> = {
    table = "assets"; idBytes = 8; rowBytes = ASSET_ROW_BYTES;
    encode = func(x : AssetRow) : Blob { let b = R.buf(); R.putText(b, x.code, CT.CODE_BYTES); R.putText(b, x.name, CT.NAME_BYTES); putPrincipal(b, x.ledger); putPrincipal(b, x.cashLedger); R.putNat(b, x.issuedSupply, 8); R.putNat(b, x.issuer, 8); padded(b, ASSET_ROW_BYTES) };
    decode = func(a : [Nat8]) : AssetRow { { code = R.getText(a, 0, 12); name = R.getText(a, 12, 48); ledger = getPrincipal(a, 60); cashLedger = getPrincipal(a, 90); issuedSupply = R.getNat(a, 120, 8); issuer = R.getNat(a, 128, 8) } };
    indexes = [{ name = "byCode"; keyBytes = 12; keyOf = func(_ : Nat, x : AssetRow) : ?Blob { ?R.textKey(x.code, CT.CODE_BYTES) } }];
  };
  /// A holder's settled position in an asset (id = a counter; the pair is unique by its index).
  public type PositionRow = { asset : Nat; holder : Nat; units : Nat };
  public let POSITION_ROW_BYTES = 24;
  public func positionKey(asset : Nat, holder : Nat) : Blob { R.key2(asset, 8, holder, 8) };
  public let positions : RS.Decl<PositionRow> = {
    table = "positions"; idBytes = 8; rowBytes = POSITION_ROW_BYTES;
    encode = func(x : PositionRow) : Blob { let b = R.buf(); R.putNat(b, x.asset, 8); R.putNat(b, x.holder, 8); R.putNat(b, x.units, 8); R.done(b, POSITION_ROW_BYTES) };
    decode = func(a : [Nat8]) : PositionRow { { asset = R.getNat(a, 0, 8); holder = R.getNat(a, 8, 8); units = R.getNat(a, 16, 8) } };
    indexes = [{ name = "byAssetHolder"; keyBytes = 16; keyOf = func(_ : Nat, x : PositionRow) : ?Blob { ?positionKey(x.asset, x.holder) } }];
  };
  /// A receipt recorded once: keyed by kind and id.
  public type ReceiptRow = { asset : Nat; kind : CT.ReceiptKind; id : Nat; block : Nat; hash : Blob; from : Nat; to : Nat; units : Nat; day : Nat };
  public let RECEIPT_ROW_BYTES = 96;   // asset 8, kind 1, id 8, block 8, hash 32, from 8, to 8, units 8, day 4, pad
  public func receiptKey(kind : CT.ReceiptKind, id : Nat) : Blob { let b = R.buf(); R.putByte(b, K.receiptKindCode(kind)); R.putNat(b, id, 8); R.done(b, 9) };
  public let receipts : RS.Decl<ReceiptRow> = {
    table = "receipts"; idBytes = 8; rowBytes = RECEIPT_ROW_BYTES;
    encode = func(x : ReceiptRow) : Blob { let b = R.buf(); R.putNat(b, x.asset, 8); R.putByte(b, K.receiptKindCode(x.kind)); R.putNat(b, x.id, 8); R.putNat(b, x.block, 8); R.putBlob(b, x.hash, 32); R.putNat(b, x.from, 8); R.putNat(b, x.to, 8); R.putNat(b, x.units, 8); R.putNat(b, x.day, 4); padded(b, RECEIPT_ROW_BYTES) };
    decode = func(a : [Nat8]) : ReceiptRow { let ?kind = K.receiptKindOf(a[8]) else Runtime.trap("receipt row: bad kind byte"); { asset = R.getNat(a, 0, 8); kind; id = R.getNat(a, 9, 8); block = R.getNat(a, 17, 8); hash = R.getBlob(a, 25, 32); from = R.getNat(a, 57, 8); to = R.getNat(a, 65, 8); units = R.getNat(a, 73, 8); day = R.getNat(a, 81, 4) } };
    indexes = [{ name = "byReceipt"; keyBytes = 9; keyOf = func(_ : Nat, x : ReceiptRow) : ?Blob { ?receiptKey(x.kind, x.id) } }];
  };
  public type ActionRow = CT.Action;
  public let ACTION_ROW_BYTES = 160;   // asset 8, kind 1 + 8 + 8 + 8 + 4, record 4, ex 4, payment 4, source 32, state 1, cursor 8, entitlements 4, cash 8, units 8, hash 1 + 32, firstEntitlement 8, pad
  func encodeAction(x : ActionRow) : Blob {
    let b = R.buf();
    R.putNat(b, x.asset, 8); R.putByte(b, K.kindCode(x.kind));
    switch (x.kind) {
      case (#cashDividend(d)) { R.putNat(b, d.perUnitMicro, 8); R.putNat(b, 0, 8); R.putNat(b, 0, 8); R.putNat(b, 0, 4) };
      case (#split(s)) { R.putNat(b, s.numerator, 8); R.putNat(b, s.denominator, 8); R.putNat(b, s.cashInLieuMicro, 8); R.putNat(b, 0, 4) };
      case (#bonus(s)) { R.putNat(b, s.numerator, 8); R.putNat(b, s.denominator, 8); R.putNat(b, s.cashInLieuMicro, 8); R.putNat(b, 0, 4) };
      case (#rights(r)) { R.putNat(b, r.numerator, 8); R.putNat(b, r.denominator, 8); R.putNat(b, r.subscriptionPriceMicro, 8); R.putNat(b, r.subscriptionDeadline, 4) };
      case (#redemption(r)) { R.putNat(b, r.ratioBps, 8); R.putNat(b, r.pricePerUnitMicro, 8); R.putNat(b, 0, 8); R.putNat(b, 0, 4) };
    };
    R.putNat(b, x.recordDate, 4); R.putNat(b, x.exDate, 4); R.putNat(b, x.paymentDate, 4); R.putBlob(b, x.source, 32); R.putByte(b, K.stateCode(x.state));
    R.putNat(b, x.holderCursor, 8); R.putNat(b, x.entitlements, 4); R.putNat(b, x.cashTotal, 8); R.putNat(b, x.unitsTotal, 8);
    switch (x.fileHash) { case (?h) { R.putByte(b, 1); R.putBlob(b, h, 32) }; case null { R.putByte(b, 0); R.putBlob(b, zero32(), 32) } };
    R.putNat(b, x.firstEntitlement, 8);
    padded(b, ACTION_ROW_BYTES)
  };
  func decodeAction(a : [Nat8]) : ActionRow {
    let kind : CT.Kind = switch (a[8]) {
      case 1 #cashDividend({ perUnitMicro = R.getNat(a, 9, 8) });
      case 2 #split({ numerator = R.getNat(a, 9, 8); denominator = R.getNat(a, 17, 8); cashInLieuMicro = R.getNat(a, 25, 8) });
      case 3 #bonus({ numerator = R.getNat(a, 9, 8); denominator = R.getNat(a, 17, 8); cashInLieuMicro = R.getNat(a, 25, 8) });
      case 4 #rights({ numerator = R.getNat(a, 9, 8); denominator = R.getNat(a, 17, 8); subscriptionPriceMicro = R.getNat(a, 25, 8); subscriptionDeadline = R.getNat(a, 33, 4) });
      case 5 #redemption({ ratioBps = R.getNat(a, 9, 8); pricePerUnitMicro = R.getNat(a, 17, 8) });
      case _ Runtime.trap("action row: bad kind byte");
    };
    let ?state = K.stateOf(a[81]) else Runtime.trap("action row: bad state byte");
    { asset = R.getNat(a, 0, 8); kind; recordDate = R.getNat(a, 37, 4); exDate = R.getNat(a, 41, 4); paymentDate = R.getNat(a, 45, 4); source = R.getBlob(a, 49, 32); state;
      holderCursor = R.getNat(a, 82, 8); entitlements = R.getNat(a, 90, 4); cashTotal = R.getNat(a, 94, 8); unitsTotal = R.getNat(a, 102, 8); fileHash = if (a[110] == 1) ?R.getBlob(a, 111, 32) else null; firstEntitlement = R.getNat(a, 143, 8); cancelReason = null }
  };
  public let actions : RS.Decl<ActionRow> = {
    table = "actions"; idBytes = 8; rowBytes = ACTION_ROW_BYTES; encode = encodeAction; decode = decodeAction;
    // the actions of an asset not yet paid or cancelled: one at a time per asset
    indexes = [{ name = "openByAsset"; keyBytes = 16; keyOf = func(id : Nat, x : ActionRow) : ?Blob { switch (x.state) { case (#announced or #struck) ?R.key2(x.asset, 8, id, 8); case (_) null } } }];
  };
  public type EntitlementRow = CT.Entitlement;
  public let ENTITLEMENT_ROW_BYTES = 80;   // action 8, holder 8, unitsAtRecord 8, cashDue 8, cashPayable 8, unitsDue 8, unitsTaken 8, rights 6, rightsTaken 6, fraction 6, paid 1, pad
  public let entitlements : RS.Decl<EntitlementRow> = {
    table = "entitlements"; idBytes = 8; rowBytes = ENTITLEMENT_ROW_BYTES;
    encode = func(e : EntitlementRow) : Blob { let b = R.buf(); R.putNat(b, e.action, 8); R.putNat(b, e.holder, 8); R.putNat(b, e.unitsAtRecord, 8); R.putNat(b, e.cashDue, 8); R.putNat(b, e.cashPayable, 8); R.putNat(b, e.unitsDue, 8); R.putNat(b, e.unitsTaken, 8); R.putNat(b, e.rights, 6); R.putNat(b, e.rightsTaken, 6); R.putNat(b, e.fractionUnits, 6); R.putBool(b, e.paid); padded(b, ENTITLEMENT_ROW_BYTES) };
    decode = func(a : [Nat8]) : EntitlementRow { { action = R.getNat(a, 0, 8); holder = R.getNat(a, 8, 8); unitsAtRecord = R.getNat(a, 16, 8); cashDue = R.getNat(a, 24, 8); cashPayable = R.getNat(a, 32, 8); unitsDue = R.getNat(a, 40, 8); unitsTaken = R.getNat(a, 48, 8); rights = R.getNat(a, 56, 6); rightsTaken = R.getNat(a, 62, 6); fractionUnits = R.getNat(a, 68, 6); paid = R.getBool(a, 74) } };
    indexes = [{ name = "byAction"; keyBytes = 16; keyOf = func(_ : Nat, e : EntitlementRow) : ?Blob { ?R.key2(e.action, 8, e.holder, 8) } }];
  };
  public type ReconciliationRow = CT.Reconciliation;
  public let RECONCILIATION_ROW_BYTES = 96;   // asset 8, day 4, block 8, holders 4, positions 8, supply 8, matched 4, breaks 4, hash 32, pad
  public let reconciliations : RS.Decl<ReconciliationRow> = {
    table = "reconciliations"; idBytes = 8; rowBytes = RECONCILIATION_ROW_BYTES;
    encode = func(x : ReconciliationRow) : Blob { let b = R.buf(); R.putNat(b, x.asset, 8); R.putNat(b, x.day, 4); R.putNat(b, x.ledgerBlock, 8); R.putNat(b, x.holders, 4); R.putNat(b, x.positionsTotal, 8); R.putNat(b, x.issuedSupply, 8); R.putNat(b, x.matched, 4); R.putNat(b, x.breaks, 4); R.putBlob(b, x.hash, 32); padded(b, RECONCILIATION_ROW_BYTES) };
    decode = func(a : [Nat8]) : ReconciliationRow { { asset = R.getNat(a, 0, 8); day = R.getNat(a, 8, 4); ledgerBlock = R.getNat(a, 12, 8); holders = R.getNat(a, 20, 4); positionsTotal = R.getNat(a, 24, 8); issuedSupply = R.getNat(a, 32, 8); matched = R.getNat(a, 40, 4); breaks = R.getNat(a, 44, 4); hash = R.getBlob(a, 48, 32) } };
    indexes = [];
  };
  public type ProposalRow = MC.ProposalRow;
  public let proposals : RS.Decl<ProposalRow> = {
    table = "proposals"; idBytes = 8; rowBytes = MC.PROPOSAL_ROW_BYTES; encode = MC.encodeProposalRow;
    decode = func(a : [Nat8]) : ProposalRow { MC.decodeProposalRow(Blob.fromArray(a)) };
    indexes = [{ name = "awaiting"; keyBytes = 8; keyOf = func(id : Nat, r : ProposalRow) : ?Blob { switch (r.status) { case (#awaiting) ?R.key(id, 8); case (_) null } } }];
  };
  public func checkSums() : Bool {
    32 + 30 <= HOLDER_ROW_BYTES and 12 + 48 + 30 + 30 + 8 + 8 == 136 and 136 <= ASSET_ROW_BYTES and 8 * 3 == POSITION_ROW_BYTES
    and 8 + 1 + 8 + 8 + 32 + 8 + 8 + 8 + 4 == 85 and 85 <= RECEIPT_ROW_BYTES
    and 8 + 1 + 8 + 8 + 8 + 4 + 4 + 4 + 4 + 32 + 1 + 8 + 4 + 8 + 8 + 1 + 32 + 8 == 151 and 151 <= ACTION_ROW_BYTES
    and 8 * 7 + 6 * 3 + 1 == 75 and 75 <= ENTITLEMENT_ROW_BYTES
    and 8 + 4 + 8 + 4 + 8 + 8 + 4 + 4 + 32 == 80 and 80 <= RECONCILIATION_ROW_BYTES
  };

  // ═══════════════════════════════════════════════════════
  //  THE STATE
  // ═══════════════════════════════════════════════════════

  public type State = {
    log : DL.State;
    holderRows : RS.Store; assetRows : RS.Store; positionRows : RS.Store; receiptRows : RS.Store; actionRows : RS.Store; entitlementRows : RS.Store; reconciliationRows : RS.Store; proposalRows : RS.Store;
    var holderBound : Nat; var nextAsset : Nat; var nextPosition : Nat; var nextReceipt : Nat; var nextAction : Nat; var nextEntitlement : Nat; var nextReconciliation : Nat;
    var policies : [Auth.DualPolicy];
  };
  public func newState() : State { newStateOver(DL.newState()) };
  public func newStateOver(log : DL.State) : State {
    { log; holderRows = RS.newStore(holders); assetRows = RS.newStore(assets); positionRows = RS.newStore(positions); receiptRows = RS.newStore(receipts); actionRows = RS.newStore(actions); entitlementRows = RS.newStore(entitlements); reconciliationRows = RS.newStore(reconciliations); proposalRows = RS.newStore(proposals);
      var holderBound = 1; var nextAsset = 1; var nextPosition = 1; var nextReceipt = 1; var nextAction = 1; var nextEntitlement = 1; var nextReconciliation = 1; var policies = [] }
  };
  public func setPolicies(s : State, ps : [Auth.DualPolicy]) { s.policies := ps };
  func policyFor(s : State, permission : Text) : ?Auth.DualPolicy { Array.find<Auth.DualPolicy>(s.policies, func(p) { p.permission == permission }) };

  // ─── reads ──────────────────────────────────────────────────────────────────────────────

  func one<Rw>(store : RS.Store, decl : RS.Decl<Rw>, index : Text, key : Blob) : ?(Nat, Rw) {
    switch (RS.page(store, decl, index, key, key, null, 1)) { case (#ok(p)) { if (p.rows.size() == 0) null else ?p.rows[0] }; case (#err(_)) null }
  };
  public func holder(s : State, id : CT.HolderId) : ?HolderRow { RS.get(s.holderRows, holders, id) };
  public func asset(s : State, id : CT.AssetId) : ?AssetRow { RS.get(s.assetRows, assets, id) };
  public func assetByCode(s : State, code : Text) : ?(CT.AssetId, AssetRow) { if (Text.encodeUtf8(code).size() == 0 or Text.encodeUtf8(code).size() > CT.CODE_BYTES) return null; one(s.assetRows, assets, "byCode", R.textKey(code, CT.CODE_BYTES)) };
  public func position(s : State, a : CT.AssetId, h : CT.HolderId) : Nat { switch (one(s.positionRows, positions, "byAssetHolder", positionKey(a, h))) { case (?(_, p)) p.units; case null 0 } };
  public func positionsOf(s : State, a : CT.AssetId, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, PositionRow)> { let (lo, hi) = R.prefixRange(a, 8, 8); RS.page(s.positionRows, positions, "byAssetHolder", lo, hi, cursor, limit) };
  public func receipt(s : State, kind : CT.ReceiptKind, id : Nat) : ?(Nat, ReceiptRow) { one(s.receiptRows, receipts, "byReceipt", receiptKey(kind, id)) };
  public func receiptById(s : State, id : Nat) : ?ReceiptRow { RS.get(s.receiptRows, receipts, id) };
  public func action(s : State, id : CT.ActionId) : ?ActionRow { RS.get(s.actionRows, actions, id) };
  /// The asset's open action, if any. A page stops at its scan budget and may hold no row while the range still does
  /// (entries of actions since paid or cancelled), so the walk follows the cursor until a row or the end of the range.
  public func openActionOf(s : State, a : CT.AssetId) : ?CT.ActionId {
    let (lo, hi) = R.prefixRange(a, 8, 8);
    var cursor : ?Page.Cursor = null;
    loop {
      switch (RS.page(s.actionRows, actions, "openByAsset", lo, hi, cursor, 1)) {
        case (#ok(p)) {
          if (p.rows.size() > 0) return ?p.rows[0].0;
          switch (p.next) { case (?n) cursor := ?n; case null return null };
        };
        case (#err(_)) return null;
      };
    };
  };
  public func entitlement(s : State, id : Nat) : ?EntitlementRow { RS.get(s.entitlementRows, entitlements, id) };
  public func entitlementOf(s : State, act : CT.ActionId, h : CT.HolderId) : ?(Nat, EntitlementRow) { one(s.entitlementRows, entitlements, "byAction", R.key2(act, 8, h, 8)) };
  public func entitlementsOf(s : State, act : CT.ActionId, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, EntitlementRow)> { let (lo, hi) = R.prefixRange(act, 8, 8); RS.page(s.entitlementRows, entitlements, "byAction", lo, hi, cursor, limit) };
  public func reconciliation(s : State, id : Nat) : ?ReconciliationRow { RS.get(s.reconciliationRows, reconciliations, id) };
  public func awaitingProposals(s : State, cursor : ?Page.Cursor, limit : Nat) : Page.Result<(Nat, ProposalRow)> { let (lo, hi) = R.fullRange(8); RS.page(s.proposalRows, proposals, "awaiting", lo, hi, cursor, limit) };
  /// The sum of every holder's position in an asset: the register's own supply.
  public func positionsTotal(s : State, a : CT.AssetId) : Nat {
    var total = 0; var cursor : ?Page.Cursor = null;
    label walk loop {
      switch (positionsOf(s, a, cursor, 1_000)) { case (#ok(p)) { for ((_, r) in p.rows.vals()) total += r.units; switch (p.next) { case (?n) cursor := ?n; case null break walk } }; case (#err(_)) break walk }
    };
    total
  };
  /// The entitlement file's lines in holder order.
  public func fileLines(s : State, act : CT.ActionId) : [K.FileLine] {
    let out = List.empty<K.FileLine>(); var cursor : ?Page.Cursor = null;
    label walk loop {
      switch (entitlementsOf(s, act, cursor, 1_000)) {
        case (#ok(p)) { for ((_, e) in p.rows.vals()) List.add(out, { holder = e.holder; unitsAtRecord = e.unitsAtRecord; cashDue = e.cashDue; cashPayable = e.cashPayable; unitsDue = e.unitsDue; unitsTaken = e.unitsTaken; rights = e.rights; rightsTaken = e.rightsTaken; fractionUnits = e.fractionUnits }); switch (p.next) { case (?n) cursor := ?n; case null break walk } };
        case (#err(_)) break walk;
      }
    };
    List.toArray(out)
  };

  // ═══════════════════════════════════════════════════════
  //  VALIDATION
  // ═══════════════════════════════════════════════════════

  func textFits(field : Text, t : Text, max : Nat) : ?CT.Error {
    let n = Text.encodeUtf8(t).size();
    if (n == 0) return ?#InvalidText({ field; reason = "empty" });
    if (n > max) return ?#InvalidText({ field; reason = "longer than " # Nat.toText(max) # " bytes" });
    null
  };
  func ratioOk(n : Nat, d : Nat) : Bool { n > 0 and d > 0 };

  public func validate(s : State, c : CT.Command) : ?CT.Error {
    switch (c) {
      case (#registerHolder(x)) {
        if (x.holder == 0) return ?#InvalidTerms({ reason = "a holder id is above zero" });
        if (holder(s, x.holder) != null) return ?#DuplicateHolder(x.holder);
        if (x.commit.size() != 32) return ?#InvalidCommitment({ field = "commit" });
        null
      };
      case (#registerAsset(x)) {
        switch (textFits("code", x.code, CT.CODE_BYTES)) { case (?e) return ?e; case null {} };
        switch (textFits("name", x.name, CT.NAME_BYTES)) { case (?e) return ?e; case null {} };
        if (assetByCode(s, x.code) != null) return ?#DuplicateAsset(x.code);
        if (holder(s, x.issuer) == null) return ?#UnknownHolder(x.issuer);
        if (x.issuedSupply == 0) return ?#InvalidAmount({ field = "issuedSupply" });
        null
      };
      case (#recordSettlement(x)) {
        if (asset(s, x.asset) == null) return ?#UnknownAsset(x.asset);
        if (holder(s, x.from) == null) return ?#UnknownHolder(x.from);
        if (holder(s, x.to) == null) return ?#UnknownHolder(x.to);
        if (x.units == 0) return ?#InvalidAmount({ field = "units" });
        if (x.receipt.hash.size() != 32) return ?#InvalidCommitment({ field = "receipt.hash" });
        if (receipt(s, x.receipt.kind, x.receipt.id) != null) return ?#ReceiptRecorded({ kind = x.receipt.kind; id = x.receipt.id });
        let held = position(s, x.asset, x.from);
        if (held < x.units) return ?#PositionShort({ asset = x.asset; holder = x.from; held; wanted = x.units });
        // a movement on or after an open action's record date would move an entitlement already struck
        switch (openActionOf(s, x.asset)) { case (?aid) { switch (action(s, aid)) { case (?a) { if (a.state == #struck and x.day <= a.paymentDate) return ?#ActionOpenOnAsset({ asset = x.asset; action = aid }) }; case null {} } }; case null {} };
        null
      };
      case (#reconcile(x)) {
        if (asset(s, x.asset) == null) return ?#UnknownAsset(x.asset);
        if (x.balances.size() > CT.MAX_RECONCILE) return ?#TooManyHolders({ max = CT.MAX_RECONCILE });
        var i = 0;
        while (i < x.balances.size()) {
          if (holder(s, x.balances[i].0) == null) return ?#UnknownHolder(x.balances[i].0);
          var j = i + 1;
          while (j < x.balances.size()) { if (x.balances[j].0 == x.balances[i].0) return ?#InvalidTerms({ reason = "a holder twice in the balances" }); j += 1 };
          i += 1;
        };
        null
      };
      case (#announceAction(x)) {
        if (asset(s, x.asset) == null) return ?#UnknownAsset(x.asset);
        switch (openActionOf(s, x.asset)) { case (?aid) return ?#ActionOpenOnAsset({ asset = x.asset; action = aid }); case null {} };
        if (x.source.size() != 32) return ?#InvalidCommitment({ field = "source" });
        if (x.exDate > x.recordDate) return ?#InvalidDay({ field = "exDate"; reason = "after the record date" });
        if (x.paymentDate < x.recordDate) return ?#InvalidDay({ field = "paymentDate"; reason = "before the record date" });
        switch (x.kind) {
          case (#cashDividend(d)) { if (d.perUnitMicro == 0) return ?#InvalidTerms({ reason = "a dividend of nothing" }) };
          case (#split(sp)) { if (not ratioOk(sp.numerator, sp.denominator) or sp.numerator == sp.denominator) return ?#InvalidTerms({ reason = "a split's ratio is above zero and not one" }) };
          case (#bonus(bn)) { if (not ratioOk(bn.numerator, bn.denominator)) return ?#InvalidTerms({ reason = "a bonus ratio is above zero" }) };
          case (#rights(rg)) { if (not ratioOk(rg.numerator, rg.denominator) or rg.subscriptionPriceMicro == 0) return ?#InvalidTerms({ reason = "rights need a ratio above zero and a price" }); if (rg.subscriptionDeadline < x.recordDate or rg.subscriptionDeadline > x.paymentDate) return ?#InvalidDay({ field = "subscriptionDeadline"; reason = "between the record date and the payment date" }) };
          case (#redemption(rd)) { if (rd.ratioBps == 0 or rd.ratioBps > M.BPS or rd.pricePerUnitMicro == 0) return ?#InvalidTerms({ reason = "a redemption ratio is 1..10000 bps with a price" }) };
        };
        null
      };
      case (#cancelAction(x)) {
        let ?a = action(s, x.action) else return ?#UnknownAction(x.action);
        if (a.state != #announced and a.state != #struck) return ?#ActionNotIn({ action = x.action; state = a.state });
        if (x.day < a.recordDate and a.state == #struck) return ?#InvalidDay({ field = "day"; reason = "before the record date" });
        textFits("reason", x.reason, 512)
      };
      case (#strikeRecordDate(x)) {
        let ?a = action(s, x.action) else return ?#UnknownAction(x.action);
        if (a.state != #announced) return ?#ActionNotIn({ action = x.action; state = a.state });
        if (x.limit == 0 or x.limit > CT.MAX_SLICE) return ?#InvalidLimit(x.limit);
        null
      };
      case (#subscribeRights(x)) {
        let ?a = action(s, x.action) else return ?#UnknownAction(x.action);
        let #rights(rg) = a.kind else return ?#NotRights(x.action);
        if (a.state != #struck) return ?#ActionNotIn({ action = x.action; state = a.state });
        if (x.rights == 0) return ?#InvalidAmount({ field = "rights" });
        if (x.day > rg.subscriptionDeadline) return ?#SubscriptionClosed({ action = x.action; deadline = rg.subscriptionDeadline; day = x.day });
        let ?(_, e) = entitlementOf(s, x.action, x.holder) else return ?#NoEntitlement({ action = x.action; holder = x.holder });
        if (e.rightsTaken + x.rights > e.rights) return ?#ExceedsRights({ action = x.action; holder = x.holder; rights = e.rights; taken = e.rightsTaken; wanted = x.rights });
        null
      };
      case (#pay(x)) {
        let ?a = action(s, x.action) else return ?#UnknownAction(x.action);
        if (a.state != #struck) return ?#ActionNotIn({ action = x.action; state = a.state });
        if (x.day < a.paymentDate) return ?#InvalidDay({ field = "day"; reason = "before the payment date" });
        if (x.limit == 0 or x.limit > CT.MAX_SLICE) return ?#InvalidLimit(x.limit);
        null
      };
      case (#certifyEntitlementFile(x)) {
        let ?a = action(s, x.action) else return ?#UnknownAction(x.action);
        if (a.state != #paid) return ?#ActionNotIn({ action = x.action; state = a.state });
        if (a.fileHash != null) return ?#ActionNotIn({ action = x.action; state = a.state });
        if (x.day < a.paymentDate) return ?#InvalidDay({ field = "day"; reason = "before the payment date" });
        null
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  APPLY
  // ═══════════════════════════════════════════════════════

  func move(s : State, a : CT.AssetId, h : CT.HolderId, delta : Int) {
    switch (one(s.positionRows, positions, "byAssetHolder", positionKey(a, h))) {
      case (?(id, p)) { let next : Int = p.units + delta; if (next < 0) Runtime.trap("apply: a position below zero after validation"); RS.put(s.positionRows, positions, id, { p with units = Int.abs(next) }) };
      case null { if (delta < 0) Runtime.trap("apply: a position below zero after validation"); let id = s.nextPosition; s.nextPosition += 1; RS.put(s.positionRows, positions, id, { asset = a; holder = h; units = Int.abs(delta) }) };
    }
  };

  func apply(s : State, c : CT.Command) : CT.Effects {
    switch (c) {
      case (#registerHolder(x)) { RS.put(s.holderRows, holders, x.holder, { commit = x.commit; account = x.account }); if (x.holder + 1 > s.holderBound) s.holderBound := x.holder + 1; [x.holder] };
      case (#registerAsset(x)) {
        let id = s.nextAsset; s.nextAsset += 1;
        RS.put(s.assetRows, assets, id, { code = x.code; name = x.name; ledger = x.ledger; cashLedger = x.cashLedger; issuedSupply = x.issuedSupply; issuer = x.issuer });
        // the issued supply opens in the issuer's position: every later movement is a receipt
        move(s, id, x.issuer, x.issuedSupply);
        [id]
      };
      case (#recordSettlement(x)) {
        let id = s.nextReceipt; s.nextReceipt += 1;
        RS.put(s.receiptRows, receipts, id, { asset = x.asset; kind = x.receipt.kind; id = x.receipt.id; block = x.receipt.block; hash = x.receipt.hash; from = x.from; to = x.to; units = x.units; day = x.day });
        move(s, x.asset, x.from, -x.units); move(s, x.asset, x.to, x.units);
        [id]
      };
      case (#reconcile(x)) {
        let ?a = asset(s, x.asset) else Runtime.trap("apply: the asset vanished after validation");
        var matched = 0; var breaks = 0;
        let rows = List.empty<(Nat, Nat, Nat)>();
        let sorted = Array.sort<(Nat, Nat)>(x.balances, func(p, q) { Nat.compare(p.0, q.0) });
        for ((h, bal) in sorted.vals()) { let p = position(s, x.asset, h); if (p == bal) matched += 1 else breaks += 1; List.add(rows, (h, p, bal)) };
        // the register's total equals the issued supply by construction (the supply opens in the issuer's position, a
        // receipt conserves units, a paid action moves the supply by the units it created or took back): the two are
        // recorded side by side for the Authority's reader, and no break can arise between them
        let total = positionsTotal(s, x.asset);
        let id = s.nextReconciliation; s.nextReconciliation += 1;
        RS.put(s.reconciliationRows, reconciliations, id, { asset = x.asset; day = x.day; ledgerBlock = x.ledgerBlock; holders = sorted.size(); positionsTotal = total; issuedSupply = a.issuedSupply; matched; breaks; hash = K.reconciliationHash(K.reconciliationBytes(x.asset, x.day, x.ledgerBlock, List.toArray(rows))) });
        [id, breaks]
      };
      case (#announceAction(x)) {
        let id = s.nextAction; s.nextAction += 1;
        RS.put(s.actionRows, actions, id, { asset = x.asset; kind = x.kind; recordDate = x.recordDate; exDate = x.exDate; paymentDate = x.paymentDate; source = x.source; state = #announced; holderCursor = 1; firstEntitlement = 0; entitlements = 0; cashTotal = 0; unitsTotal = 0; fileHash = null; cancelReason = null });
        [id]
      };
      case (#cancelAction(x)) { let ?a = action(s, x.action) else Runtime.trap("apply: unknown action after validation"); RS.put(s.actionRows, actions, x.action, { a with state = #cancelled; cancelReason = ?x.reason }); [x.action] };
      case (#strikeRecordDate(x)) {
        let ?a = action(s, x.action) else Runtime.trap("apply: unknown action after validation");
        var hc = a.holderCursor; var done = 0; var n = a.entitlements; var cash = a.cashTotal; var units = a.unitsTotal;
        let first = if (a.entitlements == 0) s.nextEntitlement else a.firstEntitlement;
        while (done < x.limit and hc < s.holderBound) {
          if (holder(s, hc) != null) {
            let held = position(s, a.asset, hc);
            if (held > 0) {
              let e = M.entitlement(a.kind, held);
              let id = s.nextEntitlement; s.nextEntitlement += 1;
              RS.put(s.entitlementRows, entitlements, id, { action = x.action; holder = hc; unitsAtRecord = held; cashDue = e.cashDue; cashPayable = 0; unitsDue = e.unitsDue; unitsTaken = 0; rights = e.rights; rightsTaken = 0; fractionUnits = e.fractionUnits; paid = false });
              n += 1; cash += e.cashDue; units += e.unitsDue;
            };
          };
          hc += 1; done += 1;
        };
        let finished = hc >= s.holderBound;
        RS.put(s.actionRows, actions, x.action, { a with holderCursor = if (finished) first else hc; firstEntitlement = first; entitlements = n; cashTotal = cash; unitsTotal = units; state = if (finished) #struck else #announced });
        [x.action, done]
      };
      case (#subscribeRights(x)) {
        let ?a = action(s, x.action) else Runtime.trap("apply: unknown action after validation");
        let #rights(rg) = a.kind else Runtime.trap("apply: not a rights action after validation");
        let ?(id, e) = entitlementOf(s, x.action, x.holder) else Runtime.trap("apply: no entitlement after validation");
        let pay = M.subscription(x.rights, rg.subscriptionPriceMicro);
        RS.put(s.entitlementRows, entitlements, id, { e with rightsTaken = e.rightsTaken + x.rights; unitsDue = e.unitsDue + x.rights; cashPayable = e.cashPayable + pay });
        RS.put(s.actionRows, actions, x.action, { a with unitsTotal = a.unitsTotal + x.rights });
        [id, pay]
      };
      case (#pay(x)) {
        let ?a = action(s, x.action) else Runtime.trap("apply: unknown action after validation");
        // the payment sweeps the action's entitlements, consecutive from the first, the cursor on the row
        var cursor = a.holderCursor; var done = 0;
        let last = a.firstEntitlement + a.entitlements;
        while (done < x.limit and cursor < last) {
          switch (entitlement(s, cursor)) {
            case (?e) {
              if (e.action == x.action and not e.paid) {
                switch (a.kind) {
                  case (#split(_)) { move(s, a.asset, e.holder, -e.unitsAtRecord); move(s, a.asset, e.holder, e.unitsDue) };
                  case (#bonus(_) or #rights(_)) { if (e.unitsDue > 0) move(s, a.asset, e.holder, e.unitsDue) };
                  case (#redemption(_)) { if (e.unitsDue > 0) move(s, a.asset, e.holder, -e.unitsDue) };
                  case (#cashDividend(_)) {};
                };
                RS.put(s.entitlementRows, entitlements, cursor, { e with unitsTaken = e.unitsDue; paid = true });
              };
            };
            case null {};
          };
          cursor += 1; done += 1;
        };
        let finished = cursor >= last;
        if (finished) {
          // the issued supply follows the units the action created or took back
          let ?as = asset(s, a.asset) else Runtime.trap("apply: the asset vanished after validation");
          let supply : Int = switch (a.kind) {
            case (#split(_)) { var v : Int = as.issuedSupply; var cur : ?Page.Cursor = null; label walk loop { switch (entitlementsOf(s, x.action, cur, 1_000)) { case (#ok(p)) { for ((_, e) in p.rows.vals()) { v := v - e.unitsAtRecord + e.unitsDue }; switch (p.next) { case (?nx) cur := ?nx; case null break walk } }; case (#err(_)) break walk } }; v };
            case (#bonus(_) or #rights(_)) as.issuedSupply + a.unitsTotal;
            case (#redemption(_)) as.issuedSupply - a.unitsTotal;
            case (#cashDividend(_)) as.issuedSupply;
          };
          RS.put(s.assetRows, assets, a.asset, { as with issuedSupply = Int.abs(supply) });
        };
        RS.put(s.actionRows, actions, x.action, { a with holderCursor = cursor; state = if (finished) #paid else #struck });
        [x.action, done]
      };
      case (#certifyEntitlementFile(x)) {
        let ?a = action(s, x.action) else Runtime.trap("apply: unknown action after validation");
        let h = K.fileHash(K.fileBytes(x.action, a.asset, a.kind, a.recordDate, a.paymentDate, fileLines(s, x.action)));
        RS.put(s.actionRows, actions, x.action, { a with fileHash = ?h });
        [x.action]
      };
    }
  };

  // ═══════════════════════════════════════════════════════
  //  THE LIFECYCLE
  // ═══════════════════════════════════════════════════════

  public type Authority = { hasGrant : (Principal, Auth.PermissionId) -> Bool; holdsRole : (Principal, Auth.RoleId) -> Bool };
  public type Outcome = { #executed : { block : Nat; effects : CT.Effects }; #proposed : { proposal : Cmd.ProposalId; required : Nat } };
  func appendExecuted(s : State, now : Nat64, caller : Principal, proposal : ?Cmd.ProposalId, version : Nat8, c : CT.Command) : (Nat, CT.Effects) {
    let effects = apply(s, c);
    let b = DL.append(s.log, K.codec, now, caller, #executed({ proposal; version; command = c; effects }), null);
    (b.index, effects)
  };
  public func submit(s : State, auth : Authority, now : Nat64, caller : Principal, c : CT.Command, partition : ?Text, justification : Text) : Result<Outcome> {
    let perm = permissionOf(c);
    if (not auth.hasGrant(caller, perm.id)) return #err(#auth(#NoGrant({ permission = perm.id })));
    switch (validate(s, c)) { case (?e) return #err(#custody(e)); case null {} };
    switch (MC.resolvePolicy(perm, policyFor(s, perm.id))) {
      case (#refuse(e)) #err(#auth(e));
      case (#single) { let (block, effects) = appendExecuted(s, now, caller, null, K.registry.current, c); #ok(#executed({ block; effects })) };
      case (#dual(policy)) {
        let ?bound = Cmd.bind(K.registry, c) else return #err(#encoding("the current encoding cannot represent this command"));
        let p : Cmd.Proposed = { permission = perm.id; partition; maker = caller; required = policy.required; eligibleRole = policy.eligibleRole; expiresAt = now + Nat64.fromNat(policy.ttlSeconds) * 1_000_000_000; justification; commandHash = bound.commandHash; commandEncoding = bound.commandEncoding };
        let trailer = Cmd.trailerWithBody(K.registry, bound.commandEncoding, c);
        let b = DL.append(s.log, K.codec, now, caller, #proposed(p), trailer);
        RS.put(s.proposalRows, proposals, b.index, { expiresAt = p.expiresAt; status = #awaiting; approvalBlocks = [] });
        #ok(#proposed({ proposal = b.index; required = policy.required }))
      };
    }
  };
  public func proposal(s : State, id : Cmd.ProposalId) : ?MC.Entry {
    let ?row = RS.get(s.proposalRows, proposals, id) else return null;
    let ?b = DL.get(s.log, K.codec, id) else return null;
    let #proposed(p) = b.event else return null;
    let approvals = Array.map<Nat, Principal>(row.approvalBlocks, func(i) { switch (DL.get(s.log, K.codec, i)) { case (?ab) ab.caller; case null Principal.fromText("aaaaa-aa") } });
    let status : MC.Status = switch (row.status) {
      case (#awaiting) #awaiting;
      case (#executed(at)) { let effects = switch (DL.get(s.log, K.codec, at)) { case (?xb) { switch (xb.event) { case (#executed(x)) x.effects; case (_) [] } }; case null [] }; #executed({ at; effects }) };
      case (#rejected(at)) { switch (DL.get(s.log, K.codec, at)) { case (?rb) { switch (rb.event) { case (#rejected(x)) #rejected({ by = x.checker; reason = x.reason }); case (_) #rejected({ by = b.caller; reason = "" }) } }; case null #rejected({ by = b.caller; reason = "" }) } };
      case (#expired(_)) #expired;
    };
    ?{ index = id; commandHash = p.commandHash; commandEncoding = p.commandEncoding; permission = p.permission; partition = p.partition; maker = p.maker; required = p.required; eligibleRole = p.eligibleRole; expiresAt = p.expiresAt; justification = p.justification; approvals; status }
  };
  public func proposedCommand(s : State, id : Cmd.ProposalId) : ?CT.Command {
    let ?b = DL.get(s.log, K.codec, id) else return null;
    let #proposed(p) = b.event else return null;
    Cmd.bodyOf(K.registry, p, b.trailer)
  };
  public func approve(s : State, auth : Authority, now : Nat64, checker : Principal, id : Cmd.ProposalId) : Result<Outcome> {
    if (not auth.hasGrant(checker, "command.approve")) return #err(#auth(#NoGrant({ permission = "command.approve" })));
    let ?e = proposal(s, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    switch (MC.checkApprover(e, checker, auth.holdsRole(checker, e.eligibleRole), now)) { case (?err) return #err(#auth(err)); case null {} };
    let ?c = proposedCommand(s, id) else return #err(#auth(#CommandHashMismatch({ index = id })));
    let ?b = DL.get(s.log, K.codec, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let #proposed(p) = b.event else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    if (not Cmd.matches(K.registry, p, c)) return #err(#auth(#CommandHashMismatch({ index = id })));
    let ?row = RS.get(s.proposalRows, proposals, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let ab = DL.append(s.log, K.codec, now, checker, #approved({ proposal = id; checker; commandHash = p.commandHash }), null);
    let approvalBlocks = Array.concat<Nat>(row.approvalBlocks, [ab.index]);
    if (approvalBlocks.size() < e.required) { RS.put(s.proposalRows, proposals, id, { row with approvalBlocks }); return #ok(#proposed({ proposal = id; required = e.required })) };
    switch (validate(s, c)) {
      case (?err) {
        let rb = DL.append(s.log, K.codec, now, checker, #rejected({ proposal = id; checker; reason = "no longer valid at execution: " # debug_show(err) }), null);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #rejected(rb.index) });
        #err(#custody(err))
      };
      case null {
        let (block, effects) = appendExecuted(s, now, checker, ?id, p.commandEncoding, c);
        RS.put(s.proposalRows, proposals, id, { row with approvalBlocks; status = #executed(block) });
        #ok(#executed({ block; effects }))
      };
    }
  };
  public func reject(s : State, auth : Authority, now : Nat64, checker : Principal, id : Cmd.ProposalId, reason : Text) : Result<()> {
    if (not auth.hasGrant(checker, "command.reject")) return #err(#auth(#NoGrant({ permission = "command.reject" })));
    let ?e = proposal(s, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    switch (MC.checkApprover(e, checker, auth.holdsRole(checker, e.eligibleRole), now)) { case (?err) return #err(#auth(err)); case null {} };
    let ?row = RS.get(s.proposalRows, proposals, id) else return #err(#auth(#ProposalNotAwaiting({ index = id })));
    let rb = DL.append(s.log, K.codec, now, checker, #rejected({ proposal = id; checker; reason }), null);
    RS.put(s.proposalRows, proposals, id, { row with status = #rejected(rb.index) });
    #ok(())
  };
  public func expire(s : State, now : Nat64, caller : Principal, limit : Nat) : Nat {
    var n = 0;
    switch (awaitingProposals(s, null, limit)) {
      case (#ok(p)) { for ((id, row) in p.rows.vals()) { if (row.expiresAt <= now) { let xb = DL.append(s.log, K.codec, now, caller, #expired({ proposal = id }), null); RS.put(s.proposalRows, proposals, id, { row with status = #expired(xb.index) }); n += 1 } } };
      case (#err(_)) {};
    };
    n
  };

  // ═══════════════════════════════════════════════════════
  //  THE FOLD
  // ═══════════════════════════════════════════════════════

  func applyBlock(s : State, b : DL.Block<K.Event>) {
    switch (b.event) {
      case (#proposed(p)) RS.put(s.proposalRows, proposals, b.index, { expiresAt = p.expiresAt; status = #awaiting; approvalBlocks = [] });
      case (#approved(a)) { switch (RS.get(s.proposalRows, proposals, a.proposal)) { case (?row) RS.put(s.proposalRows, proposals, a.proposal, { row with approvalBlocks = Array.concat<Nat>(row.approvalBlocks, [b.index]) }); case null {} } };
      case (#rejected(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #rejected(b.index) }); case null {} } };
      case (#expired(x)) { switch (RS.get(s.proposalRows, proposals, x.proposal)) { case (?row) RS.put(s.proposalRows, proposals, x.proposal, { row with status = #expired(b.index) }); case null {} } };
      case (#executed(x)) {
        let effects = apply(s, x.command);
        switch (x.proposal) { case (?id) { switch (RS.get(s.proposalRows, proposals, id)) { case (?row) RS.put(s.proposalRows, proposals, id, { row with status = #executed(b.index) }); case null {} } }; case null {} };
        if (effects != x.effects) Runtime.trap("replay: block " # Nat.toText(b.index) # " recorded effects " # debug_show(x.effects) # " but the fold produced " # debug_show(effects));
      };
    }
  };
  public func replay(fresh : State) : Fold.Report { Fold.replay<K.Event, State>(fresh.log, K.codec, func(_ : Nat) : ?Blob { null }, fresh, applyBlock) };
  public func fingerprint(s : State) : Blob {
    let f = Fold.newFingerprint();
    func table<Rw>(name : Text, store : RS.Store, decl : RS.Decl<Rw>, next : Nat) {
      Fold.section(f, name, func(w : C.Writer) { w.nat(next); var i = 1; while (i < next) { switch (RS.get(store, decl, i)) { case (?r) { w.nat(i); w.blob(decl.encode(r)) }; case null {} }; i += 1 } });
    };
    table<HolderRow>("holders", s.holderRows, holders, s.holderBound);
    table<AssetRow>("assets", s.assetRows, assets, s.nextAsset);
    table<PositionRow>("positions", s.positionRows, positions, s.nextPosition);
    table<ReceiptRow>("receipts", s.receiptRows, receipts, s.nextReceipt);
    table<ActionRow>("actions", s.actionRows, actions, s.nextAction);
    table<EntitlementRow>("entitlements", s.entitlementRows, entitlements, s.nextEntitlement);
    table<ReconciliationRow>("reconciliations", s.reconciliationRows, reconciliations, s.nextReconciliation);
    Fold.section(f, "proposals", func(w : C.Writer) { var i = 0; let n = DL.length(s.log); while (i < n) { switch (RS.get(s.proposalRows, proposals, i)) { case (?r) { w.nat(i); w.blob(MC.encodeProposalRow(r)) }; case null {} }; i += 1 } });
    Fold.section(f, "log", func(w : C.Writer) { w.nat(DL.length(s.log)); w.optBlob(DL.tipHash(s.log)) });
    Fold.fingerprintHash(f)
  };
  public func counts(s : State) : { holders : Nat; assets : Nat; positions : Nat; receipts : Nat; actions : Nat; entitlements : Nat; reconciliations : Nat; blocks : Nat } {
    { holders = RS.size(s.holderRows); assets = RS.size(s.assetRows); positions = RS.size(s.positionRows); receipts = RS.size(s.receiptRows); actions = RS.size(s.actionRows); entitlements = RS.size(s.entitlementRows); reconciliations = RS.size(s.reconciliationRows); blocks = DL.length(s.log) }
  };
}
