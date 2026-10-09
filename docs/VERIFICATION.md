# Verification record

What has been established, on what, and what has not.

## 1. Interpreter batteries (this checkout, moc 1.4.1, no replica)

| Battery | Checks | Result |
|---|---|---|
| `core/test/run_tests.mo` | 90,035 (unit cases and a 10,000-trial property simulation over fund, settle, abort, retry and reorder sequences; conservation and no-stranding on every trial) | green |
| `core/test/run_tests_icrc7.mo` | 25,033 (the unique-asset leg, including redundant same-collection replays) | green |
| `core/test/run_tests_delivery.mo` | 72,129 (the delivery gates; a 10,000-trial property simulation over deliveries accepted, reclaimed and never escrowed, with injected ledger failures; conservation, exactly-once payout or refund and no-stranding on every trial; no payout without the acceptance) | green |
| `matching/test/run_tests_matching.mo` | 53,443 (4,000 randomised windows, 3,898 crossed; clearing price, volume, priority, conservation of every fill schedule; chunked clearing equal to unbounded clearing; the properties of §6, each with its control) | green |

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

- **The matching engine on a subnet of validators in diverse locations running the production binary.** Section 6
  records it on a four-validator test chain running that binary and environment on one machine. The chain harness
  that drove that run is not part of this repository; its rows are recorded below.
- **The listing registry on the production binary.**


## 6. The matching engine's fixes and the custody guard (AU-01 to AU-05, AU-08 to AU-10)

### Defect records

| Id | Severity | Defect | Impact | Remedy | Regression cover |
|---|---|---|---|---|---|
| AU-01 | High | `recordSettlement` let any authenticated principal mark any obligation settled under any trade id; the engine then reported it settled | An unprivileged principal could stop the settlement of any match permanently | Method removed; an obligation is linked to its trade only from the core's reply, and the engine's `settled` flag never skips the core, which keys a matched settlement on the obligation and pays nothing twice | Chain rows RED on the previous engine and GREEN after: the marked obligation settled through the core after the upgrade |
| AU-02 | Medium | A bid reserved limit × quantity plus one fee and released limit × quantity only | Each bid left one fee reserved; a trader's free cash shrank until orders were refused | The reservation recorded per bid and released exactly (`MatchLogic.bidRelease`) | Property over 4,000 random lives, exact in all; the previous release leaves a residue in 3,888; chain rows; mutant X04 |
| AU-03 | Medium | An owner's buy and sell could fill each other; the core refuses a settlement whose maker is its taker | A fill that can never settle, both orders shown filled, their reservations released | Self-trade prevention, cancel-incoming, from a per-owner index of live limits built once at the upgrade for the resting book | Property over 1,321 crossed windows: no self-fill (2,800 without the rule); chain rows; mutants X05, X06 |
| AU-04 | Medium | Any authenticated principal could close and clear a window at any time | A participant could choose the moment of the clear | The clearing agent, named by the installer, alone clears; until one is named, the installer | Chain rows |
| AU-05 | Medium | Every order with its owner and every settlement event was readable by anyone; whole-collection replies grew without bound | The book's identities were public; replies failed past the size limit | Reads scoped to the caller are update calls (a query's caller is not authenticated by the node); every list is a page of at most 500 rows | Chain rows, including a query naming the clearing agent as its sender that reads nothing |
| AU-08 | Medium | The engine filled any quantity, while the core refuses an asset amount not above the ledger fee | Fills of one share could never settle: 14% to 15% of each window's obligations in settlement benchmarks on a chain with a ledger fee of one | The lot rule at entry (`MatchLogic.lotRefusal`): every quantity a whole number of lots above the asset fee, every limit price times the lot above the cash fee | Property over 4,601 fills: none unsettleable (1,342 without the rule); chain rows; mutants X01 to X03 |
| AU-09 | Medium | `settleMatched` awaited a private `async` helper; on a chain where nested asynchrony is not active the message took the helper's reply as its own and its continuation did not run | The settlement timer chain stopped after one obligation of the window | The helper is `async*`, run inline | Chain row asserting the reply is the method's own record; M4: every obligation of the window settled by the timer chain |
| AU-10 | Medium | `CustodyCore.openActionOf` read one page of the asset's open-action index with a limit of one; a page stops at its scan budget, so the entries of more than sixteen paid or cancelled actions hid the open one | A second corporate action could be announced on an asset while one was open | The read follows the page cursor to the first live row or the end of the range | Regression on a fresh register: twenty actions cancelled, the twenty-first open, a second refused; RED on the previous code |

### On a four-validator test chain running the production node binary (2026-10-07)

Four validators on one machine running the production node binary (`3c5353ab`) under the production environment;
the settlement core, two ledgers and the matching engine installed with `moc --legacy-persistence`. The previous
engine was installed first and driven into each defect; it was then upgraded in place to the fixed engine and driven
again. **44 of 44 rows pass.** The harness is not part of this repository.

| Rows | What was shown |
|---|---|
| Set-up | The core binds the engine; every holder approves the core on both ledgers |
| RED, the previous engine | AU-02: a cancelled bid leaves one fee reserved. AU-04: a principal neither installer nor agent closes and clears the window. AU-03: a fill between one owner's buy and sell, which can never settle. AU-08: a fill of one share with the ledger fee at one, which can never settle. AU-01: a principal marks another pair's obligation settled under a trade that does not exist, and the engine reports it settled. AU-05: an unrelated principal reads every order with its owner |
| Upgrade | Orders, the window, every obligation and every reservation kept |
| GREEN, the fixed engine | AU-08: no order before the lot is set; only the installer sets it; a lot not above the asset fee refused; a quantity below a lot and a part lot refused. AU-01: `recordSettlement` absent; the obligation marked before the upgrade settled through the core. AU-02: a bid holds limit × quantity plus the fee, and its cancel releases all of it. AU-03: a sell that would cross the owner's live buy refused, including a buy left resting by the previous engine. AU-04: only the installer names the agent, and only the agent or the installer clears. AU-05: a non-owner reads nothing of another's order or reservation; the owner reads its order; only the agent pages through every order; a query naming the agent as its sender reads nothing scoped. A bid accepted before the upgrade cancelled under its old release rule. AU-09: `settleMatched` replies its own record. The core's refusals recorded, and settlement stops on them |
| M | An upgrade in the middle of a window keeps its state; the agent clears; the fills equal an independent oracle's (clearing price 102, volume 250, 39 fills); no fill between one owner's orders; every fill a whole number of lots; every obligation settled through the core by the engine's own timer chain; every holder's balances equal the oracle's (14 holders, 40 settled obligations); the invariant log empty; clearing chunked at seven fills a message gives the same 39 fills in 6 messages; the cap sets only the number of messages |

### Gates (2026-10-09)

Each run from a checkout of the commit that introduced it.

| Gate | Result |
|---|---|
| `matching/test/run_tests_matching.mo` | 53,443 checks, green; the battery before the new properties (53,425 checks) is green against the fixed engine alone |
| `matching/tools/stable_compat.sh` from the previous release | Compatible; its control (a stored field's type changed) refused |
| `matching/tools/mutation_test.py` | Baseline green; 6 of 6 mutants red, each on its own rule |
| `custody/tools/check.sh`, `custody/test/run.sh` | Green, with the AU-10 regression; the same battery against the previous `CustodyCore.mo` fails on the two AU-10 checks |

