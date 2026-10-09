#!/usr/bin/env python3
"""mutation_test.py: mutation testing of the batteries. A battery that stays green when the rule it exists for is
removed is not a battery. For every entry of tools/mutations.json this tool applies one textual edit (listed by its
exact old and new text so the diff is the record) to a scratch copy of the committed tree, builds the named test
against the mutated tree and requires it to go RED (its off-chain check included). It first runs every named test on
the unmutated tree and requires it GREEN, so a red result is the mutant's and not the tree's. An entry whose old text
is absent or not unique is CONTROL BROKEN, a hard failure.

Usage: mutation_test.py [--mutations tools/mutations.json] [--only id,...] [--json out.json]

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))   # the Tachyon tree; the book module is ROOT/book


def run(cmd, cwd, timeout=1800):
    try:
        p = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return -1, 'TIMEOUT after %ds' % timeout
    return p.returncode, p.stdout + p.stderr


def build_and_run(tree, test, moc, out_dir, tag):
    pkgs = ' '.join(subprocess.check_output(['./custody/tools/packages.sh'], cwd=tree, text=True).split())
    # a battery named alone is the book's (book/test/<name>); one named with its module is that module's (<module>/<name>)
    module, name = (test.split('/', 1) if '/' in test else ('book', test))
    wasm = os.path.join(out_dir, f'{module}-{name}-{tag}.wasm')
    log = os.path.join(out_dir, f'{module}-{name}-{tag}.log')
    rc, out = run(f'{moc} -wasi-system-api {pkgs} -o {wasm} {module}/test/{name}.test.mo', tree)
    if rc != 0:
        return rc, 'COMPILE FAILED\n' + out
    # each linear memory capped, as test/run.sh caps it: a mutant that runs away traps instead of taking the box
    rc, out = run(['wasmtime', '-W', 'max-memory-size=8589934592', '-W', 'trap-on-grow-failure=y', wasm], tree)
    open(log, 'w').write(out)
    if rc != 0:
        return rc, out
    verify = os.path.join(tree, module, 'test', f'{name}.verify.sh')
    if os.path.exists(verify):
        rc2, out2 = run([verify, log], tree)
        return rc2, out + out2
    return rc, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mutations', default=os.path.join(ROOT, 'book', 'tools', 'mutations.json'))
    ap.add_argument('--only')
    ap.add_argument('--json')
    ap.add_argument('--moc', default=os.path.expanduser('~/.cache/mops/moc/1.4.1/moc'))
    ap.add_argument('--work')
    a = ap.parse_args()
    mutations = json.load(open(a.mutations))
    only = set(a.only.split(',')) if a.only else None
    work = a.work or tempfile.mkdtemp(prefix='mutation-test-')
    os.makedirs(work, exist_ok=True)
    base = os.path.join(work, 'base')
    subprocess.check_call([os.path.join(ROOT, 'custody', 'tools', 'committed_tree.sh'), base])
    out_dir = os.path.join(work, 'out'); os.makedirs(out_dir, exist_ok=True)
    tests = sorted({m['test'] for m in mutations if not only or m['id'] in only})
    if not tests:
        print('MISS: no mutation selected'); return 2
    for t in tests:
        t0 = time.time(); rc, out = build_and_run(base, t, a.moc, out_dir, 'baseline')
        print(f'baseline {t}: {"GREEN" if rc == 0 else "RED"} ({int(time.time() - t0)}s)')
        if rc != 0:
            print(out[-2000:]); print('STOP: the baseline is red'); return 1
    rows = []
    for m in mutations:
        if only and m['id'] not in only: continue
        tree = os.path.join(work, m['id']); shutil.rmtree(tree, ignore_errors=True); shutil.copytree(base, tree, symlinks=True)
        path = os.path.join(tree, m['file']); src = open(path).read()
        if src.count(m['old']) != 1:
            print(f"{m['id']}: CONTROL BROKEN (old text occurs {src.count(m['old'])} times in {m['file']})"); rows.append({'id': m['id'], 'refused': False, 'broken': True}); continue
        open(path, 'w').write(src.replace(m['old'], m['new']))
        t0 = time.time(); rc, out = build_and_run(tree, m['test'], a.moc, out_dir, m['id'])
        if 'COMPILE FAILED' in out:
            print(f"{m['id']}: CONTROL BROKEN (the mutant does not compile)"); rows.append({'id': m['id'], 'refused': False, 'broken': True}); continue
        refused = rc != 0
        # the reason: the battery's first failed check, or the reference's first disagreement, or the trap
        why = next((l for l in out.splitlines() if l.startswith('FAIL:') or 'DISAGREES' in l), None) or next((l for l in out.splitlines() if 'trap' in l), '')
        print(f"{m['id']}: {'RED' if refused else 'GREEN UNDER MUTATION'} ({int(time.time() - t0)}s) {why.strip()[:200]}")
        rows.append({'id': m['id'], 'refused': refused, 'broken': False, 'reason': why.strip()[:400], 'mutant': m['mutant']})
    refused = sum(1 for r in rows if r['refused']); total = len(rows)
    summary = {'mutations': total, 'refused': refused, 'refused_percent': 100.0 * refused / total if total else 0.0, 'rows': rows}
    print(json.dumps({k: v for k, v in summary.items() if k != 'rows'}))
    if a.json: json.dump(summary, open(a.json, 'w'), indent=1)
    return 0 if refused == total and total > 0 else 1


if __name__ == '__main__':
    sys.exit(main())
