# Verification record

What has been established, on what, and what has not.

## 1. Interpreter batteries (this checkout, moc 1.4.1, no replica)

| Battery | Checks | Result |
|---|---|---|
| `core/test/run_tests.mo` | 90,035 (unit cases and a 10,000-trial property simulation over fund, settle, abort, retry and reorder sequences; conservation and no-stranding on every trial) | green |
| `core/test/run_tests_icrc7.mo` | 25,033 (the unique-asset leg, including redundant same-collection replays) | green |
| `core/test/run_tests_delivery.mo` | 72,129 (the delivery gates; a 10,000-trial property simulation over deliveries accepted, reclaimed and never escrowed, with injected ledger failures; conservation, exactly-once payout or refund and no-stranding on every trial; no payout without the acceptance) | green |
| `matching/test/run_tests_matching.mo` | 190,256 (4,000 randomised windows, 3,898 crossed; clearing price, volume, priority, conservation of every fill schedule; chunked clearing equal to unbounded clearing; and 900 randomised reservation lifecycles over 9,970 intakes, fills, cancels, kills, settlements and voids: every release exactly covered, the reservation equal at every step to what the model prescribes for the live book and the open obligations, and exactly zero with every map empty once all of them resolve) | green |

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

## 3b. The matching engine and the listing registry on a localhost chain of the production node binary (2026-09-24)

A localhost chain stood up by `thebes-deploy start`: four validators and one boundary on
127.0.0.1 running the toolchain's production node binary (`egypt-node`, sha256 `d34849bd…`),
chain id 31337, the Motoko legacy-ABI gate armed from genesis. The nine contracts of
`deploy/example.thebes.toml` installed with `thebes-deploy` (`moc --legacy-persistence`),
driven by `test/chain/battery.py`. The ground truth for every matching row is a stateful
Python twin of `MatchLogic.mo` inside the battery — clearing price, priority sorts, the
all-or-none fixpoint, the fill schedule, reservation arithmetic and per-fill-fee settlement
deltas — fed exactly the submits, cancels and clears the battery drives on-chain. Log:
`docs/chain-battery-2026-09-24.log`. **113 of 113 rows pass** (T1–T5 and D1–D4 reproduced
on this bed, then M0–M5, MD, L1–L8, MF, and T2 last).

| Row | What was shown |
|---|---|
| M0 | A caller that is not the bound engine can never `settleMatchFor`; only the installer binds or rotates the relayer |
| M1 | A two-sided window cleared at one uniform price: obligations, book and reservations byte-identical to the twin; the 2-fill cap chunks the clear and the engine's own Timer completes it |
| M2 | Every obligation settled through the core by seq: balance deltas exact to the per-fill fee, zero core residual, the matchSeq → trade round trip, the ORDER receipt carrying its matchSeq, an idempotent re-drive |
| M3 | The first chunk reports its budget exhausted; the pre-await-armed chunk-resume Timer completes the clear unaided and the chunk count equals the arithmetic; the chunked schedule equals the twin's unbounded one; `settleMatched` settles exactly one obligation per call — the Timer it arms after its await is registered but never fires (defect recorded below); one call per obligation drains the window exactly |
| M4 | Time priority at one price: the oldest resting bid fills first, the newest same-price bid gets nothing; an all-or-none ask that cannot fully fill is killed before any mutation, its reservation released, the survivors' schedule equal to the twin's |
| M5 | Non-owner cancel, closed-window cancel, intake beyond the caller's allowance, unknown seq and zero deadline all refused; rotated away, the unbound engine is refused by the core and nothing moves; rotated back, the same obligation re-drives to settled |
| MD | A fill at or below the asset ledger's fee: the core refuses it before any trade exists (nothing escrows — funds safe), and it permanently head-blocks `settleMatched`'s drain of its window (defect recorded below) |
| L | The gated engine refuses an unlisted market at intake; issuer authorization is admin-only; a zero-supply ledger is refused as unfunded by the live cross-canister check; the funded pair lists and intake opens; delisting flips the gate off; a land collection is listable only once a title is minted |
| MF | Both engines' invariant logs empty; no obligation of the run stranded (the dust probe excepted by design); the global obligation summary equal to the twin to the last byte |
| T2 | Every validator reports the same state root at a common height |

The run recorded three defects, each pinned by a battery row that must flip with its fix:

