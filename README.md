# Tachyon: Delivery-versus-Payment Settlement on Thebes

**Tachyon is a delivery-versus-payment (DvP) settlement engine that runs as a
smart contract on the Thebes substrate.** An asset leg and a cash leg move
together, or neither moves. It settles any ICRC-1/ICRC-2 token against any
other, fungible shares against cash, and ICRC-7 unique assets against cash,
through a two-phase escrow, a batch matching engine with a single uniform
clearing price per window, and a certified receipt for every event. Written
in Motoko. Apache 2.0.

- **Both or neither.** A payout requires both legs confirmed in escrow; a trade
  whose second leg never arrives is reclaimable in full after its deadline.
- **Conservation.** Per trade and per leg, nothing leaves the core beyond what
  was escrowed; the core mints and burns nothing.
- **Idempotent settlement.** A payout retried after a ledger failure never pays
  twice; a repeated matched settlement re-drives the same trade.
- **Certified receipts.** Every order, funding, settlement and abort is a leaf of
  a Merkle mountain range whose root the network certifies; a receipt and its
  inclusion proof verify outside the chain.
- **Sealed batch matching.** Orders are staged into windows and cleared at one
  uniform price (a frequent batch auction), each fill settled through the core.

| | |
|---|---|
| Model | BIS DvP Model 1: gross, simultaneous, both-or-neither |
| Legs | ICRC-1/ICRC-2 (cash, fungible assets), ICRC-7 (unique assets) |
| Matching | frequent batch auction, uniform clearing price, price-time priority, bounded clearing |
| Proofs | Merkle mountain range receipts with a certified root |
| Verification | 168,493 interpreter checks; 25 of 25 rows on a geographically distributed subnet running the production node binary |
| Status | settlement core verified on the production node binary under the production environment; matching engine and listing registry verified in the interpreter and on a Thebes subnet |

Tachyon implements BIS DvP Model 1 (gross, simultaneous, both-or-neither) over
any ICRC-1/ICRC-2 ledger for cash and fungible assets and any ICRC-7 ledger for
unique assets, so the same core settles token against token, shares against
cash, and a registered unique asset against cash. Its matching engine follows
the frequent batch auction of Budish, Cramton and Shim.

**Type-safe, memory-safe, no silent errors.** Motoko is a strongly and
statically typed language of the ML family. It has option types in place of
nulls, arbitrary-precision and overflow-checked arithmetic that traps rather
than wraps, garbage-collected memory with no pointers to corrupt, and atomic
message execution: a trap rolls the whole message back. Tachyon is written to
that discipline throughout. Every refusal is a typed `Result` value with its
reason (a leg not yet escrowed, a deadline not reached, a caller who is not
the maker), never a default silently applied; every invariant is checked in
the contract on every transition and a violation traps the message; a ledger
reply is never trusted beyond what the ledger's own records confirm.

**Status.** The settlement core is verified on a geographically distributed
subnet running the production node binary under the production environment
(25 of 25 rows); the matching engine and the listing registry are verified in
the interpreter and on a Thebes subnet. See `docs/VERIFICATION.md`.

**The exchange.** Beside the settlement core, the repository carries an exchange built on the Thebes kernel, each part a
pure core of commands on a certified log that a contract composes: the exchange's foundation (members, traders,
accounts, segments, the calendar, instruments), a continuous order book with its central counterparty and the
instruments and cash legs a national market trades, a surveillance desk over the book's log, the venue contract that
composes them, and a FIX gateway each member runs at its own edge. Every part has a battery whose output an
independent Python oracle recomputes from the commands alone, planted-fault controls and mutants; every battery's
transcript is made again on a chain by the chain judge. See `book/SPEC.md` and `docs/VERIFICATION.md` §7.

## Why it runs on Thebes

A settlement system holds other people's assets for the duration of a trade.
Running it as a smart contract on the Thebes substrate changes what that
custody is:

- **Redundant by construction.** The core does not run on a server; it runs on
  every validator of the network, and an escrow exists only as the state a
  Byzantine fault-tolerant quorum of them agrees on. There is no primary to
  fail over from and no replica to fall behind.

- **Tamper-proof execution.** A settlement or a refund happens only if the
  validators executed the same command on the same state and reached the same
  result. No administrator, no operator of a single machine and no validator
  on its own can release an escrow, redirect a payout or remove a receipt: the
  receipt log is append-only and hash-chained, and the state every validator
  holds is hashed and compared at every height.

