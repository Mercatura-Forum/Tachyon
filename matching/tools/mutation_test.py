#!/usr/bin/env python3
"""mutation_test.py: the matching battery must go red when a rule it exists for is removed.

For every entry of matching/tools/mutations.json (one textual edit, its exact old and new text) this tool copies the
committed tree to a scratch directory (custody/tools/committed_tree.sh), applies the edit, runs
matching/test/run_tests_matching.mo in the interpreter and requires a non-zero exit. The unmutated tree runs first
and must be green, so a red result is the mutant's. An edit whose old text is absent or not unique, or a mutant that
does not compile, is CONTROL BROKEN, a hard failure.

    python3 matching/tools/mutation_test.py [--only X01,...] [--json out.json]

Attribution: Thebes Core Team.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
TEST = 'matching/test/run_tests_matching.mo'


def run(cmd, cwd, timeout=1800):
    try:
        p = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return -1, 'TIMEOUT'
    return p.returncode, p.stdout + p.stderr


def battery(tree, moc):
    srcs = subprocess.check_output('mops sources', cwd=ROOT, shell=True, text=True).split()
    pk = ' '.join(x if not x.startswith('.mops/') else os.path.join(ROOT, x) for x in srcs)
    rc, out = run(f'{moc} -r {pk} {TEST}', tree)
    if 'type error' in out or 'syntax error' in out or 'import error' in out:
        return None, out
    return rc, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mutations', default=os.path.join(ROOT, 'matching', 'tools', 'mutations.json'))
    ap.add_argument('--only')
    ap.add_argument('--json')
    ap.add_argument('--moc', default='moc')
    a = ap.parse_args()
    muts = json.load(open(a.mutations))
    only = set(a.only.split(',')) if a.only else None
    sel = [m for m in muts if not only or m['id'] in only]
    if not sel:
        print('MISS: no mutation selected'); return 2
    work = tempfile.mkdtemp(prefix='matching-mutants-')
    base = os.path.join(work, 'base')
    subprocess.check_call([os.path.join(ROOT, 'custody', 'tools', 'committed_tree.sh'), base])
    t0 = time.time(); rc, out = battery(base, a.moc)
    print(f'baseline: {"GREEN" if rc == 0 else "RED"} ({int(time.time() - t0)}s)')
    if rc != 0:
        print(out[-1500:]); return 1
    rows = []
    for m in sel:
        tree = os.path.join(work, m['id']); shutil.copytree(base, tree, symlinks=True)
        path = os.path.join(tree, m['file']); src = open(path).read()
        if src.count(m['old']) != 1:
            print(f"{m['id']}: CONTROL BROKEN (old text occurs {src.count(m['old'])} times)"); rows.append({'id': m['id'], 'refused': False, 'broken': True}); continue
        open(path, 'w').write(src.replace(m['old'], m['new']))
        t0 = time.time(); rc, out = battery(tree, a.moc)
        if rc is None:
            print(f"{m['id']}: CONTROL BROKEN (the mutant does not compile)"); rows.append({'id': m['id'], 'refused': False, 'broken': True}); continue
        fails = [l for l in out.splitlines() if 'FAIL' in l][:2]
        print(f"{m['id']}: {'RED' if rc != 0 else 'GREEN UNDER MUTATION'} ({int(time.time() - t0)}s) {m['mutant']} | {' / '.join(x.strip()[:90] for x in fails)}")
        rows.append({'id': m['id'], 'refused': rc != 0, 'broken': False})
    refused = sum(r['refused'] for r in rows)
    summary = {'mutations': len(rows), 'refused': refused, 'rows': rows}
    print(json.dumps({k: v for k, v in summary.items() if k != 'rows'}))
    if a.json: json.dump(summary, open(a.json, 'w'), indent=1)
    return 0 if refused == len(rows) and rows else 1


if __name__ == '__main__':
    sys.exit(main())
