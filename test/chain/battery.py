#!/usr/bin/env python3
"""Tachyon on a Thebes chain: the settlement battery driven through thebes-deploy.

    python3 test/chain/battery.py <manifest.toml> <network> [--out DIR]

The manifest names the ledgers and the core (see deploy/example.thebes.toml); cids must be
installed. Two identities, `tachyon-maker` and `tachyon-taker`, must exist (`thebes-deploy
identity new`), and each must hold an initial balance on the cash and asset ledgers.

Rows: T1 happy path, T3 abort and reclaim, T4 idempotent retry under an injected ledger
failure, T5 adversarial refusals, D1 a delivery free of payment accepted, D2 one reclaimed, D3 one the
taker does not accept, D4 the invariant log, T2 no fork (state root identical across validators at the
same height). Every row states its own pass condition before the calls are made.

When the manifest also installs the matching engine and the listing registry ([canisters.matching],
[canisters.matching_gated], [canisters.listing], [canisters.land], [canisters.shares_empty]), the
M and L rows run between D4 and T2; a settlement-only bed logs one SKIP line instead. The ground
truth for every matching row is a stateful Python twin of MatchLogic.mo fed exactly the submits,
cancels and clears the battery drives on-chain. M0 the relayer gate and the installer-only binding;
M1 a two-sided window cleared at one uniform price, the obligations, book and reservations equal to
the twin byte for byte; M2 every obligation settled through the core by seq with exact per-fill-fee
balance deltas, zero core residual, the matchSeq -> tradeId round trip and an idempotent re-drive;
M3 a clear under a 2-fill cap: the first chunk reports the budget exhausted, the engine's own Timer
resumes and completes it with no battery drive, the chunk count equals the twin's arithmetic; then
settleMatched drains the window in bounded inline sweeps looped to completion - each call settles up
to MAX_FILLS_PER_CHUNK obligations INSIDE the one message the caller awaits (no post-await Timer and
no fire-and-forget self-message: the substrate does not reliably dispatch a message the caller never
awaits, the recorded post-await-Timer defect being one face of it); M4 time priority at one price (the oldest resting
order fills first, the newest gets nothing) and an all-or-none order that cannot fully fill killed
before any mutation with its reservation released; M5 adversarial refusals (non-owner cancel,
closed-window cancel, an order beyond the caller's allowance, unknown seq, zero deadline) and the
relayer rotation (the unbound engine refused by the core, the re-bound engine re-drives the same
obligation to settled); M6 the drain steps over a transient refusal (a revoked maker allowance blocks
the first of two cross-party fills; the same bounded sweep steps its cursor past it and settles the
fill behind it, the refused obligation owns a trade and is never voided, and restoring the allowance
re-drives it to settled); MD the dust discipline (an order whose every fill would be dust is refused
at intake; a boundary remainder fill at or below the fee still clears exactly as the twin plans it,
the core refuses it before any trade exists - funds safe - and the drain VOIDS it, recorded with
its reason, and completes the window past it: the recorded liveness gap closed); M7 the reservation
accounting (a reservation is denominated per escrow, since the core's escrow for one fill debits the
funder amount + one fee: a live order holds its remaining notional + one fee, every created obligation
holds its own exact escrow cost until it settles or is voided, and every unit has exactly one release
event - so an ask reserves the fee its escrow costs, a cleared-but-unsettled obligation's escrow cost
stays reserved, a two-fill order reserves two fees where intake reserved one, a whole lifecycle hands
every unit back, and what the engine maintains equals what its own book and holds prescribe);
L1-L8 the listing gate
(an unlisted market refused at intake, issuer
authorization admin-only, a zero-supply ledger refused as unfunded by the live cross-canister
check, the funded pair listed and accepted, delisting flips the gate off, a land collection
listable only once a title is minted); MF the engines' invariant logs empty, no obligation of this
run stranded, the global obligation summary equal to the twin's.
"""
import argparse, base64, json, os, re, subprocess, sys, time, urllib.request, zlib

TD = os.environ.get('THEBES_DEPLOY', '/usr/local/bin/thebes-deploy')
a = argparse.ArgumentParser()
a.add_argument('manifest'); a.add_argument('network'); a.add_argument('--out', default='test/chain/out')
A = a.parse_args()
os.makedirs(A.out, exist_ok=True)
LOG = open(os.path.join(A.out, 'battery.log'), 'w')
passed = failed = 0

def log(*x):
    s = ' '.join(str(v) for v in x); print(s, flush=True); LOG.write(s + '\n'); LOG.flush()

def row(name, ok, detail=''):
    global passed, failed
    passed += ok; failed += (not ok)
    log(('  PASS  ' if ok else '  FAIL  ') + name + ('' if ok else '   -> ' + str(detail)[:300]))
    return ok

def candid_hash(name):
    h = 0
    for c in name.encode(): h = (h * 223 + c) % (2 ** 32)
    return h

def principal_text(hexraw):
    b = bytes.fromhex(hexraw)
    d = zlib.crc32(b).to_bytes(4, 'big') + b
    s = base64.b32encode(d).decode().lower().rstrip('=')
    return '-'.join(s[i:i + 5] for i in range(0, len(s), 5))

def td(kind, name, method, arg='()', identity=None, timeout=300):
    cmd = [TD] + (['--identity', identity] if identity else []) + [kind, '--manifest', A.manifest, '--network', A.network, '--no-facts', name, method, '--arg', arg]
    for attempt in range(1, 7):
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = r.stdout + r.stderr
        # Two substrate behaviours the harness must absorb, both recorded in VERIFICATION.md:
        # a nonce the chain has already executed for this sender (REPLAY_REJECTED), and a reply
        # that has not arrived (no reply). Each is retried after a pause; the call is never assumed.
        if r.returncode == 0 and 'replay' not in out.lower(): return out
        if 'no reply' not in out and 'replay' not in out.lower(): return out
        time.sleep(2 * attempt)
    return out

def whoami(identity):
    r = subprocess.run([TD, 'identity', 'list'], capture_output=True, text=True)
    m = re.search(r'\b' + re.escape(identity) + r'\s+principal=([0-9a-f]{40,})', r.stdout + r.stderr)
    return principal_text(m.group(1))

def cid_of(name):
    m = re.search(r'\[canisters\.' + re.escape(name) + r'\][^\[]*?\ncid = ([0-9]+)', open(A.manifest).read())
    return int(m.group(1))

def cid_principal(cid):
    # A Thebes cid maps to a principal from its raw 8-byte big-endian encoding.
    return principal_text(int(cid).to_bytes(8, 'big').hex())

def acct(p): return f'(record {{ owner = principal "{p}"; subaccount = null }})'

def nat_in(out):
    m = re.findall(r'\(?\s*([0-9][0-9_]*)\s*:\s*nat\)?', out)
    return int(m[-1].replace('_', '')) if m else None

def bal(ledger, p):
    time.sleep(1)
    return nat_in(td('query', ledger, 'icrc1_balance_of', acct(p)))

def allowance(ledger, owner_p, spender):
    return nat_in(td('query', ledger, 'icrc2_allowance', f'(record {{ account = {acct(owner_p)[1:-1]}; spender = {acct(spender)[1:-1]} }})'))

def approve(ledger, who, spender, amount):
    # Approve, then read the allowance back (a query right after an update can be served by a
    # validator that has not applied it yet; the read is retried until it reflects the approval).
    owner_p = MAKER if who == 'tachyon-maker' else TAKER
    for attempt in range(4):
        out = td('call', ledger, 'icrc2_approve', f'(record {{ from_subaccount = null; spender = {acct(spender)[1:-1]}; amount = {amount} : nat; expected_allowance = null; expires_at = null; fee = null; memo = null; created_at_time = null }})', identity=who)
        for _ in range(10):
            a = allowance(ledger, owner_p, spender)
            if a is not None and a >= amount: return out
            time.sleep(1)
    log(f'  approve on {ledger} for {who} did not take: allowance {allowance(ledger, owner_p, spender)}')
    return out

STATUS = {candid_hash(s): s for s in ('Open', 'Funded', 'Settled', 'Aborted')}
def status_of(trade, expect=None):
    # With `expect`, the read is retried for a few seconds: a query issued right after an update
    # may be served by a validator that has not applied it (read-after-write on this substrate).
    for attempt in range(12 if expect else 1):
        out = td('query', 'core', 'getTrade', f'({trade} : nat)')
        v = field(out, 'status') or ''
        got = None
        for h, s in STATUS.items():
            if f'{h:,}'.replace(',', '_') in v or s in v: got = s
        if got is None:
            m = re.search(r'status = variant \{ ([0-9_]+|#?\w+) \}', out); got = m.group(1) if m else out[-200:]
        if expect is None or got == expect: return got
        time.sleep(1)
    return got

OK_H = f'{candid_hash("ok"):,}'.replace(',', '_')
ERR_H = f'{candid_hash("err"):,}'.replace(',', '_')
def is_ok(out): return bool(re.search(r'variant \{\s*(' + OK_H + r'|#?ok)\b', out))
def err_text(out):
    m = re.search(ERR_H + r' = "((?:[^"\\]|\\.)*)"|#?err = "((?:[^"\\]|\\.)*)"', out)
    return (m.group(1) or m.group(2)) if m else out[-160:]

def field(out, name):
    # thebes-deploy prints record fields by name or by Candid hash; accept either.
    h = f'{candid_hash(name):,}'.replace(',', '_')
    m = re.search(r'(?:\b' + re.escape(name) + r'|' + h + r') = ([^;\n]+)', out)
    return m.group(1).strip() if m else None

def open_trade(maker, taker_p, asset, asset_amt, cash, cash_amt, deadline):
    out = td('call', 'core', 'openTrade', f'(record {{ taker = opt principal "{taker_p}"; assetLedger = principal "{asset}"; assetAmount = {asset_amt} : nat; cashLedger = principal "{cash}"; cashAmount = {cash_amt} : nat; deadlineSecs = {deadline} : nat }})', identity=maker)
    v = field(out, 'tradeId')
    m = re.match(r'([0-9_]+)', v or '')
    return (int(m.group(1).replace('_', '')) if m else None), out

MAKER, TAKER = whoami('tachyon-maker'), whoami('tachyon-taker')
CORE = cid_principal(cid_of('core')); CASH = cid_principal(cid_of('cash')); SHARES = cid_principal(cid_of('shares')); FLAKY = cid_principal(cid_of('cash_flaky'))
log(f'maker={MAKER} taker={TAKER} core={CORE} cash={CASH} shares={SHARES} flaky={FLAKY}')
core_self = td('query', 'core', 'corePrincipal')
row('the core reports its own principal as the manifest cid maps it', CORE.split('-')[0] in core_self, core_self[-120:])
FEE = 10

