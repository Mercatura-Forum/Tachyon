# Surveillance: the specification

Attribution: Thebes Core Team. The surveillance desk's domain: a fold over the book's log (book/SPEC.md) with its own log
of commands: alerts, cases and the daily regulatory report.

## 1. The scan

`scan(limit)`, the scheduler's: the next `limit` blocks of the book's log (at most 500), from the desk's cursor, are read
in order and folded into the desk's projections and rules; the scan records the range it read and the alerts it raised.
A scan with nothing to read is refused (NothingToScan). The desk's state is a function of the book's log and its own:
replaying both reproduces every alert, every case and every report.

**Owners.** The beneficial owner of an account is its client code (the investor's unified code, 32 bytes); a house
account's owner is its member (the byte 1, then the member, 8 bytes). A trader's identity, where a rule needs one, is
the byte 2, then the trader (8 bytes), found from the block's caller in the exchange's rows.

**Projections**, from the blocks as they are read: every placed order (its account, member, owner, side, instrument,
quantity, short flag, the block's time); every fill and every cancellation of an order (the orders a cancel, a mass
cancel, a sweep, a kill's sweep, a placement cancelling the account's own, or a clear or an uncross removing them
name); every instrument's phase (as the book's acts set it: trading opened or closed, a phase, an uncross's phase after,
an interruption, a halt, a resumption) and its last price traded in continuous trading.

## 2. The rules

Every threshold is a parameter, set under four eyes (`setParams`). Times are the book's blocks' times.

1. **Wash trade.** A pair whose buy and sell orders have the same owner: an alert for the pair (buy, sell, quantity,
   price).
2. **Painting the tape.** Trades between the same two owners: their window opens at a trade, counts every trade between
   them, and closes `paintSecs` after it opened. The `paintCount`-th trade of a window raises an alert (the window's
   first block, the count).
3. **Quote stuffing.** A trader's accepted placements, cancels, amendments and mass cancels: a window opens at one,
   counts every one, closes `stuffSecs` after it opened; the `stuffCount`-th raises an alert (the window's first block,
   the count).
4. **Spoofing and layering.** For an owner in an instrument, a window opens at an event and closes `spoofSecs` after it
   opened. In it: the quantity of the owner's orders cancelled unfilled within `spoofSecs` of their placement, per side;
   the quantity it traded, per side. When one side's cancelled quantity reaches `spoofQty` and the other side has
   traded, an alert (once a window): the side cancelled, the quantity cancelled, the quantity traded.
5. **Marking the close.** An uncross out of the closing auction that traded, where one owner's share of the volume on
   one side is at least `markShare` per cent and the price lies at least `markBps` basis points from the instrument's
   last continuous price: an alert for that owner (the largest share; between equal shares, the lower owner's bytes):
   the price, the last continuous price, the owner's quantity, the volume.

An alert is a row: its rule, the block that raised it, the instrument, the owner (and, for painting the tape, the other
owner), four figures of evidence, and the case it is in (0 for none).

## 3. Cases

`openCase(alert)`, the analyst's: a case for an alert not in one. `noteCase(case, note)`, the analyst's. `closeCase(case,
reason)` and `reportCase(case, summary)` (a suspicious transaction report filed), each under four eyes, end an open case.
Alerts, cases and reports are read by the desk and the regulator only: no read surface gives a party its own alerts
(tipping off).

## 4. The daily regulatory report

The desk's report for the day is a chain: SHA-256 of the text `thebes.surveillance.report.v1`, the chain before (32 zero
bytes at the start of a day) and a line, for every line in order:

- **a trade line** for every pair read: the block, the instrument, the buy and sell orders, the quantity, the price, the
  buy and sell members, the buy and sell accounts, and the sell order's short flag;
- **a reportable position line** when an owner's net quantity traded in an instrument since the day began first
  reaches `positionLevel` (bought less sold, in either direction): the block, the owner, the instrument, the net
  (its sign, then its magnitude).

`sealReport(day)`, the scheduler's: `day` must be the market day of the act and later than every day sealed. It records
the day, its number of lines and the chain's last hash, and begins the next day's chain. Anyone holding the book's log
rebuilds every line and the hash.
