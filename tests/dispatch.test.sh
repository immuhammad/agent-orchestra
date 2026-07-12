#!/bin/bash
# .harness/dispatch.test.sh — tests for dispatch.sh (T17 3-verb inbox).
# Run: bash .harness/dispatch.test.sh
#
# Uses a throwaway tmux session ("harness-dispatch-test") with panes it
# fully controls to exercise the live idle/busy nudge heuristic, and a
# throwaway fake-agent inbox (not a real agent name, so dispatch.sh's own
# pane_for_agent() correctly no-ops the nudge) to exercise the verb/ack/
# timeout logic without touching any real agent's inbox or the production
# "harness" session.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DISPATCH="$DIR/../lib/dispatch.sh"
TEST_SESSION="harness-dispatch-test"

# issue #116: dispatch.sh's root-resolution now requires an
# orchestrator.yaml/ORC_PROJECT_ROOT to exist somewhere above cwd unless
# DISPATCH_CANON_DIR overrides it outright -- pin a scratch dir so this
# test never depends on (or risks touching) any real project's discovery.
export DISPATCH_CANON_DIR
DISPATCH_CANON_DIR="$(mktemp -d)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true
  rm -rf "$CANON_DIR/inbox/testagent" "$DISPATCH_CANON_DIR"
}
trap cleanup EXIT

echo "== pane_is_idle (live, isolated panes) =="
# Source dispatch.sh for its pane_is_idle helper. BASH_SOURCE guard means
# dispatch_main does NOT run as a side effect of sourcing.
source "$DISPATCH"

# Explicit -x/-y (same fix as auto-resume.test.sh): an unattached session
# with no client falls back to tmux's own default size, which can leave a
# LOT of blank-padded rows below the actual content -- a raw `tail -N`
# on `capture-pane`'s output (no blank-line filtering, unlike auto-resume.sh's
# own ar_meaningful_tail) then grabs pure padding instead of the real text.
# Pinning a small, sane size keeps that padding short enough that tail -10
# always reaches real content.
tmux new-session -d -s "$TEST_SESSION" -n main -x 200 -y 50 2>&1
tmux split-window -h -t "$TEST_SESSION:0" 2>&1
# Pane 0: sits at a plain shell prompt -- idle.
# Pane 1: simulate a TUI mid-generation -- busy.
tmux send-keys -t "$TEST_SESSION:0.1" "printf 'Thinking...\\n'; sleep 30" Enter 2>&1
sleep 1

if pane_is_idle "$TEST_SESSION:0.0"; then
  pass "shell-prompt pane detected as idle"
else
  fail "shell-prompt pane should be idle"
fi

if pane_is_idle "$TEST_SESSION:0.1"; then
  fail "busy pane (printing 'Thinking...') should NOT be idle"
else
  pass "busy pane correctly detected as not idle"
fi

echo "== issue #86 Task 3: per-agent busy markers (agy's live-observed 'Working...' render) =="
# A DEDICATED third pane (0.2), not the shared 0.1 pane the T24 section
# below depends on staying busy -- reusing 0.1 here would both leave stale
# 'Thinking...' scrollback contaminating this check AND interrupt the
# sleep the T24 section expects to still be running.
tmux split-window -h -t "$TEST_SESSION:0" 2>&1
# agy's real busy rendering (live-confirmed 2026-07-10): "Working..." with a
# bare '>' prompt still visible underneath -- none of the Claude-Code-only
# words (thinking/generating/compacting/esc to interrupt/running...) match
# this, so the DEFAULT marker set alone reads it as idle.
tmux send-keys -t "$TEST_SESSION:0.2" "printf '⣟ Working...\\n> \\n'; sleep 30" Enter 2>&1
sleep 1
if pane_is_idle "$TEST_SESSION:0.2" "agy"; then
  fail "agy's 'Working...' render should be detected busy when checked as agy"
else
  pass "agy's 'Working...' render correctly detected as busy for agent 'agy'"
fi
if pane_is_idle "$TEST_SESSION:0.2"; then
  pass "same render with NO agent hint falls back to the Claude-Code-only list (documents the gap 'working' widening exists to close)"
