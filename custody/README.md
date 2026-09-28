# Custody beside the venue: positions as the fold of the receipts, corporate actions on the record date

The custody module keeps a register of holders and their settled positions in the assets the venue lists, as
nothing but the fold of the venue's receipts — a trade's asset leg, a delivery, an issuance, a redemption, each
recorded once by its id and hash in Tachyon's Merkle mountain range — reconciles the register to the balances the
ledgers show, and applies corporate actions (a cash dividend, a split, a bonus, rights, a redemption) to the
positions of the record date, paying them on the payment date and certifying the entitlement file per holder by its
hash. It is built on the Thebes kernel (rows, commands under maker-checker, exact arithmetic) as a pure core the
venue's contract composes; it neither escrows nor moves a leg — that is the byte-frozen DvP core's — and it holds no
person: a holder is an id and an identity commitment, its ledger account a principal the reconciliation reads
balances for.

Why beside Tachyon: Tachyon's receipts are the venue's certified record of every settled movement, so a position
here has one definition — the receipts folded — and a reconciliation is the check that the fold agrees with what
the ledgers show; the listing registry is the issuer-gated source of what is tradeable, so the assets the register
holds are the venue's own.

```
custody/src/          CustodyTypes, CustodyMath, CustodyCanonical, CustodyCore
custody/test/         the battery (custody/test/run.sh: WASI under wasmtime) and its off-chain check
custody/integration/  the Python twin
custody/tools/        packages.sh, check.sh, the committed-tree gate, mutation testing, the twin's control
vendor/thebes-kernel  the kernel, pinned by commit
```

## The register

- `registerHolder` (dual): the id, the identity commitment, the ledger account. `registerAsset` (dual): the code,
  the ledgers, the issued supply (it opens in the issuer's position), the issuer.
- `recordSettlement` (single, the reason recorded): the venue's receipt `{ kind; id; block; hash }`, once; the units
  move from one holder to another and never more than the holder has; none on an asset whose struck action awaits
  payment, because the record-date positions are the entitlement's basis.
- `reconcile` (dual): the custodian attests the ledger's balances as of a block; every holder's position is
  compared, the matches and the breaks counted, the rows sealed by a hash (`tachyon.custody.reconciliation.v1`).
  The register's total and the issued supply are recorded side by side; they agree by construction.

## The corporate actions

`announceAction` (dual) records the kind and its terms, the record, ex and payment dates and the issuer's notice by
commitment; one action at a time per asset. `strikeRecordDate` (single) sweeps the holders in slices, the cursor on
the action's row, and writes an entitlement per position from `CustodyMath.entitlement`: a **cash dividend** of a
rate per unit; a **split** (`units × numerator / denominator`, floored) and a **bonus** (the additional units, floored)
with the fraction paid in cash in lieu at the declared price (`fraction × price / denominator`, floored); **rights**
(the rights floored) a holder takes up within them and by the deadline at the subscription price
(`subscribeRights`, single); a **redemption** of a ratio in basis points at a price. `pay` (single) sweeps the
action's entitlements from the payment date, delivering or taking the units and moving the issued supply by what the
action created or took back; `certifyEntitlementFile` (dual) seals the file (holder, units at record, cash due, cash
payable, units due and taken, rights and taken, fraction) by its hash (`tachyon.custody.entitlements.v1`);
`cancelAction` (dual) withdraws an action before it is paid.

## Verification

`custody/test/Custody.test.mo`: the catalogue with a control, the single acts' reasons, eleven commands round-tripped,
the row widths and the arithmetic's vectors; four holders and an asset (a holder twice, a code twice, no supply, an
unknown issuer refused); five receipts folded (the same receipt twice, an empty position, an unknown holder, a
short position refused); two reconciliations (a match and a break) with their hashes; five actions — a dividend
struck in two slices and paid in two, a split with cash in lieu, rights subscribed within the entitlement and by the
deadline with the lapse of the rest, a redemption, a bonus cancelled after its strike — with the positions and the
supply after each and the files sealed; forty-five refusals leaving the fingerprint; the replay.
`custody/test/Custody.verify.sh` runs `custody/integration/custody_twin.py`: the positions refolded from the receipts
and the paid actions, every entitlement and total recomputed from the terms, every file's and reconciliation's hash
reproduced with its own canonical writer. `custody/tools/twin_control.sh` alters an entitlement, a position and a
file hash in turn and requires the twin to go red. `custody/tools/mutation_test.py` applies ten mutants (the fraction
rounded up, the whole price for a fraction, a receipt twice, a short position, a settlement under a struck action,
the rights bound, the deadline, the supply after a redemption, every balance matched, two actions open) to the
committed tree and requires the battery to go red on each.

