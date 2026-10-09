"""fix.py: the FIX tag=value codec and session layer of the members' gateway : FIX 4.4, and FIX 5.0 SP2 over
the FIXT.1.1 transport.

A FIX session (TCP, sequence numbers, heartbeats, resend) cannot live in a contract; the gateway each member runs at its
own edge terminates it. This module is the session's half: framing (BeginString, BodyLength, CheckSum), the session
messages (Logon, Heartbeat, TestRequest, ResendRequest, Reject, SequenceReset, Logout) and the sequence-number rules of
the FIX session layer specification (FIX Trading Community), for an acceptor:

  * an inbound sequence number above the expected one is processed after a ResendRequest for the gap (here: the gap is
    requested and the message queued until the gap is filled);
  * one below it without PossDupFlag ends the session (Logout); with PossDupFlag it is ignored;
  * a ResendRequest is answered with every stored application message again (PossDupFlag=Y, OrigSendingTime), the
    session messages in between replaced by a SequenceReset-GapFill;
  * a TestRequest is answered by a Heartbeat carrying its TestReqID; silence past the heartbeat interval sends one.

The session speaks the version the counterparty's Logon names: BeginString FIX.4.4, or FIXT.1.1 with DefaultApplVerID
(1137) 9, FIX 5.0 SP2 (the only application version a FIXT session is accepted with; any other is answered by Logout).
The session layer is the same in both; the gateway's application messages are the same tags in both.

The application's messages pass through `on_app` (the gateway) and its replies through `send_app`.

Attribution: Thebes Core Team.
"""
import datetime

SOH = b"\x01"
BEGIN_STRINGS = ("FIX.4.4", "FIXT.1.1")
FIX50SP2 = "9"          # DefaultApplVerID / ApplVerID for FIX 5.0 SP2
SESSION_TYPES = {"A", "0", "1", "2", "3", "4", "5"}


def checksum(body):
    return sum(body) % 256


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H:%M:%S.%f")[:-3]


def encode(msg_type, fields, seq, sender, target, sending_time=None, extra_header=(), begin="FIX.4.4"):
    """A message of BeginString `begin`: the header (35, 49, 56, 34, 52 and any extra header fields), the body in the order given, the
    BodyLength over everything after it up to the CheckSum, the CheckSum over everything before it."""
    head = [("35", msg_type), ("49", sender), ("56", target), ("34", str(seq)), ("52", sending_time or utc_now())] + list(extra_header)
    body = b"".join(f"{t}={v}".encode() + SOH for t, v in head + list(fields))
    start = f"8={begin}".encode() + SOH + f"9={len(body)}".encode() + SOH
    whole = start + body
    return whole + f"10={checksum(whole):03d}".encode() + SOH


class Message:
    """A parsed message: its fields in order (a tag may repeat in a group) and a dictionary of the first of each."""

    def __init__(self, pairs):
        self.pairs = pairs
        self.first = {}
        for t, v in pairs:
            self.first.setdefault(t, v)

    def get(self, tag, default=None):
        return self.first.get(tag, default)

    @property
    def type(self):
        return self.first.get("35")

    @property
    def seq(self):
        return int(self.first.get("34", "0"))


class FramingError(Exception):
    pass


def take_message(buf):
    """The first whole message in `buf` and the rest, or (None, buf) while it is incomplete. A message that does not
    start with BeginString, whose BodyLength is not a number or whose CheckSum does not hold, is a framing error."""
    if not buf:
        return None, buf
    head = next((b"8=" + v.encode() + SOH for v in BEGIN_STRINGS if buf.startswith(b"8=" + v.encode() + SOH)), None)
    if head is None:
        if len(buf) < 12 and any((b"8=" + v.encode() + SOH).startswith(buf) for v in BEGIN_STRINGS):
            return None, buf
        raise FramingError("a message starts with 8=FIX.4.4 or 8=FIXT.1.1")
    i = buf.find(SOH, len(head))
    if i < 0:
        return None, buf
    tag9 = buf[len(head):i]
    if not tag9.startswith(b"9=") or not tag9[2:].isdigit():
        raise FramingError("BodyLength after BeginString")
    length = int(tag9[2:])
    body_start = i + 1
    end_body = body_start + length
    end = end_body + 7     # "10=xyz" SOH
    if len(buf) < end:
        return None, buf
    trailer = buf[end_body:end]
    if not trailer.startswith(b"10=") or trailer[-1:] != SOH:
        raise FramingError("CheckSum where BodyLength ends")
    if int(trailer[3:6]) != checksum(buf[:end_body]):
        raise FramingError("CheckSum")
    pairs = []
    for field in buf[:end_body].split(SOH)[:-1]:
        t, _, v = field.partition(b"=")
        pairs.append((t.decode(), v.decode()))
    pairs.append(("10", trailer[3:6].decode()))
    return Message(pairs), buf[end:]


