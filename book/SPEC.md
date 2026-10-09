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
opens the instrument, within its static band (§10). Every refusal leaves every row, counter and the log
unmoved, once the due clear (§1) is recorded.

## 7. What is recorded

Every order, cancel, amend, deposit, withdrawal and clear is a block of the book's log. A clear records its price and
its pairs. The book's state is the fold of the log; a replay reproduces every row.

## 8. Phases

Each instrument is in one phase: **closed**, **continuous**, **auction** (a call: the opening auction, a volatility
interruption, the resumption after a halt), **closing auction**, **trade at close**, or **halted**. The scheduler moves an
instrument between the scheduled phases (closed, continuous, auction, closing auction, trade at close) with `setPhase`,
from its segment's schedule; `setTrading` remains as continuous (open) and closed. A phase it is already in is refused.
A halt and a resumption are acts under four eyes (§11); a halted instrument takes no `setPhase`.

- **Continuous:** §1 to §7.
- **Closed:** no clear trades; a batch's immediate orders are cancelled at its clear (§5).
- **Auction and closing auction (call phases):** orders are accepted and wait; nothing trades until the uncross; market
  orders wait at their collar price; immediate-or-cancel and fill-or-kill orders are refused (they cannot wait); stops
  do not trigger (no trade sets a price).
- **Trade at close:** each batch trades at the closing price only: buys at or above it, sells at or below it, the volume
  the lesser of the two, allocated as §3.2 at that price; the batch's immediate orders end with its clear.
- **Halted:** no order is accepted and none amended (cancels are); no clear trades; a batch's immediate orders are
  cancelled at its clear.

The scheduler opens an auction with an optional random end window (`endFrom`, `endTo`): its uncross is refused before
`endFrom`. The moment within the window is drawn by the venue from the chain's randomness in the block that ends the
auction, after every order it admits; the book records the uncross with its block like any act.

## 9. The uncross

`uncross` (the scheduler's, or the venue's at the drawn end) is accepted only in a call phase, not before its window's
start or the end of an interruption (§10). It computes the auction over every live order of the instrument at one price:

1. the price, among the live orders' prices, that maximises the executable volume min(demand, supply);
2. among those, the least surplus |demand − supply|;
3. if every remaining price has more demand than supply, the highest; if every one has more supply than demand, the
   lowest;
4. otherwise the reference, the last trade's price (the reference price if the instrument has not traded), against a
   range: with surpluses on both sides, from the highest remaining price with more demand to the lowest remaining price
   with more supply; with no surplus at any remaining price, from the lowest to the highest of them. The reference if it
   lies in the range, else the nearer end.

The allocation and the pairs are §3.2 and §3.3 at that price. Market orders left unexecuted are cancelled. The price
becomes the last price; an uncross in the closing auction sets the closing price (the last price if nothing traded).
Trailing stops follow it (§2) and stops it reaches are due. The instrument moves to the phase the uncross names
(continuous, trade at close or closed); the window and the interruption are cleared. An uncross whose price lies outside
the static band (§10) trades nothing and the auction continues.

## 10. Price bands, volatility interruptions, circuit breakers

An instrument carries a **static band** (`staticBps`) around its reference price and a **dynamic band** (`dynamicBps`,
0 for none) around its last price (the reference price before its first trade), with an interruption length
(`interruptSecs`). A band around r of b basis points runs from ⌈r × (10,000 − b) / 10,000⌉ to ⌊r × (10,000 + b) /
10,000⌋. The market collar lies within the static band (`collarBps` ≤ `staticBps`).

- **At entry:** a limit price (of a limit, immediate-or-cancel, fill-or-kill or stop-limit order) or an amended price
  outside the static band is refused.
- **At a continuous clear:** a batch whose price lies outside either band trades nothing; the instrument enters a
  **volatility interruption**: an auction whose uncross is refused until `interruptSecs` after the clear's time. The
  clear records the interruption.
