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

echo "== issue #6: no ORC_ROLE/ORC_SESSION_CLASS at all -> no lifecycle sentence (session started outside orc up) =="
NOENV_OUT="$(cd "$SANDBOX" && env -u ORC_ROLE -u ORC_SESSION_CLASS bash "$HOOK" <<< '{"source":"startup","session_id":"sid-noenv"}' 2>/dev/null)"
if echo "$NOENV_OUT" | grep -q "SESSION LIFECYCLE"; then
  fail "expected no SESSION LIFECYCLE sentence with no ORC_ROLE/ORC_SESSION_CLASS set, got: $NOENV_OUT"
else
  pass "no ORC_ROLE/ORC_SESSION_CLASS -> no lifecycle sentence (untracked, same precedent as ORC_ROLE elsewhere)"
fi

# The remaining lifecycle cases need a real .harness (orchestrator.yaml +
# inbox/orchestra) so harness_canonical_dir resolves and the FLAG dispatch
# has somewhere to land -- a fresh sandbox per case, isolated from the
# bare-JSON sandbox above.
LC_SANDBOX="$TMP/lc-sandbox"
mkdir -p "$LC_SANDBOX/.harness/inbox/orchestra"
echo "project: lifecycle-test" > "$LC_SANDBOX/orchestrator.yaml"

echo "== issue #6: ORC_SESSION_CLASS=fresh, source=startup -> FRESH sentence + role-session recorded =="
FRESH_OUT="$(cd "$LC_SANDBOX" && ORC_ROLE=builder ORC_SESSION_CLASS=fresh TMUX_PANE="%201" bash "$HOOK" <<< '{"source":"startup","session_id":"sid-fresh-1"}' 2>/dev/null)"
if echo "$FRESH_OUT" | grep -q "SESSION LIFECYCLE: FRESH"; then
  pass "fresh class -> FRESH sentence in additionalContext"
else
  fail "expected a FRESH lifecycle sentence, got: $FRESH_OUT"
fi
if [ "$(cat "$LC_SANDBOX/.harness/state/role-session/builder" 2>/dev/null)" = "sid-fresh-1" ]; then
  pass "fresh session_id recorded to the role-session registry for next time"
else
  fail "expected role-session/builder to contain sid-fresh-1"
fi
if grep -q '^idle .* sid-fresh-1 fresh$' "$LC_SANDBOX/.harness/state/pane-state/201" 2>/dev/null; then
  pass "classification recorded into the pane-state file (issue #6 point 4: watch can render it)"
else
  fail "expected pane-state/201 to end with 'sid-fresh-1 fresh', got: $(cat "$LC_SANDBOX/.harness/state/pane-state/201" 2>/dev/null)"
fi
if [ -z "$(ls -A "$LC_SANDBOX/.harness/inbox/orchestra" 2>/dev/null)" ]; then
  pass "fresh class never flags Orchestra"
else
  fail "fresh class should not write anything to orchestra's inbox"
fi

echo "== issue #6: ORC_SESSION_CLASS=resumed, source=resume -> RESUMED sentence, no FLAG =="
RESUMED_OUT="$(cd "$LC_SANDBOX" && ORC_ROLE=orchestra ORC_SESSION_CLASS=resumed TMUX_PANE="%202" bash "$HOOK" <<< '{"source":"resume","session_id":"sid-resumed-1"}' 2>/dev/null)"
if echo "$RESUMED_OUT" | grep -q "SESSION LIFECYCLE: RESUMED"; then
  pass "resumed class -> RESUMED sentence in additionalContext"
else
  fail "expected a RESUMED lifecycle sentence, got: $RESUMED_OUT"
fi
if [ -z "$(ls -A "$LC_SANDBOX/.harness/inbox/orchestra" 2>/dev/null)" ]; then
  pass "resumed class never flags Orchestra"
else
  fail "resumed class should not write anything to orchestra's inbox"
fi

echo "== issue #6: ORC_SESSION_CLASS=rebuilt, source=startup -> REBUILT sentence + durable FLAG to orchestra's inbox =="
REBUILT_OUT="$(cd "$LC_SANDBOX" && ORC_ROLE=builder ORC_SESSION_CLASS=rebuilt TMUX_PANE="%203" bash "$HOOK" <<< '{"source":"startup","session_id":"sid-rebuilt-1"}' 2>/dev/null)"
if echo "$REBUILT_OUT" | grep -q "SESSION LIFECYCLE: REBUILT"; then
  pass "rebuilt class -> REBUILT sentence in additionalContext"
else
  fail "expected a REBUILT lifecycle sentence, got: $REBUILT_OUT"
fi
if echo "$REBUILT_OUT" | grep -qi "do not assume continuity"; then
  pass "rebuilt sentence tells the agent not to trust its own memory"
else
  fail "expected explicit 'do not assume continuity' guidance in: $REBUILT_OUT"
fi
FLAG_FILES=("$LC_SANDBOX"/.harness/inbox/orchestra/*.msg)
if [ -f "${FLAG_FILES[0]}" ] && grep -q "REBUILT" "${FLAG_FILES[0]}"; then
  pass "rebuilt class writes a durable FLAG .msg to orchestra's inbox"
else
  fail "expected a FLAG .msg in orchestra's inbox mentioning REBUILT, found: ${FLAG_FILES[*]}"
fi

echo "== issue #6: dedup -- source=clear on an already-rebuilt process does NOT re-flag or re-write state =="
rm -f "$LC_SANDBOX"/.harness/inbox/orchestra/*.msg
BEFORE_STATE="$(cat "$LC_SANDBOX/.harness/state/pane-state/203" 2>/dev/null)"
CLEAR_OUT="$(cd "$LC_SANDBOX" && ORC_ROLE=builder ORC_SESSION_CLASS=rebuilt TMUX_PANE="%203" bash "$HOOK" <<< '{"source":"clear","session_id":"sid-rebuilt-1"}' 2>/dev/null)"
if echo "$CLEAR_OUT" | grep -q "SESSION LIFECYCLE"; then
  fail "a /clear re-fire (source=clear) should not re-emit a lifecycle sentence, got: $CLEAR_OUT"
else
  pass "source=clear does not re-emit a lifecycle sentence (not a real pane rebuild)"
fi
AFTER_STATE="$(cat "$LC_SANDBOX/.harness/state/pane-state/203" 2>/dev/null)"
if [ "$BEFORE_STATE" = "$AFTER_STATE" ]; then
  pass "source=clear does not touch the pane-state file"
else
  fail "pane-state/203 changed on a clear re-fire: '$BEFORE_STATE' -> '$AFTER_STATE'"
fi
MSG_COUNT_AFTER_CLEAR=$(ls "$LC_SANDBOX"/.harness/inbox/orchestra/*.msg 2>/dev/null | wc -l | tr -d ' ')
if [ "$MSG_COUNT_AFTER_CLEAR" -eq 0 ]; then
  pass "source=clear does not write a duplicate FLAG (dedup per real occurrence, not per hook fire)"
else
  fail "expected no new FLAG .msg on a clear re-fire, found $MSG_COUNT_AFTER_CLEAR"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
