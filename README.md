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
| **`core/`: the settlement core** | Two-phase escrow (fund, settle, abort); both-or-neither settlement gated on both legs confirmed in escrow; reclaim in full after the deadline; idempotent retry of a failed payout with a fixed `created_at_time` so the ledger deduplicates; a ledger `Duplicate` verified against the named escrow before it is trusted; five invariants checked on every transition; a Merkle mountain range receipt for every event; the ICRC-7 leg for unique assets. |
| **`matching/`: the batch matching engine** | Orders staged into windows and cleared at one uniform price that maximises executed volume; price-time priority with pro-rata at the margin; reservation against the core rather than custody; each fill a settlement obligation driven through the core as a matched trade; clearing metered against an instruction budget and resumed across rounds, so batch size is unbounded without a partially applied chunk. |
| **`listing/`: the listing registry** | The issuer-gated record of what is tradeable: fungible shares and unique-asset collections, funded-check at listing time; consulted by the matching engine when configured. |

## Layout

```
core/src/       DvpTypes, DvpLogic (the pure decision core), DvpCore (the actor),
                Guards, the ICRC-1/2 and ICRC-7 interfaces, MerkleMMR, the land ledger
core/test/      the interpreter batteries (90,035 and 25,033 checks)
core/fixtures/  the ledger fixtures: an ICRC-1/2 ledger and its flaky variant for
                failure injection
matching/src/   MatchTypes, MatchLogic (pure), Matching (the actor), Guards, ICRC
matching/test/  the interpreter battery (53,425 checks over 4,000 randomised windows)
listing/src/    ListingRegistry
test/pocket/    battery.py: the settlement battery on a Thebes chain
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
moc -r $S matching/test/run_tests_matching.mo
```

The contracts are built with legacy (classical) persistence so that an in-place
upgrade keeps its state. `test/pocket/README.md` describes the battery on a
chain; `deploy/example.thebes.toml` is the manifest shape.

## Known limitations

- **Matching and listing on the production binary.** The settlement core has
  been run there; the matching engine's rows have not yet.

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
