# The book: the semantics both implementations follow

Attribution: Thebes Core Team. The Motoko book (`book/src/`) and the Python reference book
(`book/integration/reference_book.py`) implement this text independently; the battery feeds both the same command
streams and requires every fill, every order's state and every balance equal.

## 1. The block is the batch

Every command carries the chain's time `now` of the message that submits it. Messages in one block share `now`; the
book treats everything submitted with one `now` as **simultaneous**. The orders of a block are not matched one by one
as they arrive: the block's orders form a **batch**. The batch is due to clear as soon as the chain's time has moved
past it: the first command submitted with a later `now`, accepted or refused, first records the clear of the earlier
batch as a block of its own, then is judged. The scheduler's `flush` act records a due clear with no other command. Inside a batch, the order in which messages arrived changes nothing: the batch's outcome is a function of
the set of its commands.

Within a batch, in this order:
1. **cancels and amends** of resting orders are applied (a cancel in the same block as a crossing order always wins);
2. **triggers**: stop orders whose stop price the previous clear's price reached become live orders of this batch;
3. **the auction**, per instrument, over the resting book and the batch's live orders (§3);
4. **expiry**: immediate-or-cancel and market remainders are cancelled; fill-or-kill orders that did not fill entirely
   are cancelled with nothing filled; good-for-day orders are cancelled when the segment closes (§5).

## 2. Orders

