#!/bin/bash
# tests/pane-state.test.sh — issue #33: lib/pane-state-lib.sh (write/read
# primitives) and hooks/pane-state.sh (the hook script wired to
# UserPromptSubmit/PreToolUse/Stop). dispatch.sh's pane_is_idle consumer
# behavior is covered separately in tests/dispatch.test.sh.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$DIR/../lib/pane-state-lib.sh"
HOOK="$DIR/../hooks/pane-state.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

echo "== pane_state_write / pane_state_read: round-trip =="
export PANE_STATE_DIR="$SCRATCH/state"
source "$LIB"

pane_state_write "%7" "busy"
GOT="$(pane_state_read "%7")"
if [ "$GOT" = "busy" ]; then
  pass "write then read round-trips the state"
else
  fail "expected 'busy', got '$GOT'"
fi

pane_state_write "%7" "idle"
GOT="$(pane_state_read "%7")"
if [ "$GOT" = "idle" ]; then
  pass "a second write overwrites the first (latest state wins)"
else
  fail "expected 'idle' after overwrite, got '$GOT'"
fi

echo "== pane_state_sanitize: strips the leading % for the on-disk filename =="
if [ "$(pane_state_sanitize "%12")" = "12" ]; then
  pass "'%12' sanitizes to '12'"
else
  fail "expected '12', got '$(pane_state_sanitize "%12")'"
fi

echo "== SECURITY (agy PR #45 REQUEST-CHANGES): pane_state_sanitize rejects a path-traversal pane_id, not just strips '%' =="
# hooks/pane-state.sh trusts \$TMUX_PANE verbatim -- any agent invoking a
# tool can `export TMUX_PANE=...` before it, since it's an ordinary
# inherited env var, not something tmux re-verifies per hook call. A
# strip-only sanitizer (the pre-fix `${1#%}`) let a traversal payload
# reach pane_state_write's `$PANE_STATE_DIR/<result>` untouched, letting
# an agent overwrite an arbitrary file outside PANE_STATE_DIR (e.g.
# .git/config, .harness/handoff.md) merely by tampering with its own
# environment before a tool call.
TRAVERSAL_TARGET="$SCRATCH/outside-pane-state-dir"
echo "PRE-EXISTING-CONTENT" > "$TRAVERSAL_TARGET"
# PANE_STATE_DIR is "$SCRATCH/state" (one level below SCRATCH), so exactly
# one "../" from there reaches $TRAVERSAL_TARGET.
pane_state_write "../outside-pane-state-dir" "busy" 2>/dev/null
if [ "$(cat "$TRAVERSAL_TARGET")" = "PRE-EXISTING-CONTENT" ]; then
  pass "pane_state_write did not let a '../'-laden pane_id escape PANE_STATE_DIR"
else
  fail "SECURITY: pane_state_write overwrote a file outside PANE_STATE_DIR via a traversal pane_id -- got: $(cat "$TRAVERSAL_TARGET" 2>/dev/null)"
fi
if pane_state_sanitize "../../../../etc/passwd" >/dev/null 2>&1; then
  fail "SECURITY: pane_state_sanitize should reject a non-tmux-shaped pane_id (traversal payload), not accept it"
else
  pass "pane_state_sanitize rejects a traversal payload outright (not a real tmux pane_id shape)"
fi
if [ "$(pane_state_sanitize "%12" 2>/dev/null)" = "12" ]; then
  pass "pane_state_sanitize still accepts a genuine tmux pane_id ('%12' -> '12')"
else
  fail "pane_state_sanitize regressed on a genuine tmux pane_id"
fi

echo "== pane_state_read: missing pane_id returns nothing (exit 1) =="
if pane_state_read "%no-such-pane" >/dev/null 2>&1; then
  fail "expected pane_state_read to fail for a pane with no state file"
else
  pass "pane_state_read fails cleanly for an unknown pane_id"
fi

echo "== issue #125: entries PERSIST by default (states are transitions, no age-out); explicit max_age still enforces freshness =="
mkdir -p "$PANE_STATE_DIR"
echo "busy 1000000000" > "$PANE_STATE_DIR/99"
if [ "$(pane_state_read "%99" 2>/dev/null)" = "busy" ]; then
  pass "issue #125: an ancient entry is still returned by default -- crash coverage is pane_state_clear (watch liveness), not an expiry"
else
  fail "issue #125: default read should trust the last-written state regardless of age"
fi
if pane_state_read "%99" 30 >/dev/null 2>&1; then
  fail "an explicit max_age=30 should reject an epoch-1000000000 entry"
else
  pass "explicit max_age still rejects a stale entry for callers that want freshness"
fi

echo "== issue #125: failsafe state + session_id round-trip =="
pane_state_write "%97" failsafe "sess-abc123"
if [ "$(pane_state_read "%97" 2>/dev/null)" = "failsafe" ]; then
  pass "failsafe is a first-class state"
else
  fail "expected pane_state_read to return 'failsafe'"