- The EGX's 10% move halting a share for ten minutes is the dynamic band at 1,000 basis points with an interruption of
  600 seconds; its daily limit is the static band.

## 11. Halts, the kill switch, risk limits

- **Halt and resume** (four eyes, with a reason): a halt takes the instrument to halted from any phase; a resumption
  takes it to an auction (no window), uncrossed by the scheduler.
- **Kill switch:** the operator, or a trader of the member, kills a member or one trader of it (the act always names the
  member; with a trader, that trader only): from that act no order of the target is accepted or amended. `killSweep` cancels its open orders, up to 500 an act, in order number order,
  until none is left. The block holds until a `revive` under four eyes, refused while any order of the target is open.
  Every order records its member and the trader that entered it (both checked against the exchange's rows at entry).
- **Risk limits per member** (four eyes): a maximum order quantity, a maximum order value and a credit limit (0 for
  none). A member's **use** is the value (price × remaining quantity) of its open orders, live or waiting, kept exact
  as orders change. An order whose quantity, value, or value added to the use exceeds a limit is refused; an amendment
  is judged on its new value in place of the old.

## 12. The first day

An instrument opens in the book with the exchange's reference price for it (the offering's hand-off): an opening that
names another is refused, so its first auction's reference and bands are the hand-off's.

## 13. The public feed

The feed is the book's log, projected: one message for every block, in the log's order, its sequence the block's index.
It names no account, member, trader, client reference or caller. A consumer that applies the messages in order holds
every order the book shows, at the price and quantity it shows, and every instrument's phase, after every block.

**What an order shows.** A live order shows its remaining quantity; an iceberg its peak, or what remains when less. A
waiting stop shows nothing until a clear triggers it. The log records what becomes visible, so the feed needs nothing
but the log: a placed order's effects carry the price it rests at (a market order's collar) and the quantity it shows
(0 unless live); an amendment's carry what the order shows after it (0 for a waiting stop); a clear's carry, for each
stop it triggers, the order, its side, its price and what it shows, and, after the trades, each iceberg that traded and
stays live with what it shows; an uncross's carry the same for its icebergs.

