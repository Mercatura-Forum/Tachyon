/// SurvTypes.mo: the surveillance desk's commands, rows and refusals (surveillance/SPEC.md).
///
/// Attribution: Thebes Core Team.

module {
  /// The rules' thresholds (SPEC §2), set under four eyes.
  public type Params = {
    paintCount : Nat; paintSecs : Nat; stuffCount : Nat; stuffSecs : Nat; spoofQty : Nat; spoofSecs : Nat;
    markShare : Nat; markBps : Nat; positionLevel : Nat;
  };
  public let DEFAULT_PARAMS : Params = {
    paintCount = 3; paintSecs = 600; stuffCount = 50; stuffSecs = 10; spoofQty = 100; spoofSecs = 60; markShare = 50; markBps = 200; positionLevel = 1_000;
  };
  /// The command families, in their frozen order: a family's tag is its position here, from 1.
  public type Command = {
    #scan : { limit : Nat };
    #setParams : Params;
    #openCase : { alert : Nat };
    #noteCase : { caseId : Nat; note : Text };
    #closeCase : { caseId : Nat; reason : Text };
    #reportCase : { caseId : Nat; summary : Text };
    #sealReport : { day : Nat };
  };
  public type Effects = [Nat];
  public type Error = {
    #NothingToScan;
    #UnknownAlert : { alert : Nat };
    #UnknownCase : { caseId : Nat };
    #CaseClosed : { caseId : Nat };
    #InvalidTerms : { reason : Text };
  };
  /// An alert (SPEC §2): its rule, the block that raised it, the instrument, the owner (and the other owner for painting
  /// the tape), four figures of evidence, and its case (0 for none).
  public type Alert = { rule : Nat; block : Nat; instrument : Nat; owner : Blob; other : Blob; e1 : Nat; e2 : Nat; e3 : Nat; e4 : Nat; caseId : Nat };
  /// A case (SPEC §3): its alert, its status (1 open, 2 closed, 3 reported) and its number of notes.
  public type Case = { alert : Nat; status : Nat; notes : Nat };
  public let MAX_SCAN = 500;
  public let TEXT_BYTES = 1_024;
}
