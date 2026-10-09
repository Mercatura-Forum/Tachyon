# The book: continuous trading in batches

The order book of the exchange (`book/SPEC.md` is its specification). The block is the batch: every order entered with
one chain time clears together, at one price per instrument, when the chain's time moves past it, so the order in which
messages arrived inside a block changes nothing between accounts. Funds are held at entry in the venue's book-entry
balances (credited by the depository's attestation of a transfer, by its reference) and move at the fill. Built on the
Thebes kernel as a pure core a contract composes: commands on a certified log, folded into fixed-width rows in stable
memory, thirteen command families frozen, the opening of an instrument under four eyes. The book reads the exchange's
foundation (`exchange/`) to judge who acts for which account and what may be traded.

```
book/SPEC.md           the semantics both implementations follow
book/src/              BookTypes, BookLogic (pure: ticks, collars, the auction), BookCanonical (the frozen bytes),
                       BookCore (catalogue, rows and indexes, validation, the clear, fold, lifecycle)
book/test/             the battery (Book.test.mo, WASI under wasmtime) and its off-chain check
book/integration/      reference_book.py, the specification written again in Python
book/tools/            check.sh, mutation_test.py and mutations.json, reference_control.sh
```

## The commands

| Command | Authority | What it does |
|---|---|---|
| `openInstrument` | four eyes | an instrument as the book trades it, matching the exchange's row: ledgers, lot, tick bands; a market collar |
| `setTrading` | the scheduler | an instrument open or closed for clearing as its segment's phase changes |
| `setReference` | the operator's system | the reference price, on the tick; it bounds market orders' collar prices |
| `deposit` | the depository | a transfer into the venue credited to an account's available funds, by its 32-byte reference, once |
| `withdraw` | a trader of the account's member | available funds out |
| `placeOrder` | a trader of the account's member | limit, market, immediate-or-cancel, fill-or-kill, stop, stop-limit, trailing stop (at most 64 per instrument and side); day, good-till-cancelled, good-till-date; icebergs; one-cancels-other; a self-trade instruction; the order's capacity and short-sale flag |
| `cancelOrder`, `amendOrder`, `massCancel` | a trader of the account's member | what an order holds returns; an amendment keeps its priority only for a smaller quantity at the same price |
| `flush`, `endOfDay`, `expireGtd` | the scheduler | a due clear recorded with no other command; the day's and the dated sweeps, in slices |
| `clear` | no principal | recorded by the book itself: the clear of a batch, its price and pairs |

## What an order costs

An index keeps the entry of a row that left it (the row store's tombstone) until compaction. Two things keep an
order's cost from growing with the day's history: a **low-water mark** per walked range (each side of the book, each
side's stops and trailing stops, the immediate orders, each account's orders, the day's and the dated orders), the key
below which the range holds nothing live, from which every walk starts and which every write lowers; and **upkeep** after
a command that compacts every order index in that message once its stale entries reach its live ones (at least 2,048),
so a pass costs at most twice the entries it drops. That pass runs inside one message, a spike in that message's cost;
compaction in slices across messages, which would remove the spike, needs a change to the kernel's row store.

## Verification

`book/test/run.sh` runs five batteries, each its own process (a WASI battery is one message, so the heap it allocates
is never collected; the split keeps each one small, and every linear memory is capped): `Book.test.mo` (the main
book, whose calls the chain judge makes again), `BookStreams1..3.test.mo` (random streams on fresh books),
`BookPermute.test.mo` (the permutation trials) and `BookEpisodes01..12.test.mo` (10,080 episodes of twenty random
commands, each from an empty book, written by `tools/episodes_parts.py`). Between them:

* the catalogue in both directions with its control; every family round-tripped and hashed twice; unknown bytes decode
  to nothing;
* every refusal by name, each leaving every row count, every id counter, the log's length and the fingerprint where
  they were;
* scenarios whose every effect is computed by hand from the specification (one price per batch, priority by batch,
  pro rata in lots with ties by key, fill-or-kill, market collars, stops, self-trade at entry and at a stop's trigger,
  one-cancels-other, icebergs, a closed instrument, amendments, the sweeps);
* random streams on fresh books with properties checked as they run: no pair of one account, every pair at the clear's
  price within both limits, every open book uncrossed once its clear is recorded, funds conserved per ledger, every
  account's held funds equal to what its open orders hold;
* the same block given in two orders on two fresh books, every outcome compared by the member's reference, with a
  control;
* the replay of every book's log to the same fingerprint; compaction of the book index changing no read.

`Book.verify.sh` also runs the regulator's replay (`book/integration/regulator_replay.py`): a reader holding only the
book's certified log checks every block's hash and link, refolds the book from the commands, requires every recorded
effect, and computes the book's fingerprint itself, which must be the book's. Each battery's `.verify.sh` runs the reference (`book/integration/reference_book.py`), which replays every stream from the
commands alone and requires every outcome, every block of the log, every order and every balance equal to the book's.
`book/tools/reference_control.sh` plants faults in a green log and requires the reference red on each (and the
regulator's replay on a changed block byte, a removed block and a fingerprint the book did not state);
`book/tools/mutation_test.py` removes each rule in `mutations.json` from the committed tree and requires the battery red, recording the first
failed check as the reason.