class Session:
    """An acceptor's session with one counterparty: the sequence numbers, the stored outbound messages for resend, the
    heartbeat. `transport(bytes)` writes to the counterparty; `on_app(message)` is the application."""

    def __init__(self, sender, target, transport, on_app, store=None):
        self.sender, self.target = sender, target
        self.transport, self.on_app = transport, on_app
        self.next_out, self.next_in = 1, 1
        self.sent = store if store is not None else {}       # seq -> (type, fields, sending time)
        self.logged_on = False
        self.heartbeat = 30
        self.queued = {}                                     # inbound messages above a gap, by seq
        self.closed = False
        self.begin = "FIX.4.4"                               # set by the counterparty's Logon

    # ── outbound ──
    def _send(self, msg_type, fields, poss_dup_of=None):
        seq = self.next_out if poss_dup_of is None else poss_dup_of[0]
        extra = () if poss_dup_of is None else (("43", "Y"), ("122", poss_dup_of[1]))
        now = utc_now()
        raw = encode(msg_type, fields, seq, self.sender, self.target, now, extra, self.begin)
        if poss_dup_of is None:
            self.sent[seq] = (msg_type, list(fields), now)
            self.next_out += 1
        self.transport(raw)
        return seq

    def send_app(self, msg_type, fields):
        return self._send(msg_type, fields)

    def reject(self, ref_seq, reason, text, ref_tag=None):
        fields = [("45", str(ref_seq))] + ([("371", ref_tag)] if ref_tag else []) + [("373", str(reason)), ("58", text)]
        self._send("3", fields)

    def logout(self, text=""):
        self._send("5", [("58", text)] if text else [])
        self.closed = True

    # ── inbound ──
    def receive(self, m):
        if m.get("49") != self.target or m.get("56") != self.sender:
            self.reject(m.seq, 9, "CompID problem")
            self.logout("CompID problem")
            return
        if not self.logged_on:
            if m.type != "A":
                self.logout("the first message is a Logon")
                return
            self.begin = m.get("8")
            if self.begin == "FIXT.1.1" and m.get("1137") != FIX50SP2:
                self.logout("a FIXT session's DefaultApplVerID is 9 (FIX 5.0 SP2)")
                return
            self.heartbeat = int(m.get("108", "30"))
            if m.get("141") == "Y":                           # ResetSeqNumFlag
                self.next_in, self.next_out, self.sent = 1, 1, {}
        if m.seq > self.next_in and not (m.type == "4" and m.get("123") != "Y"):
            # a gap: ask for it and keep this message until the gap is filled
            self.queued[m.seq] = m
            if m.type == "A":
                self._logon(m)
            self._send("2", [("7", str(self.next_in)), ("16", "0")])
            return
        if m.seq < self.next_in:
            if m.get("43") == "Y":
                return
            self.logout(f"MsgSeqNum too low, expecting {self.next_in} but received {m.seq}")
            return
        self._handle(m)
        while self.next_in in self.queued:
            self._handle(self.queued.pop(self.next_in))

    def _logon(self, m):
        if not self.logged_on:
            self.logged_on = True
            self._send("A", [("98", "0"), ("108", str(self.heartbeat))] + ([("141", "Y")] if m.get("141") == "Y" else [])
                       + ([("1137", FIX50SP2)] if self.begin == "FIXT.1.1" else []))

    def _handle(self, m):
        t = m.type
        if t == "4":
            # SequenceReset: GapFill or Reset, the next inbound number its NewSeqNo
            new = int(m.get("36", "0"))
            if new < self.next_in and m.get("123") == "Y":
                self.reject(m.seq, 5, "NewSeqNo below the expected sequence number", "36")
                return
            self.next_in = new
            return
        self.next_in = m.seq + 1
        if t == "A":
            self._logon(m)
        elif t == "0":
            pass
        elif t == "1":
            self._send("0", [("112", m.get("112", ""))])
        elif t == "2":
            self._resend(int(m.get("7", "1")), int(m.get("16", "0")))
        elif t == "3":
            pass
        elif t == "5":
            if not self.closed:
                self.logout()
        else:
            self.on_app(m)

    def _resend(self, begin, end):
        """Every stored application message from `begin` to `end` (0: to the last) again, PossDupFlag=Y; each run of
        session messages replaced by one SequenceReset-GapFill to the next application message."""
        last = self.next_out - 1 if end == 0 else min(end, self.next_out - 1)
        seq = begin
        while seq <= last:
            msg_type, fields, at = self.sent.get(seq, ("0", [], ""))
            if msg_type in SESSION_TYPES:
                nxt = seq
                while nxt <= last and self.sent.get(nxt, ("0",))[0] in SESSION_TYPES:
                    nxt += 1
                raw = encode("4", [("123", "Y"), ("36", str(nxt))], seq, self.sender, self.target, utc_now(), (("43", "Y"), ("122", at or utc_now())), self.begin)
                self.transport(raw)
                seq = nxt
            else:
                self.transport(encode(msg_type, fields, seq, self.sender, self.target, utc_now(), (("43", "Y"), ("122", at)), self.begin))
                seq += 1
