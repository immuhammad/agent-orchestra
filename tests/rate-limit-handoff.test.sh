#!/bin/bash
# .harness/rate-limit-handoff.test.sh — TDD tests for the StopFailure
# rate_limit hook, incl. its replace-not-append
# behavior. Run: bash .harness/rate-limit-handoff.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
HOOK="$(cd "$DIR/../hooks" && pwd)/rate-limit-handoff.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# issue #116: the hook now sources ../lib/handoff-lib.sh relative to its
# OWN (fixed) location in this repo's hooks/, and its handoff.md target is
# cwd-relative (.harness/handoff.md), not hook-dir-relative -- matching how
# Claude Code actually invokes it (cwd = the consumer project). So this
# just needs a scratch project dir to run the real hook FROM, not a copy
# of the hook itself.
SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/.harness"
SANDBOX_HANDOFF="$SANDBOX/.harness/handoff.md"

echo "== rate_limit hook: appends a dated section to a fresh handoff.md =="
printf '# HANDOFF\n\n## Current state\nsome prior content\n' > "$SANDBOX_HANDOFF"
echo '{"session_id":"s1"}' | (cd "$SANDBOX" && bash "$HOOK")
if grep -q '^## RATE-LIMITED' "$SANDBOX_HANDOFF"; then
  pass "RATE-LIMITED section appended"
else
  fail "expected a '## RATE-LIMITED' section"
fi
if grep -q 'session s1' "$SANDBOX_HANDOFF"; then
  pass "session id from hook payload recorded"
else
  fail "expected session id 's1' recorded"
fi
if grep -q 'some prior content' "$SANDBOX_HANDOFF"; then
  pass "prior content preserved"
else
  fail "prior content should survive"
fi

echo "== T31 (issue #68 item A): a SECOND firing REPLACES the section, doesn't append another =="
echo '{"session_id":"s2"}' | (cd "$SANDBOX" && bash "$HOOK")
COUNT="$(grep -c '^## RATE-LIMITED' "$SANDBOX_HANDOFF")"
if [ "$COUNT" -eq 1 ]; then
  pass "exactly one RATE-LIMITED section survives after two firings"
else
  fail "expected exactly 1 RATE-LIMITED section, got $COUNT: $(cat "$SANDBOX_HANDOFF")"
fi
if grep -q 'session s2' "$SANDBOX_HANDOFF" && ! grep -q 'session s1' "$SANDBOX_HANDOFF"; then
  pass "the surviving section is the SECOND (latest) firing's content"
else
  fail "expected only the second firing's session id to remain: $(cat "$SANDBOX_HANDOFF")"
fi
if grep -q 'some prior content' "$SANDBOX_HANDOFF"; then
  pass "prior non-section content is still preserved after replace"
else
  fail "prior content should survive a replace"
fi

echo "== missing session_id degrades gracefully to 'unknown' =="
printf '# HANDOFF\n' > "$SANDBOX_HANDOFF"
echo '{}' | (cd "$SANDBOX" && bash "$HOOK")
if grep -q 'session unknown' "$SANDBOX_HANDOFF"; then
  pass "missing session_id falls back to 'unknown'"
else
  fail "expected 'session unknown' fallback: $(cat "$SANDBOX_HANDOFF")"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
