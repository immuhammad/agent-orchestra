#!/bin/bash
# .harness/check-handoff.test.sh — TDD tests for the Stop hook
# check-handoff.sh, incl. its >100-line warning.
# Run: bash .harness/check-handoff.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
HOOK="$DIR/../hooks/check-handoff.sh"

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

# issue #50: the hook now gates its nag on ORC_ROLE=orchestra -- every
# EXISTING call below tests "the nag fires when it should", which under
# the new role-gated design specifically means "as orchestra". Defaulting
# to "orchestra" here preserves every pre-existing test's behavior
# unchanged (bash default-parameter expansion, no call site below needed
# to change) while letting the new role-specific tests pass an explicit
# role (including "" for the no-ORC_ROLE-at-all/unknown case).
run_hook() {
  local role="${1-orchestra}"
  if [ -z "$role" ]; then
    ( cd "$SANDBOX" && echo '{}' | bash .harness/check-handoff.sh 2>&1 )
  else
    ( cd "$SANDBOX" && echo '{}' | ORC_ROLE="$role" bash .harness/check-handoff.sh 2>&1 )
  fi
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

echo "== orchestra-role stop without a handoff.md update: nags (exit 2) -- current behavior preserved =="
touch -d '+1 hour' "$SANDBOX/.harness/.session-start" 2>/dev/null || touch -t 203001010000 "$SANDBOX/.harness/.session-start"
OUT="$(run_hook orchestra)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "not updated this session"; then
  pass "stale handoff.md (older than marker), ORC_ROLE=orchestra, blocks with exit 2"
else
  fail "expected exit 2 + 'not updated' message, got status=$STATUS: $OUT"
fi

echo "== issue #50: builder-role stop with the SAME stale handoff.md does NOT nag -- handoff.md is Orchestra's file, Builder clobbered it 3x =="
# Same stale-vs-marker state as the orchestra case above -- the only
# variable is the role. This is the live incident: a Builder stop used to
# order a rewrite of a file it has no room-level view to write honestly.
OUT="$(run_hook builder)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "issue #50: builder-role stop with a stale handoff.md is silent -- no nag, no block"
else
  fail "CORRECTNESS REGRESSION (issue #50): builder-role stop should never nag about handoff.md (got status=$STATUS): $OUT"
fi

echo "== issue #50: unknown role (no ORC_ROLE at all -- a session started outside the room) does NOT nag =="
# Fail-direction matters: a missed nag is minor, but nagging the WRONG
# role into writing handoff.md is the clobber this issue exists to stop --
# an unrecognized/absent role must never be treated as orchestra.
OUT="$(run_hook "")"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "issue #50: no ORC_ROLE at all (session started outside the room) is silent -- treated as unknown, never nagged"
else
  fail "CORRECTNESS REGRESSION (issue #50): a session with no ORC_ROLE should never nag about handoff.md (got status=$STATUS): $OUT"
fi

echo "== issue #50: an unrecognized role string (neither orchestra nor builder) does NOT nag -- unknown, not orchestra =="
OUT="$(run_hook scribe)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "issue #50: an unrecognized ORC_ROLE value is silent -- only an EXACT 'orchestra' match nags"
else
  fail "CORRECTNESS REGRESSION (issue #50): an unrecognized role should never nag about handoff.md (got status=$STATUS): $OUT"
fi

echo "== issue #50: orchestra WITH handoff.md updated this session: still no nag (role-gating doesn't override the real up-to-date check) =="
touch "$SANDBOX/.harness/.session-start"
sleep 1
printf '# HANDOFF\n\n## Current state\nfresh again\n' > "$SANDBOX/.harness/handoff.md"
OUT="$(run_hook orchestra)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "issue #50: orchestra with a freshly-updated handoff.md still passes silently"
else
  fail "expected exit 0 and no output for orchestra with a fresh handoff.md (got status=$STATUS): $OUT"
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

echo "== issue #23: ORC_ONESHOT=1 exempts a one-shot/headless session from the handoff Stop hook =="
# A one-shot scribe's OWN .session-start marker is, by construction, always
# newer than any handoff.md written before it spawned -- the exact stale
# state the block above exists to catch for a stage-owning PANE agent. A
# one-shot session is not one (and per AGENTS.md's single-writer rule must
# NEVER write handoff.md anyway), so it must not hit this block at all.
touch -d '+1 hour' "$SANDBOX/.harness/.session-start" 2>/dev/null || touch -t 203001010000 "$SANDBOX/.harness/.session-start"
OUT="$(cd "$SANDBOX" && echo '{}' | ORC_ONESHOT=1 bash .harness/check-handoff.sh 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "ORC_ONESHOT=1 exits 0 with no output even when handoff.md is stale relative to the marker"
else
  fail "ORC_ONESHOT=1 should skip the check entirely (got status=$STATUS output: $OUT)"
fi

echo "== issue #23: without ORC_ONESHOT, the same stale state still blocks (no accidental widening) =="
OUT="$(run_hook)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "not updated this session"; then
  pass "pane-agent sessions (no ORC_ONESHOT) are still blocked by stale handoff.md"
else
  fail "expected the normal block to still apply without ORC_ONESHOT (got status=$STATUS): $OUT"
fi

echo "== SECURITY (agy's probe-3 on PR #30): the ORC_ONESHOT exemption is safe only because guard-write.sh blocks the spoof it depends on =="
# The exemption above trusts that no agent can rewrite .claude/settings.json's
# Stop hook entry to inject ORC_ONESHOT=1. That guarantee lives in
# guard-write.sh (issue #31), not in this hook -- verify it end-to-end here
# so the two files' safety claims can't drift apart silently.
GUARD_WRITE="$DIR/../lib/guard-write.sh"
SPOOF_PAYLOAD="$(jq -n --arg fp ".claude/settings.json" '{tool_input: {file_path: $fp}}')"
SPOOF_OUT="$(echo "$SPOOF_PAYLOAD" | bash "$GUARD_WRITE" 2>&1)"
SPOOF_STATUS=$?
if [ "$SPOOF_STATUS" -eq 2 ]; then
  pass "guard-write.sh blocks the exact injection vector (editing .claude/settings.json's Stop hook to add ORC_ONESHOT=1)"
else
  fail "SECURITY REGRESSION: guard-write.sh should block writes to .claude/settings.json (the ORC_ONESHOT spoof vector), got status=$SPOOF_STATUS: $SPOOF_OUT"
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
