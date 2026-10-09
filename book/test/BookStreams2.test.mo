// BookStreams2.test.mo: random streams on fresh books, part 2 of 3 (each part its own process: a WASI battery is
// one message, so the heap it allocates is never collected; the streams are split to keep each process small). Every
// command printed with its outcome for the Python reference (Book.verify.sh, run for this log too).
//
// engine: Region (the row stores and the log live in stable memory).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import C "mo:kernel/codec/Canonical";
import E "mo:kernel/domain/Encoding";
import DL "mo:kernel/domain/DomainLog";
import Perm "mo:kernel/auth/Permissions";
import Auth "mo:kernel/auth/AuthTypes";
import CivilDate "mo:kernel/num/CivilDate";
import RS "mo:kernel/rows/RowStore";
import Page "mo:kernel/rows/Page";
import XT "../../exchange/src/ExchangeTypes";
import X "../../exchange/src/ExchangeCore";
import XText "../../exchange/src/ExchangeText";
import T "../src/BookTypes";
import L "../src/BookLogic";
import K "../src/BookCanonical";
import B "../src/BookCore";
import TR "../../custody/test/support/Transcript";
import W "support/World";

let w = W.World(false);
let { n; printCoverage; randomStreams; replayed; uncrossed } = w;

w.seed := w.seed ^ Nat64.fromNat(0x77_0000 + 2);
let (commands, replays) = randomStreams(3, 3, 2_000);
Debug.print("count: random commands judged by the book and the reference = " # n(commands));
Debug.print("count: books whose log replayed to the same fingerprint = " # n(replays));
printCoverage(["pairs", "clears that traded", "stops triggered", "orders cancelled at a clear", "uncrossed books checked", "checkpoints", "continuous trades checked within the bands", "trades at close", "volatility interruptions", "uncrosses", "uncrosses that traded", "uncrosses equal to their indicative price"]);


if (w.failures > 0) { Debug.print("BOOK STREAMS 2 FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("BOOK STREAMS 2 GREEN");
