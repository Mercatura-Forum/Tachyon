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
resumes and completes it with no battery drive, the chunk count equals the twin's arithmetic;
settleMatched settles exactly one obligation per call and the Timer it arms after its await never
fires on this bed (a recorded defect - the pre-await-armed chunk-resume Timer fires every run),
so the window drains by one call per obligation; M4 time priority at one price (the oldest resting
order fills first, the newest gets nothing) and an all-or-none order that cannot fully fill killed
before any mutation with its reservation released; M5 adversarial refusals (non-owner cancel,
closed-window cancel, an order beyond the caller's allowance, unknown seq, zero deadline) and the
relayer rotation (the unbound engine refused by the core, the re-bound engine re-drives the same
obligation to settled); MD the dust fill pinned exactly as it behaves today (a fill at or below
the asset ledger's fee is refused by the core before any trade exists, funds safe, and it
head-blocks settleMatched's Timer chain - the recorded liveness defect); L1-L8 the listing gate
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
        def __init__(self):
            self.orders = {}; self.window = 0; self.next_id = 1; self.next_seq = 0
            self.obls = []; self.res_shares = {}; self.res_cash = {}; self.delta = {}
        def _sub(self, m, k, d):
            cur = m.get(k, 0); m[k] = 0 if d >= cur else cur - d   # subN clamps at zero
        def _add(self, m, k, d): m[k] = m.get(k, 0) + d
        def submit(self, oid, owner, side, price, qty, aon):
            self.orders[oid] = {'id': oid, 'owner': owner, 'side': side, 'price': price, 'qty': qty,
                                'rem': qty, 'window': self.window, 'aon': aon, 'status': 'O'}
            if side == 's': self._add(self.res_shares, owner, qty)                      # an ask reserves qty
            else: self._add(self.res_cash, owner, price * qty + FEE_C)                  # a bid reserves limit*qty + one fee
            self.next_id = oid + 1
        def release(self, o):
            if o['side'] == 's': self._sub(self.res_shares, o['owner'], o['rem'])
            else: self._sub(self.res_cash, o['owner'], o['price'] * o['rem'])           # the fee margin stays (Matching.mo behaviour)
        def cancel(self, oid):
            o = self.orders[oid]; self.release(o); o['status'] = 'C'; o['rem'] = 0
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
                    self._sub(self.res_cash, b['owner'], b['price'] * f['qty'])         # released at the bid's LIMIT price
                    self._sub(self.res_shares, s['owner'], f['qty'])
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

    # ── M0 wiring: drain the bed, seed the twin, bind the relayer ─────────────────────────────
    log('== M0 wiring: engines, listing, the relayer gate')
    cfgout = td('query', 'matching', 'config')
    row('M0a the engine\'s config names the core and the ledgers as the manifest maps them',
        all(p.split('-')[0] in cfgout for p in (CORE, SHARES, CASH)) and (field(cfgout, 'maxFillsPerChunk') or '').startswith('2'), cfgout[-300:])

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
    # settle each stale obligation directly by seq (settleMatched would head-block on a dust
    # obligation - see the MD rows); a seq the core permanently refuses is logged and left.
    stale = [int(x.replace('_', '')) for x in re.findall(r'\b(?:seq|' + SKEY + r') = ([0-9_]+)', td('query', 'matching', 'unsettledObligations'))]
    for q in stale:
        out = td('call', 'matching', 'settleObligation', f'({q} : nat, 600 : nat)')
        if not is_ok(out): log(f'  drain: stale obligation {q} refused ({err_text(out)[:80]}) - left unsettled')

    TW.next_id = (nat_in(td('query', 'matching', 'orderCount')) or 0) + 1
    TW.next_seq = obl_sum().count(';')
    TW.window = nat_in(td('query', 'matching', 'getCurrentWindow')) or 0
    ms0, mc0 = resv(MAKER); ts0, tc0 = resv(TAKER)
    TW.res_shares['tachyon-maker'] = ms0; TW.res_cash['tachyon-maker'] = mc0
    TW.res_shares['tachyon-taker'] = ts0; TW.res_cash['tachyon-taker'] = tc0
    log(f'  seed: next_id={TW.next_id} next_seq={TW.next_seq} window={TW.window} resv maker={ms0}/{mc0} taker={ts0}/{tc0}')

    approve('shares', 'tachyon-maker', CORE, 100_000)
    approve('cash', 'tachyon-taker', CORE, 500_000)
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

    def resv_row(name):
        mm = resv(MAKER); tt = resv(TAKER)
        want_m = (TW.res_shares.get('tachyon-maker', 0), TW.res_cash.get('tachyon-maker', 0))
        want_t = (TW.res_shares.get('tachyon-taker', 0), TW.res_cash.get('tachyon-taker', 0))
        return row(name, mm == want_m and tt == want_t, f'maker {mm} vs {want_m}; taker {tt} vs {want_t}')

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
    resv_row('M1f reservations equal the twin (fills released at the limit price, fee margins kept)')
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
    # settleMatched settles at most ONE obligation per call on this bed: the Timer it arms
    # AFTER its cross-canister await is registered (the node's timer index grows) but never
    # fires, while driveChunk's Timer, armed in an await-free message, fires every run - the
    # asymmetry is a recorded defect; an engine or substrate fix flips M3f, which must then
    # claim the autonomous drain. Pass conditions read the chain by query (nonce dedup can
    # answer a repeated same-identity update with the earlier call's result).
    seqsB = [o['seq'] for o in TW.obls if o['window'] == wB and not o['settled']]
    n0 = len(unsettled_in({wB}))
    td('call', 'matching', 'settleMatched', f'({wB} : nat, 600 : nat)')
    time.sleep(3)
    n1 = len(unsettled_in({wB}))
    row('M3e settleMatched settles exactly one obligation per call, verified by query', n0 - n1 == 1, (n0, n1))
    t0 = time.time()
    while time.time() - t0 < 240 and len(unsettled_in({wB})) == n1: time.sleep(10)
    n2 = len(unsettled_in({wB}))
    row('M3f the Timer settleMatched arms after its await never fires on this bed (the recorded defect)',
        n2 == n1, (n1, n2))
    guard = 0
    while unsettled_in({wB}) and guard < 12:
        td('call', 'matching', 'settleMatched', f'({wB} : nat, 600 : nat)')
        guard += 1
        time.sleep(3)
    for q in seqsB: TW.settle(q)
    row('M3g one settleMatched call per obligation drains the window, nothing left unsettled',
        not unsettled_in({wB}), f'calls={guard + 1}')
    bal_row('M3h balances after the drained window exact to the twin')
    row('M3i the core still holds no residual', bal('shares', CORE) == kM['s'] and bal('cash', CORE) == kM['c'],
        (kM, bal('shares', CORE), bal('cash', CORE)))

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
    resv_row('M4f reservations after the kill equal the twin')

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
    r = td('call', 'matching', 'submitOrder', '(record { side = variant { buy }; limitPrice = 10 : nat; qty = 10 : nat; allOrNone = false })', identity='tachyon-maker')
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

    # ── MD the dust fill: a recorded defect, asserted exactly as it behaves today ────────────
    # The engine's intake accepts any qty >= 1 and the planner emits boundary fills of any
    # size, but the core refuses assetAmount <= the asset ledger's fee
    # (DvpCore.mo settleMatchFor validation), so a fill whose qty is at or below the shares
    # fee is PERMANENTLY unsettleable: every attempt is refused before a trade is created
    # (nothing escrows - funds are safe), and settleMatched's Timer chain retries the window's
    # first unsettled obligation forever, so one dust fill head-blocks the window's autonomous
    # settlement. These rows pin the behaviour; the engine-side fix (an intake floor tied to
    # the ledger fees, or settleMatched skipping a permanently refused head) flips MD2/MD3 and
    # must update them.
    log('== MD dust: a fill at the ledger fee is unsettleable and head-blocks settleMatched')
    dq = FEE_S // 2 if FEE_S > 1 else 1
    da, _ = submit('tachyon-maker', 'sell', 10, dq)
    db, _ = submit('tachyon-taker', 'buy', 10, dq)
    wF = TW.window
    pF, killedF, schedF = TW.clear()
    td('call', 'matching', 'clearWindow')
    row('MD1 the dust window clears one fill at or below the shares fee, schedule equal to the twin',
        wait_clear_gone(wF, 300) and len(schedF) == 1 and schedF[0]['qty'] == dq and obl_sum() == OSUM0 + TW.obl_text(),
        TW.obl_text(schedF))
    qF = [o['seq'] for o in TW.obls if o['window'] == wF][0]
    r = td('call', 'matching', 'settleObligation', f'({qF} : nat, 600 : nat)')
    tm = td('query', 'core', 'tradeIdForMatch', f'(principal "{ENGINE}", {qF} : nat)')
    row('MD2 the core refuses the dust obligation before any trade exists: no escrow, no trade id',
        (not is_ok(r)) and 'must exceed the asset ledger fee' in r and 'null' in tm, (r[-160:], tm[-60:]))
    bal_row('MD2b no balance moved for the dust fill (funds safe)')
    # pass conditions read the chain by query, never a call's printed result: two same-identity
    # updates back to back can be deduplicated by the ingress nonce window, the second answered
    # with the first's result.
    r = td('call', 'matching', 'settleMatched', f'({wF} : nat, 600 : nat)')
    row('MD3 settleMatched cannot pass the permanently refused head (the recorded liveness gap)',
        unsettled_in({wF}) == [wF], r[-200:])

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
    oidB, r = submit('tachyon-maker', 'sell', 10, 10, engine='matching_gated', mirror=False)
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
    row('MF2 no obligation of this run is left unsettled (the dust window excepted by design)',
        not unsettled_in(set(range(wA, TW.window + 1)) - {wF}))
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