**The message** (the kernel's canonical writer): a version byte (1), the sequence (nat), the block's time (nat64), a kind
byte, then:

| Kind | From | Body |
|---|---|---|
| 0 | a proposal, an approval, a rejection, an expiry; a deposit, a withdrawal, a kill, a revival, risk limits, a flush; a placed stop (it waits hidden) | nothing |
| 1 instrument | openInstrument | instrument, lot, reference price, bands (count, then from-price and tick each), collar, static and dynamic bands, interruption seconds |
| 2 trading | setTrading | instrument, open (bool) |
| 3 reference | setReference | instrument, price |
| 4 add | a placed live order | order, instrument, side (1 buy, 2 sell), price, shown, then the account's own orders it cancelled (count, orders) |
| 5 remove | a cancel; a mass cancel, the day's sweep, the dated sweep, a kill's sweep (their effects' orders); an order cancelled with the resting (its cancelled resting orders) | count, orders |
| 6 amend | an amendment of a live order | order, price, shown, priority kept (bool) |
| 7 clear | a clear | count of instruments, then each: instrument, price, volume, pairs (count, then buy, sell, quantity), removed (count, orders), revealed (count, then order, side, price, shown), shown (count, then order, shown), interrupted (bool) |
| 8 phase | setPhase, halt, resume | instrument, phase byte (§8 codes), window from and to (nat64; 0 for none), reason (a halt's; empty otherwise) |
| 9 uncross | an uncross | instrument, price, volume, pairs, removed, shown (as in a clear), phase after |
| 10 day | the day's seal (§15) | day, rows, the file's hash |

An amendment of a waiting stop is kind 0. A removal may name an order the feed never showed (a waiting stop cancelled):
a consumer ignores an order it does not hold. Within a clear's instrument, a consumer applies the revealed orders, then
the pairs (each reduces both orders' shown quantity; an order whose shown quantity reaches 0 and which the shown list
does not name is gone), then the removed, then the shown list, then the interruption (the instrument enters an
auction). An uncross's phase after sets the phase; an interruption, a halt (halted) and a resumption (auction) set it.

**The chain.** The feed hash of block n is SHA-256 of the text `thebes.book.feed.v1` written canonically, the feed hash
of block n − 1 (32 zero bytes before block 0), and the message. The book keeps the hash of every block and the head
(the last), in its fingerprint; a consumer that recomputes the chain over what it received detects a gap, a reordering
or an altered message at the first message it fails on.

## 14. The drop copy

A member's drop copy is every block of the log that concerns it, in the log's order, and nothing else. A block concerns a
member when its command names the member (a placement, a deposit, a withdrawal, a mass cancel, a kill and risk limits
carry the member; the exchange's rows are checked to agree), names an order of the member (a cancel, an amendment), names
a kill of the member (its sweep, its revival), or when its effects name an order of the member (a clear's or an
uncross's pairs, removed, revealed and shown orders; a sweep's orders). A proposal, an approval, a rejection or an expiry
concerns no member: the execution it leads to does.

An entry is the block's index, whether the block is the member's own (its command names the member, its account, its
order or its kill), and the block: the stored block itself when it is the member's own, the block's public message
(§13) otherwise, so that no entry carries another member's account, client reference or trader, or the caller of a
block that is not the member's. The book keeps, for every member, the index of its blocks, written with the feed; the
drop copy is read in pages from a block index, scoped to the caller's member.


## 15. The day's statistics and its sealed file

**The session's statistics.** For every instrument the book keeps, since the last seal: the first, highest, lowest and
last price traded, the closing auction's price (the closing price an uncross out of the closing auction fixes; 0 when
none ran), the volume, the value (price × quantity, summed) and the number of trades (pairs), every one updated by every
pair of a clear or an uncross.

**The seal.** `sealDay(day)`, the scheduler's: `day` must be the market day of the act's time (the exchange's clock) and
later than every day sealed before. It writes the day's file, records each instrument's statistics as the day's, and
starts a new session (every instrument's statistics back to nothing). Its effects are the day, the number of rows and
the file's SHA-256, one effect per byte; its feed message (kind 10) carries the same.

**The file** (the kernel's canonical writer): the text `thebes.book.day.v1`, the day, the number of rows (two bytes),
then for every instrument the book holds, in instrument order: the instrument, the first, high, low and last prices,
the closing price, the volume, the value, the trades and the reference price at the seal. Anyone holding the log
rebuilds it byte for byte and its hash with it.

## 16. Insider blackouts

An insider list names, for an instrument, the client codes of persons who may not trade it (the exchange's account row
holds a member's 32-byte code for its client: the investor's unified code). `setBlackout(instrument, client, until,
reason)`, under four eyes, records one until the end of the market day `until` (0: until lifted); `liftBlackout(id)`,
under four eyes, ends it. An order or an amendment on an account whose client code is blacked out for the instrument at
the act's market day is refused (InsiderBlackout). A house account (no client code) is the member's own book and is not
an insider list's subject.

## 17. Short sales

Funds are held at entry (§4), so a sale is always covered by shares the account holds; shares it holds may be borrowed.
`borrow(account, member, instrument, quantity, reference)`, the depository's attestation of a securities loan, credits
the shares and records them owed; `returnBorrow(account, member, instrument, quantity)`, a trader's act, debits them and
reduces what is owed. What an account owns free of other sales is its available shares less what it owes (at least 0).

- A sale not flagged short whose quantity exceeds what the account owns free is refused (ShortSaleNotFlagged); an
  amendment of such a sale may add only what the account owns free.
- A sale flagged short names a limit (a limit, immediate-or-cancel, fill-or-kill or stop-limit order) at or above the
  instrument's last trade price (its reference price before any trade); otherwise it is refused (ShortSalePrice). An
  amendment of it is judged on its new price.
- A return may not exceed what is owed nor what is available.
