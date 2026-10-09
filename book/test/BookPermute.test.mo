// BookPermute.test.mo: the order of arrival inside a block changes nothing across accounts (book/SPEC.md §1). Twelve
// blocks, each of one order per account, given in two orders on two fresh books, every outcome compared by the
// member's reference, with a control (the block missing its last order compares unequal). Every book's commands are
// printed for the Python reference too.
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
let { check; n; order; permutationTrials } = w;

let (equal, trades, control) = permutationTrials(12);
check(control, "control: a block missing an order compares unequal");
check(trades >= 6, "the permutation trials trade");
Debug.print("count: blocks given in two orders with every outcome equal = " # n(equal));
Debug.print("count: permutation trials in which orders traded = " # n(trades));


if (w.failures > 0) { Debug.print("BOOK PERMUTE FAILED: " # Nat.toText(w.failures)); assert false } else Debug.print("BOOK PERMUTE GREEN");