- **Verification and proofs.** Every receipt is a leaf of a Merkle mountain
  range whose root is certified by the network. A counterparty, a custodian or
  a regulator holding a receipt and its inclusion proof verifies it against the
  certified root without trusting the venue or any one validator.

- **A venue the participants can operate.** The validators of a Thebes network
  can be run by the participants themselves, the settlement members, the
  custodian, the regulator and an auditor, so that settlement runs on
  infrastructure they jointly operate and jointly verify.

## What is here

| Contract | What it does |
|---|---|
| **`core/`: the settlement core** | Two-phase escrow (fund, settle, abort); both-or-neither settlement gated on both legs confirmed in escrow; reclaim in full after the deadline; idempotent retry of a failed payout with a fixed `created_at_time` so the ledger deduplicates; a ledger `Duplicate` verified against the named escrow before it is trusted; five invariants checked on every transition; a Merkle mountain range receipt for every event; the ICRC-7 leg for unique assets; a delivery free of payment (one leg, moved by the taker's acceptance, reclaimed past the deadline) under the same receipts and invariants. |
| **`matching/`: the batch matching engine** | Orders staged into windows and cleared at one uniform price that maximises executed volume; price-time priority with pro-rata at the margin; reservation against the core rather than custody; each fill a settlement obligation driven through the core as a matched trade; clearing metered against an instruction budget and resumed across rounds, so batch size is unbounded without a partially applied chunk. |
| **`listing/`: the listing registry** | The issuer-gated record of what is tradeable: fungible shares and unique-asset collections, funded-check at listing time; consulted by the matching engine when configured. |
| **`exchange/`: the exchange's foundation** | Members admitted under four eyes, their traders, house accounts and client accounts carrying a commitment to the client, each trader's right to trade per segment; segments with their session windows and the scheduler's phase at the chain's clock; the market's calendar and UTC offset; price-dependent tick tables; instruments by ISIN with the ISO 6166 check digit. Every refusal a stable code with an English and an Arabic text. See `exchange/README.md`. |
| **`book/`: the continuous order book** | Orders of one block cleared at one price; limit, market, immediate-or-cancel, fill-or-kill, stop, iceberg, trailing and one-cancels-other orders; phases, call auctions and the indicative price, price bands and volatility interruptions, halts, the kill switch and risk limits; the public feed, each member's drop copy and the day's sealed statistics; insider blackouts and short sales; a central counterparty for clearing members with netting cycles, fails, the guarantee fund, default and its waterfall, every movement a leg of a Merkle mountain range; fees, statements, reconciliation and market makers; indices and the market-wide circuit breaker; bonds, funds, warehouse receipts, certificates and rights; attested prices, futures and options on an index; the cash leg in central bank reserves, tokenised deposits or claims bridged to the RTGS. Specified in `book/SPEC.md`; see `book/README.md`. |
| **`surveillance/`: the surveillance desk** | A fold over the book's log: wash trades, painting the tape, quote stuffing, spoofing and layering, marking the close, each threshold a parameter under four eyes; cases opened, closed or reported under four eyes; the daily regulatory report as a hash chain anyone holding the log rebuilds. See `surveillance/SPEC.md`. |
| **`venue/`: the venue contract** | Composes the exchange's foundation, the book and the desk: a member's typed calls signed by its trader, the operator's and the scheduler's acts under their grants, every read scoped to its caller. |
| **`gateway/`: the members' FIX gateway** | FIX 4.4, and FIX 5.0 SP2 over FIXT.1.1, terminated at the member's edge and translated into the venue's typed calls signed with the member's own key; ExecutionReports by one rule from the venue's replies and its public feed, rebuilt from the certified log alone; a drop-copy session; QuickFIX/J conformance sessions. Specified in `book/SPEC.md` §37. |
| **`custody/`: custody beside the venue** | A register of holders and their settled positions as the fold of the venue's receipts (each recorded once by its id and hash, never more than a holder has); reconciliation of the register to the ledgers' attested balances, sealed by a hash; corporate actions (a cash dividend, a split and a bonus with cash in lieu of fractions, rights within the entitlement and by the deadline, a redemption) struck at the record date and paid on the payment date in slices, the entitlement file certified by its hash. An initial public offering beside it: the book of bids on a price ladder, retail applications paid in full, pricing never above the book's clearing price, the underwriter's firm or best-efforts commitment, allocation by cumulative rounding with its file chained by hash, and the hand-off of the allotments to the register behind the listing gate. Pure cores on the Thebes kernel that a venue contract composes; see `custody/README.md`. |

## Layout

```
core/src/       DvpTypes, DvpLogic (the pure decision core), DvpCore (the actor),
                Guards, the ICRC-1/2 and ICRC-7 interfaces, MerkleMMR, the land ledger
core/test/      the interpreter batteries (90,035 and 25,033 checks)
core/fixtures/  the ledger fixtures: an ICRC-1/2 ledger and its flaky variant for
                failure injection
matching/src/   MatchTypes, MatchLogic (pure), Matching (the actor), Guards, ICRC
matching/test/  the interpreter battery (53,443 checks: 4,000 randomised windows and the
                properties of the lot rule, exact bid release and self-trade prevention)
matching/tools/ the mutation tool and its mutants; the upgrade gate
listing/src/    ListingRegistry
custody/        the custody register: src/, test/ (WASI batteries), integration/ (the Python twin, the chain judge,
                its test actor VenueJudge and the chain client), tools/ (the gates, the contracts' build)
exchange/       the exchange's foundation: src/, test/, integration/ (the twin), tools/
book/           the order book: SPEC.md, src/, test/ (the batteries, each its own process), integration/ (the
                reference book, the regulator's replay, the feed's consumer), tools/ (controls, mutants)
surveillance/   the desk: SPEC.md, src/, test/, integration/ (the oracle), tools/
venue/src/      Venue, the contract that composes them
gateway/        the FIX gateway: fix, er, feedwatch, orderlog, reconstruct, gateway; conformance/; test/
vendor/         the Thebes kernel the custody module builds against, named by commit
test/chain/    battery.py: the settlement battery on a Thebes chain
deploy/         an example thebes-deploy manifest
docs/           DESIGN.md, VERIFICATION.md, the run of record
```

## Building and testing

Requirements: `moc` 1.4.1 and `mops` (`mops install` fetches `core` and `sha2`),
`thebes-deploy` for a chain, Python 3 for the chain battery.

```
mops install
S=$(mops sources)
moc --legacy-persistence $S -o build/DvpCore.wasm         core/src/DvpCore.mo
moc --legacy-persistence $S -o build/Matching.wasm        matching/src/Matching.mo
moc --legacy-persistence $S -o build/ListingRegistry.wasm listing/src/ListingRegistry.mo

moc -r $S core/test/run_tests.mo
moc -r $S core/test/run_tests_icrc7.mo
moc -r $S core/test/run_tests_delivery.mo
moc -r $S matching/test/run_tests_matching.mo
```

The custody module builds against the Thebes kernel, which is not part of this repository:
`vendor/thebes-kernel/README.md` names the commit, and a checkout of the kernel at that commit is
placed in `vendor/thebes-kernel` before its batteries run (WASI under `wasmtime`, Python 3 for the twin):

```
./custody/tools/check.sh
./custody/test/run.sh
python3 custody/tools/mutation_test.py
```

The matching engine's mutation tool and upgrade gate (`moc` 1.4.1 on the `PATH`):

```
python3 matching/tools/mutation_test.py
./matching/tools/stable_compat.sh <the commit the deployed engine was built from>
```

The mutation tool copies the committed tree with `custody/tools/committed_tree.sh`, so it needs the kernel checkout
described above, although the matching engine itself does not depend on the kernel.

The exchange's batteries run as the custody module's do, each a WASI process, its log checked by the module's oracle;
the gateway's checks need Java and fetch QuickFIX/J 2.3.1 by pinned SHA-1:

```
./exchange/test/run.sh
./book/test/run.sh
./surveillance/test/run.sh
QFJ_DIR=<a directory> ./gateway/test/run.sh
python3 book/tools/mutation_test.py
./custody/tools/build_contracts.sh "$PWD" build      # the venue and the judge actor, legacy persistence
```

Each book battery's planted-fault controls are `book/tools/*_control.sh <the battery's log>`. A battery's transcript is
judged on a chain with `custody/integration/chain_judge.py --wasm build/VenueJudge.wasm --log <the battery's log>
--config custody/integration/judge/<battery>.json --chain <chain.json>`, where `chain.json` names the chain's node URLs,
its deploy gateway and its chain id (the format is in `custody/integration/thebes_client.py`); the client signs as
identities it imports into the deploy tool's store.

The contracts are built with legacy (classical) persistence so that an in-place
upgrade keeps its state. `test/chain/README.md` describes the battery on a
chain; `deploy/example.thebes.toml` is the manifest shape.

## Upgrading the matching engine

The engine built from this release closes the defects recorded in `docs/VERIFICATION.md` §6 (AU-01 to AU-05, AU-08,
AU-09). Its stored state upgrades in place from the previous release (`./matching/tools/stable_compat.sh` checks
this). Every order, obligation and reservation is kept. The interface and the behaviour change as follows.

**Methods removed:** `recordSettlement`, `allOrders`, `ordersInWindow`, `allObligations`, `unsettledObligations`,
`obligationSummary`, `bookSummary`, `killLogView`.

**Queries that became update calls,** with results scoped to the caller: `getOrder` and `reservationOf` (the owner or
the clearing agent), and `invariantLog` (the clearing agent). A query's caller is not authenticated by the node, so a
scoped read must be an update call.

**Methods added:**
- `setClearingAgent` and `setLotSize`, the installer's settings;
- `ordersPage`, `obligationsPage`, `obligationSummaryPage` and `killLogPage`, pages of at most 500 rows, for the
  clearing agent;
- `refusedObligation`, `obligationCount`, `lot` and `clearingAgentPrincipal`.

A client that read the removed whole-collection methods moves to the pages.

**Behaviour on upgrade:**
- **The lot.** An engine upgraded in place refuses every order until the installer sets the lot with `setLotSize`. The
  lot must be above the asset ledger's fee, read from the ledger when the lot is set. From then on an order is accepted
  only if its quantity is a whole number of lots and its limit price times the lot is above the cash ledger's fee.
- **The clearing agent.** Until the installer names it with `setClearingAgent`, only the installer closes and clears
  windows. The installer is the controller that installed or last upgraded the engine.
- **Indexes.** The first upgrade builds the per-owner index of live limits that self-trade prevention reads, and the
  per-window obligation cursors, from the book as it stands.
- **Bids accepted before the upgrade** keep the release rule they were reserved under. A cancelled bid of that kind
  leaves its one cash fee reserved, as the previous release did.

## Known limitations

- **Matching and listing on the production binary.** The settlement core has been run on a subnet of
  validators in diverse locations running it. The matching engine with its fixes has been run on a four-validator
  test chain running the production node binary (`docs/VERIFICATION.md` §6), not on such a subnet. The listing
  registry has not been run on the production binary.
- **The exchange on a chain.** Its batteries are judged on a four-validator test chain running the production node
  binary (`docs/VERIFICATION.md` §7), not on a subnet of validators in diverse locations.
- **Rejected orders and the log.** A refused order writes no block, so the gateway's Rejected report is the venue's
  reply and the gateway's journal, and is not rebuilt from the log; every other report is.
- **The central counterparty.** The book carries its mechanics; acting as a central counterparty is the licence of
  a clearing house that runs them.
- **Compaction.** An order index is compacted inside one message once its stale entries reach its live ones, a spike
  in that message's cost (`book/README.md`).
- **The chain judge's windows.** With several calls in flight, the chain may execute a window's calls in an order
  other than the one submitted, and a judge then stops at the first reply that differs; the run of record sends one
  call at a time.

## Design

`docs/DESIGN.md` describes the escrow state machine, why escrow-and-settle
rather than a transfer between parties, the trust model, the invariants, the
ledger-reply rules, the receipts, the matching engine and the listing gate.

## Contributing

This repository was published as a single commit, by design: the product was built in a
private tree through iteration, test batteries, oracle comparison and review, and the public
repository is the clean cut of the result, without the lab work behind it. From this release
onward, work continues here in the open. Open an issue for a defect or a question, with the
file and line; open a pull request against `main` with the battery green. Contributions are
attributed to the team.

## Licence

Apache License 2.0 (see `LICENSE`).

Attribution: Thebes Core Team.
