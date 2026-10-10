#!/usr/bin/env bash
# Executes bmx-test's evidence() in a sandbox: a wedge must save the server console and
# print its tail, and keep only the last ten copies. (ci-test.sh runs this.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fn="$(sed -n '/^evidence() {/,/^}/p' "$HERE/bmx-test")"
[ -n "$fn" ] || { echo "FAIL: no evidence() in bmx-test"; exit 1; }
eval "$fn"
CONSOLE="$T/console.log"; export BMX_EVIDENCE_DIR="$T/keep"
seq 1 100 | sed 's/^/line /' > "$CONSOLE"
err="$(evidence 2>&1)"
n=$(ls "$T/keep"/wedge-*.log | wc -l)
[ "$n" -eq 1 ] || { echo "FAIL: expected 1 saved console, got $n"; exit 1; }
cmp -s "$CONSOLE" "$T/keep"/wedge-*.log || { echo "FAIL: saved copy differs"; exit 1; }
echo "$err" | grep -q "line 100" || { echo "FAIL: tail not printed"; exit 1; }
echo "$err" | grep -q "line 40$" && { echo "FAIL: printed more than 60 lines"; exit 1; }
for i in $(seq 1 12); do touch -d "-$i min" "$T/keep/wedge-old$i.log"; done
evidence >/dev/null 2>&1
n=$(ls "$T/keep"/wedge-*.log | wc -l)
[ "$n" -eq 10 ] || { echo "FAIL: expected 10 kept, got $n"; exit 1; }
echo "ok bmx-test evidence()"
