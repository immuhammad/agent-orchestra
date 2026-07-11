#!/bin/bash
# .harness/send-lib.test.sh — tests for send-lib.sh's shared send_submit
# helper (issue #86 Tasks 1+2). Run: bash .harness/send-lib.test.sh
#
# Static checks pin down the FIX SHAPE (text/Enter as separate events,
# literal -l --, wrap-flattened confirm, clear-and-retype on a stuck
# input) directly against the function body, since faithfully simulating a
# TUI that drops an Enter or hard-wraps text isn't practical in a plain
# tmux test pane. The live section at the bottom exercises the
# non-stuck-input happy path end-to-end against a real pane.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
TEST_SESSION="harness-send-lib-test"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

source "$LIB/send-lib.sh"

SUBMIT_BODY="$(awk '/^send_submit\(\)/{f=1} f{print} f&&/^}/{exit}' "$LIB/send-lib.sh")"

echo "== send_submit: text and Enter are separate key events, sent literally (finding 4) =="
if printf '%s\n' "$SUBMIT_BODY" | grep -qF 'send-keys -t "$target" -l -- "$text"' \
  && printf '%s\n' "$SUBMIT_BODY" | grep -qF 'send-keys -t "$target" Enter'; then
  pass "send_submit sends the text via -l -- (no Enter in the same call) and a separate Enter"
else
  fail "send_submit should send text (-l --, literal) and Enter as separate send-keys calls"
fi

echo "== send_submit: T2 (#86) confirm flattens the captured tail before matching (wrap-safe) =="
TR_PATTERN="tr -d "
TR_PATTERN+="'"
TR_PATTERN+='\n'
TR_PATTERN+="'"
if printf '%s\n' "$SUBMIT_BODY" | grep -F -q "$TR_PATTERN"; then
  pass "confirm check flattens newlines before grep -- a hard-wrapped message can still match"
else
  fail "confirm check should flatten the tail with tr -d '\\n' before grep (same fix as ar_poll_pane)"
fi

echo "== send_submit: a still-stuck input is cleared and retyped, NOT re-Entered (live-proven 2026-07-10) =="
# Extract just the retry branch (inside the "if ... grep -qF" block) so this
# doesn't accidentally match the FIRST (always-sent) Enter above it.
RETRY_BODY="$(printf '%s\n' "$SUBMIT_BODY" | awk '/grep -qF "\$text"/{f=1} f{print}')"
if printf '%s\n' "$RETRY_BODY" | grep -qF 'C-u'; then
  pass "retry clears the input line with C-u"
else
  fail "retry should clear the stuck input with C-u before retyping"
fi
if printf '%s\n' "$RETRY_BODY" | grep -qF -- '-l -- "$text"'; then
  pass "retry retypes the text literally (not just re-sending Enter)"
else
  fail "retry should retype the text via -l -- after clearing"
fi
RETRY_ENTER_COUNT="$(printf '%s\n' "$RETRY_BODY" | grep -cF 'send-keys -t "$target" Enter')"
if [ "$RETRY_ENTER_COUNT" -eq 1 ]; then
  pass "retry sends exactly ONE fresh Enter after the clear-and-retype (not a second bare Enter burst)"
else
  fail "expected exactly 1 Enter in the retry branch, got $RETRY_ENTER_COUNT"
fi

echo "== send_meaningful_tail: filters blank padding before a caller's tail -N (issue #86 dogfood) =="
tmux new-session -d -s "$TEST_SESSION" -n pad -x 200 -y 50 >/dev/null 2>&1
tmux send-keys -t "$TEST_SESSION:0.0" "printf 'REALCONTENT\\n'; sleep 30" Enter >/dev/null 2>&1
sleep 1
PADDED_LEN="$(tmux capture-pane -p -t "$TEST_SESSION:0.0" | tail -10 | tr -d '[:space:]' | wc -c)"
FILTERED="$(send_meaningful_tail "$TEST_SESSION:0.0" 10)"
if [ "$PADDED_LEN" -eq 0 ] && echo "$FILTERED" | grep -q "REALCONTENT"; then
  pass "a raw tail -10 on a tall (50-row) pane holds only blank padding, but send_meaningful_tail still finds the real content"
else
  fail "expected a raw tail -10 to be blank-padding-only (got len=$PADDED_LEN) and send_meaningful_tail to find REALCONTENT: [$FILTERED]"
fi
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1

echo "== send_submit: call sites (nudge_agent, gatekeeper notify(), auto-resume resume path) =="
if grep -q 'send_submit "\$target" "check inbox"' "$LIB/dispatch.sh"; then
  pass "dispatch.sh's nudge_agent submits via send_submit (issue #86 finding 1)"
else
  fail "nudge_agent should submit via send_submit, not a raw send-keys burst"
fi
if grep -q 'source "\$DIR/send-lib.sh"' "$LIB/dispatch.sh"; then
  pass "dispatch.sh sources send-lib.sh"
else
  fail "dispatch.sh should source send-lib.sh"
fi
if grep -q 'source "\$AR_DIR/send-lib.sh"' "$LIB/auto-resume.sh"; then
  pass "auto-resume.sh sources send-lib.sh"
else
  fail "auto-resume.sh should source send-lib.sh"
fi
if grep -q 'send_meaningful_tail "\$target" 10' "$LIB/dispatch.sh"; then
  pass "dispatch.sh's pane_is_idle uses the blank-filtered send_meaningful_tail, not a raw tail -10"
else
  fail "pane_is_idle should use send_meaningful_tail, not an unfiltered capture-pane|tail"
fi

echo "== send_submit: live end-to-end happy path (non-stuck input) =="
tmux new-session -d -s "$TEST_SESSION" -n main sh >/dev/null 2>&1
sleep 1
# Multi-line output (not just the bare submitted command) so by the time
# send_submit's own confirm check captures its tail -3 (0.3s after Enter),
# the echoed input line has already scrolled past it -- a single-line
# echo's input-echo can still be WITHIN that tail-3 window, which would
# read as "still stuck" and trigger a spurious (but harmless-to-this-
# assertion) clear-and-retype. Avoiding that keeps this test deterministic.
send_submit "$TEST_SESSION:0.0" "printf 'A\\nB\\nC\\nD\\nSUBMITTED_OK\\n'"
sleep 0.5
if tmux capture-pane -p -t "$TEST_SESSION:0.0" 2>/dev/null | grep -q "SUBMITTED_OK"; then
  pass "send_submit typed and submitted the command into a real pane (sh executed it)"
else
  fail "expected the plain-shell pane to have executed the submitted command"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