fi
if [ "$(pane_state_session "%97" 2>/dev/null)" = "sess-abc123" ]; then
  pass "session_id round-trips through write/read"
else
  fail "expected pane_state_session to return 'sess-abc123'"
fi

echo "== issue #125: unknown state string is rejected, not passed through =="
echo "weird 1234567890" > "$PANE_STATE_DIR/96"
if pane_state_read "%96" >/dev/null 2>&1; then
  fail "an unknown state string should be rejected"
else
  pass "unknown state string correctly rejected"
fi

echo "== issue #125: entry with no session_id -- pane_state_session fails cleanly =="
pane_state_write "%95" idle
if pane_state_session "%95" >/dev/null 2>&1; then
  fail "pane_state_session should fail when no session_id was recorded"
else
  pass "pane_state_session fails cleanly with no recorded session_id"
fi

echo "== issue #125 follow-up: failsafe is EFFECTIVE only while the quota flag exists =="
pane_state_write "%94" failsafe "sid-eff"
EFF_FLAG="$(mktemp)"
if [ "$(PANE_STATE_QUOTA_FLAG="$EFF_FLAG" pane_state_effective "%94" 2>/dev/null)" = "failsafe" ]; then
  pass "flag present -> effective state is failsafe (delivery held)"
else
  fail "expected effective failsafe while the quota flag exists"
fi
rm -f "$EFF_FLAG"
if [ "$(PANE_STATE_QUOTA_FLAG="$EFF_FLAG" pane_state_effective "%94" 2>/dev/null)" = "idle" ]; then
  pass "flag lifted -> stale failsafe reads as idle (breaks the nothing-can-wake-it chicken-and-egg)"
else
  fail "expected effective idle once the quota flag is gone"
fi
if [ "$(pane_state_read "%94" 2>/dev/null)" = "failsafe" ]; then
  pass "raw read still reports failsafe (auto-resume ownership stays truthful)"
else
  fail "raw pane_state_read should be untouched by the effective derivation"
fi
pane_state_clear "%94"

echo "== issue #125: pane_state_clear removes the entry =="
pane_state_clear "%97"
if pane_state_read "%97" >/dev/null 2>&1; then
  fail "expected no state after pane_state_clear"
else
  pass "pane_state_clear removes the pane's state file"
fi

echo "== pane_state_read: malformed entry (no timestamp) is rejected, not misread =="
echo "busy" > "$PANE_STATE_DIR/98"
if pane_state_read "%98" >/dev/null 2>&1; then
  fail "expected a malformed (timestamp-less) entry to be rejected"
else
  pass "malformed entry correctly rejected"
fi

echo "== issue #6: classification is a 4th, optional field =="
pane_state_write "%80" idle "sess-a" "fresh"
if [ "$(pane_state_classification "%80" 2>/dev/null)" = "fresh" ]; then
  pass "classification round-trips through write/read"
else
  fail "expected pane_state_classification to return 'fresh'"
fi
if [ "$(pane_state_read "%80" 2>/dev/null)" = "idle" ]; then
  pass "a 4th field does not disturb the ordinary state read"
else
  fail "pane_state_read regressed when a classification field is present"
fi
if [ "$(pane_state_session "%80" 2>/dev/null)" = "sess-a" ]; then
  pass "a 4th field does not disturb the session_id read"
else
  fail "pane_state_session regressed when a classification field is present"
fi

echo "== issue #6: an omitted classification CARRIES FORWARD the previous one (busy/idle writes must not erase it) =="
pane_state_write "%80" busy "sess-a"
if [ "$(pane_state_classification "%80" 2>/dev/null)" = "fresh" ]; then
  pass "a later write with no 4th arg preserves the earlier classification"
else
  fail "expected classification 'fresh' to survive a busy write with no 4th arg, got '$(pane_state_classification "%80" 2>/dev/null)'"
fi
if [ "$(pane_state_read "%80" 2>/dev/null)" = "busy" ]; then
  pass "the state itself still updates normally while classification carries forward"
else
  fail "expected state to update to busy"
fi

echo "== issue #6: an explicit new classification overwrites the carried-forward one =="
pane_state_write "%80" idle "sess-b" "rebuilt"
if [ "$(pane_state_classification "%80" 2>/dev/null)" = "rebuilt" ]; then
  pass "an explicit classification argument overwrites the prior value"
else
  fail "expected classification 'rebuilt' after an explicit overwrite"
fi

echo "== issue #6: pane_state_classification on a pane with no classification ever recorded -> fails cleanly =="
pane_state_write "%81" idle "sess-c"
if pane_state_classification "%81" >/dev/null 2>&1; then
  fail "expected pane_state_classification to fail with no classification recorded"
else
  pass "pane_state_classification fails cleanly with no recorded classification"
fi

echo "== agy PR #135 round 1: empty session_id must NOT shift classification into the session_id column (awk collapses consecutive spaces) =="
pane_state_write "%82" idle "" "rebuilt"
if pane_state_session "%82" >/dev/null 2>&1; then
  fail "SECURITY/CORRECTNESS: an empty session_id should read as 'no session', not the classification value"