else
  fail "no-agent-hint call unexpectedly matched 'working' -- pane_busy_markers default branch may have widened"
fi
tmux send-keys -t "$TEST_SESSION:0.2" C-c 2>&1

echo "== T24: deferred-nudge queue (nudge_agent / retry_deferred_nudges) =="
# Override pane_for_agent so a fake agent name maps onto this test session's
# real busy pane (0.1) -- lets us drive nudge_agent's defer branch and
# retry_deferred_nudges' drain logic against a real tmux pane instead of
# just asserting on file contents.
pane_for_agent() {
  case "$1" in
    deferredtest) echo "$TEST_SESSION:0.1" ;;
    *) echo "" ;;
  esac
}
DEFERRED_TEST_FILE="$(mktemp)"
DEFERRED_FILE="$DEFERRED_TEST_FILE"

nudge_agent "deferredtest" >/dev/null 2>&1
if grep -qxF "deferredtest" "$DEFERRED_FILE" 2>/dev/null; then
  pass "nudge into a busy pane queues the agent in the deferred file"
else
  fail "busy-pane nudge should have queued 'deferredtest'"
fi

nudge_agent "deferredtest" >/dev/null 2>&1
DUP_COUNT="$(grep -cxF "deferredtest" "$DEFERRED_FILE" 2>/dev/null || echo 0)"
if [ "$DUP_COUNT" -eq 1 ]; then
  pass "re-deferring the same agent does not duplicate the queue entry"
else
  fail "expected exactly one queued entry for 'deferredtest', got $DUP_COUNT"
fi

# Make the pane idle, then retry -- should nudge for real and drain the queue.
tmux send-keys -t "$TEST_SESSION:0.1" C-c 2>&1
sleep 1
retry_deferred_nudges >/dev/null 2>&1
if [ ! -s "$DEFERRED_FILE" ]; then
  pass "retry_deferred_nudges drains the queue once the pane is idle"
else
  fail "deferred queue should be empty after retry, got: $(cat "$DEFERRED_FILE")"
fi
rm -f "$DEFERRED_TEST_FILE"
# Restore the real pane_for_agent for anything below that relies on it.
unset -f pane_for_agent
source "$DISPATCH"

echo "== message verb: writes .msg, no nudge, no ack wait =="
mkdir -p "$CANON_DIR/inbox/testagent"
OUT="$(bash "$DISPATCH" message testagent 9001 "hello" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && ls "$CANON_DIR"/inbox/testagent/*-9001.msg >/dev/null 2>&1; then
  pass "message verb wrote .msg and returned 0"
else
  fail "message verb did not behave as expected: $OUT"
fi
if echo "$OUT" | grep -q "nudged"; then
  fail "message verb should never nudge"
else
  pass "message verb did not nudge"