- **A dust fill is permanently unsettleable and head-blocks its window** (MD1–MD3). The
  engine's intake accepts any qty ≥ 1 and the planner emits boundary fills of any size, but
  `settleMatchFor` refuses `assetAmount <= fee`; such an obligation is refused before a
  trade exists, and `settleMatched` retries the window's first unsettled obligation
  forever, so the fills behind it are never attempted. Funds are safe throughout: nothing
  escrows for the refused fill and its reservation was already released at the clear.
  *Fixed engine-side and verified in section 3c.*
- **A Timer armed after a cross-canister await never fires on this bed** (M3f).
  `settleMatched`'s continuation Timer is registered (the node's timer index grows) and
  never dispatched, across three battery runs and a 150-second controlled observation; the
  chunk-resume Timer, armed in an await-free message, fired in every run. The autonomous
  window drain therefore does not run; every settlement in this section was driven by
  explicit calls, one obligation per call. *Resolved in section 3d: the engine no longer arms
  that Timer, nor any other message the caller does not await; the drain was rebuilt as a
  bounded inline sweep. The substrate defect itself - a post-await Timer that never fires -
  stands, recorded here.*
- **Reservation fee margins strand** (M1f, M4f). A filled bid's one-fee margin stays in
  `reservedCash` (intake reserves `limit·qty + fee`; a fill releases `limit·qty`), and a
  sell reserves no fee though its escrow costs one; the twin models both exactly.
  *Resolved in section 3e, where the accounting is replaced by a model rather than patched - and
  where the defect turns out to have had a third face this entry did not name.*

## 3c. The dust-fill liveness defect of 3b fixed and verified in place (2026-09-24)

The first defect of section 3b is resolved engine-side, in the two parts the record named, and
verified on the same bed. At intake, the engine refuses any order whose every possible fill
would be refused by the core's fee floors (`qty <= sharesFee`; for a bid also
`limitPrice*qty <= cashFee`), reading the fees live. At settlement, a boundary remainder fill
the core permanently refuses is resolved as VOIDED — the permanence judgment re-evaluates the
core's own validation predicate from `DvpCore.settleMatchFor` against the obligation's
immutable price and qty and the ledgers' live fees, never the error text — and fires only
while no trade exists for the seq (`dvpTradeId` null: the core refused before creating the
trade, so nothing ever escrowed; an obligation that owns a trade is never voided — the trade's
own deadline/reclaim machinery owns its funds). A voided obligation is recorded with its
reason (query `voidedObligations`), logged as a normal event beside the FOK kills, excluded
from the unsettled set and skipped by the drain, so `settleMatched` completes a window past
it. Voided is final, like a FOK kill.

The voided state is a new stable map: the engines were upgraded IN PLACE on the running bed of
section 3b (`thebes-deploy upgrade`, stable types checked compatible), the persisted book,
obligations and reservations surviving — witnessed by the battery's seed lines — and the two
stale dust obligations the 3b runs had left permanently unsettled were voided by the first
drain of the new code. Run of record: `docs/chain-battery-2026-09-24b.log`, **116 of 116 rows
pass** on the same four-validator localhost chain and binary (sha256 `d34849bd…`). The MD rows
now pin the fixed behaviour:

| Row | What was shown |
|---|---|
| MD0 | An order whose qty is at or below the shares ledger fee is refused at intake, both sides |
| MD1 | A floor-passing book still yields a boundary remainder fill at or below the fee, mid-window; the three-fill schedule equals the twin's |
| MD2 | The drain voids the permanently refused fill: recorded with its reason, no trade ever created |
| MD3 | The drain completes the window past the voided fill — nothing left unsettled (the 3b liveness gap closed) |
| MD3b | The two good fills settle exact to the twin; the voided fill moves nothing |
| MD4 | `settleObligation` on the voided seq reports the final resolution and creates no trade |

MF2 tightens with the fix: no obligation of the run is left unsettled, with no dust exception.

## 3d. The autonomous drain rebuilt as a bounded inline sweep, verified on a fresh chain of the same binaries (2026-09-27)

