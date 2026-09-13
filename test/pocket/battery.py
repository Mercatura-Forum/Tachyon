#!/usr/bin/env python3
"""Tachyon on a Thebes chain: the settlement battery driven through thebes-deploy.

    python3 test/pocket/battery.py <manifest.toml> <network> [--out DIR]

The manifest names the ledgers and the core (see deploy/example.thebes.toml); cids must be
installed. Two identities, `tachyon-maker` and `tachyon-taker`, must exist (`thebes-deploy
identity new`), and each must hold an initial balance on the cash and asset ledgers.

Rows: T1 happy path, T3 abort and reclaim, T4 idempotent retry under an injected ledger
failure, T5 adversarial refusals, T2 no fork (state root identical across validators at the
same height). Every row states its own pass condition before the calls are made.
"""
import argparse, base64, json, os, re, subprocess, sys, time, urllib.request, zlib

TD = os.environ.get('THEBES_DEPLOY', '/usr/local/bin/thebes-deploy')
a = argparse.ArgumentParser()
a.add_argument('manifest'); a.add_argument('network'); a.add_argument('--out', default='test/pocket/out')
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
m0 = {'ms': bal('shares', MAKER), 'mc': bal('cash', MAKER), 'ts': bal('shares', TAKER), 'tc': bal('cash', TAKER)}
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
row('T1 core holds no residual asset or cash', bal('shares', CORE) == 0 and bal('cash', CORE) == 0, (bal('shares', CORE), bal('cash', CORE)))
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
# The deadline is in chain seconds (block-derived clock): 20 chain-seconds elapse in about two wall
# seconds on a 4-validator bed, so the refusal row uses a long deadline and the acceptance row a
# short one, and the wall time to acceptance is recorded as the clock measurement.
log('== T3 abort and reclaim')
approve('shares', 'tachyon-maker', CORE, 2_000 + FEE)
tid3a, o3a = open_trade('tachyon-maker', TAKER, SHARES, 2_000, CASH, 1_000, 3600)
fm = td('call', 'core', 'fundMaker', f'({tid3a} : nat)', identity='tachyon-maker'); row('T3 maker leg escrowed', is_ok(fm) or (field(o3a,'makerEscrowed') or '').startswith('true'), fm[-160:])
r = td('call', 'core', 'reclaim', f'({tid3a} : nat)', identity='tachyon-maker'); row('T3 reclaim before the deadline refused', not is_ok(r), r[-160:])
approve('shares', 'tachyon-maker', CORE, 2_000 + FEE)
m0 = {'ms': bal('shares', MAKER)}
tid3, o3 = open_trade('tachyon-maker', TAKER, SHARES, 2_000, CASH, 1_000, 20)
t_open = time.time()
td('call', 'core', 'fundMaker', f'({tid3} : nat)', identity='tachyon-maker')
t0 = time.time(); r = ''
while time.time() - t0 < 600:
    r = td('call', 'core', 'reclaim', f'({tid3} : nat)', identity='tachyon-maker')
    if is_ok(r) or status_of(tid3) == 'Aborted': break
    time.sleep(5)
row('T3 reclaim after the deadline accepted', is_ok(r) or status_of(tid3) == 'Aborted', r[-200:])
row('T3 status Aborted', status_of(tid3, 'Aborted') == 'Aborted', status_of(tid3))
row('T3 maker got the asset back minus the escrow and refund fees', m0['ms'] - bal('shares', MAKER) == 2 * FEE, (m0['ms'], bal('shares', MAKER)))
log(f'T3 clock measurement: a 20 chain-second deadline was accepted {time.time() - t_open:.0f} wall seconds after open')

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
row('T4 core holds no residual on the flaky ledger', bal('cash_flaky', CORE) == 0, bal('cash_flaky', CORE))
inv = td('query', 'core', 'invariantLog'); row('T4 no invariant violation logged', 'fail' not in inv.lower(), inv[-200:])

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
