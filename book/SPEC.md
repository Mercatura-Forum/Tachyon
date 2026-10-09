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

## 18. The central counterparty and clearing accounts

Two kinds of account trade on one book. A **pre-funded** account is as §4 describes: funds held at entry, its fill final
at the fill (BIS DvP Model 1). A **clearing** account belongs to a clearing member and is designated under four eyes;
its fills are **novated** to the venue's central counterparty (the CCP), which faces every clearing member, and settle
in a cycle (§19). An account is designated only while it has no open order, and a designation is permanent, so an
order's kind is its account's at entry for its whole life.

**The market's clearing terms** (four eyes): the CCP's account (an exchange account of the CCP's member, empty and with
no order when first named), its member and the clearing currency (fixed by the first act), the cycle (seconds, or a
number of business days, §19), the fail penalty in basis points, the deadline in failed cycles before a close-out, the
guarantee fund's rate in basis points of a member's largest cycle purchase and its floor. Per instrument, the initial
margin in basis points of value (four eyes). The CCP's account moves only by clearing: no deposit, withdrawal, loan or
trader's order on it.

**A clearing member** (four eyes; at most 64) has a settlement account (one of its accounts, where its cash and
shares settle), a credit line, and the CCP holds for it: its collateral (cash posted from its settlement account and
withdrawn within its requirement and the CCP's free cash), its guarantee fund contribution, its **custody** (the shares
it bought and not yet delivered, and the shares pledged for its sales), and its cash obligations in the cycles not yet
settled (owed to it, owed by it).

**At entry**, a clearing account's order:
- a **buy** holds no funds; it holds its initial margin (the instrument's rate × price × quantity, rounded up; a market
  order at its collar) in its member's requirement, and is refused (FundShort) while the member's fund contribution is
  below its requirement; refused (MarginShort) unless the requirement — the open buys' margin, this one's, and the
  variation margin (what the member owes in unsettled cycles and rolled debt beyond what it is owed and its custody's
  value at the last price, at least 0) — stays within its collateral plus its credit line; and refused
  (LiquidityShort) unless the CCP's free cash (its account's cash less the open clearing buys' value it is committed
  to) covers the order's value;
- a **sale** is covered (§17) by the member's shares: what the CCP holds for it free of its sales, then its settlement
  account's (free of loans unless flagged short). Its shares are **pledged**: taken from the custody's free shares
  first, the rest moved from the settlement account into the CCP's account.
An amendment is judged the same way on what it adds.

**At the fill**, each pair settles as its parties' kinds say:
- a pre-funded buyer pays out of what it holds at its own price (the difference returns) and receives the shares; a
  pre-funded seller delivers what it holds and is paid;
- a clearing buyer's member owes the value in the open cycle and the shares join its custody; a clearing seller's
  member is owed the value and its pledged shares leave its custody;
- where one side is pre-funded and the other clearing, the CCP pays or is paid, receives or delivers, at the fill: a
  pre-funded party's fill is final at the fill whatever its counterparty.
A clearing buy's margin falls with what remains of it.

## 19. The netting cycle (Model 3 per cycle) and the settlement range