The second defect of section 3b is resolved engine-side by taking the substrate primitive it
depended on out of the drain's path entirely. The lesson of the M3f defect generalised: this
bed does not reliably dispatch a message the caller never awaits - the post-await Timer was one
face of it, and a fire-and-forget self-call armed after the settlement await proved to be
another (it ran inline in one controlled trace and was dropped in a battery run). So the drain
no longer hands the next step to any such message. `settleMatched` now performs a BOUNDED
INLINE SWEEP: within the one message the caller awaits, it walks the window's open obligations
in seq order and resolves each in turn - settles it through the core, or, by the unchanged 3c
discipline, voids it when the refusal is permanent and no trade exists - advancing a cursor past
every obligation it touches, until it has attempted `MAX_FILLS_PER_CHUNK` of them (each attempt
is one inter-canister round trip, so this bounds the message's work exactly as the same constant
bounds a clear chunk) or the window is empty. The relayer calls it until `remaining` reaches
zero - the identical loop-to-completion contract as the chunked clear's `continueClear`, and for
the same reason: one message does a bounded slice and the caller drives the rest. A transiently
refused obligation (balance, allowance, a ledger outage, a concurrent sweep holding the core's
per-trade lock) is stepped over within the sweep and left unsettled, so it can never head-block
the fills behind it, and a later sweep retries it; the new public `continueSettle(window,
deadlineSecs, afterSeq)` resumes a sweep past a given seq, the deterministic skip a relayer uses
when a refused obligation sits at a window's head and its condition has not cleared. That the
substrate executes every one of a message's sequential settlement awaits - not just the first -
was confirmed directly on this bed before the run: one `settleMatched` call against a
three-fill window settled exactly two (the `MAX_FILLS_PER_CHUNK` bound) and reported "2 of 2
attempted settled this sweep", the third draining on the next call. No stable state was added
and the response shape is unchanged.

