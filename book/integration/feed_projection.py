"""feed_projection.py: the public feed of SPEC §13 written again from a decoded block (`regulator_replay.read_block`):
one message per block, naming no account, member, trader, client reference or caller, and the feed's hash chain. The
regulator's replay folds the chain into the book's fingerprint, so the book's own projection and this one must agree on
every byte of every message.

Attribution: Thebes Core Team.
"""
import hashlib

DOMAIN = "thebes.book.feed.v1"
GENESIS = bytes(32)
PHASE_CODE = {"closed": 1, "continuous": 2, "auction": 3, "closingAuction": 4, "tradeAtClose": 5, "halted": 6}
LIVE = 2   # the order status code of a live order


class W:
    """The kernel's canonical writer: a nat is its byte count then its big-endian bytes (zero one zero byte); a count and
    a text's length two bytes."""

    def __init__(self):
        self.b = bytearray()

    def byte(self, x):
        self.b.append(x)

    def nat(self, n):
        if n == 0:
            self.b.append(0)
        else:
            bs = n.to_bytes((n.bit_length() + 7) // 8, "big")
            self.b.append(len(bs)); self.b += bs

    def nat64(self, n):
        self.b += n.to_bytes(8, "big")

    def len16(self, n):
        self.b += n.to_bytes(2, "big")

    def nats(self, xs):
        self.len16(len(xs))
        for x in xs:
            self.nat(x)

    def text(self, t):
        e = t.encode(); self.len16(len(e)); self.b += e

    def boolean(self, x):
        self.b.append(1 if x else 0)


def message(block):
    """The message of a block decoded by `regulator_replay.read_block`."""
    w = W()
    w.byte(1); w.nat(block["index"]); w.nat64(block["time"])
    ev = block["event"]
    if ev["t"] != "executed":
        w.byte(0)
    else:
        body(w, ev["command"], ev["effects"])
    return bytes(w.b)


def body(w, c, e):
    k = c["k"]
    if k == "openInstrument":
        w.byte(1); w.nat(c["instrument"]); w.nat(c["lot"]); w.nat(c["price"])
        w.len16(len(c["bands"]))
        for f, t in c["bands"]:
            w.nat(f); w.nat(t)
        w.nat(c["collar"]); w.nat(c["static"]); w.nat(c["dynamic"]); w.nat(c["secs"])
    elif k == "setTrading":
        w.byte(2); w.nat(c["instrument"]); w.boolean(c["open"])
    elif k == "setReference":
        w.byte(3); w.nat(c["instrument"]); w.nat(c["price"])
    elif k == "placeOrder":
        own = e[5:]
        if e[2] == LIVE:
            w.byte(4); w.nat(e[1]); w.nat(c["instrument"]); w.byte(1 if c["side"] == "buy" else 2); w.nat(e[3]); w.nat(e[4]); w.nats(own)
        elif own:
            w.byte(5); w.nats(own)
        else:
            w.byte(0)
    elif k == "cancelOrder":
        w.byte(5); w.nats([c["order"]])
    elif k == "amendOrder":
        if e[3] == 0:
            w.byte(0)
        else:
            w.byte(6); w.nat(c["order"]); w.nat(c["price"]); w.nat(e[3]); w.boolean(e[2] == 1)
    elif k in ("massCancel", "endOfDay", "expireGtd"):
        w.byte(5); w.nats(e[2:2 + e[1]])
    elif k == "killSweep":
        w.byte(5); w.nats(e[3:3 + e[2]])
    elif k == "clear":
        w.byte(7); clear_body(w, e)
    elif k == "setPhase":
        w.byte(8); w.nat(c["instrument"]); w.byte(PHASE_CODE[c["phase"]]); w.nat64(c["from"]); w.nat64(c["to"]); w.text("")
    elif k == "halt":
        w.byte(8); w.nat(c["instrument"]); w.byte(PHASE_CODE["halted"]); w.nat64(0); w.nat64(0); w.text(c["reason"])
    elif k == "resume":
        w.byte(8); w.nat(c["instrument"]); w.byte(PHASE_CODE["auction"]); w.nat64(0); w.nat64(0); w.text("")
    elif k == "uncross":
        w.byte(9); w.nat(c["instrument"])
        p = instrument_body(w, e, 2, False)
        w.byte(e[p])
    elif k == "sealDay":
        w.byte(10); w.nat(e[1]); w.nat(e[2]); w.b += bytes(e[3:35])
    elif k in ("deposit", "withdraw", "flush", "kill", "revive", "setLimits"):
        w.byte(0)
    else:
        raise ValueError(f"no feed message for {k}")


def clear_body(w, e):
    starts, k = [], 1
    while k < len(e):
        starts.append(k)
        np_ = e[k + 3]
        p = k + 4 + 3 * np_
        p += 1 + e[p]
        p += 1 + 4 * e[p]
        p += 1 + 2 * e[p]
        k = p + 1
    w.len16(len(starts))
    for k in starts:
        w.nat(e[k])
        p = instrument_body(w, e, k + 1, True)
        w.boolean(e[p] == 1)


def instrument_body(w, e, at, triggers):
    w.nat(e[at]); w.nat(e[at + 1])
    np_ = e[at + 2]; w.len16(np_); p = at + 3
    for _ in range(np_):
        w.nat(e[p]); w.nat(e[p + 1]); w.nat(e[p + 2]); p += 3
    nc = e[p]; w.nats(e[p + 1:p + 1 + nc]); p += 1 + nc
    if triggers:
        nt = e[p]; w.len16(nt); p += 1
        for _ in range(nt):
            w.nat(e[p]); w.byte(e[p + 1]); w.nat(e[p + 2]); w.nat(e[p + 3]); p += 4
    ns = e[p]; w.len16(ns); p += 1
    for _ in range(ns):
        w.nat(e[p]); w.nat(e[p + 1]); p += 2
    return p


def chain(previous, msg):
    w = W(); w.text(DOMAIN)
    return hashlib.sha256(bytes(w.b) + previous + msg).digest()
