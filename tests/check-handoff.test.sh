#!/bin/bash
# .harness/check-handoff.test.sh — TDD tests for the Stop hook
# check-handoff.sh, incl. T31 (issue #68 item A)'s >100-line warning.
# Run: bash .harness/check-handoff.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
HOOK="$DIR/check-handoff.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# check-handoff.sh hardcodes relative paths ".harness/handoff.md" and
# ".harness/.session-start", so run it with cwd inside an isolated
# sandbox repo shape rather than touching the live handoff.md/.session-start.
SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/.harness"
cp "$HOOK" "$SANDBOX/.harness/check-handoff.sh"

run_hook() {
  ( cd "$SANDBOX" && echo '{}' | bash .harness/check-handoff.sh 2>&1 )
}

echo "== no session marker: never blocks =="
rm -f "$SANDBOX/.harness/.session-start" "$SANDBOX/.harness/handoff.md"
OUT="$(run_hook)"
STATUS=$?
[ "$STATUS" -eq 0 ] && pass "no marker -> exit 0" || fail "no marker should exit 0 (got $STATUS)"

echo "== handoff.md updated after marker: passes silently =="
touch "$SANDBOX/.harness/.session-start"
sleep 1
printf '# HANDOFF\n\n## Current state\nsmall\n' > "$SANDBOX/.harness/handoff.md"
OUT="$(run_hook)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "small, fresh handoff.md passes with no warning"
else
  fail "expected exit 0 and no output, got status=$STATUS output: $OUT"
fi

echo "== handoff.md NOT updated since marker: blocks (exit 2) =="
touch -d '+1 hour' "$SANDBOX/.harness/.session-start" 2>/dev/null || touch -t 203001010000 "$SANDBOX/.harness/.session-start"
OUT="$(run_hook)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "not updated this session"; then
  pass "stale handoff.md (older than marker) blocks with exit 2"
else
  fail "expected exit 2 + 'not updated' message, got status=$STATUS: $OUT"
fi

echo "== T31 (issue #68 item A): handoff.md over 100 lines WARNS but does not block =="
touch "$SANDBOX/.harness/.session-start"
sleep 1
{ echo "# HANDOFF"; for i in $(seq 1 110); do echo "line $i"; done; } > "$SANDBOX/.harness/handoff.md"
OUT="$(run_hook)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -qi "WARNING.*handoff.md is 111 lines"; then
  pass "111-line handoff.md warns but still exits 0"
else
  fail "expected exit 0 + a >100-line WARNING, got status=$STATUS: $OUT"
fi

echo "== handoff.md at/under 100 lines: no warning =="
touch "$SANDBOX/.harness/.session-start"
sleep 1
{ echo "# HANDOFF"; for i in $(seq 1 79); do echo "line $i"; done; } > "$SANDBOX/.harness/handoff.md"
OUT="$(run_hook)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "80-line handoff.md (under the cap) has no warning"
else
  fail "expected exit 0 and no output, got status=$STATUS output: $OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