The verification bed is a fresh localhost chain of the same production node binary (sha256
`d34849bd…`), stood up by `thebes-deploy start --clean` after the 3b/3c chain was retired. The
retirement is itself a record: on that bed, every `InstallCommit(upgrade)` for the ungated
engine's cid arrived at `post_upgrade` with a zero-length argument (four executed attempts,
each trapped decoding the class parameter and rolled back cleanly to the old wasm, state
intact), while the gated engine's identical wasm upgraded in place with its argument intact,
stable types checked compatible and state preserved; during the failing attempts two of the
four validators safety-halted on INV-D4-PEER-PARITY (one reporting an all-zero state root) -
the halt working as designed against drifted state. The deploy tool's own recovery for a stuck
chunked-install session is a fresh cid (the upload id derives from the cid, and a failed
commit's session has no GC), so the chain, no longer trustworthy as a verification bed, was
retired rather than repaired around. Raw incident logs are kept beside the run artifacts
(`test/chain/out/incident-2026-09-27/`, local, not committed).

The nine contracts of `deploy/example.thebes.toml` were installed fresh with `thebes-deploy`
(`moc --legacy-persistence`, the same wasm the failed upgrades carried), and the full battery
driven by `test/chain/battery.py` against the stateful Python twin. Log:
`docs/chain-battery-2026-09-27.log`. **118 of 118 rows pass.** Against section 3c's 116: the
five M3 drain rows that pinned the one-call-per-obligation defect became one row (M3e, the
looped inline drain), the MD drive flipped to the looped sweep, and a new six-row M6 section
revokes an allowance mid-drain to show the sweep step over the refused fill, settle the one
behind it, refuse to void it, and re-drive it to settled once the allowance returns. The fresh
bed also re-proves the L8 unminted-collection refusal, provable only while the land collection
is empty.

| Row | What was shown |
|---|---|
| M3e | `settleMatched` drains the whole five-fill window in bounded inline sweeps looped to completion - no Timer, no self-message - verified by query |
| M6a | A two-party window clears two cross-party fills - the maker selling the first, the taker the second - equal to the twin |
| M6b | The maker's shares allowance to the core revoked, the sweep's first attempt is refused at leg escrow; the same bounded sweep steps its cursor past it and settles the fill behind it - a transient refusal cannot head-block the drain |
| M6c | The refused obligation owns a trade (the core created it before the escrow failed) and the void discipline leaves it alone - voiding stays reserved for permanent refusals with no trade |
| M6d | The allowance restored, the next sweep re-drives the same trade to SETTLED through the core's idempotent re-drive - nothing left unsettled |
| M6e, M6f | Balances exact to the twin, the interrupted escrow landing exactly once; the core holds no residual |
| MD1-MD4 | The dust window drains under the looped sweep - settle, void the permanent dust refusal in stride, settle - the 3c void discipline exercised inside the bounded inline drain |

## 3e. The reservation accounting made exact, and the last defect of section 3b closed (2026-09-28)

The third defect of section 3b is resolved. Reading the engine against the core's own escrow first
showed that the entry had understated it: what stranded was one face of a single miscount, and there
were three.

The escrow the core pulls for a fill is an `icrc2_transfer_from` carrying the ledger's fee, so it
debits the FUNDER the amount plus one fee, and the payout pays the escrow minus one fee, so the
recipient bears that one. Per fill a buyer therefore needs `price·qty + one cash fee` of balance AND
allowance, and a seller `qty + one shares fee`. Against that the engine (a) reserved `qty` for an ask
and no fee at all, so an ask approved for exactly its qty was ADMITTED and its escrow could then only
be refused - the engine told a trader an order was fundable that never was; (b) released a filled
bid's notional but never its one-fee margin, which is the strand the record named; and (c) released
the WHOLE notional at the fill, leaving the two escrows a created obligation still owes reserved
nowhere at all, so between the clear and the settlement the same trader could submit a new order
against the very funds the cleared match needed. (c) is not in the earlier record.

The size of (b) is not an inference. The bed of sections 3b-3d is still running the binary those
sections report, and in a state where the correct reservation for every trader is unambiguously
zero - no order resting, no obligation unsettled - it reserves 10 cash for the maker and 80 for the
taker: ninety units held against nothing, nine stranded fees, read from it by query.

The fix decides the accounting rather than releasing the margin. A reservation is denominated PER
ESCROW, in three terms and one rule. A live order reserves its remaining notional plus ONE fee, the
fee of the next escrow it can produce. Every created-but-unresolved obligation reserves its OWN EXACT
escrow cost - the notional at the clearing price plus one fee, on each side - from the moment its fill
is applied until it settles or is voided. And every unit reserved has exactly ONE release event: an
order's notional as a fill consumes it or at cancel and kill, an order's margin when the order goes
terminal, an obligation's hold when it resolves. So `reserved(p)` is the sum over that trader's live
orders of remaining notional plus one fee, plus the sum over its open obligations of their exact
escrow cost, and a trader with no live order and no open obligation has reserved EXACTLY ZERO. A
K-fill order's K fees are discovered as its fills are applied, each obligation bringing its own, which
is why one fee at intake is a floor and not an estimate: intake cannot know how many escrows an order
will produce, and under this model it does not have to.

The arithmetic and the five transitions are a new PURE module, `matching/src/Reservations.mo`, over
the engine's own maps - the actor and the interpreter battery call the same functions, so the property
battery exercises production code. Every release replays an amount that module itself recorded
(`orderMargin` per live order, `obligationHold` per obligation, both TAKEN rather than recomputed), so
a ledger that moves its fee between intake and escrow cannot make a release differ from its
reservation, and a resolution is idempotent under an idempotent re-drive, a second void, or two
callers racing one seq. A release that ever exceeded its reservation is returned as a drift and
written to the no-stranding invariant log instead of vanishing into a clamped subtraction: unreachable
by construction, and asserted so. Nothing was added to any await path and no Timer moved - the fee a
margin is denominated in is the one intake already reads for the dust floor, recorded on the order, so
`clearWindow` and `continueClear` gained no await and the chunk-resume Timer of section 3b stays armed
in an await-free message, which the M1 and M3 rows continue to prove.

The interpreter battery for the matching engine goes from 53,425 checks to 190,256: a new part drives
those production functions over 900 randomised lifecycles and 9,970 intakes, fills (whole and partial),
cancels, kills, settlements, voids and repeated resolutions, checking after EVERY step that no release
exceeded what was reserved and that the reservation equals what the model prescribes for the live book
and the open obligations, and after every trial - once each order is closed and each obligation
resolved - that it is exactly zero with all four maps empty: not one key, not one unit.

The verification bed is a SECOND localhost chain, deliberately not the one the 118-of-118 run was made
on: four validators on 127.0.0.1:18490-18493 with its own boundary and chain id 31338, so that bed and
the binaries it runs were never touched (its engine still answers that it has no `reservationAudit`
method, and the ninety units above were read from it read-only). The nine contracts were installed
there on a bit-identical copy of the binary that bed runs (`e523835b…`, the module hash both chains
report), and driven under the OLD accounting until they held the state a fix has to carry: two
obligations settled, one left unsettled, one ask resting live on 77 shares, and three stranded fees -
the taker's reserved cash at exactly 30, predicted before the calls were made and read back equal.
Both engines were then UPGRADED IN PLACE (`thebes-deploy upgrade`, "stable types: compatible with what
is installed", module hash `0b56f142…`), the ungated engine's cid included - the cid whose
`InstallCommit(upgrade)` failed four times on the retired 3b/3c chain - with no zero-length argument
and no validator halt, on two independent attempts. Across the upgrade the window, the book and the
obligation schedule came back byte for byte and the reservations unchanged; the new `reservationAudit`
then attributed them exactly, the maker's 77 shares fully prescribed by its live ask and the taker's
30 cash prescribed by nothing at all - the previous accounting's residue, isolated by the new query on
state the previous accounting created.

Log: `docs/chain-battery-2026-09-28.log`. **131 of 131 rows pass.** Against section 3d's 118: a
ten-row M7 section, and one precondition row for each scenario that needs a known book.

| Row | What was shown |
|---|---|
| M7a | On an emptied book the audit reconciles: no live order, no open obligation, nothing prescribed - what stands is the previous accounting's residue, measured and not assumed |
| M7b | An ask reserves its qty AND the one fee its escrow costs - the leg the previous accounting missed, which admitted an ask whose escrow could only be refused |
| M7c | Cancelling it releases the notional AND the margin: the reservation is the baseline again, to the unit (the margin used to stay for the life of the engine) |
| M7d | At intake a bid reserves its notional at its own limit plus exactly ONE escrow fee |
| M7e | The window clears two fills and the bid then reserves TWO escrows - one fee per fill, the second discovered at the clear where intake had reserved one |
| M7f | The cleared-but-unsettled obligations hold their escrow costs on both sides: what a cleared match owes is not free for another order to spend |
| M7g | The audit reconciles while the obligations are open: the prescription recomputed from the engine's own book and holds equals what it maintains, to the same residue |
| M7h | The drain settles both fills and every unit reserved comes back: the baseline again on both sides, to the unit |
| M7i | The whole lifecycle left the residue untouched - the strand is frozen at what it was and this accounting never adds to it |
| M7j | Balances after the M7 window exact to the twin |
| M6pre, MDpre, M7pre | The open window holds only orders the twin knows, so each of the three scenarios that names its own fills gets the book it describes |

The run also corrected two defects in the battery itself, both of which had been latent rather than
absent. **M5d was not idempotent across runs**: it asserts that a maker's bid is refused for want of a
cash allowance, which holds only while the maker has none - true on a fresh bed, false on any bed where
an earlier run's M6 had granted one, and allowances persist on the ledger. Section 3d was a single run
on a fresh chain, so it never surfaced. Because a row that expects a refusal does not mirror its order
to the twin, the order it wrongly accepted then rested in the book and self-matched against the maker's
own asks in the windows that followed: three obligations whose buyer and seller are the same trader,
which the core refuses and which can never settle. The row now asks for a notional above any allowance
this battery grants and far below the caller's balance, so what refuses it is the allowance gate
whatever an earlier run left behind. **And the three scenario preambles absorbed that pollution
silently**, cancelling only the resting orders the twin knew; they are now one helper that cancels
those and then ASSERTS nothing else is resting, so an unmirrored order is one row naming the cause
rather than a dozen failures downstream. The engine was not implicated in any of it: through every
polluted window the invariant log stayed empty, the audit's maintained-minus-prescribed held at the
residue on both sides, and the balance rows stayed exact to the twin - a self-match is a refusal, not
an accounting drift, and the drift oracle correctly did not fire. The claim that the bed persists and
re-runs are safe now holds for the whole battery, and is itself established by a second full run on
the persisted bed.

Two limits are worth stating. The fee a margin and a hold are denominated in is the one read live at
the order's intake, the fee the order was admitted under; a ledger that RAISES its fee between intake
and escrow leaves that hold short by the difference, the escrow then refuses transiently and the drain
retries it, and the accounting stays exact regardless because a release is always the amount recorded
when it was reserved. And the residue of the previous accounting does not disappear: a margin the old
code never recorded cannot honestly be released by the new one, so on a bed carried across the upgrade
the strand stays at what it was - 30 on this bed, measured by M7a and asserted frozen by M7i - and only
a contract installed fresh starts at zero.

## 4. On local replicas (September 2026)

The core as a consumer of journal-backed ledgers: reservation escrow on such ledgers, and the rule
that a ledger `Duplicate` reply is not trusted until the named escrow is verified.

## 5. Not established

- **The matching engine and the listing registry on a geographically distributed subnet
  under the production environment.** Sections 3b-3d establish them on the production node
  binary on one machine, with `test/chain/battery.py` covering them end to end - the
  autonomous drain rows included; the distributed composition of section 3's bed remains to
  be run.
