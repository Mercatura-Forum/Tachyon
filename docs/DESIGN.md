# Design

## 1. What is settled

A trade references a delivery leg `(ledgerA, assetA)` and a payment leg `(ledgerB, amountB)`.
Each ledger is an ICRC ledger: ICRC-1/ICRC-2 for cash and for fungible assets, ICRC-7 for a unique
asset. The core is indifferent to what the legs are; the same state machine settles token against
token, shares against cash, and a registered unique asset against cash. This is BIS DvP Model 1:
gross, simultaneous, both-or-neither.

## 2. Escrow and settle, not a transfer between parties

Inter-contract calls on the substrate are asynchronous and not atomic. A design that moved leg one
by `transfer_from` and then leg two would, on a failure between the two, have moved value one way.
The core therefore moves the only non-atomic step to a point where a failure is recoverable rather
than lossy:

- **Fund.** Each party moves its leg into the core's own account (ICRC-2 `approve` and
  `transfer_from`, or an ICRC-7 transfer). The two fundings are independent. If only one lands, the
  party that funded reclaims after the deadline. No counterparty exposure exists in this phase.
- **Settle.** Possible only once both legs are confirmed in escrow. The core pays out from balances
  it already holds, asset to taker and cash to maker, so a payout cannot fail for allowance
  reasons. A transient ledger failure on a payout is retried; the core still holds the funds, so
  nothing is lost and nothing is half-applied.
- **Abort.** If both legs are not in escrow by the deadline, each funded party reclaims its escrow
  in full. No trade is left funded and stuck.

The state machine is forward-only. A payout is recorded before the call it guards, never after, so
a lost reply cannot produce a second payment.

## 3. Trust model

Parties trust the core contract, and the consensus beneath it, for the duration of an escrow only.
The core holds funds only between Fund and Settle or Abort of a live trade. There is no path out of
an escrow other than settlement to the counterparty or refund to the owner; both are enforced by
the state machine, and neither is available to a controller.

## 4. Invariants

| Id | Statement |
|---|---|
| INV-DVP-1 | Conservation: per trade and per leg, the amount paid out or refunded never exceeds the amount escrowed. The core mints and burns nothing. |
| INV-DVP-2 | DvP gate: a payout to either party requires both legs confirmed in escrow. |
| INV-DVP-3 | No double resolution: no escrow is both settled and refunded. |
| INV-DVP-4 | No stranding: a terminal status implies every escrowed leg is resolved to exactly one of settled or refunded. |
| INV-DVP-5 | Idempotent settlement: a payout replayed after a transient failure does not pay twice. |
| INV-DEL-1 to 5 | The same five over a delivery's single leg, the gate being the escrow and the taker's acceptance (section 6a). |

Each invariant is checked in the contract on every transition (`checkInvariants`); a violation
traps the message, which discards the transition. The pure decision core (`DvpLogic.mo`) holds
every state-machine decision and is exercised by the interpreter battery without a replica,
including a randomised property simulation over fund, settle, abort, retry and reorder sequences.

## 5. Ledger replies

- **`Duplicate`** from a ledger means the ledger has seen the same argument tuple before; it does
  not by itself establish that the intended transfer is the one that landed. The core verifies the
  named escrow before treating a `Duplicate` as success.
- **Reject and error are different outcomes.** Every ledger call is wrapped so that a rejected call
  and an error reply are both handled; neither leaves a status mark standing over a transfer that
  did not happen.
- **`created_at_time`** is fixed on the first attempt of a transfer and reused on every retry, so
  the ledger's deduplication window makes a retry safe.

## 6. Receipts

Every order, funding, settlement and abort is appended to a Merkle mountain range. The root is
queryable (`auditRoot`), the events are enumerable (`auditEvents`), and a settlement trail can be
re-derived and verified outside the chain.

## 6a. Delivery free of payment

A securities movement with no cash against it (a collateral pledge under a credit support annex,
its return, a transfer to a counterparty's custody account) is the case the DvP models exclude
(BIS CPSS 1992). The core settles it as a **delivery**: one leg, from a maker to a named taker,
through the trade's own escrow, payout and refund helpers on the trade's own leg state, so a
delivery's receipt has the shape of a trade's, one leg short.

- **Open and fund.** The maker opens the delivery to a named taker and escrows the leg into the
  core (`openDelivery` for a fungible leg, `openTokenDelivery` for a unique asset; `fundDelivery`
  re-drives an escrow whose reply was lost).
- **Accept.** The leg moves only when the taker has accepted it (`acceptDelivery`), within the
  deadline. This is Model 1's discipline applied to one leg: the asset moves when both parties have
  acted, never by the maker's act alone, so a delivery to the wrong account is refused by the
  account it reaches rather than reversed. A payout whose ledger did not answer is re-driven by
  `settleDelivery`, never twice.
- **Reclaim.** Past the deadline an unaccepted delivery is reclaimed by either party to the maker,
  in full and once; a delivery never escrowed closes with nothing moved.

The invariants are the trade's, one leg short: INV-DEL-1 conservation, INV-DEL-2 the gate (a payout
requires the escrow and the acceptance), INV-DEL-3 no double resolution, INV-DEL-4 no stranding,
INV-DEL-5 idempotence. Deliveries share the trades' id space, so no leg key names two escrows, and
the audit trail records DELIVERY, FUND, ESCROWED, ACCEPTED and DELIVERED or RECLAIMED under the same
root as the trades.

## 7. Matching

`matching/` is a separate contract that orchestrates the core; it re-implements neither escrow nor
settlement.

- **Frequent batch auction** with a single uniform clearing price per window (Budish, Cramton and
  Shim). Orders are staged into the current window; at the clear, demand and supply curves are
  built and the price that maximises executed volume is chosen; fills at that price are allocated
  by price-time priority with pro-rata at the margin.
- **Reservation, not custody.** Submitting an order reserves the submitter's balance against the
  core (ICRC-2 approval to the core plus an engine-side reservation); the engine never holds funds.
- **Each fill becomes a settlement obligation** and settles as a DvP trade through the core, seller
  as maker and buyer as taker, driven by the engine as the core's authorised relayer.
  `settleMatchFor` is idempotent under `matchSeq`: a repeated call re-drives the existing trade.
- **Bounded clearing.** The clear is metered against an instruction budget. When the budget is
  exhausted mid-clear, the fill slice computed so far is applied atomically, a pending clear is
  saved, and a timer resumes it next round; the remainder is re-enqueued at its original
  price-time priority. The planner is pure and read-only; the apply step mutates. Batch size is
  therefore unbounded without any operator-set cap and without any chunk being partially applied.

## 8. Listing

`listing/` is the issuer-gated registry of what is tradeable. An issuer registers a fungible share
or a unique-asset collection; the registry verifies the share is funded at listing time. The
matching engine optionally consults the registry (`listingRegistry` in its configuration); when
set, `submitOrder` refuses a pair that is not listed, and when unset the engine's behaviour is
unchanged.

## 9. References

- Bank for International Settlements, *Delivery versus payment in securities settlement systems*
  (1992): the three DvP models; Model 1 is implemented here.
- E. Budish, P. Cramton and J. Shim, *The High-Frequency Trading Arms Race: Frequent Batch
  Auctions as a Market Design Response*, Quarterly Journal of Economics (2015).
- ICRC-1, ICRC-2 and ICRC-7 token standards, including the ICRC-1
  deduplication rule on `created_at_time`.
- Merkle mountain ranges (P. Todd, 2012; used by OpenTimestamps and Grin).