# T1 happy path: asset to taker, cash to maker, core residual zero, MMR root re-derivable.
log('== T1 happy path')
# the chain persists between runs: the core's holdings at the start are the baseline every residual row is against
k0 = {'s': bal('shares', CORE), 'c': bal('cash', CORE), 'f': bal('cash_flaky', CORE)}
log(f'  core holdings at the start: {k0}')
approve('shares', 'tachyon-maker', CORE, 10_000 + FEE); approve('cash', 'tachyon-taker', CORE, 5_000 + FEE)
m0 = {'ms': bal('shares', MAKER), 'mc': bal('cash', MAKER), 'ts': bal('shares', TAKER), 'tc': bal('cash', TAKER)}
tid, out = open_trade('tachyon-maker', TAKER, SHARES, 10_000, CASH, 5_000, 3600)
row('T1 openTrade', tid is not None, out[-200:])
log('  T1 openTrade note: ' + str(field(out, 'note'))[:160] + ' makerEscrowed=' + str(field(out, 'makerEscrowed')))
fm = td('call', 'core', 'fundMaker', f'({tid} : nat)', identity='tachyon-maker')
row('T1 fundMaker reports the maker leg escrowed (inline at open, or now)', (is_ok(fm) and (field(fm,'legEscrowed') or '').startswith('true')) or (field(out,'makerEscrowed') or '').startswith('true'), fm[-200:])
ft = td('call', 'core', 'fundTaker', f'({tid} : nat)', identity='tachyon-taker'); row('T1 fundTaker escrowed and auto-settled', is_ok(ft) and (field(ft,'bothEscrowed') or '').startswith('true'), ft[-200:])
st = status_of(tid, 'Settled'); row('T1 status Settled', st == 'Settled', st)
m1 = {'ms': bal('shares', MAKER), 'mc': bal('cash', MAKER), 'ts': bal('shares', TAKER), 'tc': bal('cash', TAKER)}
row('T1 taker received asset minus one payout fee', m1['ts'] - m0['ts'] == 10_000 - FEE, (m0, m1))
row('T1 maker received cash minus one payout fee', m1['mc'] - m0['mc'] == 5_000 - FEE, (m0, m1))
row('T1 core holds no residual asset or cash from the trade', bal('shares', CORE) == k0['s'] and bal('cash', CORE) == k0['c'], (k0, bal('shares', CORE), bal('cash', CORE)))
ev = td('query', 'core', 'auditEvents', f'({tid} : nat)')
row('T1 receipt chain ORDER, FUND, FUND, SETTLED', all(k in ev for k in ('ORDER', 'FUND', 'SETTLED')), ev[-300:])
root = td('query', 'core', 'auditRootHex'); row('T1 audit root present', re.search(r'[0-9a-f]{64}', root) is not None, root[-100:])

# T5 adversarial on the settled trade and on a fresh open one.
log('== T5 adversarial')
b0 = (bal('shares', TAKER), bal('cash', MAKER))
r = td('call', 'core', 'settle', f'({tid} : nat)', identity='tachyon-maker')
row('T5 settle again is a no-op: refused or reported already settled, and no second payment', ((not is_ok(r)) or 'already settled' in r) and (bal('shares', TAKER), bal('cash', MAKER)) == b0, r[-160:])
r = td('call', 'core', 'reclaim', f'({tid} : nat)', identity='tachyon-maker'); row('T5 reclaim after settle refused', not is_ok(r), r[-160:])
tid2, _ = open_trade('tachyon-maker', TAKER, SHARES, 1_000, CASH, 500, 3600)
r = td('call', 'core', 'settle', f'({tid2} : nat)', identity='tachyon-maker'); row('T5 settle before both escrowed refused', not is_ok(r), r[-160:])
r = td('call', 'core', 'fundMaker', f'({tid2} : nat)', identity='tachyon-taker'); row('T5 taker cannot fund the maker leg', not is_ok(r), r[-160:])

# T3 abort: one leg funded, the deadline passes, the funded party reclaims in full.
# The refusal row uses a long deadline and the acceptance row a short one.
log('== T3 abort and reclaim')
approve('shares', 'tachyon-maker', CORE, 2_000 + FEE)
tid3a, o3a = open_trade('tachyon-maker', TAKER, SHARES, 2_000, CASH, 1_000, 3600)
fm = td('call', 'core', 'fundMaker', f'({tid3a} : nat)', identity='tachyon-maker'); row('T3 maker leg escrowed', is_ok(fm) or (field(o3a,'makerEscrowed') or '').startswith('true'), fm[-160:])
r = td('call', 'core', 'reclaim', f'({tid3a} : nat)', identity='tachyon-maker'); row('T3 reclaim before the deadline refused', not is_ok(r), r[-160:])
approve('shares', 'tachyon-maker', CORE, 2_000 + FEE)
m0 = {'ms': bal('shares', MAKER)}
tid3, o3 = open_trade('tachyon-maker', TAKER, SHARES, 2_000, CASH, 1_000, 20)
td('call', 'core', 'fundMaker', f'({tid3} : nat)', identity='tachyon-maker')
t0 = time.time(); r = ''
while time.time() - t0 < 600:
    r = td('call', 'core', 'reclaim', f'({tid3} : nat)', identity='tachyon-maker')
    if is_ok(r) or status_of(tid3) == 'Aborted': break
    time.sleep(5)
row('T3 reclaim after the deadline accepted', is_ok(r) or status_of(tid3) == 'Aborted', r[-200:])
row('T3 status Aborted', status_of(tid3, 'Aborted') == 'Aborted', status_of(tid3))
row('T3 maker got the asset back minus the escrow and refund fees', m0['ms'] - bal('shares', MAKER) == 2 * FEE, (m0['ms'], bal('shares', MAKER)))

# T4 idempotent retry: the cash payout fails once on the flaky ledger; the retry settles; no double payment.
log('== T4 idempotent retry under an injected failure')
m0 = {'mf': bal('cash_flaky', MAKER), 'tf': bal('cash_flaky', TAKER), 'ts': bal('shares', TAKER)}
approve('shares', 'tachyon-maker', CORE, 3_000 + FEE); approve('cash_flaky', 'tachyon-taker', CORE, 1_500 + FEE)
m0 = {'mf': bal('cash_flaky', MAKER), 'tf': bal('cash_flaky', TAKER), 'ts': bal('shares', TAKER)}
tid4, _ = open_trade('tachyon-maker', TAKER, SHARES, 3_000, FLAKY, 1_500, 3600)
fm4 = td('call', 'core', 'fundMaker', f'({tid4} : nat)', identity='tachyon-maker'); log('  T4 fundMaker: ' + fm4[-120:].replace('\n', ' '))
td('call', 'cash_flaky', 'set_fail_next', '(1 : nat)')  # the installer identity owns the switch
ft = td('call', 'core', 'fundTaker', f'({tid4} : nat)', identity='tachyon-taker')
log('  T4 first attempt note: ' + ft[-200:].replace('\n', ' '))
st = status_of(tid4)
if st != 'Settled':
    r = td('call', 'core', 'settle', f'({tid4} : nat)', identity='tachyon-taker'); log('  T4 retry: ' + r[-200:].replace('\n', ' '))
    r2 = td('call', 'core', 'settle', f'({tid4} : nat)', identity='tachyon-taker'); log('  T4 second retry: ' + r2[-200:].replace('\n', ' '))
row('T4 status Settled after the retry', status_of(tid4, 'Settled') == 'Settled', status_of(tid4))
row('T4 maker paid exactly once on the flaky ledger', bal('cash_flaky', MAKER) - m0['mf'] == 1_500 - FEE, (m0['mf'], bal('cash_flaky', MAKER)))
row('T4 taker received the asset exactly once', bal('shares', TAKER) - m0['ts'] == 3_000 - FEE, (m0['ts'], bal('shares', TAKER)))
row('T4 core holds no residual on the flaky ledger from the trade', bal('cash_flaky', CORE) == k0['f'], (k0['f'], bal('cash_flaky', CORE)))
inv = td('query', 'core', 'invariantLog'); row('T4 no invariant violation logged', 'fail' not in inv.lower(), inv[-200:])

# D1 delivery free of payment: the maker escrows one leg, the taker accepts, the leg moves once.
log('== D1 delivery accepted')
DSTATUS = {candid_hash(s): s for s in ('Open', 'Escrowed', 'Delivered', 'Reclaimed')}
def dstatus_of(did, expect=None):
    for attempt in range(12 if expect else 1):
        out = td('query', 'core', 'getDelivery', f'({did} : nat)')
        v = field(out, 'status') or ''
        got = None
        for h, sname in DSTATUS.items():
            if f'{h:,}'.replace(',', '_') in v or sname in v: got = sname
        if expect is None or got == expect: return got
        time.sleep(1)
    return got
def open_delivery(maker, taker_p, ledger, amount, deadline):
    out = td('call', 'core', 'openDelivery', f'(record {{ taker = principal "{taker_p}"; ledger = principal "{ledger}"; amount = {amount} : nat; deadlineSecs = {deadline} : nat }})', identity=maker)
    v = field(out, 'deliveryId')
    m = re.match(r'([0-9_]+)', v or '')
    return (int(m.group(1).replace('_', '')) if m else None), out
n0 = nat_in(td('query', 'core', 'deliveriesOpened')) or 0
approve('shares', 'tachyon-maker', CORE, 4_000 + FEE)
d0 = {'ms': bal('shares', MAKER), 'ts': bal('shares', TAKER)}
did, od = open_delivery('tachyon-maker', TAKER, SHARES, 4_000, 3600)
row('D1 openDelivery', did is not None, od[-200:])
fd = td('call', 'core', 'fundDelivery', f'({did} : nat)', identity='tachyon-maker')
row('D1 the leg escrowed (inline at open, or now)', (is_ok(fd) and (field(fd, 'escrowed') or '').startswith('true')) or (field(od, 'makerEscrowed') or '').startswith('true'), fd[-200:])
row('D1 status Escrowed, awaiting the taker', dstatus_of(did, 'Escrowed') == 'Escrowed', dstatus_of(did))
c0 = bal('shares', CORE)
row('D1 the core holds the leg and the taker has nothing yet', c0 >= 4_000 and bal('shares', TAKER) == d0['ts'], (c0, bal('shares', TAKER)))
r = td('call', 'core', 'acceptDelivery', f'({did} : nat)', identity='tachyon-maker'); row('D1 the maker cannot accept its own delivery', not is_ok(r), r[-160:])
r = td('call', 'core', 'settleDelivery', f'({did} : nat)', identity='tachyon-maker'); row('D1 no payout before the acceptance (the gate)', not is_ok(r), r[-160:])
ad = td('call', 'core', 'acceptDelivery', f'({did} : nat)', identity='tachyon-taker'); row('D1 the taker accepts and the leg is paid out', is_ok(ad) and (field(ad, 'delivered') or '').startswith('true'), ad[-200:])
row('D1 status Delivered', dstatus_of(did, 'Delivered') == 'Delivered', dstatus_of(did))
row('D1 taker received the leg minus one payout fee, once', bal('shares', TAKER) - d0['ts'] == 4_000 - FEE, (d0['ts'], bal('shares', TAKER)))
row('D1 the core released the leg', bal('shares', CORE) == c0 - 4_000, (c0, bal('shares', CORE)))
ev = td('query', 'core', 'auditEvents', f'({did} : nat)')
row('D1 receipt chain DELIVERY, FUND, ESCROWED, ACCEPTED, DELIVERED', all(k in ev for k in ('DELIVERY', 'FUND', 'ESCROWED', 'ACCEPTED', 'DELIVERED')), ev[-300:])
b1 = bal('shares', TAKER)
r = td('call', 'core', 'acceptDelivery', f'({did} : nat)', identity='tachyon-taker'); row('D1 a second acceptance reports delivered and pays nothing', ('already delivered' in r or is_ok(r)) and bal('shares', TAKER) == b1, r[-160:])
r = td('call', 'core', 'reclaimDelivery', f'({did} : nat)', identity='tachyon-maker'); row('D1 reclaim after delivery refused (INV-DEL-3)', not is_ok(r), r[-160:])

