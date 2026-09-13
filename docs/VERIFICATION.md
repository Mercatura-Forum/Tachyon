# Verification record

What has been established, on what, and what has not.

## 1. Interpreter batteries (this checkout, moc 1.4.1, no replica)

| Battery | Checks | Result |
|---|---|---|
| `core/test/run_tests.mo` | 90,035 (unit cases and a 10,000-trial property simulation over fund, settle, abort, retry and reorder sequences; conservation and no-stranding on every trial) | green |
| `core/test/run_tests_icrc7.mo` | 25,033 (the unique-asset leg, including redundant same-collection replays) | green |
| `matching/test/run_tests_matching.mo` | 53,425 (4,000 randomised windows, 3,898 crossed; clearing price, volume, priority, conservation of every fill schedule; chunked clearing equal to unbounded clearing) | green |

## 2. On a four-validator throwaway chain running the Thebes node binary (June 2026)

Contracts deployed with `thebes-deploy`; two independent proofs of each row; block hash and state
root identical across all four validators at every trade height (no fork).

| Row | What was shown |
|---|---|
| T1 / L1 | Happy path, fungible and unique-asset legs: asset to taker, cash to maker, core residual zero, receipt chain `ORDER → FUND → FUND → SETTLED` whose root re-derives |
| T2 / L6 | No fork: block hash and state root identical on all four validators across the trade window |
| T3 / L2 | Abort: one leg funded, deadline passed, the funded party reclaims in full; the unique asset returns to its owner |
| T4 / L3 | Idempotent retry under live failure injection: a ledger that fails its first payout attempt (flaky fixture, unique-asset and cash variants); second attempt settles; no double payment; no half-settled terminal state |
| T5 / L4 | Adversarial: double-settle, double-refund, settle-before-both-escrowed, reclaim-after-settle, settle-after-reclaim all refused deterministically |
| L5 | The unique-asset leg was added without a change to the settlement state machine (the diff against the fungible baseline is confined to the ICRC-7 handler) |
| M1 | Chunked clearing produces the same fill schedule as unbounded clearing |
| M2, M3 | Budget exhaustion mid-clear applies the computed slice atomically and re-enqueues the remainder at its original priority |
| M4 | Every obligation settles both-or-neither through the core; no funds stranded |
| M5 | No dependence on an operator-set batch size cap |

## 3. On local replicas (September 2026)

The core as a consumer of journal-backed ledgers: reservation escrow on such ledgers, and the rule
that a ledger `Duplicate` reply is not trusted until the named escrow is verified.

## 4. Not established

- **The production node binary and the production environment.** Every replica run above used the
  node binary of June 2026 or a local replica. A run on the production binary with the production
  environment is scheduled before any production use.
- **The contract clock.** On the substrate the contract clock is derived from block height until
  real block timestamps are activated. Funding deadlines are currently compared against that
  clock; the scheduled change expresses them against the application calendar.
- **Read-after-write.** A query immediately after an update may be served by a validator that has
  not applied it. The client-side sequence-and-retry pattern is not part of this repository.
- **Cycle cost per settlement** under the substrate's credit gate.
- **Independent audit.** None has been performed.