```
mops install
./custody/tools/check.sh
./custody/test/run.sh
python3 custody/tools/mutation_test.py
custody/tools/twin_control.sh <battery log>
```

Attribution: Thebes Core Team. Licence: Apache 2.0 (the repository's).

## The offering: underwriting, book-building, allocation, the hand-off

The offering (`OfferingTypes`, `OfferingMath`, `OfferingCanonical`, `OfferingCore`) takes a company to listing and
issues the shares this register then holds. It shares the register's kernel and its commands under maker-checker.

- **The offering (dual).** `openOffering` records:
  - the shares offered and outstanding, and a price range on a tick (at most 400 rungs);
  - the lot, and the retail tranche's share of the offer;
  - the cap on cornerstones;
  - the underwriter's fee, and whether it commits firmly or on best efforts with a minimum;
  - the listing gate (free float, holders);
  - the calendar.
- **Cornerstones (dual).** `commitCornerstone` is accepted before the book opens and within the cap. The cornerstones are
  allocated in full and locked up.
- **Bids (single).** `placeBid` and `withdrawBid`:
  - a bid is on the tick while the book is open, one live bid per investor, and a revision is a withdrawal and a new bid;
  - the ladder holds the live lots at each rung.
- **Retail (single).** `subscribeRetail`: one application per investor, paid in full at the top of the range, within
  the retail days and the tranche.
- **Pricing (dual).** `priceOffering` is accepted after both closes, never above the book's clearing price (the highest
  price at which the cornerstones and the bids at or above it cover the institutional tranche).
  - The tranches take each other's unfilled lots.
  - The underwriter takes up the rest under a firm commitment.
  - A best-efforts offering short of its minimum fails, and every retail payment is refunded.
- **Allocation (single, in slices).** `allocate` gives:
  - the cornerstones in full;
  - the bids at or above the price and the retail applications pro rata by cumulative rounding (each within a lot, each
    tranche exact);
  - the cash due and the refunds.

  The allocation file is a hash chain under `tachyon.offering.allocation.v1`, closed by the underwriter's take-up.
- **Hand-off (dual).** `handOff` is accepted on or after the listing day and behind the listing gate:
  - the free float is the book's and the retail's shares over the shares outstanding;
  - the holders are the allotted orders and the underwriter;
  - it records the gross proceeds, the fee (half up), the net to the issuer and the reference price for the first
    auction.

  `handOffLines` pages the allotments to the register, which records each one as an issuance receipt from the issuer
  and reconciles.
- **Withdrawal (dual).** `withdrawOffering` is accepted before the listing. It voids every allocation and refunds every
  retail payment in full.

The battery `test/Offering.test.mo` covers four offerings:
- a book-built flagship (3 cornerstones, 168 bids with revisions, 900 retail applications), priced a tick below the
  clearing price and handed to the register;
- a best-efforts failure;
- an undersubscribed firm commitment the underwriter takes up;
- a withdrawal at the gate.

It also has 35 named refusals and the replay. The twin is `integration/offering_twin.py`, with 6 controls in
`test/Offering.verify.sh`. The mutants are M11–M23 in `tools/mutations.json`. The screen is `docs/screens/offering.html`
(`tools/offering_screen.py`).
