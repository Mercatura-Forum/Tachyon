#!/usr/bin/env python3
"""feed_book.py: a consumer of the book's public feed (book/SPEC.md §13) that holds the book from the feed alone.

It reads the battery's `F|sequence|message|feed hash` lines (every block's message, in the log's order) and its
`V|sequence|digest` lines (the visible book as the book's own state holds it after each act: every open instrument's
phase, and every live order's side, price and shown quantity). It requires:
  * the sequence without a gap, and every feed hash the chain over what it received (a dropped, reordered or altered
    message is refused at the first message it fails on);
  * every message parsed to its last byte;
  * after every act, the visible book it built from the messages, digested the same way, equal to the book's.

    python3 book/integration/feed_book.py <battery log>

Attribution: Thebes Core Team.
"""
import hashlib
import sys

DOMAIN = "thebes.book.feed.v1"
VISIBLE = "thebes.book.visible.v1"
KINDS = {}   # messages by kind, over every book read
PHASE = {"closed": 1, "continuous": 2, "auction": 3, "closingAuction": 4, "tradeAtClose": 5, "halted": 6}


class R:
    def __init__(self, b):
        self.b, self.p = b, 0

    def byte(self):
        x = self.b[self.p]; self.p += 1
        return x

    def nat(self):
        n = self.byte()
        x = int.from_bytes(self.b[self.p:self.p + n], "big"); self.p += n
        return x

    def nat64(self):
        x = int.from_bytes(self.b[self.p:self.p + 8], "big"); self.p += 8
        return x

    def len16(self):
        x = int.from_bytes(self.b[self.p:self.p + 2], "big"); self.p += 2
        return x

    def nats(self):
        return [self.nat() for _ in range(self.len16())]

    def text(self):
        n = self.len16(); x = self.b[self.p:self.p + n].decode(); self.p += n
        return x

    def boolean(self):
        x = self.byte()
        assert x in (0, 1), "a bool byte"
        return x == 1


def text_bytes(t):
    e = t.encode()
    return len(e).to_bytes(2, "big") + e


