"""er.py: the ExecutionReports of a member's orders, as one rule applied to a sequence of the venue's events.

The gateway drives it from the venue's replies and the public feed as they arrive; `reconstruct.py` drives it from the
book's log alone. Both feed it the same events in the same order (the log's), so every report is reconstructible: the
gateway's emitted reports and the log's reconstruction are compared field by field (every application field; the
session header and SendingTime are the session's, not the order's).

Events, in the log's order:
  ("new", order, clOrdID, symbol, side, qty, price)
  ("fill", order, qty, price)                        a pair of a clear or an uncross the order took part in
  ("cancel", order)                                  the order left the book without filling (a cancel, a sweep, a clear)
  ("replace", order, clOrdID, origClOrdID, qty, price)

Every identifier a report carries is the order's and its state's (ExecID: the order, the kind, the quantity filled or the
replacement's number), never a block number the gateway learns only later.

Attribution: Thebes Core Team.
"""

from decimal import Decimal, ROUND_HALF_EVEN

SIDE = {"buy": "1", "sell": "2"}


def px(minor):
    """A venue price in minor units (piastres) as a FIX Price in pounds with two decimals."""
    return f"{minor // 100}.{minor % 100:02d}"


def avg_px(notional, cum):
    """The average price of the fills, exactly: the notional in minor units over the quantity, in pounds to six decimals,
    half-even (FIX's AvgPx is a decimal)."""
    if cum == 0:
        return "0"
    return str((Decimal(notional) / Decimal(cum * 100)).quantize(Decimal("0.000001"), rounding=ROUND_HALF_EVEN))


class Book:
    """The member's orders as the reports describe them."""

    def __init__(self, account):
        self.account = account
        self.orders = {}      # order -> dict(clOrdID, symbol, side, qty, cum, price, notional, open)

    def apply(self, ev):
        """The reports one event makes: a list of FIX field lists (tag, value) for ExecutionReports (35=8)."""
        kind = ev[0]
        if kind == "new":
            _, order, cl, symbol, side, qty, price = ev
            self.orders[order] = dict(cl=cl, symbol=symbol, side=side, qty=qty, cum=0, price=price, notional=0, open=True, replaced=0)
            return [self.report(order, f"{order}.N", "0", "0")]
        o = self.orders.get(ev[1])
        if o is None or not o["open"]:
            return []
        order = ev[1]
        if kind == "fill":
            _, _, qty, price = ev
            o["cum"] += qty; o["notional"] += qty * price
            done = o["cum"] >= o["qty"]
            if done:
                o["open"] = False
            return [self.report(order, f"{order}.F{o['cum']}", "F", "2" if done else "1", last=(qty, price))]
        if kind == "cancel":
            o["open"] = False
            return [self.report(order, f"{order}.C", "4", "4")]
        if kind == "replace":
            _, _, cl, orig, qty, price = ev
            o["cl"], o["qty"], o["price"] = cl, o["cum"] + qty, price
            o["replaced"] += 1
            return [self.report(order, f"{order}.R{o['replaced']}", "5", "1" if o["cum"] else "0", orig=orig)]
        raise ValueError(kind)

    def report(self, order, exec_id, exec_type, status, last=None, orig=None):
        o = self.orders[order]
        fields = [("37", str(order)), ("11", o["cl"])] + ([("41", orig)] if orig else []) + [
            ("17", exec_id), ("150", exec_type), ("39", status), ("1", str(self.account)), ("55", o["symbol"]), ("54", SIDE[o["side"]]),
            ("38", str(o["qty"])), ("40", "2"), ("44", px(o["price"]))]
        if last:
            fields += [("32", str(last[0])), ("31", px(last[1]))]
        fields += [("151", str(max(0, o["qty"] - o["cum"]) if o["open"] else 0)), ("14", str(o["cum"])), ("6", avg_px(o["notional"], o["cum"]))]
        return fields