fi
rm -f "$CANON_DIR"/inbox/testagent/*.msg

echo "== assign verb: writes .msg, returns immediately without an ack =="
START=$SECONDS
OUT="$(bash "$DISPATCH" assign testagent 9002 "hello" 2>&1)"
STATUS=$?
ELAPSED=$((SECONDS - START))
if [ "$STATUS" -eq 0 ] && [ "$ELAPSED" -lt 5 ] && ls "$CANON_DIR"/inbox/testagent/*-9002.msg >/dev/null 2>&1; then
  pass "assign verb wrote .msg and returned immediately (${ELAPSED}s) without an ack"
else
  fail "assign verb did not behave as expected (status=$STATUS elapsed=${ELAPSED}s): $OUT"
fi
rm -f "$CANON_DIR"/inbox/testagent/*.msg

echo "== handoff verb: round-trip -- ack appears before timeout =="
(
  # Simulate the receiver: wait briefly, then ack the newest .msg with a
  # real one-line status (T30, issue #56: acks must be non-empty receipts).
  sleep 2
  msg="$(ls -t "$CANON_DIR"/inbox/testagent/*-9003.msg 2>/dev/null | head -1)"
  [ -n "$msg" ] && echo "done" > "${msg%.msg}.ack"
) &
OUT="$(bash "$DISPATCH" handoff testagent 9003 "hello" 10 2>&1)"
STATUS=$?
wait
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -q "received"; then
  pass "handoff verb returned success once the .ack appeared"
else
  fail "handoff verb round-trip failed (status=$STATUS): $OUT"
fi
rm -f "$CANON_DIR"/inbox/testagent/*.msg "$CANON_DIR"/inbox/testagent/*.ack

echo "== T30 (#56): handoff verb treats an empty/whitespace-only ack as suspect, keeps waiting =="
(
  # Receiver writes an EMPTY ack first (the old "just touch it" habit),
  # then a real one shortly after -- handoff should only accept the second.
  sleep 1
  msg="$(ls -t "$CANON_DIR"/inbox/testagent/*-9007.msg 2>/dev/null | head -1)"
  [ -n "$msg" ] && touch "${msg%.msg}.ack"
  sleep 2
  [ -n "$msg" ] && echo "SKIPPED: not applicable" > "${msg%.msg}.ack"
) &
OUT="$(bash "$DISPATCH" handoff testagent 9007 "hello" 10 2>&1)"
STATUS=$?
wait
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -q "received" && echo "$OUT" | grep -q "empty/whitespace-only"; then
  pass "handoff verb logged the empty ack as suspect and waited for a real one"
else
  fail "handoff verb should log+skip the empty ack then accept the real one (status=$STATUS): $OUT"
fi
rm -f "$CANON_DIR"/inbox/testagent/*.msg "$CANON_DIR"/inbox/testagent/*.ack

echo "== T30 (#56): handoff verb times out if the ack STAYS empty the whole window =="
(
  sleep 1
  msg="$(ls -t "$CANON_DIR"/inbox/testagent/*-9008.msg 2>/dev/null | head -1)"
  [ -n "$msg" ] && touch "${msg%.msg}.ack"
) &
OUT="$(bash "$DISPATCH" handoff testagent 9008 "hello" 3 2>&1)"
STATUS=$?
wait
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "timeout"; then
  pass "handoff verb times out when the ack never becomes non-empty"
else
  fail "handoff verb should time out on a permanently-empty ack (status=$STATUS): $OUT"
fi
rm -f "$CANON_DIR"/inbox/testagent/*.msg "$CANON_DIR"/inbox/testagent/*.ack

echo "== handoff verb: timeout when no ack ever appears =="
OUT="$(bash "$DISPATCH" handoff testagent 9004 "hello" 3 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "timeout"; then
  pass "handoff verb times out cleanly when no .ack appears"
else
  fail "handoff verb should time out with exit 2 (status=$STATUS): $OUT"
fi
rm -f "$CANON_DIR"/inbox/testagent/*.msg

echo "== issue #89: assign/handoff scribe spawns a one-shot headless run, not a pane nudge =="
# Its own scratch CANON_DIR (via DISPATCH_CANON_DIR) so this never touches
# a real project's inbox history.
SCRIBE_SCRATCH="$(mktemp -d)"
mkdir -p "$SCRIBE_SCRATCH/inbox/scribe"
CLAUDE_CALLS="$SCRIBE_SCRATCH/claude-calls.log"
: > "$CLAUDE_CALLS"
# Fake `claude` on PATH (dispatch_main runs as a subprocess via `bash
# "$DISPATCH"`, so a shell function override wouldn't reach it -- a PATH
# stub is the only way to intercept what that subprocess actually execs).
FAKE_BIN="$SCRIBE_SCRATCH/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'FAKECLAUDE'
#!/bin/bash
echo "$*" >> "$CLAUDE_CALLS_FILE"
# Find the .ack path the prompt asked us to write to and write a receipt,
# simulating the real headless run completing its judgment task.
ACK_PATH="$(echo "$*" | grep -Eo '/[^ ]*\.ack' | tail -1)"
[ -n "$ACK_PATH" ] && echo "DONE: scribe handled it" > "$ACK_PATH"
FAKECLAUDE
chmod +x "$FAKE_BIN/claude"

OUT="$(PATH="$FAKE_BIN:$PATH" CLAUDE_CALLS_FILE="$CLAUDE_CALLS" DISPATCH_CANON_DIR="$SCRIBE_SCRATCH" bash "$DISPATCH" assign scribe 9010 "do the judgment task" 2>&1)"
sleep 1 # scribe_spawn_headless backgrounds the claude call
if echo "$OUT" | grep -q "spawning one-shot headless scribe" && ! echo "$OUT" | grep -q "no pane mapping"; then
  pass "assign scribe spawned the headless run instead of trying to nudge a pane"
else
  fail "assign scribe should spawn headless, not attempt a pane nudge: $OUT"
fi
if grep -q -- "--model haiku" "$CLAUDE_CALLS"; then
  pass "spawned claude with --model haiku"
else
  fail "expected the spawned claude call to use --model haiku: $(cat "$CLAUDE_CALLS")"
fi
if ls "$SCRIBE_SCRATCH"/inbox/scribe/*-9010.msg >/dev/null 2>&1; then
  pass "the .msg landed in the durable inbox (scribe dir -- scribe's real physical inbox, issue #22)"
else
  fail "expected the .msg in the scribe inbox dir"
fi
if ! grep -q "career-ops-harness" "$CLAUDE_CALLS"; then
  pass "issue #18 B3: the scribe prompt no longer hardcodes 'career-ops-harness' (project-agnostic)"
else
  fail "scribe prompt should not hardcode career-ops-harness: $(cat "$CLAUDE_CALLS")"
fi

echo "== issue #22: legacy 'copilot' verb resolves INTO 'scribe's physical inbox dir (inverted alias) =="
: > "$CLAUDE_CALLS"
OUT="$(PATH="$FAKE_BIN:$PATH" CLAUDE_CALLS_FILE="$CLAUDE_CALLS" DISPATCH_CANON_DIR="$SCRIBE_SCRATCH" bash "$DISPATCH" assign copilot 9011 "another judgment task" 2>&1)"
sleep 1
if ls "$SCRIBE_SCRATCH"/inbox/scribe/*-9011.msg >/dev/null 2>&1; then
  pass "'copilot' still lands in the same physical inbox dir as 'scribe'"
else
  fail "'copilot' alias should resolve to the same inbox dir as 'scribe'"
fi
if grep -q -- "--model haiku" "$CLAUDE_CALLS"; then
  pass "'copilot' also spawns the headless run (same code path as 'scribe')"
else
  fail "'copilot' should also spawn the headless scribe run"
fi

echo "== issue #89: handoff scribe waits for the headless run's own .ack, same as any other agent =="
: > "$CLAUDE_CALLS"
OUT="$(PATH="$FAKE_BIN:$PATH" CLAUDE_CALLS_FILE="$CLAUDE_CALLS" DISPATCH_CANON_DIR="$SCRIBE_SCRATCH" bash "$DISPATCH" handoff scribe 9012 "judge this" 10 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -q "received"; then
  pass "handoff scribe received the headless run's own .ack before timing out"
else
  fail "handoff scribe should receive the spawned run's .ack (status=$STATUS): $OUT"
fi
rm -rf "$SCRIBE_SCRATCH"

echo "== issue #22: assign scribe succeeds in a FRESH room seeded only with inbox/scribe/ (no legacy copilot/) =="
FRESH_ROOM="$(mktemp -d)"
mkdir -p "$FRESH_ROOM/inbox/scribe"
CLAUDE_CALLS2="$FRESH_ROOM/claude-calls.log"
: > "$CLAUDE_CALLS2"
OUT="$(PATH="$FAKE_BIN:$PATH" CLAUDE_CALLS_FILE="$CLAUDE_CALLS2" DISPATCH_CANON_DIR="$FRESH_ROOM" bash "$DISPATCH" assign scribe 9020 "fresh room task" 2>&1)"
sleep 1
if ls "$FRESH_ROOM"/inbox/scribe/*-9020.msg >/dev/null 2>&1; then
  pass "issue #22: assign scribe writes .msg into inbox/scribe/ in a fresh room with no copilot/ dir"
else
  fail "issue #22: assign scribe should resolve to inbox/scribe/ in a fresh clone-per-project room (got: $OUT)"
fi
rm -rf "$FRESH_ROOM"

echo "== issue #22: legacy 'copilot' dispatch verb still lands somewhere valid (aliases TO scribe/, not the reverse) =="
LEGACY_ROOM="$(mktemp -d)"
mkdir -p "$LEGACY_ROOM/inbox/scribe"
CLAUDE_CALLS3="$LEGACY_ROOM/claude-calls.log"
: > "$CLAUDE_CALLS3"
OUT="$(PATH="$FAKE_BIN:$PATH" CLAUDE_CALLS_FILE="$CLAUDE_CALLS3" DISPATCH_CANON_DIR="$LEGACY_ROOM" bash "$DISPATCH" assign copilot 9021 "legacy verb task" 2>&1)"
sleep 1
if ls "$LEGACY_ROOM"/inbox/scribe/*-9021.msg >/dev/null 2>&1; then
  pass "issue #22: legacy 'copilot' verb resolves into inbox/scribe/ (inverted alias)"
else
  fail "issue #22: legacy 'copilot' verb should resolve into inbox/scribe/, not require a copilot/ dir (got: $OUT)"
fi
rm -rf "$LEGACY_ROOM"

echo "== unmapped agent name: never nudges (pane_for_agent has no entry) =="
OUT="$(bash "$DISPATCH" assign testagent 9005 "hello" 2>&1)"
if echo "$OUT" | grep -q "no pane mapping"; then
  pass "unmapped agent name skips the nudge safely"
else
  fail "unmapped agent should log a skipped nudge: $OUT"
fi
rm -f "$CANON_DIR"/inbox/testagent/*.msg

echo "== unknown verb is rejected =="
OUT="$(bash "$DISPATCH" bogus testagent 9006 "hello" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 1 ] && echo "$OUT" | grep -q "unknown verb"; then
  pass "unknown verb rejected with exit 1"
else
  fail "unknown verb should be rejected (status=$STATUS): $OUT"
fi

echo "== issue #19: DISPATCH_SESSION derives from THIS project's own orchestrator.yaml -- two projects never share a session =="
# This test file exports DISPATCH_CANON_DIR globally (line ~22) so the rest
# of the suite never touches a real project's discovery -- explicitly unset
# it (and DISPATCH_SESSION) here so real per-project orchestrator.yaml
# discovery is exercised, the actual mechanism issue #19's live repro hit.
PROJECT_A="$(mktemp -d)"
PROJECT_B="$(mktemp -d)"
echo "project: project-a" > "$PROJECT_A/orchestrator.yaml"
echo "project: project-b" > "$PROJECT_B/orchestrator.yaml"

PANE_A="$(cd "$PROJECT_A" && env -u DISPATCH_CANON_DIR -u DISPATCH_SESSION bash -c "source '$DISPATCH'; pane_for_agent orchestra")"
PANE_B="$(cd "$PROJECT_B" && env -u DISPATCH_CANON_DIR -u DISPATCH_SESSION bash -c "source '$DISPATCH'; pane_for_agent orchestra")"

if [ "$PANE_A" = "project-a:0.0" ]; then
  pass "project A's dispatch resolves to ITS OWN session (project-a:0.0)"
else
  fail "expected project-a:0.0, got $PANE_A"
fi
if [ "$PANE_B" = "project-b:0.0" ]; then
  pass "project B's dispatch resolves to ITS OWN session (project-b:0.0)"
else
  fail "expected project-b:0.0, got $PANE_B"
fi
if [ -n "$PANE_A" ] && [ "$PANE_A" != "$PANE_B" ]; then
  pass "project A and project B never resolve to the same session (cross-project nudge collision, issue #19)"
else
  fail "CORRECTNESS REGRESSION (issue #19): two different projects resolved to the SAME session ($PANE_A / $PANE_B) -- a nudge from one project would hit the other's pane"
fi
rm -rf "$PROJECT_A" "$PROJECT_B"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
