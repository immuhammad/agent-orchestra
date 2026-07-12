#!/bin/bash
# tests/session-start.test.sh — issue #18 items 2+3: session-start.sh's
# additionalContext must wire Reviewer skills (not just Builder/Orchestra)
# and must tell every role to read decisions.log (durable context), not
# just handoff.md (ephemeral). Run: bash tests/session-start.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
HOOK="$DIR/../hooks/session-start.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# session-start.sh only touches .harness/.session-start (relative path) and
# echoes JSON -- run it from an isolated sandbox so it doesn't touch this
# checkout's real .harness/.
SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/.harness"
OUT="$(cd "$SANDBOX" && bash "$HOOK" 2>/dev/null)"

echo "== additionalContext is valid JSON =="
if echo "$OUT" | python3 -m json.tool >/dev/null 2>&1; then
  pass "output parses as JSON"
else
  fail "expected valid JSON, got: $OUT"
fi

echo "== bootup read-order names decisions.log, not just handoff.md =="
if echo "$OUT" | grep -q "decisions.log"; then
  pass "additionalContext mentions decisions.log"
else
  fail "additionalContext should tell agents to read decisions.log at bootup"
fi
if echo "$OUT" | grep -q "handoff.md"; then
  pass "additionalContext still mentions handoff.md"
else
  fail "additionalContext should still mention handoff.md"
fi

echo "== Reviewer skills are wired, not just Builder/Orchestra =="
if echo "$OUT" | grep -q "Reviewer -- code-review"; then
  pass "additionalContext names Reviewer's code-review skill"
else
  fail "additionalContext should name Reviewer's auto-use skill(s)"
fi

echo "== issue #23: ORC_ONESHOT=1 emits NO room-state additionalContext (minimal-context spawn) =="
# A scribe spawn was observed booting, reading THIS additionalContext's
# "read handoff.md" + quota-rule briefing, concluding (from a STALE
# handoff.md) that the room was quota-parked, and self-aborting instead of
# doing its dispatched task. A one-shot has no standing pane and no
# handoff.md duty (its own Stop hook already exempts it via ORC_ONESHOT,
# see check-handoff.sh) -- it should never see this pane-agent briefing.
: > "$SANDBOX/.harness/.session-start"
ONESHOT_OUT="$(cd "$SANDBOX" && ORC_ONESHOT=1 bash "$HOOK" 2>/dev/null)"
if echo "$ONESHOT_OUT" | grep -qi "HARNESS ACTIVE\|handoff.md\|decisions.log\|quota"; then
  fail "ORC_ONESHOT=1 should suppress the room-state briefing entirely, got: $ONESHOT_OUT"
else
  pass "ORC_ONESHOT=1 emits no room-state additionalContext"
fi
if echo "$ONESHOT_OUT" | python3 -m json.tool >/dev/null 2>&1; then
  pass "ORC_ONESHOT=1 output still parses as valid JSON"
else
  fail "expected valid JSON even for the minimal-context case, got: $ONESHOT_OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
