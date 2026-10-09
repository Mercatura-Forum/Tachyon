"""thebes_client.py: the chain batteries' transport to a Thebes chain. An update is a signed ingress message on the
node API (the envelope the deploy tool uses, `thebes-deploy-protocol`), awaited on its receipt; a query is the node's
`/api/query`; an install or an upgrade is the deploy tool's own chunked protocol (`InstallStart`, one `InstallChunk`
per 32 KiB, `InstallCommit` in the install or the upgrade mode) spoken by the same client with the init argument as
the bytes the battery encodes, so a value never passes through a textual form; a principal is an ed25519 identity
whose seed derives from its name, imported into the tool's identity store so the tool and the client sign as one.

The surface is the one the batteries use in a local replica (`create_canister`, `set_sender`, `query_call`,
`update_call`), so a battery changes its set-up and nothing of its rows. There is no `set_time`: the chain's clock is
its own, and the desk's calendar is the journal's business-date authority.

The node behaviours the client absorbs, each by a bounded rule:

- a receipt not yet there (the message is in a block not yet finalised, or the node answering has not caught up):
  asked again until it is;
- a submission rejected on its nonce (the chain executed one of this sender's before): a fresh nonce is signed and
  the message resubmitted;
- a node's pool holds about a mebibyte of a contract's pending bytes and can report a message past that accepted
  while dropping it (fifteen install chunks of thirty-two kibibytes): the client keeps eight chunks and forty calls
  in flight and resubmits what has no receipt;
- a node rate-limits a sender (a burst of fifty, refilled at twenty-five a second, the refusal named
  `RATE_LIMITED`): a window stays under the burst and a message refused for the rate is submitted again after the
  bucket has refilled;
- a node can stop answering its API for a while and still execute every block: a receipt is read from the other
  nodes too once the client's node has not given it within a few seconds. A receipt found there says the message is
  final and the client's node behind, so the client goes on waiting for its own node (a read after the write must
  see it) and moves to another node only when its own has stayed silent to the end of the wait;
- a node whose memory is over the cap it runs under sheds ingress with a 503 and a retry interval, or does not answer
  within the timeout while a block of heavy calls executes: the client asks again after the interval, or a second,
  for up to five minutes;
- a node proposes the messages of its own pool and the next round's leader is not predictable, so a message handed
  to one node waits in that node's pool for its turn. Handing every message to every node can lose messages of a
  window, so a message goes to one node. A message that waits past its five-minute window is carried by no node, so a
  chunk is signed as it is submitted and a message resubmitted near the end of its window is signed again.

Everything else is an error the battery sees.

The chain is the one the user names, by a JSON description passed to `ThebesChain` or named by `THEBES_CHAIN`:
`{"nodes": [<each validator's node API base URL>], "gateway": <the deploy gateway's base URL>, "chain_id": <n>}`. The
client has no chain of its own: without a description it refuses to start.

Environment: `THEBES_CHAIN` (the description's path), `THEBES_CHAIN_NODE` (the index of the node this client submits
to), `THEBES_DEPLOY` (default `/usr/local/bin/thebes-deploy`, used to import the identities
so the tool's own `call`, `query` and `upgrade` can act as them), `THEBES_IDENTITY_PREFIX` (the identity names' prefix
in `~/.thebes/identities`, default `tachyon`).
"""
import hashlib
import json
import os
import re
import secrets
import socket
import subprocess
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from ic.principal import Principal

import blake3
from ic.candid import encode

DOMAIN_INNER = b"egypt-l1-ingress-v1"
DOMAIN_OUTER = b"egypt-l1-outer-sig-v2"
DOMAIN_UPLOAD = b"install-chunked-v1"
VERSION = b"\x02"
CHUNK = 32 * 1024
IN_FLIGHT = 8            # install chunks in flight: the pool holds a mebibyte of a contract's pending bytes, fifteen chunks on the wire
IN_FLIGHT_CALLS = 40     # calls in flight: under the node's per-sender burst of fifty (refilled at twenty-five a second)
OTHER_NODES_AFTER_S = 5.0
TD = os.environ.get("THEBES_DEPLOY", "/usr/local/bin/thebes-deploy")
IDENTITY_DIR = os.path.expanduser("~/.thebes/identities")
PREFIX = os.environ.get("THEBES_IDENTITY_PREFIX", "tachyon")
RECEIPT_TIMEOUT_S = 120.0
RESUBMIT_AFTER_S = 25.0
SHED_WAIT_S = 300.0
QUERY_RETRIES = 5


