"""feedwatch.py: a member gateway's reading of the venue's public feed: the events of orders, from the log's
projection (book/SPEC.md §13), in its order.

Each message is read as `book/integration/feed_book.py` reads it; what the gateway needs are the order events:
  ("fill", order, qty, price)  for both orders of every pair of a clear (kind 7) or an uncross (kind 9);
  ("cancel", order)            for every order a placement (4), a cancellation or sweep (5), a clear or uncross (7, 9)
                               or a quote (11) removed.

Attribution: Thebes Core Team.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "book", "integration"))
from feed_book import R  # noqa: E402
from venue_candid import Types, encode, decode, field  # noqa: E402

NAT = Types.Nat


def events(msg):
    """The order events of one feed message, in the order the message lists them."""
    r = R(msg)
    assert r.byte() == 1, "feed version"
    r.nat(); r.nat64()
    kind = r.byte()
    out = []

    def instrument_body(triggers):
        price = r.nat(); r.nat()
        pairs = [(r.nat(), r.nat(), r.nat()) for _ in range(r.len16())]
        removed = r.nats()
        if triggers:
            for _ in range(r.len16()):
                r.nat(); r.byte(); r.nat(); r.nat()
        for _ in range(r.len16()):
            r.nat(); r.nat()
        for b, a, q in pairs:
            out.append(("fill", b, q, price)); out.append(("fill", a, q, price))
        out.extend(("cancel", x) for x in removed)

    if kind == 4:
        r.nat(); r.nat(); r.byte(); r.nat(); r.nat()
        out.extend(("cancel", x) for x in r.nats())
    elif kind == 5:
        out.extend(("cancel", x) for x in r.nats())
    elif kind == 7:
        for _ in range(r.len16()):
            r.nat(); instrument_body(True); r.boolean()
    elif kind == 9:
        r.nat(); instrument_body(False); r.byte()
    elif kind == 11:
        for _ in range(r.len16()):
            r.nat()
            out.extend(("cancel", x) for x in r.nats())
            for _ in range(r.len16()):
                r.nat(); r.byte(); r.nat(); r.nat()
    return out


class Watch:
    """The feed from where the gateway last read it, in pages."""

    def __init__(self):
        self.next = 0

    def poll(self, chain, venue):
        got = []
        while True:
            v = decode(chain.query_call(venue, "feed", encode([{"type": NAT, "value": self.next}, {"type": NAT, "value": 200}])))[0]["value"]
            msgs = _field(v, "messages")
            for (seq, msg, _hash) in ((_tuple(m)) for m in msgs):
                if seq == self.next:
                    got.extend(events(bytes(msg)))
                    self.next += 1
            if not msgs or self.next >= _field(v, "next"):
                return got


def _field(v, name):
    return field(v, name)


def _tuple(m):
    """A (Nat, Blob, Blob) as the decoder gives it: a tuple, or a record with fields 0, 1, 2."""
    if isinstance(m, (list, tuple)):
        return m[0], m[1], m[2]
    return m["_0_"], m["_1_"], m["_2_"]
