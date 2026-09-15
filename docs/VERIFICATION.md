# Verification record

What has been established, on what, and what has not.

## 1. Interpreter batteries (this checkout, moc 1.4.1, no replica)

| Battery | Checks | Result |
|---|---|---|
| `core/test/run_tests.mo` | 90,035 (unit cases and a 10,000-trial property simulation over fund, settle, abort, retry and reorder sequences; conservation and no-stranding on every trial) | green |
| `core/test/run_tests_icrc7.mo` | 25,033 (the unique-asset leg, including redundant same-collection replays) | green |
| `core/test/run_tests_delivery.mo` | 72,129 (the delivery gates; a 10,000-trial property simulation over deliveries accepted, reclaimed and never escrowed, with injected ledger failures; conservation, exactly-once payout or refund and no-stranding on every trial; no payout without the acceptance) | green |
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
`test/chain/battery.py`. Log: `docs/chain-battery-2026-09-13.log`. **25 of 25 rows pass.**

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

### The same bed on 2026-09-14, with the deliveries

The same the validators and the same binary, the core upgraded in place with `thebes-deploy upgrade` to the build
with the delivery entrypoints (the state of every earlier trade kept), driven by the same `test/chain/battery.py`
with the D rows added. Log: `docs/chain-battery-2026-09-14.log`. **53 of 53 rows pass.** The bed persists
between runs, so every residual row is measured against the core's holdings at the start of the run, printed on
the log's first lines.

| Row | What was shown |
|---|---|
| T1 to T5 | As on 2026-09-13, on the upgraded core |
| D1 | A delivery opened by the maker to a named taker, the leg escrowed and held by the core with nothing at the taker; the maker cannot accept its own delivery; no payout before the acceptance; the taker's acceptance pays the leg out once, minus one fee; receipt chain DELIVERY, FUND, ESCROWED, ACCEPTED, DELIVERED; a second acceptance reports delivered and pays nothing; reclaim after delivery refused (INV-DEL-3) |
| D2 | Reclaim before the deadline refused on a long-dated delivery, which is then accepted; a short-dated delivery reclaimed after its deadline, status Reclaimed, the maker refunded minus exactly the escrow and refund fees; acceptance after the reclaim refused; a second reclaim reports reclaimed and returns nothing |
| D3 | Only the named taker accepts; the chain's clock read through a probe delivery opened unfunded in the same window (its funding refused as past the deadline once the chain is there, nothing of it ever moving); acceptance past the deadline refused with the leg still in the core; the taker may reclaim it to the maker; the probe reclaimed with nothing moved |
| D4 | No invariant violation logged across the run's trades and deliveries; five deliveries opened in the run |
| T2 | Every validator report the same state root at a common height |

## 4. On local replicas (September 2026)

The core as a consumer of journal-backed ledgers: reservation escrow on such ledgers, and the rule
that a ledger `Duplicate` reply is not trusted until the named escrow is verified.

## 5. Not established

- **The matching engine and the listing registry on the production binary.** Section 3 covers the
  settlement core; the M-series rows are verified in the interpreter and on the subnet of section 2.