An order has: account, instrument, side, quantity (a whole number of the instrument's lots), a price (limit), a type,
a validity, an optional stop price, an optional peak (iceberg), a self-trade instruction, a capacity (agency or
principal), a short-sale flag, and the member's client reference (the key the member and the battery compare by).

| Type | Price | In the auction | After the auction |
|---|---|---|---|
| limit | its limit | at its limit | the remainder rests |
| market | none | at its collar price (§6): immediate-or-cancel at that price | the remainder is cancelled |
| immediate-or-cancel | its limit | at its limit | the remainder is cancelled |
| fill-or-kill | its limit | at its limit, all or nothing (§3.4) | cancelled if not filled entirely |
| stop | a stop price; market once triggered | not until triggered | as market |
| stop-limit | a stop price and a limit | not until triggered | as limit |
| trailing stop | a stop price and a trail | not until triggered | as market |

A **buy stop** triggers when the previous clear's price of its instrument is at or above its stop price; a **sell stop**
when it is at or below. A triggered stop joins the batch in which it is triggered (step 2) with the priority of that
batch. Stops are triggered buys first, by stop price from the lowest, then sells, by stop price from the highest, ties
by order number. Two orders may be linked one-cancels-other: when either fills any quantity or is triggered, the other is
cancelled in the same batch.

A **trailing stop** is a stop whose stop price follows the price by its trail (a whole number of ticks at its stop
price). After every clear of its instrument that trades at p, a sell trailing stop's stop price becomes the greater of
itself and p − trail on the tick at or below; a buy trailing stop's the lesser of itself and p + trail on the tick at or
above; it never moves the other way. It triggers as a stop does, on the moved stop price. An instrument holds at most
64 trailing stops per side (every clear that trades moves each one); a trailing stop beyond that is refused.

An **iceberg** shows its peak and hides the rest; in the auction it takes part with its whole remaining quantity. Its
priority is the batch in which its displayed peak was last refreshed: when a clear fills the whole displayed peak, the
peak is refreshed from the hidden part and the order's priority becomes the batch of that clear.

## 3. The auction (per instrument, per batch)

### 3.1 The price
Over every live order (resting and new): demand(p) = the quantity of buys whose price is at or above p; supply(p) = the
quantity of sells at or below p. Market buys count at every p, market sells at every p. The clearing price p* is the
price, among the prices of the live orders, that maximises min(demand, supply); ties go to the least
|demand − supply|, then to the lower price. A batch where nothing crosses has no price and no fill.

### 3.2 Who fills (priority)
The volume V = min(demand(p*), supply(p*)). Every eligible order on the **short** side (the side whose eligible quantity
is V) fills entirely. On the **long** side the volume goes by **price** first, most aggressive first (buys from the
highest price, sells from the lowest), whole price levels while the volume lasts; at the level where it runs out:
- first by **priority batch**, earliest first (a resting order's batch is the one it entered or was last refreshed in),
  whole batches while the volume lasts;
- within the batch where it runs out, **pro rata** by remaining quantity, in whole lots: each order gets
  floor(left × its quantity / the batch's quantity) lots, and the lots left by rounding down go one each to the orders
  with the largest remainders of that division, ties broken by the order's **key** (the SHA-256 of its account, side,
  price, quantity and client reference), never by arrival.
Eligible means: a buy priced at or above p*, a sell priced at or below p*.

### 3.3 The pairs
Fills are paired buy to sell for the record: buys and sells each in their fill order (price, then priority batch,
then key), matched greedily. Every pair trades at p*.

### 3.4 Fill-or-kill
If a fill-or-kill order would not fill entirely, it is removed and the auction is computed again; the order removed is
the fill-or-kill order with the latest priority batch, then the greatest key. Repeat until stable.

### 3.5 Self-trade prevention
Checked at entry against the account's own live orders on the other side of the same instrument. Like the funds check
(§4), it is judged when the order arrives, so within one block the first of two of an account's own orders that would
cross each other (or together exceed its funds) stands and the second is refused: the one place where arrival inside a
block matters, and it concerns only that account's own orders; for every other participant the batch is a function of
its set of commands. If the new order's
price would cross one of them (a buy at or above the own sell, a sell at or below the own buy; a market order always
crosses), the order's instruction applies: **cancel incoming** (the new order is refused), **cancel resting** (every
crossing own order is cancelled, the new order accepted), **cancel both**. A stop is not judged at entry, since it does
not trade until triggered; it is judged when it is triggered (step 2), against the account's own live orders at that
moment, the stops triggered before it in the same step included: **cancel incoming** cancels the triggered stop,
**cancel resting** cancels every crossing own order, **cancel both** both; the triggered stop is listed as triggered
and, when cancelled, as cancelled, and its one-cancels-other partner is cancelled either way. A pair of the same account
never trades.

## 4. Funds: held at entry, moved at the fill

Each account has, per ledger, an **available** and a **held** balance, in the ledger's smallest unit. A deposit,
attested by the depository with the reference of the ledger transfer into the venue, adds to available; a withdrawal
takes from available. A buy holds limit × quantity of cash at entry (a market buy holds the instrument's reference
price × quantity × the market collar, §6); a sell holds its quantity of shares. An order whose holding exceeds
available is refused. At a fill of q at p*: the buyer's held cash falls by its price × q, of which p* × q goes to the
seller's available cash and the rest returns to the buyer's available; the seller's held shares fall by q and the
buyer's available shares rise by q. A cancel or expiry returns what the order still holds. **Conservation:** per
ledger, the sum of every account's available and held equals deposits less withdrawals, at every step.

## 5. Validity and the segment's phases

Good-for-day orders are cancelled by the scheduler's end-of-day sweep; good-till-date orders by its expiry sweep for a
day, which must be the chain's market day at submission; good-till-cancelled orders rest until filled or cancelled. A
batch clears an instrument only while the book holds it open (set by the scheduler from the segment's phase); while it
is closed its resting orders wait, and the batch's immediate orders (market, immediate-or-cancel, fill-or-kill, a
triggered stop) are cancelled at the clear, since they cannot wait. A good-till-date order is valid through its day;
the expiry sweep for day d cancels those whose day is before d.

A stop triggered by a clear's price, or placed when the last clear's price already triggers it, joins the next clear:
its instrument is due, and the first command with a later `now` (or the scheduler's flush) records that clear, whose
time is the last recorded block's; the stops it triggers take that time as their priority. An amendment applies
to a live limit order: the new remaining quantity and price; a price change or a larger quantity takes the priority of
the batch it is made in, a smaller quantity at the same price keeps the order's priority.

## 6. Collars and refusals at entry

A market order's price is its collar price: for a buy the highest price on the tick at or below the reference price ×
(1 + collar), for a sell the lowest price on the tick at or above the reference price × (1 − collar); it holds and
trades as immediate-or-cancel at that price. The collar is the instrument's, in basis points, recorded when the book
opens the instrument. Every refusal leaves every row, counter and the log
unmoved, once the due clear (§1) is recorded.

## 7. What is recorded

Every order, cancel, amend, deposit, withdrawal and clear is a block of the book's log. A clear records its price and
its pairs. The book's state is the fold of the log; a replay reproduces every row.
