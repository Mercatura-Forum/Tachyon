#!/usr/bin/env bash
# Runs every test/*.test.mo compiled to WASI under wasmtime. A test passes when it exits 0 and
# prints at least one "count: <what> = <n>" line with no zero count. The same runner as the kernel's.
set -u
cd "$(dirname "$0")/.."   # the exchange module
MOC="${MOC:-$HOME/.cache/mops/moc/1.4.1/moc}"
SOURCES="$(../custody/tools/packages.sh)"
OUT="${TEST_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
fail=0; total=0
for t in test/${1:-*}.test.mo; do
  name="$(basename "$t" .test.mo)"; total=$((total+1))
  echo "=== $name"
  if ! "$MOC" -wasi-system-api $SOURCES -o "$OUT/$name.wasm" "$t" 2> "$OUT/$name.compile.log"; then
    echo "COMPILE FAILED: $name"; grep -v "warning" "$OUT/$name.compile.log" | head -30; fail=$((fail+1)); continue
  fi
  if ! wasmtime "$OUT/$name.wasm" > "$OUT/$name.log" 2>&1; then
    echo "FAILED: $name"; tail -30 "$OUT/$name.log"; fail=$((fail+1)); continue
  fi
  grep -E '^(count:|FAIL|[A-Z0-9 ]+ GREEN)' "$OUT/$name.log"
  if ! grep -Eq '^count: [^=]+ = [1-9][0-9]*$' "$OUT/$name.log"; then echo "FAILED: $name printed no count line"; fail=$((fail+1)); continue; fi
  if grep -Eq '^count: [^=]+ = 0$' "$OUT/$name.log"; then echo "FAILED: $name examined zero records"; fail=$((fail+1)); continue; fi
  # a test may carry an off-chain check over its own output (a second implementation reading the dump)
  if [ -x "test/$name.verify.sh" ]; then
    if ! "test/$name.verify.sh" "$OUT/$name.log"; then echo "FAILED: $name off-chain check"; fail=$((fail+1)); continue; fi
  fi
done
echo "tests: $total, failed: $fail  (logs in $OUT)"
[ "$fail" -eq 0 ]
