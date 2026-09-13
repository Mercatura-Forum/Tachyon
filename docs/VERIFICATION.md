# Verification record

What has been established, on what, and what has not.

## 1. Interpreter batteries (this checkout, moc 1.4.1, no replica)

| Battery | Checks | Result |
|---|---|---|
| `core/test/run_tests.mo` | 90,035 (unit cases and a 10,000-trial property simulation over fund, settle, abort, retry and reorder sequences; conservation and no-stranding on every trial) | green |
| `core/test/run_tests_icrc7.mo` | 25,033 (the unique-asset leg, including redundant same-collection replays) | green |
| `matching/test/run_tests_matching.mo` | 53,425 (4,000 randomised windows, 3,898 crossed; clearing price, volume, priority, conservation of every fill schedule; chunked clearing equal to unbounded clearing) | green |

## 2. On a throwaway subnet of geographically distributed validators running the Thebes node binary (June 2026)

Contracts deployed with `thebes-deploy`; two independent proofs of each row; block hash and state
root identical across every validator at every trade height (no fork).

| Row | What was shown |
|---|---|
| T1 / L1 | Happy path, fungible and unique-asset legs: asset to taker, cash to maker, core residual zero, receipt chain `ORDER → FUND → FUND → SETTLED` whose root re-derives |
| T2 / L6 | No fork: block hash and state root identical on every validator across the trade window |
| T3 / L2 | Abort: one leg funded, deadline passed, the funded party reclaims in full; the unique asset returns to its owner |
| T4 / L3 | Idempotent retry under live failure injection: a ledger that fails its first payout attempt (flaky fixture, unique-asset and cash variants); second attempt settles; no double payment; no half-settled terminal state |
| T5 / L4 | Adversarial: double-settle, double-refund, settle-before-both-escrowed, reclaim-after-settle, settle-after-reclaim all refused deterministically |
| L5 | The unique-asset leg was added without a change to the settlement state machine (the diff against the fungible baseline is confined to the ICRC-7 handler) |
| M1 | Chunked clearing produces the same fill schedule as unbounded clearing |
| M2, M3 | Budget exhaustion mid-clear applies the computed slice atomically and re-enqueues the remainder at its original priority |
| M4 | Every obligation settles both-or-neither through the core; no funds stranded |
| M5 | No dependence on an operator-set batch size cap |

## 3. On a subnet running the production node binary and environment (2026-09-13)

A subnet of validators in diverse locations running the production node binary (`fad75b2c`) under the production environment,
the four contracts installed with `thebes-deploy` (`moc --legacy-persistence`), driven by
`test/pocket/battery.py`. Log: `docs/pocket-thebes-battery-2026-09-13.log`. **25 of 25 rows pass.**

| Row | What was shown |
|---|---|
| T1 | Maker leg escrowed inline at open, taker leg escrowed, auto-settled: asset to taker and cash to maker each minus one fee, core residual zero, receipt chain ORDER, FUND, FUND, SETTLED, audit root present |
| T5 | Settle again is a no-op (reported already settled, no second payment); reclaim after settle refused; settle before both escrowed refused; taker cannot fund the maker leg |
| T3 | Reclaim refused before the deadline; accepted after it; status Aborted; maker refunded minus exactly the escrow and refund fees |
| T4 | Cash ledger injected to fail its first payout: first attempt paid leg A and reported leg B pending; the retry settled; maker paid exactly once, taker received exactly once, zero residual, no invariant violation |
| T2 | Every validator reports the same state root at a common height |

The run also exposed a defect in the vendored ledger fixture, fixed here: the deduplication key was
recorded before the transfer was validated, so a transfer refused on allowance poisoned every retry
that reused the same `created_at_time`; and the key was `created_at_time` alone. The fixture now
keys on caller, time, amount and memo, and records the key only when the block is appended. The
core's rule that a ledger `Duplicate` is verified against the named escrow before it is trusted is
what turned the defect into a refusal rather than a loss.

## 4. On local replicas (September 2026)

The core as a consumer of journal-backed ledgers: reservation escrow on such ledgers, and the rule
that a ledger `Duplicate` reply is not trusted until the named escrow is verified.

## 5. Not established

- **The matching engine and the listing registry on the production binary.** Section 3 covers the
  settlement core; the M-series rows are verified in the interpreter and on the subnet of section 2.