The scheduler **cuts** the open cycle: in a market of seconds, no sooner than the cycle's length after the last cut,
and only once the last cut cycle is settled (the cycle settles at once); in a market of business days (T+n, the
EGX's T+2), once a market day, naming the settlement day the exchange's calendar gives — n business days after the
market day, holidays and rest days skipped — so up to n + 1 cycles are pending at once.

`settleCycle` settles the oldest cut cycle when due (its settlement day reached), every clearing member not closed,
all or nothing. Each member's side is fixed before any leg moves, from the cycle as cut: what it owes (its purchases
in the cycle and its rolled debt) against what it is owed (its sales in the cycle). Payers first, so receivers are paid
out of what the payers brought in:
- a payer pays its net from its settlement account if the account holds it; otherwise it **fails**: the net rolls as
  its debt with the penalty added (the penalty accrues to the venue's skin-in-the-game), its failed cycles counted;
- a receiver is paid its net within the CCP's free cash; what the CCP cannot pay rolls to it in the next cycle.
A member that owes nothing after the cycle, and is not in default, receives the shares the CCP holds for it free of its
sales and of its purchases in later cycles (delivery against payment: shares bought in a cycle are delivered only when
that cycle is paid). A member's net equals the sum of its gross obligations in the cycle, signed.

**The settlement range.** Every movement between two of the venue's accounts is a **leg**, appended to a Merkle
mountain range under the kernel's proof hashing (`MmrProof`: leaf SHA-256(0x00 ‖ leg), node SHA-256(0x01 ‖ left ‖
right), the root bagging the peaks from the highest): kind 1, a pre-funded party's gross fill (its cash and its
shares); kind 2, a cycle's net payment, receipt or delivery; kind 3, a transfer to or from the CCP outside a fill or a
cycle (a sale's pledge, collateral, a fund contribution, the venue's skin). A leg records its kind, the ledger, the two
accounts, the units and the block that settled it; each account's holding in a ledger is therefore its deposits and
loans less its withdrawals and returns, plus its legs in, less its legs out. The root at any earlier leg count stays
computable, and a leg's inclusion proof is given against the root at any count that holds it.

**Custody composed with the book.** The custody register admits a leg as a receipt (`admitLeg`) only with its
inclusion proof against the book's own root at the count the command names, the host composing the register with the
book supplying that root; the holders are the holders the custodian linked to the leg's accounts under four eyes, the
units and the ledger the leg's, and each leg is admitted once.

## 20. Fails and close-out

A member that has failed the deadline's number of cycles in a row, or is in default, is **closed out** by the
scheduler, one instrument at a time: the CCP's account sells, as a market order at the collar, the whole lots of the
member's custody free of its sales; the order holds those custody shares. As it fills, the proceeds pay the member's
debt, and what exceeds the debt is owed to the member in the open cycle. This is a cash fail's resolution (CSDR's
sell-out); sales being covered and pledged at entry, a trade cannot fail on its delivery side, so a securities buy-in
cannot arise.

## 21. The guarantee fund, default and the waterfall

The scheduler **calls** the fund: each active clearing member's requirement is the larger of the floor's share (the
floor over the active members, rounded up) and the fund's rate × its largest cycle purchase, both from the fold. A
member pays its contribution from its settlement account, up to its requirement. The venue funds its skin-in-the-game
from an account of the CCP's member (four eyes).

A member is **declared in default** under four eyes: its member is killed (§11), and its kill is not revived before
its waterfall. Once its orders are cancelled, its shares sold and its cycles settled, `closeDefault` (four eyes) meets
what it still owes in this order: its collateral, its fund contribution, the venue's skin-in-the-game, then the other
active members' contributions pro rata to them (whole units; the units left go to the largest remainders, ties in
member order). What it had beyond its loss stays as its collateral, to withdraw; what no layer covers stays its debt;
the member is closed. Every step is a recorded act, and the waterfall moves claims on the CCP's cash, not cash: the
CCP's cash is always its members' collateral and contributions plus its skin plus what it is owed, less what it owes
(checked after every act).

## 22. Fees