# D2 reclaim: the taker never accepts, the deadline passes, the maker reclaims in full, once.
log('== D2 delivery reclaimed')
# the refusal row uses a long deadline (the chain clock runs ahead of the wall clock) and is then accepted;
# the acceptance row a short one.
approve('shares', 'tachyon-maker', CORE, 700 + FEE)
did2a, _ = open_delivery('tachyon-maker', TAKER, SHARES, 700, 3600)
td('call', 'core', 'fundDelivery', f'({did2a} : nat)', identity='tachyon-maker')
r = td('call', 'core', 'reclaimDelivery', f'({did2a} : nat)', identity='tachyon-maker'); row('D2 reclaim before the deadline refused', not is_ok(r), r[-160:])
r = td('call', 'core', 'acceptDelivery', f'({did2a} : nat)', identity='tachyon-taker'); row('D2 the long-dated delivery accepted instead', is_ok(r), r[-160:])
approve('shares', 'tachyon-maker', CORE, 2_500 + FEE)
d0 = {'ms': bal('shares', MAKER)}
did2, od2 = open_delivery('tachyon-maker', TAKER, SHARES, 2_500, 20)
td('call', 'core', 'fundDelivery', f'({did2} : nat)', identity='tachyon-maker')
t0 = time.time(); r = ''
while time.time() - t0 < 600:
    r = td('call', 'core', 'reclaimDelivery', f'({did2} : nat)', identity='tachyon-maker')
    if is_ok(r) or dstatus_of(did2) == 'Reclaimed': break
    time.sleep(5)
row('D2 reclaim after the deadline accepted', is_ok(r) or dstatus_of(did2) == 'Reclaimed', r[-200:])
row('D2 status Reclaimed', dstatus_of(did2, 'Reclaimed') == 'Reclaimed', dstatus_of(did2))
row('D2 maker got the leg back minus the escrow and refund fees', d0['ms'] - bal('shares', MAKER) == 2 * FEE, (d0['ms'], bal('shares', MAKER)))
r = td('call', 'core', 'acceptDelivery', f'({did2} : nat)', identity='tachyon-taker'); row('D2 acceptance after the reclaim refused', not is_ok(r), r[-160:])
b2 = bal('shares', MAKER)
r = td('call', 'core', 'reclaimDelivery', f'({did2} : nat)', identity='tachyon-maker'); row('D2 a second reclaim reports reclaimed and returns nothing', ('already reclaimed' in r or is_ok(r)) and bal('shares', MAKER) == b2, r[-160:])

# D3 the wrong account: a delivery to a taker who does not accept it past its deadline goes back to the maker.
log('== D3 a delivery the taker does not accept')
approve('shares', 'tachyon-maker', CORE, 1_200 + FEE)
did3, _ = open_delivery('tachyon-maker', TAKER, SHARES, 1_200, 20)
td('call', 'core', 'fundDelivery', f'({did3} : nat)', identity='tachyon-maker')
# the chain's clock is read through a probe: an unfunded delivery opened in the same breath with the same
# window, whose funding is refused as past its deadline once the chain is there (nothing of it ever moves)
didp, _ = open_delivery('tachyon-maker', TAKER, SHARES, FEE + 1, 20)
r = td('call', 'core', 'acceptDelivery', f'({did3} : nat)', identity='tachyon-maker'); row('D3 only the named taker accepts', not is_ok(r), r[-160:])
t0 = time.time(); r = ''
while time.time() - t0 < 600:
    r = td('call', 'core', 'fundDelivery', f'({didp} : nat)', identity='tachyon-maker')
    if not is_ok(r) and 'deadline' in r: break
    time.sleep(5)
row('D3 the probe delivery is past its deadline unfunded', not is_ok(r) and 'deadline' in r, r[-160:])
time.sleep(5)
r = td('call', 'core', 'acceptDelivery', f'({did3} : nat)', identity='tachyon-taker')
row('D3 acceptance past the deadline refused', not is_ok(r) and 'deadline' in r, r[-160:])
row('D3 the leg still in the core', dstatus_of(did3, 'Escrowed') == 'Escrowed')
r = td('call', 'core', 'reclaimDelivery', f'({did3} : nat)', identity='tachyon-taker'); row('D3 the taker may reclaim to the maker', is_ok(r) and dstatus_of(did3, 'Reclaimed') == 'Reclaimed', r[-160:])
r = td('call', 'core', 'reclaimDelivery', f'({didp} : nat)', identity='tachyon-maker'); row('D3 the probe reclaimed with nothing moved', is_ok(r) and (field(r, 'amount') or '').startswith('0') and dstatus_of(didp, 'Reclaimed') == 'Reclaimed', r[-160:])
inv = td('query', 'core', 'invariantLog'); row('D4 no invariant violation logged across trades and deliveries', 'fail' not in inv.lower(), inv[-200:])
n = td('query', 'core', 'deliveriesOpened'); row('D4 five deliveries opened in this run', (nat_in(n) or 0) - n0 == 5, n[-60:])

# ══ M/L rows: the matching engine and the listing registry on the chain ══════════════════════
# The ground truth is a stateful Python twin of MatchLogic.mo (ported function for function
# below), fed exactly the submits, cancels and clears the battery drives on-chain. The bed
# persists between runs: the battery drains resting orders and unsettled obligations first,
# then seeds the twin's counters, reservations and balance baselines from the chain.

def has_canister(name):
    return re.search(r'\[canisters\.' + re.escape(name) + r'\]', open(A.manifest).read()) is not None

MATCHING = has_canister('matching')
if not MATCHING:
    log('== M/L rows skipped: no [canisters.matching] in the manifest (settlement-only bed)')