class FeedBook:
    def __init__(self):
        self.phase = {}       # instrument -> phase code
        self.orders = {}      # order -> [instrument, side, price, shown]
        self.next = 0
        self.head = bytes(32)
        self.kinds = KINDS

    def receive(self, seq, msg, fh):
        if seq != self.next:
            raise ValueError(f"a gap: message {seq} where {self.next} was due")
        h = hashlib.sha256(text_bytes(DOMAIN) + self.head + msg).digest()
        if h != fh:
            raise ValueError(f"message {seq}: its feed hash is not the chain over what was received")
        self.head, self.next = h, seq + 1
        self.apply(msg, seq)

    def apply(self, msg, seq):
        r = R(msg)
        assert r.byte() == 1, "feed version"
        assert r.nat() == seq, "the message's sequence"
        r.nat64()
        kind = r.byte()
        self.kinds[kind] = self.kinds.get(kind, 0) + 1
        if kind == 0:
            pass
        elif kind == 1:
            inst = r.nat(); r.nat(); r.nat()
            for _ in range(r.len16()):
                r.nat(); r.nat()
            r.nat(); r.nat(); r.nat(); r.nat()
            self.phase[inst] = PHASE["closed"]
        elif kind == 2:
            inst = r.nat(); self.phase[inst] = PHASE["continuous"] if r.boolean() else PHASE["closed"]
        elif kind == 3:
            r.nat(); r.nat()
        elif kind == 4:
            oid, inst, side, price, shown = r.nat(), r.nat(), r.byte(), r.nat(), r.nat()
            self.orders[oid] = [inst, side, price, shown]
            for x in r.nats():
                self.orders.pop(x, None)
        elif kind == 5:
            for x in r.nats():
                self.orders.pop(x, None)
        elif kind == 6:
            oid, price, shown = r.nat(), r.nat(), r.nat(); r.boolean()
            if oid in self.orders:
                self.orders[oid][2] = price; self.orders[oid][3] = shown
        elif kind == 7:
            for _ in range(r.len16()):
                inst = r.nat()
                self.instrument_body(r, inst, True)
                if r.boolean():
                    self.phase[inst] = PHASE["auction"]
        elif kind == 8:
            inst = r.nat(); code = r.byte(); r.nat64(); r.nat64(); r.text()
            self.phase[inst] = code
        elif kind == 9:
            inst = r.nat()
            self.instrument_body(r, inst, False)
            self.phase[inst] = r.byte()
        elif kind == 11:
            # a maker's quotes: per quote its cancelled orders, then the sides it adds
            for _ in range(r.len16()):
                inst = r.nat()
                for x in r.nats():
                    self.orders.pop(x, None)
                for _ in range(r.len16()):
                    oid, side, price, shown = r.nat(), r.byte(), r.nat(), r.nat()
                    self.orders[oid] = [inst, side, price, shown]
        elif kind == 10:
            r.nat(); r.nat(); r.p += 32      # the day's seal: day, rows, the file's hash; nothing visible changes
        else:
            raise ValueError(f"message {seq}: kind {kind}")
        assert r.p == len(msg), f"message {seq}: bytes after its body"

    def instrument_body(self, r, inst, triggers):
        """§13: revealed, then the pairs, then the removed, then the shown list; an order that shows nothing is gone."""
        r.nat(); r.nat()
        pairs = [(r.nat(), r.nat(), r.nat()) for _ in range(r.len16())]
        removed = r.nats()
        revealed = [(r.nat(), r.byte(), r.nat(), r.nat()) for _ in range(r.len16())] if triggers else []
        shown = [(r.nat(), r.nat()) for _ in range(r.len16())]
        for oid, side, price, sh in revealed:
            self.orders[oid] = [inst, side, price, sh]
        touched = set()
        for b, a, q in pairs:
            for oid in (b, a):
                if oid in self.orders:
                    self.orders[oid][3] = max(0, self.orders[oid][3] - q); touched.add(oid)
        for x in removed:
            self.orders.pop(x, None)
        for oid, sh in shown:
            if oid in self.orders:
                self.orders[oid][3] = sh
        for oid in touched:
            if oid in self.orders and self.orders[oid][3] == 0:
                del self.orders[oid]

    def digest(self):
        w = bytearray(text_bytes(VISIBLE))

        def nat(n):
            if n == 0:
                w.append(0)
            else:
                bs = n.to_bytes((n.bit_length() + 7) // 8, "big"); w.append(len(bs)); w.extend(bs)
        for inst in sorted(self.phase):
            live = sorted((oid, o) for oid, o in self.orders.items() if o[0] == inst)
            nat(inst); w.append(self.phase[inst]); w.extend(len(live).to_bytes(2, "big"))
            for oid, (_, side, price, shown) in live:
                nat(oid); w.append(side); nat(price); nat(shown)
        return hashlib.sha256(bytes(w)).digest()


def main():
    lines, kept = [], False
    for l in open(sys.argv[1], encoding="utf-8"):
        l = l.rstrip("\n")
        if l.startswith("+|"):
            if kept:
                lines[-1] += l[2:]
        elif l[:2] in ("F|", "V|", "S|"):
            lines.append(l); kept = True
        else:
            kept = False
    feed, books, messages, digests, errors = None, 0, 0, 0, []
    for l in lines:
        if l.startswith("S|"):          # a fresh book: its feed starts again at 0
            feed = FeedBook(); books += 1
            continue
        if feed is None:
            feed = FeedBook(); books += 1
        tag, seq, a, *rest = l.split("|")
        try:
            if tag == "F":
                feed.receive(int(seq), bytes.fromhex(a), bytes.fromhex(rest[0])); messages += 1
            else:
                if int(seq) != feed.next - 1:
                    raise ValueError(f"a digest after message {seq} while {feed.next - 1} was the last received")
                if feed.digest() != bytes.fromhex(a):
                    raise ValueError(f"after message {seq}: the book held from the feed is not the book's visible book")
                digests += 1
        except (ValueError, AssertionError, IndexError) as e:
            errors.append(str(e)); break
    print(f"feed: {books} books, {messages} messages received and chained, {digests} visible books compared after acts")
    print("feed: messages by kind " + ", ".join(f"{k}:{v}" for k, v in sorted(KINDS.items())))
    if errors or digests == 0:
        print("feed: DISAGREES: " + (errors[0] if errors else "nothing was compared"))
        return 1
    print("feed: the book held from the feed alone is the book's visible book after every act: VERIFIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