An instrument's **fee schedule** (four eyes) names its levies — each a recipient account of the venue's own member (the
exchange's fee, the depository's, the regulator's) and a rate in parts per million of a fill's value — charged to
**each side** of every fill. A side's fee is its fill's value × the levies' total rate, computed exactly and quantised
**once, half-even**, to minor units; the fee is then split among the levies by the largest remainder of their rates
(the kernel's `Rounding.allocate`), so the parts sum exactly to what was charged and no difference is left to post.
A pre-funded party pays at the fill. A buy holds at entry its value, the fee on it at its own price rounded up, and
one minor unit per lot (the most a fill's rounding can take); at each fill it pays the fill's value and fee, its hold
is recomputed by the same rule for what remains, and the excess returns. A sale's fee is taken from its proceeds. A
clearing party's fee is owed by its member in the open cycle; the CCP owes it to the levies and pays them at the
cycle's settlement, after the payers, within its free cash (what it cannot pay rolls to the next cycle). An instrument without a
schedule charges nothing. Every member's fees are totalled per instrument for the period the next maker settlement closes (§25).

## 23. Member statements

Each fill of a member's account appends a line to the member's open statement (the block, the order, the side, the
quantity, the price, the fee), chained by SHA-256; the scheduler's `sealStatements` for the market day records every
open statement's hash and count of lines in the log, and opens the next. A member reads its own statement and its seal.

## 24. Member reconciliation

A trader of a member attests the balances of its member's accounts as of a market day; every attested balance is compared with the book's, the
matches and the breaks counted, the rows hashed under `thebes.book.reconciliation.v1` and recorded. A break is a
record, never a correction.

## 25. Market makers

**Registration** (four eyes): a member the exchange admitted as a market maker is registered for an instrument with
its obligations — the maximum spread in basis points of the mid, the minimum quantity on each side, the presence
required in basis points of the continuous session — and the rebate it earns when it meets them, in basis points of
the fees its fills paid on the instrument that day.

**Quotes**: a registered maker's trader enters a two-sided quote (a bid and an ask, a quantity each side) on one of its
member's accounts, or a mass quote over several instruments. A quote **replaces** the maker's live quote on that
instrument atomically: both new sides are judged first — with the funds the old quote holds counted as released —
and either both old sides are cancelled and both new ones entered in the same block, or nothing changes. Quote sides
are limit orders, good for the day, and trade as any order does.

**Presence** is measured in the fold from the block times: a maker is present on an instrument while the instrument
is in continuous trading and both sides of its quote are live with at least the minimum quantity each and a spread
within the maximum. Every act re-judges every registration and accrues the time since the last act to the presence and
to the continuous session. The scheduler's `settleMakers` for a market day records, for every registration, its
presence, the session's length and whether the obligation was met, then resets both; a maker that met it is paid its
rebate from the exchange's fee account. The rebate is the fees its fills paid on that instrument that day × the rebate
rate, quantised half-even.

## 26. Indices

An **index** is defined under four eyes: its constituents (each an instrument and its free-float shares), its base
level, a weight cap in basis points (0 for none) and its breaker's two thresholds (§27). Its level is computed in the
fold, from the same trades as everything else, never from a feed: the adjusted capitalisation M is the sum over the
constituents of the last price (the reference before any trade) × the free-float shares × the capping factor (parts
per billion, 10^9 uncapped); the level, in hundredths of a point, is M × 10^18 / D quantised half-even, D the divisor.
At definition D is M × 10^18 / (the base × 100), half-even, so the index starts at its base.

**Capping** (as the EGX 30 Capped): at definition and at every review (four eyes) the factors are recomputed so that no
constituent's weight exceeds the cap: the constituents above it are fixed at the cap, the others share the rest in
proportion, repeated until none is above; each factor quantised half-even to parts per billion.

**Continuity**: whenever the factors, the free-float shares or a constituent's price change for any reason other than
a trade — a review, a corporate action — the divisor is set again to M_after × 10^18 / the level before, half-even, so
the level does not move by itself (the divisor's purpose in index methodology).

**The path**: after every act that moves a constituent's last price, each index's level is recomputed and, when it
changed, recorded with the block.

**Corporate actions** (four eyes, with the custody register's action named by its hash): a **split** of n new for d
old multiplies the instrument's free-float shares in every index by n / d and divides its reference and last prices by
it (quantised to the tick, half-even); a **cash dividend** lowers its reference and last prices by the dividend at the
ex-date. The instrument must be closed with no open order. Each index holding it is then made continuous as above.

## 27. The market-wide circuit breaker

Each index's **reference** is its level at definition and at every day's seal (§15). When a recomputed level moves
from its reference by at least the first threshold (as the EGX100's ±10%), the book records, in the block straight after
the one that moved it, a `tripBreaker` that halts **every** instrument in that one block; by at least the second
(±20%), the halt is a **suspension to the close**: no instrument may be resumed before the next market day. A tripped
level is not tripped again until the next seal re-arms it. `tripBreaker` is the book's own act; no principal submits it.

## 28. Instrument classes and bonds

An instrument takes a **class** under four eyes, once, while it is closed with no open order: a bond, a warehouse
receipt, a certificate or a right; without one it is a share. The class's terms are reference data in the fold.

**Supply.** For every ledger the book keeps the units it holds: a deposit and a loan add to it, a withdrawal and a loan's
return take from it, as do a receipt's issue and cancellation, a retirement and an exercise; a fill never changes it. The
units of a ledger always equal the sum of its balances (available and held).

**A bond's quantity and price.** Its quantity is in units of 100,000 minor units of face (1,000 pounds) and its price in
thousandths of a percent of face (98,500 is 98.500%), so price × quantity is the clean value in minor units and every
rule of the book (holds, fees, limits, margins, the CCP's commitment) reads it as any instrument's value.

**Accrued interest.** The terms name the coupon (basis points a year), the coupons a year (1, 2, 4 or 12), the day count
(ISO 20022 A004 ACT/365 fixed, A006 30/360 bond basis, A001 ACT/ACT ICMA), the maturity and the settlement lag (T+n
business days by the exchange's calendar; government bonds T+1). The coupon dates step back from the maturity by
whole months (a day past a month's end its last day). Each market day the scheduler records the bond's **value date**,
which validation requires to be the calendar's T+n and before the maturity; an order or a quote on a bond is refused
until it is recorded, and past the maturity. A fill of q units at value date V pays the seller

  accrued = 100,000 × q × coupon × fraction(L, V) / 10,000, quantised once, half-even,

L the last coupon date on or before V and N the next: the fraction is (V − L)/365 for A004, the 30/360 bond-basis
days over 360 for A006 (the kernel's day counts) and (V − L)/(coupons a year × (N − L)) for A001 (ICMA Rule 251).
The buyer pays it beside the clean value; it moves as its own leg (kind 6); a clearing party's share joins its
member's obligation. A buy holds, and a clearing buy commits the CCP to, the most a fill can accrue whatever its
value date: a coupon period's interest counted at 31 days a month over 360, rounded up. Fees are on the clean value.

## 29. Funds and the indicative NAV

A fund's **indicative net asset value** is defined under four eyes: the units of a creation, the cash in it and its
basket (up to fifty instruments with the shares each in a creation). The iNAV of a unit is (cash + Σ mark × shares) /
units, half-even, in minor units, the marks as an index's (§26). After every act that moves a price it is computed
again and, when it changed, recorded with the block on the fund's path; both are public, as an exchange's iNAV is.

## 30. Warehouse receipts

A receipt instrument is one graded commodity; its terms name the warehouses licensed for it. The class
is taken only while none of its units is in the book and only on a ledger no other instrument uses. A licensed
warehouse's receipt is issued under four eyes to an account for a quantity, naming the warehouse's document by its
hash (once); its units are credited. When the goods leave, the receipt is cancelled under four eyes out of the account
presenting it, which must hold its quantity free. The book refuses deposits, withdrawals and loans of a receipt's
units, so the units in the book always equal the live receipts' quantities, and a cancelled receipt's units cannot be
traded.

## 31. Certificates

A certificate instrument names its registry by hash (the EGX's carbon certificates come from projects in an accredited registry). A trader of the holder's member retires certificates the account
holds free, naming the beneficiary by hash: the units leave the book and the retirement is recorded. A retired unit no
longer exists, so it can never be offered.

## 32. Rights

A right's terms name its underlying instrument, the subscription price, the ratio (num new shares for den rights), the
deadline (a market day) and the issuer's account with its member. Rights trade as any instrument until the deadline;
past it, orders and quotes are refused. By the deadline a trader of the holder's member exercises rights the account
holds free, in multiples of den: the rights leave the book, the subscription (price × the new shares) moves from the
holder's cash to the issuer's (a leg of kind 7), and the entitlement (the rights, the new shares, the payment) is
recorded for the custody register, which delivers the shares.

## 33. Attested prices

Three attestors are registered under four eyes. Each records, once a market day, its price for a derivative for that
day; a price for any other day is refused, so no position is ever marked at a stale price. A derivative's **daily
settlement price** is the median of the three attestors' prices for the day (the median of
three); a daily settlement is refused until all three have attested. The prices are public through the venue.

## 34. Futures

A future is an instrument of class `future` on an index the book computes (§26): its multiplier, its expiry day and its
initial margin rate in basis points of notional; quoted in hundredths of an index point, as the index's level. The CCP
(§18) is the counterparty: only clearing members' designated accounts trade derivatives, and a derivative's sale is a
position, never a short sale. An order holds its initial margin (contracts × price × multiplier × rate, rounded up) on
either side, within its member's collateral and credit line with every other requirement (§18, the positions' margin
included); nothing is paid or delivered at the fill.

**Positions.** A fill nets into each account's position (a buy reduces a short first). Every position is marked at the
contract's **mark** (its last settlement price; the reference price before the first): a trade at price p is marked at
once, the buyer owed (or owing) (mark − p) × contracts × multiplier and the seller the opposite, in the open cycle.
Open interest is conserved: the long contracts equal the short ones.

**Daily settlement.** After the close the scheduler settles the contract's positions in slices from a stored cursor
(the run's price fixed when it begins; trading may not reopen within a run): each position is owed or owes (price −
mark) × contracts × multiplier in the open cycle and is marked at the price; its margin is recomputed at it. The
amounts net with every other obligation and settle at the cycle (§19), failing and defaulting as any (§20, §21).

**Expiry.** On the expiry day the price is the index's level in the fold (the EGX30 future's final settlement on the
index, cash-settled through a CCP); after the last variation every position closes and the contract takes no
further order.

## 35. Options

An option is an instrument of class `option`: European, on an index, settled in cash; its strike in hundredths of a
point, call or put, multiplier, expiry, and the writer's margin rates a and b. The buyer owes the premium (price ×
contracts × multiplier) in the open cycle and its writer is owed it. A buy holds the premium as margin until filled; a
writer's order and position hold the premium at the mark plus the greater of a × the index's level less what the option
is out of the money and b × the level for a call or b × the strike for a put, × contracts × multiplier, rounded up (the
margin for short broad-based index options). The daily settlement marks the positions at the attested premium and recomputes the writers' margin. On the expiry
day each option pays its intrinsic value at the index's level, max(level − strike, 0) for a call and max(strike − level,
0) for a put, × contracts × multiplier, from its writers to its holders in the open cycle; every position closes.

## 36. The cash leg

The book settles against any cash ledger; what a national market needs is that ledger's money to be one a central bank
stands behind. Three shapes, the venue's code the same for all: (a) a **reserve ledger** the central
bank operates on the subnet: its deposits are the central bank's attestations, and a fill's cash is final on the subnet
in central bank money; (b) a **tokenised deposit ledger** a licensed bank operates: final on the subnet in commercial
bank money, the bank's own liability; (c) a **bridge** to the RTGS, which this section specifies.

**A bridged ledger** is registered under four eyes, only while none of its units is in the book, with the principal of
the RTGS operator. Its units are **claims** on cash the RTGS holds earmarked:

- an **earmark** is the RTGS operator's attestation that it reserved an amount at the central bank for a participant
  (its message named by hash, once); the bridge mints as many claims to the participant's account. Nothing else mints:
  deposits of a bridged ledger are refused;
- claims move between accounts as the cash leg of any fill, final on the subnet as claims;
- a **redemption** is a member's request to take claims out: they are held at once; the RTGS operator then attests the
  transfer out of the earmark (the claims are burned) or its failure (the claims return to the account). Nothing else
  burns: withdrawals of a bridged ledger are refused.

At every block a bridged ledger's claims in the book equal its **backing**: the cash earmarked less the cash transferred
out (the claims held by pending redemptions are still backed). Either both the RTGS's cash and the claims move, or
neither: a rejected transfer leaves the earmark and the claims as they were. The cash's finality is the RTGS's: final
when the central bank settles the transfer.