else
  pass "empty session_id reads as absent, not shifted into the classification's slot"
fi
if [ "$(pane_state_classification "%82" 2>/dev/null)" = "rebuilt" ]; then
  pass "classification survives an empty session_id (field position preserved)"
else
  fail "expected classification 'rebuilt' to survive an empty session_id, got '$(pane_state_classification "%82" 2>/dev/null)'"
fi
if [ "$(pane_state_read "%82" 2>/dev/null)" = "idle" ]; then
  pass "state itself unaffected by the empty session_id"
else
  fail "expected state 'idle'"
fi

echo "== issue #6: pane_state_classification on an entirely unknown pane -> fails cleanly =="
if pane_state_classification "%no-such-pane" >/dev/null 2>&1; then
  fail "expected pane_state_classification to fail for an unknown pane_id"
else
  pass "pane_state_classification fails cleanly for an unknown pane_id"
fi

echo "== pane_state_write: empty pane_id is a no-op, not an error =="
if pane_state_write "" "busy" 2>&1; then
  pass "pane_state_write with an empty pane_id returns success (no-op)"
else
  fail "pane_state_write should no-op cleanly on an empty pane_id"
fi

echo "== hooks/pane-state.sh: no \$TMUX_PANE -- silent no-op, no state file written =="
BEFORE_COUNT="$(find "$PANE_STATE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
OUT="$(env -u TMUX_PANE PANE_STATE_CANON_DIR="$SCRATCH/canon" bash "$HOOK" busy <<< '{}' 2>&1)"
STATUS=$?
AFTER_COUNT="$(find "$PANE_STATE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$STATUS" -eq 0 ] && [ "$BEFORE_COUNT" -eq "$AFTER_COUNT" ]; then
  pass "no \$TMUX_PANE: hook exits 0 and writes nothing (headless one-shot, issue #89)"
else
  fail "hook should no-op cleanly with no \$TMUX_PANE (status=$STATUS out=$OUT)"
fi

echo "== hooks/pane-state.sh: with \$TMUX_PANE, writes busy/idle to PANE_STATE_CANON_DIR/state/pane-state =="
HOOK_CANON="$SCRATCH/hookcanon"
OUT="$(TMUX_PANE="%42" PANE_STATE_CANON_DIR="$HOOK_CANON" bash "$HOOK" busy <<< '{}' 2>&1)"
STATUS=$?
STATE_FILE="$HOOK_CANON/state/pane-state/42"
if [ "$STATUS" -eq 0 ] && [ -f "$STATE_FILE" ] && grep -q '^busy ' "$STATE_FILE"; then
  pass "hook writes 'busy <timestamp>' to the state file keyed by the sanitized pane_id"
else
  fail "expected $STATE_FILE to contain 'busy <ts>' (status=$STATUS out=$OUT, file: $(cat "$STATE_FILE" 2>/dev/null || echo MISSING))"
fi

OUT="$(TMUX_PANE="%42" PANE_STATE_CANON_DIR="$HOOK_CANON" bash "$HOOK" idle <<< '{}' 2>&1)"
if grep -q '^idle ' "$STATE_FILE"; then
  pass "a subsequent 'idle' call overwrites the same pane's state file"
else
  fail "expected $STATE_FILE to now contain 'idle <ts>' (out=$OUT, file: $(cat "$STATE_FILE" 2>/dev/null || echo MISSING))"
fi

echo "== hooks/pane-state.sh: rejects a call with no state argument =="
if TMUX_PANE="%1" bash "$HOOK" <<< '{}' >/dev/null 2>&1; then
  fail "expected the hook to fail without a busy|idle argument"
else
  pass "hook fails cleanly when called without a state argument"
fi

echo "== hooks/pane-state.sh: reads and drains stdin (never blocks on the hook JSON) =="
# No `timeout` binary on stock macOS -- background the call and poll for
# completion instead, so a hang still fails the test rather than the
# harness itself.
(echo '{"session_id":"abc"}' | TMUX_PANE="%5" PANE_STATE_CANON_DIR="$HOOK_CANON" bash "$HOOK" busy >/dev/null 2>&1) &
HOOK_PID=$!
WAITED=0
while kill -0 "$HOOK_PID" 2>/dev/null && [ "$WAITED" -lt 5 ]; do
  sleep 1
  WAITED=$((WAITED + 1))
done
if kill -0 "$HOOK_PID" 2>/dev/null; then
  fail "hook did not return within 5s on real Claude Code hook JSON input (hung on stdin?)"
  kill "$HOOK_PID" 2>/dev/null
else
  wait "$HOOK_PID"
  if [ $? -eq 0 ]; then
    pass "hook consumes stdin and returns promptly with real hook-shaped JSON"
  else
    fail "hook exited non-zero on real Claude Code hook JSON input"
  fi
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
