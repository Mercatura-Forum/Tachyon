/// Transcript.mo: test support. A battery's transcript, for the chain judge (`integration/chain_judge.py`): every call a
/// battery makes that can write state, in the order it made it, with what the domain's log records of it and what it
/// returned, so a test actor on a chain can make the same calls and must get the same answers and the same logs.
///
/// One entry per call: `call|<domain>|<op>|<caller>|<now>|<version>|<argument>|<justification>|<outcome>`, where `op` is
/// `submit` or `approve`; the caller is the role principal the battery acted as; `now` the clock it passed; the argument
/// the command's frozen bytes (hex) for a submission or the proposal id for an approval; the justification in hex; the
/// outcome `x=<effects>` for an execution, `p=<proposal>` for a proposal opened or approved short of its quorum, or
/// `e=<Name>` for a refusal by its name. A command's bytes longer than a WASI print holds go first on `callb|` lines; an
/// outcome longer than 300 characters goes first on `callo|` lines and its `call|` line carries `@` in its place.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

module {
  /// A blob as lower-case hex, as ASCII bytes decoded once: a text built character by character (or by `Text.fromArray`,
  /// which concatenates) is a chain of concatenations, and a command of thousands of bytes made one deep enough to
  /// exhaust the stack when it is printed.
  func hexBytes(b : Blob) : [Nat8] {
    let d : [Nat8] = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102];
    let a = Blob.toArray(b);
    Array.tabulate<Nat8>(a.size() * 2, func(i) { let n = Nat8.toNat(a[i / 2]); if (i % 2 == 0) d[n / 16] else d[n % 16] })
  };
  func ascii(xs : [Nat8]) : Text { switch (Text.decodeUtf8(Blob.fromArray(xs))) { case (?t) t; case null "" } };
  public func hex(b : Blob) : Text { ascii(hexBytes(b)) };
  public func csv(xs : [Nat]) : Text { var o = ""; for (x in xs.vals()) o := o # (if (o == "") "" else ",") # Nat.toText(x); o };

  /// The name of a refusal in a result's text: the variant under the domain's wrapper (`#err(#register(#DayNotStruck(..`
  /// names `DayNotStruck`; `#err(#auth(#NoGrant(..` names `NoGrant`); for text shaped otherwise, the text.
  public func errName(t : Text) : Text {
    let parts = Text.split(t, #char '#');
    ignore parts.next();                 // before the first mark
    let ?a = parts.next() else return t; // err(
    if (not Text.startsWith(a, #text "err")) return t;
    let ?b = parts.next() else return t; // the domain's wrapper, or a bare name
    let tail = switch (parts.next()) { case (?c) c; case null b };
    var name = "";
    label take for (ch in tail.chars()) { if (Char.isAlphabetic(ch) or Char.isDigit(ch)) name := name # Text.fromChar(ch) else break take };
    if (name == "") t else name
  };

  func lines(prefix : Text, xs : [Nat8]) {
    var k = 0;
    while (k < xs.size()) {
      let n = Nat.min(400, xs.size() - k : Nat);
      Debug.print(prefix # ascii(Array.sliceToArray<Nat8>(xs, k, k + n)));
      k += n;
    };
  };

  /// An outcome as the `call|` line carries it: itself, or `@` after its `callo|` lines when it would not fit.
  func outcomeField(outcome : Text) : Text {
    if (outcome.size() <= 300) return outcome;
    lines("callo|", Blob.toArray(Text.encodeUtf8(outcome)));
    "@"
  };
  /// A submission: the command's bytes at `version`, the caller, the clock, the justification, the outcome.
  public func submitted(domain : Text, version : Nat8, bytes : Blob, caller : Principal, now : Nat64, justification : Text, outcome : Text) {
    lines("callb|", hexBytes(bytes));
    let o = outcomeField(outcome);
    Debug.print("call|" # domain # "|submit|" # Principal.toText(caller) # "|" # Nat64.toText(now) # "|" # Nat8.toText(version) # "|-|" # hex(Text.encodeUtf8(justification)) # "|" # o);
  };
  /// An approval of a proposal by the caller at the clock, and its outcome.
  public func approved(domain : Text, proposal : Nat, caller : Principal, now : Nat64, outcome : Text) {
    let o = outcomeField(outcome);
    Debug.print("call|" # domain # "|approve|" # Principal.toText(caller) # "|" # Nat64.toText(now) # "|0|" # Nat.toText(proposal) # "||" # o);
  };
  /// The fingerprint a domain stands at, for the judge to compare with the chain's.
  public func fingerprint(domain : Text, fp : Blob) { Debug.print("fingerprint|" # domain # "|" # hex(fp)) };
}
