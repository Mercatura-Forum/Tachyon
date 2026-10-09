"""orderlog.py: a member's order events from the book's log, or from its drop copy.

Both are the log: the certified log's raw blocks, or the member's scoped page of it (book/SPEC.md §14: its own blocks raw,
every other block that concerns it as the public feed's message). A raw block gives the member's placements and
replacements; every block, raw or projected, gives the fills and removals as the public feed carries them. The events
feed one `er.Book` per account, so the reports are the ones the gateway's rule gives.

Attribution: Thebes Core Team.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "book", "integration"))
import er  # noqa: E402
import feedwatch  # noqa: E402
import regulator_replay as RR  # noqa: E402
import feed_projection as FP  # noqa: E402


class Reports:
    """The reports of the orders of some accounts (`accounts`, or every account of member `member`), entry by entry."""

    def __init__(self, accounts=None, member=None):
        self.accounts, self.member = accounts, member
        self.books = {}          # account -> er.Book
        self.where = {}          # order -> account

    def mine(self, c):
        return (self.accounts is not None and c["account"] in self.accounts) or (self.member is not None and c["member"] == self.member)

    def raw(self, block_bytes):
        """A raw block: its command's events for these accounts, then its feed projection's."""
        b = RR.read_block(block_bytes)
        out = []
        ev = b["event"]
        if ev["t"] == "executed":
            c, e = ev["command"], ev["effects"]
            if c["k"] == "placeOrder" and self.mine(c):
                book = self.books.setdefault(c["account"], er.Book(c["account"]))
                self.where[e[1]] = c["account"]
                out += [(e[1], r) for r in book.apply(("new", e[1], c["ref"], str(c["instrument"]), c["side"], c["qty"], e[3]))]
            elif c["k"] == "replaceOrder" and e[1] in self.where:
                book = self.books[self.where[e[1]]]
                out += [(e[1], r) for r in book.apply(("replace", e[1], c["ref"], book.orders[e[1]]["cl"], c["qty"], c["price"]))]
        return out + self.projected(FP.message(b))

    def projected(self, msg):
        """A feed message: the fills and removals of these accounts' orders."""
        out = []
        for fe in feedwatch.events(msg):
            if fe[1] in self.where:
                out += [(fe[1], r) for r in self.books[self.where[fe[1]]].apply(fe)]
        return out

    def entry(self, own, data):
        """A drop copy entry: the member's own block raw, any other as the feed's message."""
        return self.raw(data) if own else self.projected(data)
