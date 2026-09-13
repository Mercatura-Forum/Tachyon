# Tachyon

Delivery-versus-payment settlement on Thebes: an asset leg and a cash leg move together, or
neither moves.

Tachyon is three Motoko contracts on the Thebes substrate:

| Contract | Role |
|---|---|
| `core/` | the settlement core: two-phase escrow, both-or-neither settlement, reclaim after the deadline, idempotent retry, a Merkle mountain range receipt for every event |
| `matching/` | a sealed batch matching engine over the core: orders staged into windows, cleared as a batch, each fill settled through the core as a matched obligation |
| `listing/` | the issuer-gated registry of what is tradeable: fungible shares and unique asset collections, funded-check at listing time |

Any ICRC-1/ICRC-2 ledger serves as the cash leg or a fungible asset leg; an ICRC-7 ledger serves as
a unique-asset leg. The same core therefore settles token against token, shares against cash, and a
registered unique asset against cash.

**Status: the settlement core verified on pocket-thebes (the production node binary and environment,
four validators, 25 of 25 rows) and on a throwaway chain; not deployed to the production chain; not
independently audited.** See `docs/VERIFICATION.md` for what has been
established and what has not.

## Properties

1. **Both or neither.** A payout to either party is possible only after both legs are confirmed
   in escrow (INV-DVP-2). A trade whose second leg never arrives is reclaimable in full by the party
   that funded, once the deadline has passed (INV-DVP-4).
2. **Conservation.** Per trade, what leaves the core on each leg never exceeds what was escrowed on
   that leg; the core mints and burns nothing (INV-DVP-1).
3. **No double resolution.** No escrow is both settled and refunded; terminal states are mutually
   exclusive (INV-DVP-3).
4. **Idempotent settlement.** A payout retried after a transient ledger failure does not pay twice;
   a repeated matched-settlement call re-drives the existing trade rather than creating a second
   (INV-DVP-5, `matchSeq`).
5. **A ledger's `Duplicate` reply is never trusted on its own**; the named escrow is verified first.
6. **Every order, funding, settlement and abort is appended to a Merkle mountain range** whose root
   is queryable, so a settlement trail can be verified outside the chain.

## Design

`docs/DESIGN.md`: the escrow state machine, why escrow-and-settle rather than a transfer between
parties, the trust model, the matching engine's sealed windows, and the listing gate.

## Layout

```
core/src/       DvpTypes, DvpLogic (pure decision core), DvpCore (the actor), Guards,
                ICRC and ICRC7 interfaces, MerkleMMR
core/test/      run_tests.mo (90,035 checks incl. a 10,000-trial property simulation),
                run_tests_icrc7.mo (25,033 checks)
core/fixtures/  the ledger fixtures (ICRC-1/2, and the flaky variant for failure injection)
test/pocket/    battery.py: the settlement battery on a Thebes chain (pocket-thebes or any network)
matching/src/   MatchTypes, MatchLogic (pure), Matching (the actor), Guards, ICRC
matching/test/  run_tests_matching.mo (53,425 checks, 4,000 randomised windows)
listing/src/    ListingRegistry
docs/           DESIGN.md, VERIFICATION.md
```

## Build and test

```sh
mops install
S=$(mops sources)
moc --legacy-persistence $S -o build/DvpCore.wasm         core/src/DvpCore.mo
moc --legacy-persistence $S -o build/Matching.wasm        matching/src/Matching.mo
moc --legacy-persistence $S -o build/ListingRegistry.wasm listing/src/ListingRegistry.mo

moc -r $S core/test/run_tests.mo
moc -r $S core/test/run_tests_icrc7.mo
moc -r $S matching/test/run_tests_matching.mo
```

Toolchain: moc 1.4.1, `mo:core` 2.4.0, `sha2` 0.1.9 (pinned in `mops.lock`). The example manifest
`deploy/example.thebes.toml` deploys with `thebes-deploy`; the validator list is the network's own.

## Known limitations

- **Time.** Funding deadlines are compared against the contract clock. On the Thebes substrate the
  contract clock is derived from block height until real block timestamps are activated, so a
  deadline expressed in seconds is a deadline in blocks. Deadlines are to be expressed against the
  application calendar; this change is scheduled and not yet made.
- **Read after write.** A query issued immediately after a successful update may be served by a
  validator that has not yet applied it. Clients re-read until the update is reflected;
  `test/pocket/battery.py` shows the pattern.
- **Cycle cost.** A settlement is three to four inter-canister calls; the cost per trade under the
  substrate's credit gate has not been measured on the production binary.
- **Matching and listing not yet run on the production binary.** The settlement core has been;
  the M-series rows for the matching engine have not.

Attribution: Thebes Core Team. Licence: Apache 2.0.