def _lp(b):
    return len(b).to_bytes(4, "big") + b


def cid_principal(cid):
    """A Thebes contract id as a principal: its eight-byte big-endian encoding."""
    return Principal(bytes=int(cid).to_bytes(8, "big"))


def principal_cid(p):
    b = p.bytes if isinstance(p, Principal) else bytes(p)
    assert len(b) == 8, f"not a contract principal: {b.hex()}"
    return int.from_bytes(b, "big")


class Identity:
    """An ed25519 identity named for the battery's role, its seed the hash of the name, present in the deploy
    tool's store so `thebes-deploy` installs and the client's messages come from one key."""

    _by_principal = {}

    def __init__(self, name):
        self.name = f"{PREFIX}-{name}"
        self.seed = hashlib.sha256(b"thebes-chain-battery-identity:" + self.name.encode()).digest()
        self.sk = Ed25519PrivateKey.from_private_bytes(self.seed)
        self.pk = self.sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        der = self.sk.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        self.principal = Principal(bytes=hashlib.sha224(der).digest() + b"\x02")
        self.nonce = int(time.time_ns() // 1000)
        Identity._by_principal[self.principal.bytes] = self
        self._ensure_in_store()

    def _ensure_in_store(self):
        path = os.path.join(IDENTITY_DIR, self.name + ".seed")
        if os.path.exists(path):
            assert open(path).read().strip() == self.seed.hex(), f"identity {self.name} in the store has another seed"
            return
        r = subprocess.run([TD, "identity", "import", "--seed-hex", self.seed.hex(), self.name], capture_output=True, text=True)
        assert r.returncode == 0 and os.path.exists(path), f"identity import failed: {r.stdout}{r.stderr}"

    @classmethod
    def of(cls, principal):
        b = principal.bytes if isinstance(principal, Principal) else bytes(principal)
        who = cls._by_principal.get(b)
        assert who is not None, f"no identity holds the principal {Principal(bytes=b).to_str()}"
        return who

    @property
    def bytes(self):
        return self.principal.bytes

    def to_str(self):
        return self.principal.to_str()

    def __str__(self):
        return self.principal.to_str()

    def __eq__(self, other):
        return self.bytes == (other.bytes if hasattr(other, "bytes") else other)

    def __hash__(self):
        return hash(self.bytes)


class ChainError(RuntimeError):
    pass


class ThebesChain:
    """The chain as the batteries drive it: contracts installed through the deploy tool, calls signed by the
    current sender, replies as Candid bytes."""

    def __init__(self, description=None):
        path = description or os.environ.get("THEBES_CHAIN")
        if not path:
            raise ChainError("no chain named: pass a chain description or set THEBES_CHAIN")
        cfg = json.loads(open(path).read())
        self.nodes = [str(u).rstrip("/") for u in cfg["nodes"]]
        if not self.nodes:
            raise ChainError(f"{path}: a chain description names at least one node")
        self.validators = len(self.nodes)
        self.gateway = str(cfg["gateway"]).rstrip("/")
        self.chain_id = int(cfg["chain_id"])
        self.sender = None
        # the node this client submits to and reads from: a node's pool holds fifteen messages, so two batteries on
        # one chain at once take different nodes (`THEBES_CHAIN_NODE`, else the identity prefix chooses)
        self.node = int(os.environ.get("THEBES_CHAIN_NODE", sum(PREFIX.encode()) % self.validators))
        self.read_node = self.node
        self.cids = {}          # principal bytes -> cid
        self.calls = 0
        self.queries = 0
        self.retries = {"receipt": 0, "nonce": 0, "query": 0, "resubmit": 0, "shed": 0, "resigned": 0, "unanswered": 0, "moved": 0, "rate": 0}
        self._signed = {}       # id(envelope) -> what was signed, for a fresh signature
        # the fuel the last call or query consumed, as the node reports it in the receipt or the reply
        # (`cycles_used`): the measure of a call's cost on this chain, where `ic0.performance_counter` reads the
        # block's time rather than an instruction count
        self.last_fuel = 0
        self.last_window_fuel = []

    # ── http ──
    def _get(self, url, timeout=30):
        return self._http(urllib.request.Request(url), timeout)

    def _post(self, url, payload, timeout=60):
        req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST")
        return self._http(req, timeout)

    def _http(self, req, timeout):
        """One request; a node that sheds ingress (503 with Retry-After, its memory over the cap it runs under) is
        asked again after the interval it names, and a node that does not answer within the timeout (its API
        waits while a block of heavy calls executes) is asked again after a second,
        either for at most `SHED_WAIT_S` in all. Any other error is the caller's."""
        deadline = time.time() + SHED_WAIT_S
        while True:
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return json.loads(r.read())
            except urllib.error.HTTPError as e:
                if e.code != 503 or time.time() > deadline:
                    raise
                self.retries["shed"] += 1
                try:
                    wait = float(e.headers.get("Retry-After", "1"))
                except ValueError:
                    wait = 1.0
                time.sleep(min(max(wait, 0.25), 5.0))
            except (TimeoutError, socket.timeout, urllib.error.URLError) as e:
                if time.time() > deadline:
                    raise
                self.retries["unanswered"] += 1
                time.sleep(1.0)

    def status(self, node=0):
        return self._get(f"{self.nodes[node]}/api/status")

    def height(self, node=0):
        return self.status(node)["finalized_height"]

    def block(self, height, node=0):
        """A finalised block as one node reports it; a node that reports the height but has not stored the block yet
        answers 404 for a moment, so the read is retried briefly."""
        for attempt in range(20):
            try:
                return self._get(f"{self.nodes[node]}/api/block/{height}")
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    raise
                time.sleep(0.25)
        raise ChainError(f"node {node} does not serve block {height}")

    # ── the surface the batteries drive ──
    def set_sender(self, principal):
        self.sender = Identity.of(principal)

    def create_canister(self):
        """A fresh contract id chosen here, as the deploy tool chooses one for `cid = "auto"`: the substrate
        accepts any id no contract holds."""
        cid = secrets.randbits(47) | (1 << 46)
        p = cid_principal(cid)
        self.cids[p.bytes] = cid
        return p

    def add_cycles(self, cid, amount):
        return None

    def set_time(self, ns):
        raise ChainError("the chain's clock is its own: a battery rolls the business date and waits on the chain for a deadline")

    def cid_of(self, principal):
        """A contract's number, from the number itself or from its principal."""
        if isinstance(principal, int):
            return principal
        b = principal.bytes if isinstance(principal, Principal) else bytes(principal)
        if b in self.cids:
            return self.cids[b]
        return principal_cid(b)

    def query_call(self, cid, method, arg_bytes):
        self.queries += 1
        payload = {"canister_id": self.cid_of(cid), "method": method, "arg": arg_bytes.hex(), "sender": (self.sender.pk.hex() if self.sender else "")}
        last = None
        for attempt in range(QUERY_RETRIES):
            try:
                r = self._post(f"{self.nodes[self.read_node]}/api/query", payload)
            except (urllib.error.URLError, TimeoutError) as e:
                last = e; self.retries["query"] += 1; time.sleep(0.2 * (attempt + 1)); continue
            if r.get("status") == "success":
                self.last_fuel = int(r.get("cycles_used") or 0)
                return bytes.fromhex(r["reply"])
            raise ChainError(f"query {method} on {self.cid_of(cid)}: {r.get('error') or r}")
        raise ChainError(f"query {method}: the node did not answer: {last}")

    def _sign(self, kind, body, inner):
        """The signed envelope of one message: `inner` is the kind's signing payload after the domain and the tag,
        `body` the JSON body with the sender filled in."""
        who = self.sender
        assert who is not None, "no sender set"
        payload = DOMAIN_INNER + inner
        expiry = time.time_ns() + 5 * 60 * 1_000_000_000
        signing = DOMAIN_OUTER + VERSION + self.chain_id.to_bytes(8, "big") + len(payload).to_bytes(4, "big") + payload + expiry.to_bytes(8, "big")
        sig = who.sk.sign(signing)
        body = dict(body); body["sender"] = who.pk.hex(); body["signature"] = ""
        env = {"message": {kind: body}, "ingress_expiry_ns": expiry, "chain_id": self.chain_id, "outer_signature": sig.hex()}
        self._signed[id(env)] = (who, kind, body, inner)
        return env

    def _resign(self, env):
        """The same message (the same sender, nonce and payload) signed again with a fresh expiry: a message that
        waited past its five-minute window is not carried by any node, and a copy with the same nonce that the
        chain did execute refuses the new one as a replay, so the first receipt is what is awaited."""
        who, kind, body, inner = self._signed.pop(id(env))
        keep = self.sender
        self.sender = who
        try:
            body = {k: v for k, v in body.items() if k not in ("sender", "signature")}
            return self._sign(kind, body, inner)
        finally:
            self.sender = keep

    def _envelope(self, cid, method, arg_bytes):
        who = self.sender
        who.nonce += 1
        nonce = who.nonce
        inner = b"\x02" + int(cid).to_bytes(8, "big") + _lp(method.encode()) + _lp(arg_bytes) + _lp(who.pk) + nonce.to_bytes(8, "big")
        return self._sign("Call", {"canister_id": int(cid), "method": method, "arg": arg_bytes.hex(), "nonce": nonce}, inner)

    def _submit(self, envelopes):
        """The envelopes submitted in one request; a slot the node refused for the sender's rate is offered again
        after the bucket has refilled, until every slot has an id or another refusal stands."""
        r = self._post(f"{self.nodes[self.node]}/api/submit_signed", {"messages": envelopes})
        ids = list(r.get("message_ids") or [None] * len(envelopes))
        rejected = list(r.get("rejected") or [None] * len(envelopes))
        for attempt in range(20):
            again = [i for i, rj in enumerate(rejected) if rj and rj.get("code") == "RATE_LIMITED"]
            if not again:
                break
            self.retries["rate"] += 1
            time.sleep(max(1.0, len(again) / 25.0))
            r2 = self._post(f"{self.nodes[self.node]}/api/submit_signed", {"messages": [envelopes[i] for i in again]})
            ids2 = r2.get("message_ids") or [None] * len(again)
            rej2 = r2.get("rejected") or [None] * len(again)
            for k, i in enumerate(again):
                ids[i] = ids2[k] if k < len(ids2) else None
                rejected[i] = rej2[k] if k < len(rej2) else None
        return ids, [x for x in rejected if x], r

    def _await(self, message_ids, what, timeout=None):
        """The receipt of a message under any of the ids it has been submitted with, polled on the client's node;
        None when none has appeared within `timeout`."""
        ids = [message_ids] if isinstance(message_ids, str) else list(message_ids)
        started = time.time()
        deadline = started + (timeout or RECEIPT_TIMEOUT_S)
        others = [i for i in range(len(self.nodes)) if i != self.node]
        foreign = None   # (node index, receipt): the message is final chain-wide, the client's node not yet caught up

        def ask(i, message_id):
            try:
                req = urllib.request.Request(f"{self.nodes[i]}/api/receipt?hash={message_id}")
                with urllib.request.urlopen(req, timeout=10) as r:
                    rc = json.loads(r.read())
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    self.retries["unanswered"] += 1
                return None
            except (TimeoutError, socket.timeout, urllib.error.URLError, ValueError):
                self.retries["unanswered"] += 1
                return None
            return rc if rc.get("found") and rc.get("lifecycle") in ("success", "error") else None

        while True:
            for message_id in ids:
                rc = ask(self.node, message_id)
                if rc is not None:
                    return rc
            # the other nodes hold the receipt of a finalised message too; one found there says the message is
            # final and the client's node is behind, so the wait goes on for the client's node (a read after it
            # must see the write), and only a node silent to the end of the wait is given up on
            if foreign is None and time.time() - started > OTHER_NODES_AFTER_S:
                for i in others:
                    for message_id in ids:
                        rc = ask(i, message_id)
                        if rc is not None:
                            foreign = (i, rc)
                            break
                    if foreign:
                        break
            if time.time() > deadline:
                if foreign is not None:
                    self.retries["moved"] += 1
                    self.node = self.read_node = foreign[0]
                    return foreign[1]
                return None
            self.retries["receipt"] += 1
            time.sleep(0.1)

    def _settle(self, env, message_id, what):
        """A submitted message driven to its receipt. A node's pool holds fifteen messages and reports one past that
        accepted while dropping it, so a message without a receipt after a bounded
        wait is submitted again with the same nonce: a copy the chain already executed is refused as a replay and
        the first receipt is awaited on; a dropped one is executed now. A message whose five-minute window is
        nearly out is signed again with a fresh one, the receipt then awaited under either id. Never assumed done."""
        ids = [message_id]
        for attempt in range(6):
            rc = self._await(ids, what, timeout=RESUBMIT_AFTER_S)
            if rc is not None:
                return rc
            self.retries["resubmit"] += 1
            if env["ingress_expiry_ns"] - time.time_ns() < 60 * 1_000_000_000:
                env = self._resign(env)
                self.retries["resigned"] += 1
            r = self._post(f"{self.nodes[self.node]}/api/submit_signed", {"messages": [env]})
            new_ids = [x for x in (r.get("message_ids") or []) if x]
            for x in new_ids:
                if x not in ids:
                    ids.append(x)
            text = json.dumps(r).lower()
            if "replay" in text or "duplicate" in text:
                rc = self._await(ids, what)
                if rc is not None:
                    return rc
        raise ChainError(f"{what}: no receipt for {ids} after six submissions")

    def _reply(self, rc, what):
        self.last_fuel = int(rc.get("cycles_used") or 0)
        if rc.get("lifecycle") == "success":
            return bytes.fromhex(rc["reply"]) if rc.get("reply") else b""
        raise ChainError(f"{what}: {rc.get('error')}")

    def update_call(self, cid, method, arg_bytes):
        self.calls += 1
        cidn = self.cid_of(cid)
        what = f"call {method} on {cidn}"
        for attempt in range(6):
            env = self._envelope(cidn, method, arg_bytes)
            ids, rejected, raw = self._submit([env])
            if not ids or not ids[0]:
                text = json.dumps(raw)
                if "replay" in text.lower() or "nonce" in text.lower():
                    self.retries["nonce"] += 1; self.sender.nonce += 1000; time.sleep(0.2); continue
                raise ChainError(f"{what}: submission refused: {text[:300]}")
            rc = self._settle(env, ids[0], what)
            err = (rc.get("error") or "")
            if rc.get("lifecycle") == "error" and ("REPLAY" in err or "replay" in err):
                self.retries["nonce"] += 1; self.sender.nonce += 1000; time.sleep(0.2); continue
            return self._reply(rc, what)
        raise ChainError(f"{what}: refused on its nonce six times")

    def update_calls_as(self, batch):
        """As `update_calls`, each message from its own sender: `batch` is a list of (sender principal, cid, method,
        arg bytes); a window is submitted in one request in the order given."""
        out = []
        keep = self.sender
        for k in range(0, len(batch), IN_FLIGHT_CALLS):
            part = batch[k:k + IN_FLIGHT_CALLS]
            envs = []
            for who, cid, method, arg_bytes in part:
                self.set_sender(who)
                envs.append(self._envelope(self.cid_of(cid), method, arg_bytes))
            self.calls += len(envs)
            ids, rejected, raw = self._submit(envs)
            assert len(ids) == len(envs) and all(ids), f"batch submission: {json.dumps(rejected)[:600]}"
            for (who, cid, method, _), env, mid in zip(part, envs, ids):
                rc = self._settle(env, mid, f"call {method} on {self.cid_of(cid)}")
                out.append(self._reply(rc, f"call {method} on {self.cid_of(cid)}"))
        self.sender = keep
        return out

    def update_calls(self, batch):
        """Independent messages in flight: `batch` is a list of (cid, method, arg_bytes) from the current sender;
        every message is signed and submitted, then every receipt awaited in order. The replies come back in the
        batch's order; the chain executes them in block order."""
        out = []
        self.last_window_fuel = []
        for k in range(0, len(batch), IN_FLIGHT_CALLS):
            part = batch[k:k + IN_FLIGHT_CALLS]
            envs = [self._envelope(self.cid_of(cid), method, arg_bytes) for cid, method, arg_bytes in part]
            self.calls += len(envs)
            ids, rejected, raw = self._submit(envs)
            assert len(ids) == len(envs) and all(ids), f"batch submission: {json.dumps(rejected)[:600]}"
            for (cid, method, _), env, mid in zip(part, envs, ids):
                rc = self._settle(env, mid, f"call {method} on {self.cid_of(cid)}")
                out.append(self._reply(rc, f"call {method} on {self.cid_of(cid)}"))
                self.last_window_fuel.append(self.last_fuel)
        return out

    # ── installs through the deploy tool's chunked protocol ──
    def install(self, cid, wasm_path, init_args, name="contract", upgrade=False):
        """The wasm at `wasm_path` on `cid` with `init_args` (the typed list `encode` takes): `InstallStart` with
        the module's hash and the upload id the substrate derives from it, every 32 KiB chunk submitted in flight
        and its receipt awaited, then `InstallCommit` in the install mode or, for an upgrade in place, the upgrade
        mode (the substrate carries the stable memory to the new module). Signed by the current sender."""
        who = self.sender
        cidn = self.cid_of(cid)
        wasm = open(wasm_path, "rb").read()
        arg = encode(list(init_args)) if init_args else encode([])
        digest = hashlib.sha256(wasm).digest()
        chunks = [wasm[i:i + CHUNK] for i in range(0, len(wasm), CHUNK)]
        n = len(chunks)
        upload_id = blake3.blake3(DOMAIN_UPLOAD + who.pk + cidn.to_bytes(8, "big") + n.to_bytes(4, "big") + digest).digest()
        what = f"{'upgrade' if upgrade else 'install'} of {name} on {cidn}"
        t0 = time.time()
        start = self._sign("InstallStart", {"canister_id": cidn, "expected_chunks": n, "wasm_sha256": digest.hex(), "upload_id": upload_id.hex()},
                           b"\x08" + cidn.to_bytes(8, "big") + n.to_bytes(4, "big") + _lp(digest) + _lp(upload_id) + _lp(who.pk))
        ids, rejected, raw = self._submit([start])
        assert ids and ids[0], f"{what}: start refused: {json.dumps(raw)[:300]}"
        rc = self._settle(start, ids[0], what + " (start)")
        if rc.get("lifecycle") != "success":
            raise ChainError(f"{what}: start failed: {rc.get('error')}")
        # every chunk signed as it is submitted (a chunk signed at the start would outlive its five-minute window
        # on a loaded node before its turn), submitted on its own and in flight (the substrate's chunk store takes
        # them in any order), the receipts awaited in order once a window of them is out: the node's pool holds
        # fifteen of a sender's messages and reports a sixteenth accepted while dropping it, so the window stays well under
        # that
        window = IN_FLIGHT
        pending = []
        for i, c in enumerate(chunks):
            env = self._sign("InstallChunk", {"upload_id": upload_id.hex(), "chunk_index": i, "bytes": c.hex()},
                             b"\x09" + _lp(upload_id) + i.to_bytes(4, "big") + _lp(c) + _lp(who.pk))
            ids, rejected, raw = self._submit([env])
            if not ids or not ids[0]:
                raise ChainError(f"{what}: chunk {i} refused: {json.dumps(raw)[:300]}")
            pending.append((i, env, ids[0]))
            if len(pending) >= window:
                for j, e, mid in pending:
                    rc = self._settle(e, mid, f"{what} (chunk {j})")
                    if rc.get("lifecycle") != "success":
                        raise ChainError(f"{what}: chunk {j} failed: {rc.get('error')}")
                pending = []
        for j, e, mid in pending:
            rc = self._settle(e, mid, f"{what} (chunk {j})")
            if rc.get("lifecycle") != "success":
                raise ChainError(f"{what}: chunk {j} failed: {rc.get('error')}")
        inner = b"\x0a" + cidn.to_bytes(8, "big") + _lp(upload_id) + _lp(arg) + _lp(who.pk) + (b"\x01" if upgrade else b"")
        body = {"canister_id": cidn, "upload_id": upload_id.hex(), "arg": arg.hex()}
        if upgrade:
            body["mode"] = "Upgrade"
        commit = self._sign("InstallCommit", body, inner)
        ids, rejected, raw = self._submit([commit])
        assert ids and ids[0], f"{what}: commit refused: {json.dumps(raw)[:300]}"
        rc = self._settle(commit, ids[0], what + " (commit)")
        if rc.get("lifecycle") != "success":
            raise ChainError(f"{what}: commit failed: {rc.get('error')}")
        self.calls += n + 2
        return {"cid": cidn, "chunks": n, "bytes": len(wasm), "sha256": digest.hex(), "commit": ids[0], "seconds": round(time.time() - t0, 1)}

    def module_hash(self, cid):
        """The module hash the substrate reports for a contract, as the deploy tool verifies it after an install."""
        r = self._get(f"{self.nodes[self.node]}/api/canister/{self.cid_of(cid)}/module_hash")
        return r.get("module_hash") if isinstance(r, dict) else r