if MATCHING:
    ENGINE = cid_principal(cid_of('matching'))
    ENGINEB = cid_principal(cid_of('matching_gated'))
    LISTING = cid_principal(cid_of('listing'))
    LAND = cid_principal(cid_of('land'))
    SHARES_EMPTY = cid_principal(cid_of('shares_empty'))
    FEE_S = nat_in(td('query', 'shares', 'icrc1_fee')) or 0
    FEE_C = nat_in(td('query', 'cash', 'icrc1_fee')) or 0

    def text_of(out):
        m = re.findall(r'"((?:[^"\\]|\\.)*)"', out)
        return m[-1] if m else None

    # ── MatchLogic.mo, ported line for line ──────────────────────────────────────────────────
    def tw_demand(bids, p): return sum(b['qty'] for b in bids if b['price'] >= p)
    def tw_supply(asks, p): return sum(a['qty'] for a in asks if a['price'] <= p)

    def tw_clearing_price(bids, asks):
        # argmax executable volume; tie -> min imbalance; tie -> lowest price (MatchLogic.clearingPrice)
        cands = list(dict.fromkeys([o['price'] for o in bids] + [o['price'] for o in asks]))
        best = None; best_ex = 0; best_imb = 0
        for p in cands:
            d = tw_demand(bids, p); s = tw_supply(asks, p); ex = min(d, s)
            if ex > 0:
                imb = d - s if d > s else s - d
                if best is None or ex > best_ex or (ex == best_ex and (imb < best_imb or (imb == best_imb and p < best))):
                    best, best_ex, best_imb = p, ex, imb
        return best

    def tw_elig_bids(bids, p):
        # limit >= p*, best price first, then earliest id (MatchLogic.eligibleBids)
        return sorted([b for b in bids if b['price'] >= p], key=lambda o: (-o['price'], o['id']))
    def tw_elig_asks(asks, p):
        return sorted([a for a in asks if a['price'] <= p], key=lambda o: (o['price'], o['id']))

    def tw_fill_schedule(eb, ea, price, V):
        out = []; i = j = cb = ca = filled = 0
        while not (filled >= V or i >= len(eb) or j >= len(ea)):
            b = cb if cb else eb[i]['qty']; a = ca if ca else ea[j]['qty']
            f = min(b, a, V - filled)
            out.append({'buyId': eb[i]['id'], 'sellId': ea[j]['id'], 'price': price, 'qty': f})
            b -= f; a -= f; filled += f; cb, ca = b, a
            if b == 0: i += 1; cb = 0
            if a == 0: j += 1; ca = 0
        return out

    def tw_clear_aon(book):
        # MatchLogic.clearAON: kill the under-filled all-or-none order with the HIGHEST id; refixpoint.
        live = list(book); killed = []
        while True:
            bids = [o for o in live if o['isBid']]; asks = [o for o in live if not o['isBid']]
            p = tw_clearing_price(bids, asks)
            if p is None: return None, killed
            V = min(tw_demand(bids, p), tw_supply(asks, p))
            sched = tw_fill_schedule(tw_elig_bids(bids, p), tw_elig_asks(asks, p), p, V)
            got = {}
            for f in sched:
                got[f['buyId']] = got.get(f['buyId'], 0) + f['qty']
                got[f['sellId']] = got.get(f['sellId'], 0) + f['qty']
            victim = None
            for o in live:
                if o['aon'] and got.get(o['id'], 0) < o['qty']:
                    victim = o['id'] if victim is None else max(victim, o['id'])
            if victim is None: return p, killed
            killed.append(victim); live = [o for o in live if o['id'] != victim]

    # ── the stateful twin of Matching.mo's book, reservations, obligations and settlement ────
    class Twin:
        # The reservation model is Reservations.mo's, to the unit: the escrow the core pulls for one
        # fill debits the funder amount + one fee, once PER FILL, so a live order holds its remaining
        # notional + one fee (the fee of its next escrow), every created obligation holds its own
        # exact escrow cost until it settles or is voided, and every unit reserved has exactly one
        # release event - so a trader with no live order and no open obligation holds exactly nothing.
        def __init__(self):
            self.orders = {}; self.window = 0; self.next_id = 1; self.next_seq = 0
            self.obls = []; self.res_shares = {}; self.res_cash = {}; self.delta = {}
            self.margin = {}    # orderId -> the one-fee margin a live order holds
            self.hold = {}      # obligation seq -> the exact escrow cost it holds, per side
        def _sub(self, m, k, d):
            cur = m.get(k, 0); m[k] = 0 if d >= cur else cur - d   # the engine's debit clamps at zero
        def _add(self, m, k, d): m[k] = m.get(k, 0) + d
        def submit(self, oid, owner, side, price, qty, aon):
            self.orders[oid] = {'id': oid, 'owner': owner, 'side': side, 'price': price, 'qty': qty,
                                'rem': qty, 'window': self.window, 'aon': aon, 'status': 'O'}
            if side == 's':
                self._add(self.res_shares, owner, qty + FEE_S)          # an ask: qty + the fee its escrow costs
                self.margin[oid] = FEE_S
            else:
                self._add(self.res_cash, owner, price * qty + FEE_C)    # a bid: limit*qty + the fee its escrow costs
                self.margin[oid] = FEE_C
            self.next_id = oid + 1
        def release(self, o):
            # a terminal order (cancel, FOK kill) can produce no escrow: the remaining notional AND
            # the fee margin both go back
            fee = self.margin.pop(o['id'], 0)
            if o['side'] == 's': self._sub(self.res_shares, o['owner'], o['rem'] + fee)
            else: self._sub(self.res_cash, o['owner'], o['price'] * o['rem'] + fee)
        def cancel(self, oid):
            o = self.orders[oid]; self.release(o); o['status'] = 'C'; o['rem'] = 0
        def resolve(self, seq):
            # a settled or voided obligation releases exactly the escrow cost it held - the amounts
            # recorded when its fill was applied, never a recomputation. Idempotent.
            h = self.hold.pop(seq, None)
            if h is None: return
            ob = next(o for o in self.obls if o['seq'] == seq)
            self._sub(self.res_cash, self.orders[ob['buyId']]['owner'], h['cash'])
            self._sub(self.res_shares, self.orders[ob['sellId']]['owner'], h['shares'])
        def void(self, seq):
            self.resolve(seq)   # VOIDED is final, like a kill: nothing escrowed, nothing will
        def clear(self):
            w = self.window
            snap = sorted([o for o in self.orders.values() if o['window'] == w and o['rem'] > 0 and o['status'] in 'OP'], key=lambda o: o['id'])
            book = [{'id': o['id'], 'price': o['price'], 'qty': o['rem'], 'aon': o['aon'], 'isBid': o['side'] == 'b'} for o in snap]
            self.window += 1
            p, killed = tw_clear_aon(book)
            for vid in killed: self.cancel(vid)
            sched = []
            if p is not None:
                live = [b for b in book if b['id'] not in killed]
                bids = [o for o in live if o['isBid']]; asks = [o for o in live if not o['isBid']]
                V = min(tw_demand(bids, p), tw_supply(asks, p))
                sched = tw_fill_schedule(tw_elig_bids(bids, p), tw_elig_asks(asks, p), p, V)
                for f in sched:
                    b = self.orders[f['buyId']]; s = self.orders[f['sellId']]
                    b['rem'] -= f['qty']; s['rem'] -= f['qty']
                    bid_fee = self.margin.get(f['buyId'], 0); ask_fee = self.margin.get(f['sellId'], 0)
                    # the fill moves the reservation from the orders to the obligation it creates: the
                    # notional the fill consumed leaves each order (the bid's at its LIMIT price, which
                    # is what intake reserved), and the obligation takes up the two escrows it now owes
                    self._sub(self.res_cash, b['owner'], b['price'] * f['qty'])
                    self._sub(self.res_shares, s['owner'], f['qty'])
                    h = {'cash': p * f['qty'] + bid_fee, 'shares': f['qty'] + ask_fee}
                    self._add(self.res_cash, b['owner'], h['cash'])
                    self._add(self.res_shares, s['owner'], h['shares'])
                    self.hold[self.next_seq] = h
                    # an order left with nothing can produce no further escrow: its margin goes back
                    if b['rem'] == 0:
                        self._sub(self.res_cash, b['owner'], bid_fee); self.margin.pop(f['buyId'], None)
                    if s['rem'] == 0:
                        self._sub(self.res_shares, s['owner'], ask_fee); self.margin.pop(f['sellId'], None)
                    b['status'] = 'F' if b['rem'] == 0 else 'P'
                    s['status'] = 'F' if s['rem'] == 0 else 'P'
                    self.obls.append({'seq': self.next_seq, 'window': w, 'buyId': f['buyId'], 'sellId': f['sellId'],
                                      'price': p, 'qty': f['qty'], 'settled': False})
                    self.next_seq += 1
            for o in self.orders.values():                                              # re-enqueue, original ids kept
                if o['window'] == w and o['rem'] > 0 and o['status'] in 'OP': o['window'] = self.window
            return p, killed, sched
        def chunks_expected(self, fills, cap):
            # driveChunk breaks AFTER the cap-th fill even when the schedule just ended, so a
            # divisible fill count costs one extra completion chunk.
            if fills == 0: return 1
            return fills // cap + 1 if fills % cap == 0 else -(-fills // cap)
        def settle(self, seq):
            ob = next(o for o in self.obls if o['seq'] == seq)
            seller = next(x['owner'] for x in self.orders.values() if x['id'] == ob['sellId'])
            buyer = next(x['owner'] for x in self.orders.values() if x['id'] == ob['buyId'])
            cash = ob['price'] * ob['qty']
            self._add(self.delta, ('shares', seller), 0); self.delta[('shares', seller)] -= ob['qty'] + FEE_S   # escrow pull costs amount + fee
            self._add(self.delta, ('cash', seller), cash - FEE_C)                                              # a payout arrives minus one fee
            self._add(self.delta, ('cash', buyer), 0); self.delta[('cash', buyer)] -= cash + FEE_C
            self._add(self.delta, ('shares', buyer), ob['qty'] - FEE_S)
            ob['settled'] = True
            self.resolve(seq)               # the obligation resolved: it releases the escrow cost it held
        def obl_text(self, obls=None):
            return ''.join(f"{o['buyId']}>{o['sellId']}@{o['price']}:{o['qty']};" for o in (self.obls if obls is None else obls))
        def book_seg(self, oid):
            o = self.orders[oid]
            return f"{oid}:{o['side']}:{o['rem']}:{o['status']};"

    TW = Twin()
    OWNER_P = {'tachyon-maker': MAKER, 'tachyon-taker': TAKER}

    def submit(who, side, price, qty, aon=False, engine='matching', mirror=True):
        out = td('call', engine, 'submitOrder',
                 f'(record {{ side = variant {{ {side} }}; limitPrice = {price} : nat; qty = {qty} : nat; allOrNone = {"true" if aon else "false"} }})',
                 identity=who)
        v = field(out, 'orderId'); m = re.match(r'([0-9_]+)', v or '')
        oid = int(m.group(1).replace('_', '')) if m else None
        if oid is not None and mirror:
            TW.submit(oid, who, 's' if side == 'sell' else 'b', price, qty, aon)
        return oid, out

    def wait_clear_gone(w, secs):
        t0 = time.time()
        while time.time() - t0 < secs:
            if 'record' not in td('query', 'matching', 'pendingClearStatus', f'({w} : nat)'): return True
            time.sleep(2)
        return False

    # record fields print by name or by Candid hash (T4's log shows the hashes); match either.
    WKEY = f'{candid_hash("window"):,}'.replace(',', '_')
    IDKEY = f'{candid_hash("id"):,}'.replace(',', '_')
    SKEY = f'{candid_hash("seq"):,}'.replace(',', '_')

    def unsettled_in(windows):
        out = td('query', 'matching', 'unsettledObligations')
        ws = [int(x.replace('_', '')) for x in re.findall(r'\b(?:window|' + WKEY + r') = ([0-9_]+)', out)]
        return [w for w in ws if w in windows]

    def obl_sum(): return text_of(td('query', 'matching', 'obligationSummary')) or ''
    def book_sum(): return text_of(td('query', 'matching', 'bookSummary')) or ''
    def resv(p):
        out = td('query', 'matching', 'reservationOf', f'(principal "{p}")')
        s = field(out, 'shares'); c = field(out, 'cash')
        g = lambda v: int(re.match(r'([0-9_]+)', v or '0').group(1).replace('_', ''))
        return g(s), g(c)

    def audit(p):
        # The reservation the engine HOLDS beside the one its own live book and open obligations
        # PRESCRIBE: Σ live orders (remaining notional + margin) + Σ open obligations (their recorded
        # escrow cost). Equal for everything this accounting has seen; any difference is residue the
        # accounting that preceded it left behind, which this one never adds to.
        out = td('query', 'matching', 'reservationAudit', f'(principal "{p}")')
        g = lambda k: int(re.match(r'([0-9_]+)', field(out, k) or '0').group(1).replace('_', ''))
        return {k: g(k) for k in ('maintainedShares', 'maintainedCash', 'prescribedShares',
                                  'prescribedCash', 'liveOrders', 'openObligations')}

    def residue_of(a): return (a['maintainedShares'] - a['prescribedShares'], a['maintainedCash'] - a['prescribedCash'])

    # ── M0 wiring: drain the bed, seed the twin, bind the relayer ─────────────────────────────
    log('== M0 wiring: engines, listing, the relayer gate')
    cfgout = td('query', 'matching', 'config')
    row('M0a the engine\'s config names the core and the ledgers as the manifest maps them',
        all(p.split('-')[0] in cfgout for p in (CORE, SHARES, CASH)) and (field(cfgout, 'maxFillsPerChunk') or '').startswith('2'), cfgout[-300:])

    # the standing approvals FIRST: the drain below settles stale obligations left by an earlier
    # run, and those settles escrow through the core against these same allowances - granted
    # after the drain they would refuse leg escrow with the T rows' small residue.
    approve('shares', 'tachyon-maker', CORE, 100_000)
    approve('cash', 'tachyon-taker', CORE, 500_000)

    # drain: cancel every resting order of the open window (owner unknown - try both identities),
    # then settle any unsettled obligation left by an earlier run. Not rows; bed hygiene.
    for _ in range(3):
        w_open = nat_in(td('query', 'matching', 'getCurrentWindow')) or 0
        rest = td('query', 'matching', 'ordersInWindow', f'({w_open} : nat)')
        ids = [int(x.replace('_', '')) for x in re.findall(r'\b(?:id|' + IDKEY + r') = ([0-9_]+)', rest)]
        if not ids: break
        for i in ids:
            td('call', 'matching', 'cancelOrder', f'({i} : nat)', identity='tachyon-maker')
            td('call', 'matching', 'cancelOrder', f'({i} : nat)', identity='tachyon-taker')
    # settle each stale obligation directly by seq; one the core permanently refuses (dust left
    # unsettled by an earlier run) is VOIDED by the engine - resolved, no longer counted unsettled.
    stale = [int(x.replace('_', '')) for x in re.findall(r'\b(?:seq|' + SKEY + r') = ([0-9_]+)', td('query', 'matching', 'unsettledObligations'))]
    for q in stale:
        out = td('call', 'matching', 'settleObligation', f'({q} : nat, 600 : nat)')
        if 'VOIDED' in out or 'voided' in out: log(f'  drain: stale obligation {q} voided (permanently unsettleable dust from an earlier run)')
        elif not is_ok(out): log(f'  drain: stale obligation {q} refused ({err_text(out)[:80]}) - left unsettled')

    TW.next_id = (nat_in(td('query', 'matching', 'orderCount')) or 0) + 1
    TW.next_seq = obl_sum().count(';')
    TW.window = nat_in(td('query', 'matching', 'getCurrentWindow')) or 0
    ms0, mc0 = resv(MAKER); ts0, tc0 = resv(TAKER)
    TW.res_shares['tachyon-maker'] = ms0; TW.res_cash['tachyon-maker'] = mc0
    TW.res_shares['tachyon-taker'] = ts0; TW.res_cash['tachyon-taker'] = tc0
    log(f'  seed: next_id={TW.next_id} next_seq={TW.next_seq} window={TW.window} resv maker={ms0}/{mc0} taker={ts0}/{tc0}')

    BASE = {('shares', 'tachyon-maker'): bal('shares', MAKER), ('cash', 'tachyon-maker'): bal('cash', MAKER),
            ('shares', 'tachyon-taker'): bal('shares', TAKER), ('cash', 'tachyon-taker'): bal('cash', TAKER)}
    kM = {'s': bal('shares', CORE), 'c': bal('cash', CORE)}
    OSUM0 = obl_sum()
    log(f'  baselines: core={kM} obligations so far={TW.next_seq}')

    def bal_row(name):
        ok = True; detail = []
        for (ledger, who), want in sorted(TW.delta.items()):
            have = bal(ledger, OWNER_P[who]) - BASE[(ledger, who)]
            detail.append(f'{who}/{ledger}: {have} vs {want}')
            ok = ok and have == want
        return row(name, ok, '; '.join(detail))

    def twres(who): return (TW.res_shares.get(who, 0), TW.res_cash.get(who, 0))

    def resv_row(name):
        mm = resv(MAKER); tt = resv(TAKER)
        want_m = twres('tachyon-maker'); want_t = twres('tachyon-taker')
        return row(name, mm == want_m and tt == want_t, f'maker {mm} vs {want_m}; taker {tt} vs {want_t}')

    def approve_feed(ledger, who, amount, exact=False):
        # A mid-battery approve burns one ledger fee from the approver - a harness action, not an
        # engine settlement. Feed the OBSERVED burn to the twin's deltas so the balance rows stay
        # byte-exact, and log if it is ever not exactly one fee. With exact=True (a revoke), wait
        # until the allowance reads back EQUAL to the amount - the >= wait inside approve() is
        # vacuous for 0 and a stale read must not race the row that depends on the revocation.
        p = OWNER_P[who]
        b0 = bal(ledger, p)
        approve(ledger, who, CORE, amount)
        if exact:
            for _ in range(20):
                if (allowance(ledger, p, CORE) or 0) == amount: break
                time.sleep(1)
        b1 = bal(ledger, p)
        fee = FEE_S if ledger == 'shares' else FEE_C
        if b0 - b1 != fee: log(f'  approve_feed: {who}/{ledger} burned {b0 - b1} (expected one fee {fee})')
        TW.delta[(ledger, who)] = TW.delta.get((ledger, who), 0) - (b0 - b1)

    def drain_window(window, tries=16):
        # The autonomous drain's loop-to-completion contract: settleMatched settles a BOUNDED
        # slice (MAX_FILLS_PER_CHUNK obligations) of the window per call inside the one message the
        # caller awaits - no Timer, no self-message - so the relayer calls it until nothing is left
        # or the count stops falling (a transiently refused obligation the sweep stepped over,
        # whose underlying condition has not cleared). Reads the chain by query, never a call's
        # printed result (ingress-nonce dedup can answer a repeated same-identity update with the
        # earlier call's result). Returns the seqs still unsettled in the window.
        for _ in range(tries):
            before = len(unsettled_in({window}))
            if before == 0: break
            td('call', 'matching', 'settleMatched', f'({window} : nat, 600 : nat)')
            time.sleep(3)
            if len(unsettled_in({window})) == before: break   # no progress -> stuck head, stop looping
        return unsettled_in({window})

    def known_book(tag):
        # A scenario that names its own fills needs the open window to hold EXACTLY its own orders.
        # Cancel the twin-known remainders resting there (the M1->M5 rows leave them on purpose and
        # depend on them), then assert nothing ELSE is resting. An order the twin never saw - one a row
        # expected to be refused and was not, or one an earlier run left after the seed - would pair
        # with this scenario's orders, and a fill whose buyer and seller are the same trader is one the
        # core refuses ("maker and taker must differ") and that can never settle, so every balance and
        # reservation row downstream drifts. Left unnamed that surfaces as a dozen confusing failures
        # far from the cause; named here it is one row pointing straight at it.
        # Live orders are read from bookSummary, not ordersInWindow: the latter also returns the
        # window's cancelled and filled orders, which are not resting and must not be counted.
        segs = [s.split(':') for s in book_sum().split(';') if s]
        live = [int(a) for a, _sd, rem, st in segs if st in ('O', 'P') and int(rem) > 0]
        unknown = []
        for i in live:
            o = TW.orders.get(i)
            if o is None:
                unknown.append(i)
            elif o['status'] in 'OP' and o['rem'] > 0:
                if is_ok(td('call', 'matching', 'cancelOrder', f'({i} : nat)', identity=o['owner'])): TW.cancel(i)
        row(f'{tag} the open window holds only orders the twin knows, so this scenario gets the book it describes',
            not unknown, f'resting orders the twin never saw: {unknown}')
        return nat_in(td('query', 'matching', 'getCurrentWindow')) or 0

    r = td('call', 'core', 'settleMatchFor',
           f'(record {{ matchSeq = 999_999_999 : nat; maker = principal "{MAKER}"; taker = principal "{TAKER}"; assetLedger = principal "{SHARES}"; assetAmount = 100 : nat; cashLedger = principal "{CASH}"; cashAmount = 100 : nat; deadlineSecs = 60 : nat }})')
    row('M0b a caller that is not the bound engine can never settleMatchFor', not is_ok(r), r[-200:])
    r = td('call', 'core', 'setMatchingEngine', f'(principal "{ENGINE}")', identity='tachyon-maker')
    row('M0c only the core installer may bind the relayer', not is_ok(r), r[-160:])
    r = td('call', 'core', 'setMatchingEngine', f'(principal "{ENGINE}")')
    mp = td('query', 'core', 'matchingEnginePrincipal')
    row('M0d the installer binds the engine and the core reports it', is_ok(r) and ENGINE.split('-')[0] in mp, (r[-120:], mp[-120:]))

    # ── M1 one window, one uniform price, the twin byte for byte ─────────────────────────────
    log('== M1 auction: a two-sided window against the twin')
    wA = TW.window
    ids_ok = []
    # every planned fill stays above the ledger fee (10): a fill at or below it is permanently
    # unsettleable through the core - provoked deliberately in the MD rows, never by accident here.
    for who, side, price, qty in (('tachyon-maker', 'sell', 10, 1000), ('tachyon-maker', 'sell', 11, 500),
                                  ('tachyon-taker', 'buy', 12, 1200), ('tachyon-taker', 'buy', 10, 300)):
        want = TW.next_id
        oid, out = submit(who, side, price, qty)
        ids_ok.append(oid == want)
    a1, a2, b1, b2 = TW.next_id - 4, TW.next_id - 3, TW.next_id - 2, TW.next_id - 1
    row('M1a four orders accepted with exactly the twin\'s ids', all(ids_ok), ids_ok)
    pA, killedA, schedA = TW.clear()
    r = td('call', 'matching', 'clearWindow')
    row('M1b clearWindow accepted', is_ok(r), r[-200:])
    row('M1c the clear completes (the engine\'s own Timer finishes the capped chunks)', wait_clear_gone(wA, 300))
    row('M1d the obligation schedule equals the twin\'s unbounded schedule, byte for byte',
        obl_sum() == OSUM0 + TW.obl_text(), f'chain={obl_sum()[-160:]} twin_suffix={TW.obl_text()[-160:]}')
    bs = book_sum()
    row('M1e the book after the clear: filled, partial and resting exactly as the twin',
        all(TW.book_seg(i) in bs for i in (a1, a2, b1, b2)), bs[-200:])
    resv_row('M1f reservations equal the twin (each fill moves the notional it consumed into its obligation\'s own escrow cost)')
    ch = nat_in(td('query', 'matching', 'chunksUsed', f'({wA} : nat)'))
    row('M1g the chunk count equals the twin\'s arithmetic for a 2-fill cap',
        ch == TW.chunks_expected(len(schedA), 2), f'chunks={ch} fills={len(schedA)}')
    inv = td('query', 'matching', 'invariantLog')
    row('M1h the engine\'s invariant log is empty', text_of(inv) in (None, ''), inv[-160:])

    # ── M2 settlement through the core, by seq, exact to the fee ─────────────────────────────
    log('== M2 settlement: every obligation of the window through the core')
    seqsA = [o['seq'] for o in TW.obls if o['window'] == wA and not o['settled']]
    trades = {}
    all_settled = True
    for q in seqsA:
        out = td('call', 'matching', 'settleObligation', f'({q} : nat, 600 : nat)')
        m = re.search(r'DvP trade ([0-9_]+)', out)
        trades[q] = int(m.group(1).replace('_', '')) if m else None
        all_settled = all_settled and is_ok(out) and 'SETTLED' in out
        TW.settle(q)
    row('M2a every obligation of the window reports SETTLED with its DvP trade id',
        all_settled and all(v is not None for v in trades.values()), trades)
    bal_row('M2b maker and taker balances moved exactly as the twin (per-fill fees included)')
    row('M2c the core holds no residual from the matched settlements',
        bal('shares', CORE) == kM['s'] and bal('cash', CORE) == kM['c'], (kM, bal('shares', CORE), bal('cash', CORE)))
    q0 = seqsA[0]
    tm = td('query', 'core', 'tradeIdForMatch', f'(principal "{ENGINE}", {q0} : nat)')
    ev = td('query', 'core', 'auditEvents', f'({trades[q0]} : nat)')
    row('M2d the matchSeq round-trips to the trade and its ORDER receipt names the matchSeq',
        str(trades[q0]) in tm.replace('_', '') and f'matchSeq={q0}' in ev and 'SETTLED' in ev, (tm[-80:], ev[-200:]))
    snap = (bal('shares', MAKER), bal('cash', MAKER), bal('shares', TAKER), bal('cash', TAKER))
    r = td('call', 'matching', 'settleObligation', f'({q0} : nat, 600 : nat)')
    row('M2e a settled obligation re-driven reports already settled and moves nothing',
        is_ok(r) and 'already settled' in r and snap == (bal('shares', MAKER), bal('cash', MAKER), bal('shares', TAKER), bal('cash', TAKER)), r[-160:])
    r = td('call', 'matching', 'settleMatched', f'({wA} : nat, 600 : nat)')
    row('M2f settleMatched on the settled window reports nothing left', is_ok(r) and (field(r, 'remaining') or '').startswith('0'), r[-160:])

    # ── M3 chunked clear, the Timer's own resume, autonomous settlement ──────────────────────
    log('== M3 chunking: a 5-ask book under the 2-fill cap, resumed by the engine alone')
    wB = TW.window
    for i in range(5): submit('tachyon-maker', 'sell', 10, 200)
    big, _ = submit('tachyon-taker', 'buy', 10, 1000)
    pB, killedB, schedB = TW.clear()
    r = td('call', 'matching', 'clearWindow')
    row('M3a the first chunk reports the budget exhausted (the 2-fill cap bites)',
        is_ok(r) and (field(r, 'complete') or '').startswith('false'), r[-200:])
    auto = wait_clear_gone(wB, 360)
    row('M3b the engine\'s Timer resumes and completes the clear with no battery drive', auto)
    if not auto:
        log('  M3b FAIL - driving continueClear manually so the rows after it still run')
        for _ in range(20):
            if 'record' not in td('query', 'matching', 'pendingClearStatus', f'({wB} : nat)'): break
            td('call', 'matching', 'continueClear', f'({wB} : nat)')
    ch = nat_in(td('query', 'matching', 'chunksUsed', f'({wB} : nat)'))
    row('M3c the chunk count equals the twin\'s arithmetic and is >= 2',
        ch == TW.chunks_expected(len(schedB), 2) and (ch or 0) >= 2, f'chunks={ch} fills={len(schedB)}')
    row('M3d the chunked schedule equals the twin\'s unbounded schedule (carried remainders included)',
        obl_sum() == OSUM0 + TW.obl_text(), f'twin_suffix={TW.obl_text()[-220:]}')
    # The autonomous drain: settleMatched settles a bounded slice per call INSIDE the one message
    # the caller awaits (no Timer, no self-message - the substrate does not reliably dispatch a
    # message the caller never awaits, the recorded post-await-Timer defect being one face of it),
    # and the relayer loops until the window is empty. drain_window does exactly that.
    seqsB = [o['seq'] for o in TW.obls if o['window'] == wB and not o['settled']]
    n0 = len(unsettled_in({wB}))
    t0 = time.time()
    left = drain_window(wB)
    drain_secs = time.time() - t0
    for q in seqsB: TW.settle(q)
    row('M3e settleMatched drains the whole window in bounded inline sweeps (looped to completion, no self-message)',
        n0 == len(seqsB) and n0 >= 2 and not left, (n0, left, f'{drain_secs:.0f}s'))

    # ── M4 time priority and the all-or-none kill ────────────────────────────────────────────
    log('== M4 priority and FOK')
    X, _ = submit('tachyon-taker', 'buy', 10, 400)
    Z, _ = submit('tachyon-taker', 'buy', 10, 400)
    S, _ = submit('tachyon-maker', 'sell', 10, 400)
    wC = TW.window
    pC, killedC, schedC = TW.clear()
    td('call', 'matching', 'clearWindow')
    row('M4a the clear completes', wait_clear_gone(wC, 300))
    bs = book_sum()
    row('M4b the oldest resting bid fills first; the newest same-price bid gets nothing',
        obl_sum() == OSUM0 + TW.obl_text() and all(TW.book_seg(i) in bs for i in (X, Z, S)), bs[-200:])
    seqsC = [o['seq'] for o in TW.obls if o['window'] == wC and not o['settled']]
    okC = True
    for q in seqsC:
        out = td('call', 'matching', 'settleObligation', f'({q} : nat, 600 : nat)')
        okC = okC and is_ok(out) and 'SETTLED' in out
        TW.settle(q)
    row('M4c every obligation of the priority window reports SETTLED', okC and len(seqsC) == 2, len(seqsC))
    bal_row('M4c2 the priority window settles exact to the twin')
    SA, _ = submit('tachyon-maker', 'sell', 10, 1000, aon=True)
    wD = TW.window
    pD, killedD, schedD = TW.clear()
    r = td('call', 'matching', 'clearWindow')
    row('M4d the all-or-none ask that cannot fully fill is killed before any mutation: no cross, no fill',
        is_ok(r) and killedD == [SA] and pD is None and 'no cross' in r and obl_sum() == OSUM0 + TW.obl_text(), r[-200:])
    kl = td('query', 'matching', 'killLogView')
    bs = book_sum()
    row('M4e the kill is logged, the order Cancelled, its reservation released, the rest of the book intact',
        f'FOK-KILL order {SA}' in kl and TW.book_seg(SA) in bs and all(TW.book_seg(i) in bs for i in (X, Z)), (kl[-160:], bs[-160:]))
    resv_row('M4f reservations after the kill equal the twin (the kill releases the notional and the fee margin both)')

    # ── M5 adversarial refusals and the relayer rotation ─────────────────────────────────────
    log('== M5 adversarial and the rotation')
    r = td('call', 'matching', 'cancelOrder', f'({Z} : nat)', identity='tachyon-maker')
    row('M5a only the owner may cancel', not is_ok(r), r[-120:])
    TW.cancel(Z)
    r = td('call', 'matching', 'cancelOrder', f'({Z} : nat)', identity='tachyon-taker')
    resv_ok = resv(TAKER) == (TW.res_shares.get('tachyon-taker', 0), TW.res_cash.get('tachyon-taker', 0))
    row('M5b the owner cancels and the reservation is released to the twin\'s number', is_ok(r) and resv_ok, r[-120:])
    r = td('call', 'matching', 'cancelOrder', f'({a1} : nat)', identity='tachyon-maker')
    row('M5c an order of a closed window cannot be cancelled', not is_ok(r), r[-120:])
    # The need must exceed any allowance this battery ever grants (500_000) while staying far under the
    # caller's balance, so the row tests the ALLOWANCE gate and not the balance gate, and so it does
    # not depend on what an earlier run left on the ledger. An earlier version asked for 200 + a fee,
    # which is refused only while the maker holds no cash allowance: true on a fresh bed, false on any
    # bed where a previous run's M6 had granted one - and because a row that expects a refusal does not
    # mirror its order to the twin, the order it wrongly accepted then rested in the book and
    # self-matched against the maker's own asks in the windows that followed.
    # Three conditions, all of them needed for this row to mean what it says:
    #  (a) qty above the shares fee and notional above the cash fee, or the MD intake floors refuse it
    #      for dust first and the refusal never reaches the allowance gate at all;
    #  (b) need above any allowance this battery ever grants (500_000), so the ALLOWANCE gate is what
    #      refuses it - and so the row does not depend on what an earlier run left on the ledger;
    #  (c) need far below the caller's balance (~100_000_000), because the balance gate is checked
    #      first and would otherwise refuse it with a different message.
    M5D_Q, M5D_P = 10 * FEE_S, 100_000      # need = 10_000_000 + one cash fee
    r = td('call', 'matching', 'submitOrder', f'(record {{ side = variant {{ buy }}; limitPrice = {M5D_P} : nat; qty = {M5D_Q} : nat; allOrNone = false }})', identity='tachyon-maker')
    row('M5d an order beyond the caller\'s allowance to the core is refused at intake',
        not is_ok(r) and 'allowance' in r, r[-200:])
    r = td('call', 'matching', 'settleObligation', '(999_999 : nat, 600 : nat)')
    r2 = td('call', 'matching', 'settleObligation', '(0 : nat, 0 : nat)')
    row('M5e an unknown seq and a zero deadline are refused', not is_ok(r) and not is_ok(r2), (r[-100:], r2[-100:]))
    S2, _ = submit('tachyon-maker', 'sell', 10, 200)
    wE = TW.window
    pE, killedE, schedE = TW.clear()
    td('call', 'matching', 'clearWindow')
    row('M5f the rotation window clears one fill', wait_clear_gone(wE, 300) and len(schedE) == 1, TW.obl_text(schedE))
    qE = [o['seq'] for o in TW.obls if o['window'] == wE and not o['settled']][0]
    r = td('call', 'core', 'setMatchingEngine', f'(principal "{ENGINEB}")')
    snap = (bal('shares', MAKER), bal('cash', MAKER), bal('shares', TAKER), bal('cash', TAKER))
    r2 = td('call', 'matching', 'settleObligation', f'({qE} : nat, 600 : nat)')
    row('M5g rotated away, the unbound engine\'s settle is refused by the core and nothing moves',
        is_ok(r) and (not is_ok(r2)) and 'authorized matching engine' in r2 and unsettled_in({wE}) == [wE]
        and snap == (bal('shares', MAKER), bal('cash', MAKER), bal('shares', TAKER), bal('cash', TAKER)), r2[-200:])
    r = td('call', 'core', 'setMatchingEngine', f'(principal "{ENGINE}")')
    r2 = td('call', 'matching', 'settleObligation', f'({qE} : nat, 600 : nat)')
    TW.settle(qE)
    row('M5h rotated back, the same obligation re-drives to SETTLED', is_ok(r) and is_ok(r2) and 'SETTLED' in r2, r2[-160:])
    bal_row('M5i balances after the rotation window exact to the twin')

    # ── M6 the autonomous drain steps over a transient refusal ───────────────────────────────
    # A transient refusal must be SKIPPED, not head-block the window: a two-party window whose
    # first fill settles shares from the maker and whose second settles shares from the taker,
    # the maker's shares allowance to the core revoked before the drain. The sweep attempts the
    # first fill - the core creates the trade, escrows the cash leg, cannot pull the asset leg,
    # so it stays unsettled - steps its cursor past it and settles the second fill in the same
    # bounded sweep (MAX_FILLS_PER_CHUNK is 2, so both are attempted in the one call). The refused
    # obligation owns a trade, so the void discipline must leave it alone. Restoring the allowance,
    # one more sweep re-drives the same trade to settled - the T4 idempotent-retry story through
    # the engine's drain. This scenario needs a book of exactly the four orders below, so it clears
    # the open window of any re-enqueued remainder first (like MD): a leftover order pairing with
    # one of them could make a fill whose buyer and seller are the same trader - a self-trade the
    # core refuses and can never settle - which is why it runs here, after the M1->M5 windows that
    # depend on the resting remainders this drain would cancel.
    log('== M6 the autonomous drain steps over a transient refusal')
    known_book('M6pre')
    approve_feed('shares', 'tachyon-taker', 100_000)   # the taker sells in this window
    approve_feed('cash', 'tachyon-maker', 100_000)     # the maker buys in this window
    aT, _ = submit('tachyon-maker', 'sell', 10, 100)   # fill 1: seller maker (aT), buyer taker (bT)
    aU, _ = submit('tachyon-taker', 'sell', 10, 150)   # fill 2: seller taker (aU), buyer maker (bU)
    bT, _ = submit('tachyon-taker', 'buy', 10, 100)
    bU, _ = submit('tachyon-maker', 'buy', 10, 150)
    wB2 = TW.window
    pB2, killedB2, schedB2 = TW.clear()
    td('call', 'matching', 'clearWindow')
    row('M6a the window clears exactly two cross-party fills (maker sells the first, taker the second), equal to the twin',
        wait_clear_gone(wB2, 300) and len(schedB2) == 2
        and schedB2[0]['sellId'] == aT and schedB2[0]['buyId'] == bT
        and schedB2[1]['sellId'] == aU and schedB2[1]['buyId'] == bU
        and obl_sum() == OSUM0 + TW.obl_text(), TW.obl_text(schedB2))
    seqs2 = [o['seq'] for o in TW.obls if o['window'] == wB2]
    seq1, seq2 = (seqs2 + [999_999_998, 999_999_999])[:2]
    approve_feed('shares', 'tachyon-maker', 0, exact=True)   # revoke: fill 1's asset escrow now refused
    left = drain_window(wB2)   # sweep attempts seq1 (refused, stepped over), settles seq2, stalls on seq1
    TW.settle(seq2)
    row('M6b the sweep steps over the transiently refused first fill and settles the fill behind it in one bounded sweep',
        left == [wB2], left)
    vq = td('query', 'matching', 'voidedObligations')
    voided_now = [int(x.replace('_', '')) for x in re.findall(r'\b(?:seq|' + SKEY + r') = ([0-9_]+)', vq)]
    tm = td('query', 'core', 'tradeIdForMatch', f'(principal "{ENGINE}", {seq1} : nat)')
    row('M6c the refused obligation owns a trade and is never voided (the void discipline holds under a transient refusal)',
        seq1 not in voided_now and 'null' not in tm, (vq[-120:], tm[-80:]))
    approve_feed('shares', 'tachyon-maker', 100_000)   # restore the allowance
    left = drain_window(wB2)   # the refused trade re-drives to settled now the allowance is back
    TW.settle(seq1)
    row('M6d the allowance restored, the next sweep re-drives the same trade to SETTLED - nothing left unsettled',
        not left, left)
    bal_row('M6e balances after the drained window exact to the twin (the interrupted escrow landed exactly once)')
    row('M6f the core still holds no residual', bal('shares', CORE) == kM['s'] and bal('cash', CORE) == kM['c'],
        (kM, bal('shares', CORE), bal('cash', CORE)))

    # ── MD the dust discipline: intake floors, the boundary void, the drain completes ────────
    # The core refuses a settlement whose asset amount is at or below the asset ledger's fee
    # (DvpCore.mo settleMatchFor validation) BEFORE any trade exists, so nothing ever escrows
    # for such a fill. The engine now (a) refuses at intake any order whose EVERY fill would
    # land under a floor (qty <= sharesFee; for a bid also limitPrice*qty <= cashFee), and
    # (b) resolves a boundary remainder fill the core permanently refuses as VOIDED - recorded
    # with its reason, excluded from the unsettled set, skipped by the drain - so one dust fill
    # can no longer head-block a window's settlement (the liveness gap of the first 2026-09-24
    # record, closed). The void fires only while no trade exists for the seq; an obligation
    # with a trade is never voided.
    log('== MD dust: intake floors; a boundary dust fill is voided and the drain completes')
    r = td('call', 'matching', 'submitOrder', f'(record {{ side = variant {{ sell }}; limitPrice = 10 : nat; qty = {FEE_S} : nat; allOrNone = false }})', identity='tachyon-maker')
    row('MD0a a sell whose qty is at or below the shares ledger fee is refused at intake', not is_ok(r) and 'fee' in r, r[-200:])
    r = td('call', 'matching', 'submitOrder', f'(record {{ side = variant {{ buy }}; limitPrice = 10 : nat; qty = {FEE_S} : nat; allOrNone = false }})', identity='tachyon-taker')
    row('MD0b a buy whose qty is at or below the shares ledger fee is refused at intake', not is_ok(r) and 'fee' in r, r[-200:])
    # a KNOWN book for the boundary scenario: the bed persists, so partially filled orders of the
    # M rows still rest in the open window (M4's marginal bid, M1's unfilled ask) and would absorb
    # the boundary fills. Cancel them first, mirroring the twin - the same hygiene as the M0 drain.
    known_book('MDpre')
    # a floor-passing book whose schedule still holds one boundary remainder fill under the fee:
    # asks 12 and 20, bids 15 and 17, all at one price -> fills 12, 3 (dust, mid-window), 17.
    a1d, _ = submit('tachyon-maker', 'sell', 10, 12)
    a2d, _ = submit('tachyon-maker', 'sell', 10, 20)
    b1d, _ = submit('tachyon-taker', 'buy', 10, 15)
    b2d, _ = submit('tachyon-taker', 'buy', 10, 17)
    wF = TW.window
    pF, killedF, schedF = TW.clear()
    td('call', 'matching', 'clearWindow')
    dustF = [f for f in schedF if f['qty'] <= FEE_S]
    row('MD1 the boundary window clears: three fills, exactly one at or below the shares fee, schedule equal to the twin',
        wait_clear_gone(wF, 300) and len(schedF) == 3 and len(dustF) == 1 and obl_sum() == OSUM0 + TW.obl_text(),
        TW.obl_text(schedF))
    dust_list = [o['seq'] for o in TW.obls if o['window'] == wF and o['qty'] <= FEE_S]
    dust_seq = dust_list[0] if dust_list else 999_999_999   # no dust -> the rows below fail, the battery continues
    good_seqs = [o['seq'] for o in TW.obls if o['window'] == wF and o['qty'] > FEE_S]
    # drain the window with settleMatched looped to completion: the bounded inline sweeps settle
    # the first good fill, void the permanently refused dust fill in stride, and settle the fill
    # beyond it. drain_window reads the chain by query, never a call's printed result.
    t0 = time.time()
    drain_window(wF)
    md_secs = time.time() - t0
    for q in good_seqs: TW.settle(q)
    TW.void(dust_seq)   # the voided fill settles nothing and moves nothing, but it releases its hold
    vq = td('query', 'matching', 'voidedObligations')
    voided_now = [int(x.replace('_', '')) for x in re.findall(r'\b(?:seq|' + SKEY + r') = ([0-9_]+)', vq)]
    tm = td('query', 'core', 'tradeIdForMatch', f'(principal "{ENGINE}", {dust_seq} : nat)')
    row('MD2 the drain voids the permanently refused dust fill: recorded with its reason, no trade ever created',
        dust_seq in voided_now and 'ledger fee' in vq and 'null' in tm, (vq[-200:], tm[-60:]))
    row('MD3 the looped drain completes the window past the voided fill - nothing left unsettled (settle, void, settle)',
        not unsettled_in({wF}), f'drained in {md_secs:.0f}s')
    bal_row('MD3b the two good fills settled exact to the twin; the voided fill moved nothing')
    r = td('call', 'matching', 'settleObligation', f'({dust_seq} : nat, 600 : nat)')
    tm2 = td('query', 'core', 'tradeIdForMatch', f'(principal "{ENGINE}", {dust_seq} : nat)')
    row('MD4 settleObligation on the voided seq reports the final resolution and creates no trade',
        is_ok(r) and 'voided' in r.lower() and 'null' in tm2, r[-200:])

    # ── M7 the reservation accounting: every unit reserved comes back ─────────────────────────
    # A reservation is the engine's claim on a trader's FREE capacity (balance ∧ allowance-to-core);
    # the engine holds no custody. The escrow the core pulls for one fill debits the funder
    # `amount + one fee`, once PER FILL, so the accounting is denominated per escrow
    # (Reservations.mo): a live order holds its remaining notional + one fee, every created
    # obligation holds its OWN exact escrow cost until it settles or is voided, and every unit has
    # exactly one release event - so a trader with no live order and no open obligation holds
    # exactly nothing. These rows measure that on the chain, each against the accounting it
    # replaces: the fee an ask never reserved though its escrow costs one, the escrow cost of a
    # cleared-but-unsettled obligation that used to be released into thin air between the clear and
    # the settlement, the SECOND fee a two-fill order needs where intake reserved one, and a whole
    # lifecycle handing every unit back. `reservationAudit` recomputes the prescription from the
    # engine's own book and open obligations, independently of the incremental arithmetic that
    # maintains the totals, so the equality is checked and not merely mirrored by the twin.
    # Like M6 and MD this needs a known book, so it cancels the open window's remainders first.
    log('== M7 the reservation accounting: nothing strands')
    known_book('M7pre')
    approve_feed('shares', 'tachyon-maker', 100_000)   # the maker sells in the M7 window
    approve_feed('cash', 'tachyon-taker', 500_000)     # the taker buys
    audM, audT = audit(MAKER), audit(TAKER)
    resM0, resT0 = residue_of(audM), residue_of(audT)
    base_m, base_t = resv(MAKER), resv(TAKER)
    log(f'  M7 baseline: maker resv={base_m} taker resv={base_t}; residue of the previous accounting maker={resM0} taker={resT0}')
    row('M7a on an emptied book the audit reconciles: no live order, no open obligation, nothing prescribed - what stands is the previous accounting\'s residue, measured here and not assumed',
        audM['liveOrders'] == 0 and audT['liveOrders'] == 0
        and audM['openObligations'] == 0 and audT['openObligations'] == 0
        and (audM['prescribedShares'], audM['prescribedCash'], audT['prescribedShares'], audT['prescribedCash']) == (0, 0, 0, 0)
        and min(resM0 + resT0) >= 0
        and base_m == twres('tachyon-maker') and base_t == twres('tachyon-taker'),
        (audM, audT))

    ASK_Q = 50
    aM, _ = submit('tachyon-maker', 'sell', 99, ASK_Q)   # a limit high above the book: it crosses nothing
    got_m = resv(MAKER)
    row('M7b an ask reserves its qty AND the one fee its escrow costs - the leg the previous accounting missed, which admitted an ask whose escrow could only be refused',
        got_m[0] == base_m[0] + ASK_Q + FEE_S and got_m == twres('tachyon-maker'),
        f'{got_m} vs baseline {base_m} + qty {ASK_Q} + fee {FEE_S}')
    r = td('call', 'matching', 'cancelOrder', f'({aM} : nat)', identity='tachyon-maker')
    if is_ok(r): TW.cancel(aM)
    after_cancel = resv(MAKER)
    row('M7c cancelling it releases the notional AND the margin: the reservation is the baseline again, to the unit (the margin used to stay for the life of the engine)',
        is_ok(r) and after_cancel == base_m and after_cancel == twres('tachyon-maker'),
        f'{after_cancel} vs baseline {base_m}')

    # one bid filled by TWO asks: at intake the bid reserves one escrow fee; the clear discovers that
    # it owes two, and each obligation carries its own. EVERY qty here must clear the MD intake floor
    # (qty > the shares fee) or the order is refused and the window is not the one these rows
    # describe - so the three ids are asserted before a single number is measured.
    A_Q, B_Q = 3 * FEE_S, 2 * FEE_S
    BID_Q = A_Q + B_Q
    s1, _ = submit('tachyon-maker', 'sell', 10, A_Q)
    s2, _ = submit('tachyon-maker', 'sell', 10, B_Q)
    bq, _ = submit('tachyon-taker', 'buy', 10, BID_Q)
    intake_t = resv(TAKER)
    row('M7d the three orders are accepted, and at intake the bid reserves its notional at its own limit plus exactly ONE escrow fee',
        None not in (s1, s2, bq)
        and intake_t[1] == base_t[1] + BID_Q * 10 + FEE_C and intake_t == twres('tachyon-taker'),
        f'ids {(s1, s2, bq)}; {intake_t} vs baseline {base_t} + {BID_Q * 10} + fee {FEE_C}')
    w7 = TW.window
    p7, killed7, sched7 = TW.clear()
    td('call', 'matching', 'clearWindow')
    ok7 = wait_clear_gone(w7, 300) and len(sched7) == 2 and obl_sum() == OSUM0 + TW.obl_text()
    after_t, after_m = resv(TAKER), resv(MAKER)
    row('M7e the window clears two fills and the bid now reserves TWO escrows - one fee per fill, the second discovered at the clear where intake had reserved one',
        ok7 and after_t[1] == base_t[1] + (A_Q * 10 + FEE_C) + (B_Q * 10 + FEE_C) and after_t[1] == intake_t[1] + FEE_C
        and after_t == twres('tachyon-taker'),
        f'{after_t} vs intake {intake_t} + one more fee {FEE_C}')
    row('M7f the cleared-but-unsettled obligations hold their escrow costs on both sides: what a cleared match owes is not free for another order to spend (this accounting\'s predecessor released it entirely at the fill)',
        after_m[0] == base_m[0] + (A_Q + FEE_S) + (B_Q + FEE_S) and after_m == twres('tachyon-maker'),
        f'{after_m} vs baseline {base_m} + ({A_Q}+{FEE_S}) + ({B_Q}+{FEE_S})')
    a7m, a7t = audit(MAKER), audit(TAKER)
    row('M7g the audit reconciles while the obligations are open: the prescription recomputed from the engine\'s own book and holds equals what it maintains, to the same residue',
        residue_of(a7m) == resM0 and residue_of(a7t) == resT0
        and a7m['openObligations'] == 2 and a7t['openObligations'] == 2
        and a7m['liveOrders'] == 0 and a7t['liveOrders'] == 0,
        (a7m, a7t))

    left7 = drain_window(w7)
    for o in TW.obls:
        if o['window'] == w7 and not o['settled']: TW.settle(o['seq'])
    end_m, end_t = resv(MAKER), resv(TAKER)
    row('M7h the drain settles both fills and every unit reserved comes back: the reservation is the baseline again on both sides, to the unit',
        not left7 and end_m == base_m and end_t == base_t
        and end_m == twres('tachyon-maker') and end_t == twres('tachyon-taker'),
        f'maker {end_m} vs {base_m}; taker {end_t} vs {base_t}')
    a8m, a8t = audit(MAKER), audit(TAKER)
    row('M7i the whole lifecycle left the residue of the previous accounting untouched - the strand is frozen at what it was, and this accounting never adds to it',
        residue_of(a8m) == resM0 and residue_of(a8t) == resT0
        and (a8m['prescribedShares'], a8m['prescribedCash'], a8t['prescribedShares'], a8t['prescribedCash']) == (0, 0, 0, 0)
        and a8m['openObligations'] == 0 and a8t['openObligations'] == 0,
        (a8m, a8t, resM0, resT0))
    bal_row('M7j balances after the M7 window exact to the twin')

    # ── L rows: the listing registry gates the gated engine's intake ─────────────────────────
    log('== L listing: the issuer gate, the funded check, the land collection')
    r = td('call', 'matching_gated', 'submitOrder', '(record { side = variant { sell }; limitPrice = 10 : nat; qty = 10 : nat; allOrNone = false })', identity='tachyon-maker')
    row('L1 the gated engine refuses an unlisted market at intake', not is_ok(r) and 'not a registered' in r, r[-200:])
    r = td('call', 'listing', 'registerIssuer', f'(principal "{MAKER}")', identity='tachyon-taker')
    row('L2a only the venue admin may authorize an issuer', not is_ok(r), r[-120:])
    r = td('call', 'listing', 'registerIssuer', f'(principal "{MAKER}")')
    ia = td('query', 'listing', 'isAuthorizedIssuer', f'(principal "{MAKER}")')
    row('L2b the admin authorizes the issuer', is_ok(r) and 'true' in ia, (r[-100:], ia[-60:]))
    r = td('call', 'listing', 'listShare', f'(principal "{SHARES_EMPTY}", principal "{CASH}")', identity='tachyon-maker')
    row('L3 a zero-supply ledger is refused as unfunded by the live cross-canister check',
        not is_ok(r) and 'not funded' in r, r[-200:])
    r = td('call', 'listing', 'listShare', f'(principal "{SHARES}", principal "{CASH}")', identity='tachyon-taker')
    row('L4 a caller that is not an authorized issuer may not list', not is_ok(r), r[-160:])
    r = td('call', 'listing', 'listShare', f'(principal "{SHARES}", principal "{CASH}")', identity='tachyon-maker')
    tr = td('query', 'listing', 'isPairTradeable', f'(principal "{SHARES}", principal "{CASH}")')
    vf = td('call', 'listing', 'verifyShareFunded', f'(principal "{SHARES}")')
    row('L5 the funded pair lists; tradeable; the live re-verification confirms the supply',
        is_ok(r) and 'true' in tr and is_ok(vf), (r[-120:], tr[-60:], vf[-100:]))
    oidB, r = submit('tachyon-maker', 'sell', 10, 20, engine='matching_gated', mirror=False)
    r2 = td('call', 'matching_gated', 'cancelOrder', f'({oidB} : nat)', identity='tachyon-maker') if oidB else ''
    row('L6 the gated engine accepts intake once the pair is listed (and the probe order cancels clean)',
        oidB is not None and is_ok(r2), (r[-160:] if isinstance(r, str) else r))
    r = td('call', 'listing', 'delistShare', f'(principal "{SHARES}")', identity='tachyon-maker')
    r2 = td('call', 'listing', 'delistShare', f'(principal "{SHARES}")')
    tr = td('query', 'listing', 'isPairTradeable', f'(principal "{SHARES}", principal "{CASH}")')
    r3 = td('call', 'matching_gated', 'submitOrder', '(record { side = variant { sell }; limitPrice = 10 : nat; qty = 10 : nat; allOrNone = false })', identity='tachyon-maker')
    row('L7 delisting is admin-only, flips the gate off, and intake refuses again',
        (not is_ok(r)) and is_ok(r2) and 'false' in tr and (not is_ok(r3)), (r[-80:], tr[-40:], r3[-120:]))
    # the bed persists: the unminted refusal is provable only while the collection is empty;
    # a later run mints the next title id and proves the funded path again.
    sup0 = nat_in(td('query', 'land', 'icrc7_total_supply')) or 0
    r = td('call', 'listing', 'listLandCollection', f'(principal "{LAND}")', identity='tachyon-maker')
    refused_unminted = (not is_ok(r)) and 'no minted titles' in r
    if sup0 > 0: log(f'  L8 note: collection already holds {sup0} title(s); the unminted refusal was proven on the fresh bed')
    mint = td('call', 'land', 'mint', f'(record {{ owner = principal "{MAKER}"; subaccount = null }}, {sup0 + 1} : nat, vec {{}})')
    r2 = td('call', 'listing', 'listLandCollection', f'(principal "{LAND}")', identity='tachyon-maker')
    lt = td('query', 'listing', 'isLandTradeable', f'(principal "{LAND}")')
    row('L8 a land collection is listable only once a title is minted, then tradeable',
        (sup0 > 0 or refused_unminted) and is_ok(mint) and is_ok(r2) and 'true' in lt, (r[-100:], mint[-100:], r2[-100:], lt[-40:]))

    # ── MF finals: nothing stranded, nothing violated, the twin to the last byte ─────────────
    log('== MF finals')
    inv = td('query', 'matching', 'invariantLog')
    invB = td('query', 'matching_gated', 'invariantLog')
    row('MF1 both engines\' invariant logs are empty (no-stranding oracle)',
        text_of(inv) in (None, '') and text_of(invB) in (None, ''), (inv[-120:], invB[-120:]))
    row('MF2 no obligation of this run is left unsettled - the voided dust fill is resolved, not stranded',
        not unsettled_in(set(range(wA, TW.window + 1))))
    row('MF3 the global obligation summary equals the twin to the last byte', obl_sum() == OSUM0 + TW.obl_text(),
        f'twin_total={TW.next_seq}')
    inv = td('query', 'core', 'invariantLog')
    row('MF4 the core\'s invariant log records no violation across the matched settlements', 'fail' not in inv.lower(), inv[-200:])

# T2 no fork: every validator reports the same state root at the same height.
log('== T2 no fork')
vals = re.findall(r'"(http://[^"]+)"', open(A.manifest).read())
roots = {}
for v in vals:
    try:
        d = json.loads(urllib.request.urlopen(v + '/api/status', timeout=10).read())
        roots.setdefault(d.get('finalized_height'), set()).add(d.get('state_root') or d.get('finalized_state_root'))
    except Exception as e: roots.setdefault('err', set()).add(str(e)[:60])
same = [h for h, s in roots.items() if h != 'err' and len(s) == 1]
row('T2 validators agree on the state root at a common height', len(same) >= 1 and 'err' not in roots, roots)
log(f'\n{passed} passed, {failed} failed')
sys.exit(0 if failed == 0 else 1)
