#!/bin/bash
# .harness/pre-compact-checkpoint.test.sh — TDD tests for the PreCompact
# hook (T25, issue #40). Simulates the hook payload (no real /compact
# trigger available from a non-interactive test) and asserts on the
# checkpoint block appended to an isolated handoff file.
# Run: bash .harness/pre-compact-checkpoint.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
HOOK="$DIR/../hooks/pre-compact-checkpoint.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CURRENT_BRANCH="$(git -C "$DIR/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

echo "== PreCompact hook: appends a dated checkpoint block =="
HANDOFF="$TMP/handoff.md"
echo "# HANDOFF" > "$HANDOFF"

PAYLOAD='{"session_id":"test-session-1","trigger":"manual"}'
echo "$PAYLOAD" | PRE_COMPACT_HANDOFF_FILE="$HANDOFF" bash "$HOOK"

if grep -q '^## COMPACT CHECKPOINT' "$HANDOFF"; then
  pass "checkpoint block header appended"
else
  fail "expected a '## COMPACT CHECKPOINT' block in $HANDOFF"
fi

if grep -q 'session test-session-1' "$HANDOFF"; then
  pass "session id from hook payload is recorded"
else
  fail "expected session id 'test-session-1' in checkpoint"
fi

if grep -q 'trigger: manual' "$HANDOFF"; then
  pass "trigger from hook payload is recorded"
else
  fail "expected 'trigger: manual' in checkpoint"
fi

if grep -q "Branch: $CURRENT_BRANCH" "$HANDOFF"; then
  pass "current git branch is recorded"
else
  fail "expected 'Branch: $CURRENT_BRANCH' in checkpoint"
fi

echo "== PreCompact hook: infers issue number from feature/issue-N branch name =="
HANDOFF2="$TMP/handoff2.md"
echo "# HANDOFF" > "$HANDOFF2"
PAYLOAD2='{"session_id":"test-session-2","trigger":"auto"}'
echo "$PAYLOAD2" | PRE_COMPACT_HANDOFF_FILE="$HANDOFF2" bash "$HOOK"
case "$CURRENT_BRANCH" in
  feature/issue-*)
    EXPECTED_ISSUE="${CURRENT_BRANCH#feature/issue-}"
    if grep -q "(issue #$EXPECTED_ISSUE)" "$HANDOFF2"; then
      pass "issue number inferred from branch name"
    else
      fail "expected '(issue #$EXPECTED_ISSUE)' in checkpoint"
    fi
    ;;
  *)
    echo "SKIP: current branch '$CURRENT_BRANCH' is not feature/issue-N, skipping issue-inference assertion"
    ;;
esac

echo "== PreCompact hook: missing session_id/trigger fall back to 'unknown' =="
HANDOFF3="$TMP/handoff3.md"
echo "# HANDOFF" > "$HANDOFF3"
echo '{}' | PRE_COMPACT_HANDOFF_FILE="$HANDOFF3" bash "$HOOK"
if grep -q 'session unknown, trigger: unknown' "$HANDOFF3"; then
  pass "missing session_id/trigger degrade gracefully to 'unknown'"
else
  fail "expected graceful 'unknown' fallback: $(cat "$HANDOFF3")"
fi

echo "== PreCompact hook: does not overwrite prior handoff content =="
HANDOFF4="$TMP/handoff4.md"
printf '# HANDOFF\n\n## Current state\nsome prior content\n' > "$HANDOFF4"
echo '{"session_id":"s4","trigger":"manual"}' | PRE_COMPACT_HANDOFF_FILE="$HANDOFF4" bash "$HOOK"
if grep -q 'some prior content' "$HANDOFF4" && grep -q 'COMPACT CHECKPOINT' "$HANDOFF4"; then
  pass "checkpoint is appended, prior content preserved"
else
  fail "expected both prior content and the new checkpoint to be present"
fi

echo "== T31 (issue #68 item A): a SECOND firing REPLACES the checkpoint, doesn't append another =="
HANDOFF5="$TMP/handoff5.md"
printf '# HANDOFF\n\n## Current state\nsome prior content\n' > "$HANDOFF5"
echo '{"session_id":"first","trigger":"manual"}' | PRE_COMPACT_HANDOFF_FILE="$HANDOFF5" bash "$HOOK"
echo '{"session_id":"second","trigger":"auto"}' | PRE_COMPACT_HANDOFF_FILE="$HANDOFF5" bash "$HOOK"
COUNT="$(grep -c '^## COMPACT CHECKPOINT' "$HANDOFF5")"
if [ "$COUNT" -eq 1 ]; then
  pass "exactly one COMPACT CHECKPOINT block survives after two firings"
else
  fail "expected exactly 1 COMPACT CHECKPOINT block, got $COUNT: $(cat "$HANDOFF5")"
fi
if grep -q 'session second' "$HANDOFF5" && ! grep -q 'session first' "$HANDOFF5"; then
  pass "the surviving block is the SECOND (latest) firing's content"
else
  fail "expected only the second firing's session id to remain: $(cat "$HANDOFF5")"
fi
if grep -q 'some prior content' "$HANDOFF5"; then
  pass "prior non-checkpoint content (e.g. Current state) is still preserved"
else
  fail "prior content above the checkpoint should survive a replace"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
