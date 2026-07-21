#!/bin/bash
# .harness/gatekeeper.test.sh — tests for T19 (OAuth usage sensor +
# gatekeeper liveness) and T26 (hermetic: never touches the real "harness"
# session). Run: bash .harness/gatekeeper.test.sh
#
# Requires live Claude Code credentials (Keychain or
# ~/.claude/.credentials.json) and network access to
# api.anthropic.com -- this is inherently an integration test of a live
# sensor, not something you can meaningfully fake. If no credentials are
# found the first block is skipped with a clear message rather than
# failing (a machine with no Claude Code login shouldn't fail this suite).
#
# T26 safety fix: gatekeeper.sh's notify() used to hardcode the "harness"
# tmux session -- at real usage over the 80% threshold, this test running
# the real gatekeeper_main loop fired REAL alerts into the REAL
# harness:0.0/0.1 panes (confirmed live: text landed in and was submitted,
# via a real Enter, to a live Claude Code session's input box, which reads
# as a genuine user prompt -- a safety bug, not just noise). Every
# gatekeeper.sh/gatekeeper-liveness.sh invocation below points
# GATEKEEPER_NOTIFY_SESSION / GATEKEEPER_LIVENESS_TARGET at a throwaway
# session (gktest-$$) created and destroyed by this test, never at
# "harness". See the final block, which explicitly verifies zero text
# reached the real harness session's panes across the whole run.
#
# Heartbeat and log paths are overridden to throwaway temp files for the
# whole run (GATEKEEPER_HEARTBEAT_FILE / GATEKEEPER_LIVENESS_LOG) so this
# test never touches the real .harness/gatekeeper.heartbeat or the tracked
# .harness/budget.log, even if a real gatekeeper happens to be running on
# this machine at the same time. Same reasoning for AUTO_RESUME_STATE_FILE
# (T20) -- gatekeeper.sh's loop always calls ar_poll_all, which touches the
# state file on every single iteration regardless of usage%.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
GATEKEEPER="$LIB/gatekeeper.sh"
LIVENESS="$LIB/gatekeeper-liveness.sh"
TEST_SESSION="gktest-$$"
REAL_SESSION="harness"

export GATEKEEPER_HEARTBEAT_FILE
export GATEKEEPER_LIVENESS_LOG
export AUTO_RESUME_STATE_FILE
export GATEKEEPER_NOTIFY_SESSION
export DISPATCH_SESSION
export DISPATCH_CANON_DIR
export GATEKEEPER_ALERT_STATE_FILE
export GATEKEEPER_BUDGET_LOG
export GATEKEEPER_LIVENESS_RATELIMIT_PANES
export GATEKEEPER_LIVENESS_HANDOFF_FILE
GATEKEEPER_HEARTBEAT_FILE="$(mktemp)"
GATEKEEPER_LIVENESS_LOG="$(mktemp)"
AUTO_RESUME_STATE_FILE="$(mktemp)"
GATEKEEPER_NOTIFY_SESSION="$TEST_SESSION"
# #11 secondary gap: gatekeeper-liveness.sh's rate-limit-stuck heuristic
# defaults to watching the REAL "harness:0.1" (Builder) pane and reading
# the caller-cwd-resolved real handoff.md -- same class of leak T26 already
# fixed for GATEKEEPER_LIVENESS_TARGET/DISPATCH_SESSION above. Both must
# point at throwaway locations for the whole run.
GATEKEEPER_LIVENESS_RATELIMIT_PANES="$TEST_SESSION:0.1"
GATEKEEPER_LIVENESS_HANDOFF_FILE="$(mktemp)"
# issue #105: alerts now route through dispatch.sh (gk_alert_orchestra),
# which has its OWN session target (pane_for_agent hardcoded "harness"
# otherwise, ignoring GATEKEEPER_NOTIFY_SESSION entirely -- found writing
# these very tests, a real safety gap) and its OWN inbox root (CANON_DIR).
# Both must point at throwaway locations or a real 80%+ crossing during
# this test run nudges the real harness:0.0 pane and writes into the real
# orchestra inbox.
DISPATCH_SESSION="$TEST_SESSION"
DISPATCH_CANON_DIR="$(mktemp -d)"
mkdir -p "$DISPATCH_CANON_DIR/inbox/orchestra"
GATEKEEPER_ALERT_STATE_FILE="$(mktemp)"
rm -f "$GATEKEEPER_ALERT_STATE_FILE" # gk_ensure_alert_state should recreate it
GATEKEEPER_BUDGET_LOG="$(mktemp)"

# issue #60 task D: gk_check_room_branch runs every gatekeeper_main tick and
# fires its own durable orchestra alert on a room-branch mismatch. Every
# EXISTING test below runs the real loop against the repo this test happens
# to execute in -- often a feature-branch worktree, i.e. a genuine
# mismatch -- which would otherwise inject an unrelated "room-branch" .msg
# into every "exactly one alert" assertion below. A dedicated clean-repo
# fixture, always on its own "uat" integration branch, keeps every
# pre-existing (non-room-branch) test hermetic; the task D tests further
# down override GATEKEEPER_ROOM_ROOT per-invocation to exercise mismatches
# on purpose.
export GATEKEEPER_ROOM_ROOT
GATEKEEPER_ROOM_ROOT="$(mktemp -d)"
GATEKEEPER_ROOM_ROOT="$(cd "$GATEKEEPER_ROOM_ROOT" && pwd -P)"
git init -q "$GATEKEEPER_ROOM_ROOT"
git -C "$GATEKEEPER_ROOM_ROOT" config user.email "test@test.local"
git -C "$GATEKEEPER_ROOM_ROOT" config user.name "test"
echo "project: gk-hermetic-room" > "$GATEKEEPER_ROOM_ROOT/orchestrator.yaml"
git -C "$GATEKEEPER_ROOM_ROOT" checkout -q -b uat
git -C "$GATEKEEPER_ROOM_ROOT" add orchestrator.yaml
git -C "$GATEKEEPER_ROOM_ROOT" commit -q -m init

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; }

GATEKEEPER_PID=""
LIVENESS_PID=""

# Portable stand-in for `timeout` (neither `timeout` nor `gtimeout` is
# guaranteed to be installed, e.g. on stock macOS): run "$@" in the
# background with output captured to a temp file, let it run for up to
# $1 seconds, then kill it and print whatever it produced. Used to exercise
# gatekeeper.sh's first loop iteration without waiting out its (long,
# production-realistic) CHECK_INTERVAL sleep.
run_briefly() {
  local secs="$1"; shift
  local out
  out="$(mktemp)"
  ("$@") > "$out" 2>&1 &
  local pid=$!
  sleep "$secs"
  kill "$pid" >/dev/null 2>&1
  wait "$pid" 2>/dev/null
  cat "$out"
  rm -f "$out"
}

cleanup() {
  [ -n "$GATEKEEPER_PID" ] && kill "$GATEKEEPER_PID" >/dev/null 2>&1
  [ -n "$LIVENESS_PID" ] && kill "$LIVENESS_PID" >/dev/null 2>&1
  tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true
  rm -f "$GATEKEEPER_HEARTBEAT_FILE" "$GATEKEEPER_LIVENESS_LOG" "$AUTO_RESUME_STATE_FILE" "$GATEKEEPER_LIVENESS_HANDOFF_FILE"
  rm -rf "$GATEKEEPER_ROOM_ROOT"
}
# issue #37: an EXIT trap does NOT fire on SIGKILL or when the sweep shell
# is torn down mid-run, so gktest-<pid> sessions from abandoned runs used
# to pile up forever (84 found once during PR #30 cleanup). EXIT is kept
# for the clean path; INT/TERM/HUP cover the common interrupt paths and
# MUST `exit` explicitly -- a bash trap handler that returns normally
# RESUMES the script after the interrupted command (review finding on PR
# #99: a plain `trap cleanup INT TERM HUP` cleaned up, then kept running
# the rest of the suite against the torn-down environment, then cleaned
# up again -- defeating e.g. `timeout 120 bash tests/gatekeeper.test.sh`).
# cleanup is idempotent, so the EXIT-trap double-fire after this exit is
# harmless.
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# T26 VERIFY setup: count how many lines already match the leak markers
# (see the final block) in the real harness session BEFORE this run, if it
# exists on this machine. A pane's scrollback can already contain this
# text from a real incident before this fix landed (confirmed on this very
# machine -- the T19/T20 incident this ticket exists to fix left three
# "quota Claude 5h at 98%..." lines sitting in a live pane) -- so the
# check below is a before/after COUNT comparison, not "is the marker text
# present at all", which would false-positive forever on a machine with
# that kind of pre-existing contamination.
LEAK_MARKERS='follow AGENTS.md failsafe|AUTO-RESUME:|auto-resuming per AGENTS.md|gatekeeper watchdog: no heartbeat'
REAL_SESSION_EXISTS=false
REAL_LEAK_COUNT_BEFORE=0
if tmux has-session -t "$REAL_SESSION" >/dev/null 2>&1; then
  REAL_SESSION_EXISTS=true
  REAL_LEAK_COUNT_BEFORE="$(for p in 0 1 2 3 4; do tmux capture-pane -p -t "$REAL_SESSION:0.$p" 2>/dev/null; done | grep -Ec "$LEAK_MARKERS")"
fi

# issue #37: a trap alone is provably not enough (it cannot fire on
# SIGKILL), so also self-heal on the way IN -- reap any gktest-<pid>
# session whose PID suffix is no longer alive before creating ours. This
# converges the machine even after a kill no trap could catch, and never
# touches a live session (its own gktest-$$ included -- kill -0 $$ passes).
reap_orphan_sessions() {
  local s pid
  while IFS= read -r s; do
    pid="${s#gktest-}"
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -0 "$pid" 2>/dev/null || tmux kill-session -t "$s" >/dev/null 2>&1
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^gktest-')
}
reap_orphan_sessions

# Throwaway session standing in for "harness": 5 panes (0-4), matching the
# current pane map (orchestra/builder/agy/gatekeeper/watch -- issue #89
# retired pane 3), so any pane-index-specific target has somewhere valid to
# land without touching the real session.
tmux new-session -d -s "$TEST_SESSION" -n main -x 200 -y 50 >/dev/null 2>&1
for _ in 1 2 3 4; do
  tmux split-window -t "$TEST_SESSION:0" -x 200 -y 50 >/dev/null 2>&1
done
tmux select-layout -t "$TEST_SESSION:0" tiled >/dev/null 2>&1

echo "== issue #37: orphan gktest-* session reaping =="
# A dead-PID orphan (stands in for a gktest-<pid> stranded by a SIGKILLed
# run) must be reaped; the live current session (gktest-$$) must survive.
# 2147483647 (INT_MAX) is never a live PID, so `kill -0` on it always
# fails -- a deterministic, non-flaky stale marker.
ORPHAN_SESSION="gktest-2147483647"
tmux new-session -d -s "$ORPHAN_SESSION" >/dev/null 2>&1
# Assert the orphan actually exists BEFORE reaping -- without this, a
# silently-failed new-session would make the "orphan was killed" check
# below pass vacuously (green for the wrong reason).
if tmux has-session -t "$ORPHAN_SESSION" 2>/dev/null; then
  pass "dead-PID orphan fixture created ($ORPHAN_SESSION exists pre-reap)"
else
  fail "could not create the dead-PID orphan fixture $ORPHAN_SESSION"
fi
reap_orphan_sessions
if tmux has-session -t "$ORPHAN_SESSION" 2>/dev/null; then
  fail "reap_orphan_sessions left a dead-PID orphan alive"
  tmux kill-session -t "$ORPHAN_SESSION" >/dev/null 2>&1 || true
else
  pass "reap_orphan_sessions killed the dead-PID orphan"
fi
if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
  pass "reap_orphan_sessions kept the live current session (gktest-\$\$)"
else
  fail "reap_orphan_sessions wrongly killed the live current session"
fi

echo "== live OAuth usage endpoint =="
source "$GATEKEEPER" 2>/dev/null || true # BASH_SOURCE guard means the loop never runs
TOKEN="$(get_claude_token)"
if [ -z "$TOKEN" ]; then
  skip "no Claude Code credentials found (Keychain or ~/.claude/.credentials.json) -- cannot exercise the live endpoint on this machine"
else
  USAGE_JSON="$(fetch_claude_usage)"
  FIVE_HOUR="$(echo "$USAGE_JSON" | jq -r '.five_hour.utilization // empty' 2>/dev/null)"
  SEVEN_DAY="$(echo "$USAGE_JSON" | jq -r '.seven_day.utilization // empty' 2>/dev/null)"
  if [ -n "$FIVE_HOUR" ] && [ -n "$SEVEN_DAY" ]; then
    pass "live endpoint returned five_hour.utilization=$FIVE_HOUR and seven_day.utilization=$SEVEN_DAY"
  else
    fail "expected numeric five_hour/seven_day utilization from the live endpoint, got: $USAGE_JSON"
  fi
fi

echo "== gatekeeper.sh prints live percentages sourced from the endpoint =="
# T33 (issue #77): output is now a multi-line cleared-and-redrawn board
# (QUOTA/HEARTBEAT/AUTO-RESUME/LAST ALERT sections), not a single line, so
# this greps the whole one-iteration capture rather than just the first 2
# lines.
if [ -n "$TOKEN" ]; then
  OUT="$(GATEKEEPER_INTERVAL=9999 run_briefly 5 bash "$GATEKEEPER")"
  if echo "$OUT" | grep -Eq 'Claude 5h: [0-9]+% \| Claude weekly: [0-9]+% \| agy'; then
    pass "gatekeeper.sh printed a live percentage line: $(echo "$OUT" | grep -E 'Claude 5h:')"
  else
    fail "gatekeeper.sh did not print the expected percentage line: $OUT"
  fi
else
  skip "no credentials, see above"
fi

echo "== gatekeeper.sh dashboard board: sections present (QUOTA/HEARTBEAT/AUTO-RESUME/LAST ALERT) =="
if [ -n "$TOKEN" ]; then
  OUT="$(GATEKEEPER_INTERVAL=9999 run_briefly 5 bash "$GATEKEEPER")"
  MISSING=""
  for section in QUOTA HEARTBEAT AUTO-RESUME "LAST ALERT"; do
    echo "$OUT" | grep -q "== $section ==" || MISSING="$MISSING [$section]"
  done
  if [ -z "$MISSING" ]; then
    pass "all dashboard sections present"
  else
    fail "missing dashboard section(s):$MISSING -- got: $OUT"
  fi
else
  skip "no credentials, see above"
fi

echo "== gatekeeper.sh writes a heartbeat each iteration =="
# issue #86: send_submit's clear-and-retype retry (Task 1) is a strictly
# heavier path than the old bare-Enter retry it replaced -- when real usage
# is over the 80% threshold, notify() actually fires and each send_submit
# call can now take ~2.8s worst-case (vs ~1.3s before) if its confirm check
# reads a throwaway shell pane's echoed input as "still stuck". A 5s window
# was enough when notify() never fired in practice; widened so a real
# threshold-crossing alert (2 panes, possible retries) still finishes
# before the heartbeat-write line at the end of the loop body is checked.
rm -f "$GATEKEEPER_HEARTBEAT_FILE"
GATEKEEPER_INTERVAL=9999 run_briefly 10 bash "$GATEKEEPER" >/dev/null
if [ -f "$GATEKEEPER_HEARTBEAT_FILE" ]; then
  pass "gatekeeper.sh wrote the heartbeat file"
else
  fail "gatekeeper.sh did not write a heartbeat file"
fi

echo "== issue #24: liveness alerts via a durable orchestra .msg (dispatch_main), not raw send-keys text+Enter in one burst =="
# Fast intervals for a quick test: liveness checks every 1s, and considers
# the heartbeat stale after 3s of silence.
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
tmux send-keys -t "$TEST_SESSION:0.0" "clear" Enter 2>&1
echo "1" > "$GATEKEEPER_HEARTBEAT_FILE"  # an ancient (epoch=1) heartbeat -- immediately stale
GATEKEEPER_LIVENESS_INTERVAL=1 GATEKEEPER_LIVENESS_STALE_AFTER=3 \
  GATEKEEPER_LIVENESS_TARGET="$TEST_SESSION:0.0" \
  bash "$LIVENESS" >/dev/null 2>&1 &
LIVENESS_PID=$!
disown
sleep 5
CAPTURE="$(tmux capture-pane -p -t "$TEST_SESSION:0.0" 2>&1)"
ORCH_MSGS_STALE=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
if [ -e "${ORCH_MSGS_STALE[0]}" ]; then
  pass "liveness watchdog wrote a durable .msg to orchestra's inbox on a stale heartbeat"
else
  fail "expected a durable orchestra .msg for the stale heartbeat, found none"
fi
if [ -e "${ORCH_MSGS_STALE[0]}" ] && grep -q "no heartbeat" "${ORCH_MSGS_STALE[0]}" 2>/dev/null; then
  pass "the .msg contains the actual stale-heartbeat text"
else
  fail "expected the orchestra .msg to contain the stale-heartbeat text: $(cat "${ORCH_MSGS_STALE[0]}" 2>/dev/null)"
fi
if echo "$CAPTURE" | grep -q "check inbox"; then
  pass "the target pane was nudged with 'check inbox' (send_submit), not typed the raw alert text"
else
  fail "expected a 'check inbox' nudge on the target pane, got: $CAPTURE"
fi
if echo "$CAPTURE" | grep -q "gatekeeper watchdog: no heartbeat"; then
  fail "issue #24: the raw alert text should NOT be typed directly into the pane (that's the stranded-input bug) -- got: $CAPTURE"
else
  pass "issue #24: no raw alert text was typed directly into the pane"
fi
if grep -q "ALERT: gatekeeper heartbeat stale" "$GATEKEEPER_LIVENESS_LOG" 2>/dev/null; then
  pass "liveness watchdog logged the alert to its own log file (not the tracked budget.log)"
else
  fail "expected an ALERT line in the isolated liveness log"
fi
kill "$LIVENESS_PID" >/dev/null 2>&1
LIVENESS_PID=""

echo "== issue #41: gatekeeper-liveness pane-tail rate-limit heuristic =="
# Deterministic unit-style tests: stub send_meaningful_tail with a REAL
# blank-strip+tail (review round 2 finding 3: the original stub ignored its
# line-count arg entirely, proving nothing about window sizing) and the
# usage-corroboration lookup, then call gkl_check_rate_limit_stuck directly.
# RATELIMIT_WATCH_PANES resolves to a fake pane name at source time
# (DISPATCH_SESSION:0.1) but is never actually captured -- the stub
# intercepts before any tmux call happens.
GKL_RUN() { # $1 = tail text the pane 'shows', $2 = five_hour pct, $3 = seven_day pct (either empty = unknown)
  MOCK_TAIL="$1" MOCK_FIVE="$2" MOCK_SEVEN="$3" bash -c "
    source '$LIVENESS' 2>/dev/null
    send_meaningful_tail() { printf '%s\n' \"\$MOCK_TAIL\" | grep -v '^[[:space:]]*\$' | tail -\"\${2:-20}\"; }
    gkl_usage_pcts() { printf '%s %s' \"\$MOCK_FIVE\" \"\$MOCK_SEVEN\"; }
    gkl_check_rate_limit_stuck
  "
}

MOTD_TAIL=' ▎ Extended through July 19
 ▎ We are extending Claude Fable 5 access on all paid plans, as well as keeping Claude Codes weekly
 ▎ rate limits 50% higher, through July 19.

❯ '
REAL_BANNER_TAIL='5-hour limit reached
resets at 3:00 PM

❯ '
# review round 2 finding 1: banner pushed behind several CLI hint lines --
# 7 non-blank lines total, banner 7th-from-bottom. The OLD 5-line window
# missed this (confirmed red before the fix); the new 10-line window covers it.
FALSE_NEG_BANNER_TAIL='5-hour limit reached
resets at 3:00 PM
Press Enter to retry
Press Enter to retry
Press Enter to retry
Press Ctrl+C to exit

❯ '
# review round 2 (Orchestra's own concern re: widening the window): a
# banner-shaped PHRASE quoted deep in ordinary scrollback (e.g. two agents
# discussing this very bug) must not alert just because the window grew --
# 13 non-blank lines total, the quote sits 13th-from-bottom, well outside
# the 10-line window; everything within the window is unrelated/healthy.
MIDSCROLL_TAIL='Note from earlier: someone had pasted "5-hour limit reached" while discussing this exact bug.
line 2 of unrelated scrollback
line 3 of unrelated scrollback
line 4 of unrelated scrollback
line 5 of unrelated scrollback
line 6 of unrelated scrollback
line 7 of unrelated scrollback
line 8 of unrelated scrollback
line 9 of unrelated scrollback
line 10 of unrelated scrollback
line 11 of unrelated scrollback
line 12 of unrelated scrollback

❯ '

echo "-- MOTD false positive: startup promo copy must never alert (usage pinned HIGH so this is a pure regex probe, not masked by the corroboration-suppression branch) --"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
GKL_RUN "$(printf '%s' "$MOTD_TAIL")" "95" "95" >/dev/null 2>&1
MOTD_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
if [ -e "${MOTD_MSGS[0]}" ]; then
  fail "issue #41: the Anthropic startup MOTD ('...weekly rate limits 50% higher...') falsely triggered a rate-limit-stuck alert: $(cat "${MOTD_MSGS[0]}" 2>/dev/null)"
else
  pass "issue #41: startup MOTD promo copy does not trigger a rate-limit-stuck alert"
fi

echo "-- real banner + BOTH quota classes confirmed high (>=80%): alerts --"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
GKL_RUN "$(printf '%s' "$REAL_BANNER_TAIL")" "95" "95" >/dev/null 2>&1
BANNER_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
if [ -e "${BANNER_MSGS[0]}" ]; then
  pass "issue #41: a real rate-limit banner at the pane tail, corroborated by high 5h+weekly usage, alerts"
else
  fail "expected a rate-limit-stuck alert for a real banner + corroborating high usage"
fi

echo "-- real banner shape but BOTH quota classes confirmed low (0%): does NOT alert (issue #41's own example -- 'a pane at 5h:0% cannot be rate-limited whatever its text says') --"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
GKL_RUN "$(printf '%s' "$REAL_BANNER_TAIL")" "0" "0" >/dev/null 2>&1
ZEROPCT_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
if [ -e "${ZEROPCT_MSGS[0]}" ]; then
  fail "issue #41: banner-shaped text alerted even though real usage is 0% on both classes -- corroboration layer did not suppress it: $(cat "${ZEROPCT_MSGS[0]}" 2>/dev/null)"
else
  pass "issue #41: banner-shaped text at 0% usage (both classes) is treated as a false positive (no alert)"
fi

echo "-- review round 2 finding 2: five_hour LOW but weekly (seven_day) HIGH: still alerts -- a weekly-limited pane must not be suppressed by a low 5h reading --"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
GKL_RUN "$(printf '%s' "$REAL_BANNER_TAIL")" "5" "95" >/dev/null 2>&1
WEEKLY_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
if [ -e "${WEEKLY_MSGS[0]}" ]; then
  pass "issue #41: a weekly-limited pane (5h=5% weekly=95%) still alerts -- not wrongly suppressed by the low 5h reading"
else
  fail "CORRECTNESS REGRESSION (finding 2): a genuinely weekly-limited pane (5h low, weekly high) was suppressed"
fi

echo "-- real banner shape, usage UNKNOWN (fetch failed): still alerts (fail-open -- no corroborating evidence AGAINST it, backup signal errs toward alerting) --"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
GKL_RUN "$(printf '%s' "$REAL_BANNER_TAIL")" "" "" >/dev/null 2>&1
UNKNOWN_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
if [ -e "${UNKNOWN_MSGS[0]}" ]; then
  pass "issue #41: a real banner with usage corroboration unavailable still alerts (fails open, not silently swallowed)"
else
  fail "expected a rate-limit-stuck alert when usage corroboration is unavailable but the banner text is a real match"
fi

echo "-- review round 2 finding 1: a real banner pushed behind CLI hint lines (7th non-blank line from the bottom) still alerts under the widened window --"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
GKL_RUN "$(printf '%s' "$FALSE_NEG_BANNER_TAIL")" "95" "95" >/dev/null 2>&1
FALSENEG_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
if [ -e "${FALSENEG_MSGS[0]}" ]; then
  pass "issue #41: a real banner behind hint lines (7 non-blank lines deep) still alerts -- the 5-line window's false negative is fixed"
else
  fail "CORRECTNESS REGRESSION (finding 1): a real banner pushed behind CLI hint lines was missed by the tail window"
fi

echo "-- review round 2: a banner-shaped phrase quoted deep in ordinary scrollback (13 non-blank lines back) does NOT alert -- the widened window is still bounded --"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
GKL_RUN "$(printf '%s' "$MIDSCROLL_TAIL")" "95" "95" >/dev/null 2>&1
MIDSCROLL_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
if [ -e "${MIDSCROLL_MSGS[0]}" ]; then
  fail "issue #41: a rate-limit phrase quoted mid-scrollback (outside the tail window) falsely alerted even with corroborating high usage: $(cat "${MIDSCROLL_MSGS[0]}" 2>/dev/null)"
else
  pass "issue #41: a banner-shaped phrase quoted deep in scrollback, outside the tail window, does not alert"
fi
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack

echo "-- review round 2 finding A: case + dialect coverage -- real renderings the case-sensitive regex missed --"
DIALECT_WEEKLY_TAIL='Weekly limit reached . resets Jul 24

❯ '
DIALECT_TRYAGAIN_TAIL='You have reached your usage limit. Try again in 2 hours.

❯ '
for DIALECT_CASE in "DIALECT_WEEKLY_TAIL:capitalized 'Weekly limit reached'" "DIALECT_TRYAGAIN_TAIL:capitalized 'Try again in'"; do
  DIALECT_VAR="${DIALECT_CASE%%:*}"
  DIALECT_DESC="${DIALECT_CASE#*:}"
  DIALECT_TEXT="${!DIALECT_VAR}"
  rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack
  GKL_RUN "$DIALECT_TEXT" "95" "95" >/dev/null 2>&1
  DIALECT_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg)
  if [ -e "${DIALECT_MSGS[0]}" ]; then
    pass "issue #41: $DIALECT_DESC alerts (case-insensitive match)"
  else
    fail "CORRECTNESS REGRESSION (finding A): $DIALECT_DESC did not alert -- case-sensitive regex miss"
  fi
done
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*rate-limit-stuck*.ack

echo "== review round 2 finding B: gkl_usage_pcts's subshell must not leak gatekeeper.sh's own EXIT trap into the real/tracked budget.log =="
# gatekeeper.sh registers `trap gk_log_exit EXIT` unconditionally at source
# time (not gated behind its own BASH_SOURCE guard) -- exercised here
# WITHOUT stubbing gkl_usage_pcts (unlike every test above) so the real
# subshell-source path actually runs. A PATH-stubbed curl stands in for the
# network call, same idiom as the issue #105 mocked-crossing tests above.
GKL_FAKE_BIN="$(mktemp -d)"
cat > "$GKL_FAKE_BIN/curl" <<'FAKECURL'
#!/bin/bash
echo '{"five_hour":{"utilization":42},"seven_day":{"utilization":7}}'
FAKECURL
chmod +x "$GKL_FAKE_BIN/curl"
GKL_FAKE_HOME="$GKL_FAKE_BIN/home"
mkdir -p "$GKL_FAKE_HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}' > "$GKL_FAKE_HOME/.claude/.credentials.json"
: > "$GATEKEEPER_BUDGET_LOG"
GKL_REAL_RESULT="$(PATH="$GKL_FAKE_BIN:$PATH" HOME="$GKL_FAKE_HOME" bash -c "source '$LIVENESS' 2>/dev/null; gkl_usage_pcts")"
if [ "$GKL_REAL_RESULT" = "42 7" ]; then
  pass "gkl_usage_pcts returns the real five_hour/seven_day pair from a mocked fetch (42 7)"
else
  fail "expected gkl_usage_pcts to return '42 7', got '$GKL_REAL_RESULT'"
fi
if grep -q "GATEKEEPER EXIT" "$GATEKEEPER_BUDGET_LOG" 2>/dev/null; then
  fail "REGRESSION (finding B): gkl_usage_pcts's subshell leaked a phantom 'GATEKEEPER EXIT' line into budget.log: $(cat "$GATEKEEPER_BUDGET_LOG")"
else
  pass "gkl_usage_pcts's subshell does not leak a phantom EXIT-trap line into budget.log"
fi
rm -rf "$GKL_FAKE_BIN"

echo "== regression (Ahmad fold-in, PR#17 rework finding 6): an EMPTY heartbeat file (mid-write race) does NOT produce a false death alert =="
# The confirmed live incident: gatekeeper.sh's non-atomic `date +%s >
# "$HEARTBEAT"` truncates the file before writing, and a reader that
# lands in that window sees an EMPTY string with a SUCCESSFUL `cat` --
# the old `|| echo 0` fallback only fires on a `cat` FAILURE, so it never
# caught this, and bash arithmetic silently treats "" as 0, making
# age ~= now (~1.78 billion seconds) -- always past any real
# STALE_AFTER. This reproduces the empty-file case directly (no need to
# actually race gatekeeper.sh's writer) and confirms it's now a no-op
# tick, not a false alert.
: > "$GATEKEEPER_HEARTBEAT_FILE"  # empty, not missing -- the exact race condition
: > "$GATEKEEPER_LIVENESS_LOG"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
GATEKEEPER_LIVENESS_INTERVAL=1 GATEKEEPER_LIVENESS_STALE_AFTER=3 \
  GATEKEEPER_LIVENESS_TARGET="$TEST_SESSION:0.0" \
  bash "$LIVENESS" >/dev/null 2>&1 &
LIVENESS_PID=$!
disown
sleep 4
kill "$LIVENESS_PID" >/dev/null 2>&1
LIVENESS_PID=""
ORCH_MSGS_EMPTY=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
if [ -e "${ORCH_MSGS_EMPTY[0]}" ]; then
  fail "SECURITY/RELIABILITY REGRESSION (finding 6): an empty heartbeat file produced a false death alert .msg: $(cat "${ORCH_MSGS_EMPTY[0]}" 2>/dev/null)"
else
  pass "an empty heartbeat file produces NO false alert (skips the tick instead of treating '' as epoch 0)"
fi
if grep -q "heartbeat file empty/non-numeric this tick" "$GATEKEEPER_LIVENESS_LOG" 2>/dev/null; then
  pass "the skipped tick was logged for diagnosability (not a silent no-op)"
else
  fail "expected a debug log line explaining the skipped tick"
fi

echo "== regression (finding 6): a genuinely-old but VALID numeric heartbeat still alerts (the fix doesn't over-correct) =="
echo "1" > "$GATEKEEPER_HEARTBEAT_FILE"  # ancient (epoch=1) -- a real, valid, stale heartbeat
: > "$GATEKEEPER_LIVENESS_LOG"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
GATEKEEPER_LIVENESS_INTERVAL=1 GATEKEEPER_LIVENESS_STALE_AFTER=3 \
  GATEKEEPER_LIVENESS_TARGET="$TEST_SESSION:0.0" \
  bash "$LIVENESS" >/dev/null 2>&1 &
LIVENESS_PID=$!
disown
sleep 4
kill "$LIVENESS_PID" >/dev/null 2>&1
LIVENESS_PID=""
ORCH_MSGS_VALID=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
if [ -e "${ORCH_MSGS_VALID[0]}" ]; then
  pass "a genuinely stale, validly-numeric heartbeat still triggers a real alert .msg"
else
  fail "the empty-heartbeat fix over-corrected -- a real stale heartbeat should still alert"
fi

echo "== liveness: does NOT warn while the heartbeat stays fresh =="
: > "$GATEKEEPER_LIVENESS_LOG"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
date +%s > "$GATEKEEPER_HEARTBEAT_FILE"
( while true; do date +%s > "$GATEKEEPER_HEARTBEAT_FILE"; sleep 1; done ) &
REFRESHER_PID=$!
disown
GATEKEEPER_LIVENESS_INTERVAL=1 GATEKEEPER_LIVENESS_STALE_AFTER=3 \
  GATEKEEPER_LIVENESS_TARGET="$TEST_SESSION:0.0" \
  bash "$LIVENESS" >/dev/null 2>&1 &
LIVENESS_PID=$!
disown
sleep 5
kill "$REFRESHER_PID" >/dev/null 2>&1
kill "$LIVENESS_PID" >/dev/null 2>&1
LIVENESS_PID=""
ORCH_MSGS_FRESH=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
if [ -e "${ORCH_MSGS_FRESH[0]}" ]; then
  fail "liveness watchdog alerted even though the heartbeat stayed fresh: $(cat "${ORCH_MSGS_FRESH[0]}" 2>/dev/null)"
else
  pass "liveness watchdog stayed quiet while the heartbeat stayed fresh"
fi

echo "== liveness: this is literally 'kill gatekeeper -> warning appears' =="
rm -f "$GATEKEEPER_HEARTBEAT_FILE"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
GATEKEEPER_INTERVAL=2 bash "$GATEKEEPER" >/dev/null 2>&1 &
GATEKEEPER_PID=$!
disown
sleep 8 # let it write at least one real heartbeat (see #86 note above on notify() timing)
if [ ! -f "$GATEKEEPER_HEARTBEAT_FILE" ]; then
  fail "gatekeeper.sh (live) never wrote a heartbeat before the kill"
else
  kill "$GATEKEEPER_PID"
  wait "$GATEKEEPER_PID" 2>/dev/null
  GATEKEEPER_PID=""
  GATEKEEPER_LIVENESS_INTERVAL=1 GATEKEEPER_LIVENESS_STALE_AFTER=3 \
    GATEKEEPER_LIVENESS_TARGET="$TEST_SESSION:0.0" \
    bash "$LIVENESS" >/dev/null 2>&1 &
  LIVENESS_PID=$!
  disown
  sleep 6
  kill "$LIVENESS_PID" >/dev/null 2>&1
  LIVENESS_PID=""
  ORCH_MSGS_KILLED=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
  if [ -e "${ORCH_MSGS_KILLED[0]}" ]; then
    pass "killing the real gatekeeper.sh process -> liveness warning .msg appeared"
  else
    fail "killing gatekeeper.sh should have produced a liveness warning .msg"
  fi
fi

# issue #105 Tasks 1/2/3/4: a deterministic mocked usage crossing, driven
# through REAL `bash "$GATEKEEPER"` subprocess invocations (not a
# backgrounded function call in this shell -- GK_VOICE/BUDGET_LOG/etc. are
# all resolved ONCE at source time, so an env-var prefix on a function call
# in an already-sourced shell has no effect; only a fresh subprocess
# re-reads them). PATH-stubbed `curl`/`say` intercept the network call and
# the audible speech respectively -- CURL_MOCK_JSON_FILE holds whatever
# canned usage JSON the current test section wants, so it can be
# rewritten between invocations to simulate a crossing, a restart with the
# same crossing still active, and a drop back below the re-arm threshold.
FAKE_BIN="$(mktemp -d)"
CURL_MOCK_JSON_FILE="$FAKE_BIN/mock-usage.json"
SAY_CALLS="$FAKE_BIN/say-calls.log"
: > "$SAY_CALLS"
cat > "$FAKE_BIN/curl" <<'FAKECURL'
#!/bin/bash
cat "$CURL_MOCK_JSON_FILE"
FAKECURL
cat > "$FAKE_BIN/say" <<'FAKESAY'
#!/bin/bash
echo "$*" >> "$SAY_CALLS_FILE"
FAKESAY
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/say"

# get_claude_token tries macOS Keychain first (silently no-ops on Linux --
# no `security` binary), then falls back to $HOME/.claude/.credentials.json.
# fetch_claude_usage returns immediately (never even calling the mocked
# curl above) if that token is empty -- on a dev machine with real Claude
# Code credentials in Keychain this always happened to succeed by
# accident, but a CI runner has neither, silently no-oping the entire
# mocked-crossing section below. FAKE_HOME's dummy credentials file makes
# this section run the same everywhere, with no real token ever needed
# since curl itself is mocked and never inspects it.
FAKE_HOME="$FAKE_BIN/home"
mkdir -p "$FAKE_HOME/.claude"
echo '{"claudeAiOauth":{"accessToken":"test-token-not-real"}}' > "$FAKE_HOME/.claude/.credentials.json"

gk_mocked_run() { # $1 = seconds to run, $2 = usage JSON, $3.. = extra env assignments
  local secs="$1" json="$2"; shift 2
  echo "$json" > "$CURL_MOCK_JSON_FILE"
  env "$@" PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" CURL_MOCK_JSON_FILE="$CURL_MOCK_JSON_FILE" SAY_CALLS_FILE="$SAY_CALLS" \
    GATEKEEPER_INTERVAL=9999 bash "$GATEKEEPER" >/dev/null 2>&1 &
  GATEKEEPER_PID=$!
  sleep "$secs"
  kill "$GATEKEEPER_PID" >/dev/null 2>&1
  wait "$GATEKEEPER_PID" 2>/dev/null
  GATEKEEPER_PID=""
}

CROSSED_85='{"five_hour":{"utilization":85,"resets_at":"2026-07-11T00:00:00Z"},"seven_day":{"utilization":5}}'
DROPPED_10='{"five_hour":{"utilization":10,"resets_at":"2026-07-11T00:00:00Z"},"seven_day":{"utilization":5}}'

echo "== issue #105 Task 1/2: threshold crossing writes exactly one durable orchestra .msg, no Builder keystrokes =="
: > "$GATEKEEPER_BUDGET_LOG"
rm -f "$GATEKEEPER_ALERT_STATE_FILE" "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
gk_mocked_run 4 "$CROSSED_85"

ORCH_MSGS=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
if [ -e "${ORCH_MSGS[0]}" ] && [ "${#ORCH_MSGS[@]}" -eq 1 ]; then
  pass "exactly one durable .msg landed in orchestra's inbox for the crossing"
else
  fail "expected exactly one orchestra .msg, got: ${ORCH_MSGS[*]}"
fi
if grep -q "quota Claude 5h at 85%" "${ORCH_MSGS[0]}" 2>/dev/null; then
  pass "the .msg contains the actual quota message"
else
  fail "expected the orchestra .msg to contain the quota text: $(cat "${ORCH_MSGS[0]}" 2>/dev/null)"
fi
if tmux capture-pane -p -t "$TEST_SESSION:0.1" 2>/dev/null | grep -q "quota Claude 5h"; then
  fail "Builder's pane (0.1) should NEVER receive direct alert keystrokes"
else
  pass "Builder's pane received no direct alert keystrokes (Orchestra-only, issue #105 Task 2)"
fi
if tmux capture-pane -p -t "$TEST_SESSION:0.0" 2>/dev/null | grep -q "check inbox"; then
  pass "Orchestra's pane was nudged to check its inbox (not typed the raw quota text)"
else
  fail "expected Orchestra's pane to be nudged with 'check inbox'"
fi

echo "== issue #105 Task 1: persisted alert state survives a gatekeeper restart (no re-alert) =="
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
gk_mocked_run 4 "$CROSSED_85"
ORCH_MSGS_AFTER_RESTART=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
if [ ! -e "${ORCH_MSGS_AFTER_RESTART[0]}" ]; then
  pass "restarting gatekeeper with the SAME crossing still active did not re-alert (persisted state survived the restart)"
else
  fail "gatekeeper should not re-alert an already-alerted, still-active crossing after a restart: ${ORCH_MSGS_AFTER_RESTART[*]}"
fi

echo "== issue #105: re-arm clears persisted state once usage drops back below 50% =="
gk_mocked_run 4 "$DROPPED_10"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
gk_mocked_run 4 "$CROSSED_85"
ORCH_MSGS_AFTER_REARM=("$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg)
if [ -e "${ORCH_MSGS_AFTER_REARM[0]}" ]; then
  pass "claude_5h re-armed after dropping below 50% -- the next crossing alerted again"
else
  fail "expected a fresh alert after re-arm + a new crossing"
fi

echo "== issue #105 Task 4: voice is OFF by default -- no 'say' call on a real crossing =="
: > "$SAY_CALLS"
rm -f "$GATEKEEPER_ALERT_STATE_FILE" "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
gk_mocked_run 4 "$CROSSED_85"
if [ -s "$SAY_CALLS" ]; then
  fail "voice defaults to off -- 'say' should not have been called: $(cat "$SAY_CALLS")"
else
  pass "voice off by default: no 'say' call on a real 80%+ crossing"
fi

echo "== issue #105 Task 4: voice on speaks once per crossing =="
: > "$SAY_CALLS"
rm -f "$GATEKEEPER_ALERT_STATE_FILE" "$DISPATCH_CANON_DIR"/inbox/orchestra/*.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*.ack
gk_mocked_run 4 "$CROSSED_85" GATEKEEPER_VOICE=on
SAY_COUNT="$(wc -l < "$SAY_CALLS" | tr -d ' ')"
if [ "$SAY_COUNT" = "1" ]; then
  pass "voice on: 'say' was called exactly once for the crossing"
else
  fail "expected exactly 1 'say' call with voice on, got $SAY_COUNT: $(cat "$SAY_CALLS")"
fi

echo "== issue #105 Task 3: EXIT trap logs the exit reason to budget.log =="
: > "$GATEKEEPER_BUDGET_LOG"
rm -f "$GATEKEEPER_ALERT_STATE_FILE"
gk_mocked_run 3 "$DROPPED_10"
if grep -q "GATEKEEPER EXIT" "$GATEKEEPER_BUDGET_LOG"; then
  pass "gatekeeper logged its exit reason to budget.log"
else
  fail "expected a 'GATEKEEPER EXIT' line in budget.log: $(cat "$GATEKEEPER_BUDGET_LOG")"
fi
rm -rf "$FAKE_BIN"

echo "== T26: notify() targets the throwaway session, never a hardcoded 'harness' =="
if grep -Eq '"harness:0\.' "$GATEKEEPER"; then
  fail "gatekeeper.sh still hardcodes the real 'harness' session somewhere"
else
  pass "gatekeeper.sh contains no hardcoded 'harness:0.N' pane target"
fi

echo "== issue #19 follow-up: gatekeeper-liveness.sh / gatekeeper.sh DEFAULTS (no override) derive from THIS project's orchestrator.yaml, not 'harness' =="
# Unlike every other block in this file (which pins GATEKEEPER_LIVENESS_TARGET
# / GATEKEEPER_NOTIFY_SESSION / GATEKEEPER_CANON_DIR to a throwaway session so
# a real 80%+ crossing during a test run can't reach the real "harness"
# session), THIS block specifically tests what the DEFAULT resolves to when
# none of those are set -- the exact gap the bug #19 follow-up flagged.
# Two different projects (own orchestrator.yaml, own cwd) must resolve to
# two DIFFERENT session defaults, same two-session-isolation shape as
# dispatch.test.sh's own issue #19 regression case.
PROJECT_C="$(mktemp -d)"
PROJECT_D="$(mktemp -d)"
echo "project: project-c" > "$PROJECT_C/orchestrator.yaml"
echo "project: project-d" > "$PROJECT_D/orchestrator.yaml"

LIVENESS_TARGET_C="$(cd "$PROJECT_C" && env -u GATEKEEPER_LIVENESS_TARGET -u GATEKEEPER_CANON_DIR -u DISPATCH_CANON_DIR -u DISPATCH_SESSION -u ORC_PROJECT_ROOT bash -c "source '$LIVENESS'; echo \"\$TARGET\"" 2>&1)"
LIVENESS_TARGET_D="$(cd "$PROJECT_D" && env -u GATEKEEPER_LIVENESS_TARGET -u GATEKEEPER_CANON_DIR -u DISPATCH_CANON_DIR -u DISPATCH_SESSION -u ORC_PROJECT_ROOT bash -c "source '$LIVENESS'; echo \"\$TARGET\"" 2>&1)"

if [ "$LIVENESS_TARGET_C" = "project-c:0.0" ]; then
  pass "gatekeeper-liveness.sh's default TARGET derives from project-c's own orchestrator.yaml"
else
  fail "expected project-c:0.0, got $LIVENESS_TARGET_C"
fi
if [ -n "$LIVENESS_TARGET_C" ] && [ "$LIVENESS_TARGET_C" != "$LIVENESS_TARGET_D" ]; then
  pass "gatekeeper-liveness.sh's default TARGET differs between two projects (never collides on 'harness:0.0')"
else
  fail "CORRECTNESS REGRESSION (issue #19 follow-up): two projects resolved to the same liveness TARGET ($LIVENESS_TARGET_C / $LIVENESS_TARGET_D)"
fi

NOTIFY_SESSION_C="$(cd "$PROJECT_C" && env -u GATEKEEPER_NOTIFY_SESSION -u GATEKEEPER_CANON_DIR -u DISPATCH_CANON_DIR -u DISPATCH_SESSION -u ORC_PROJECT_ROOT bash -c "source '$GATEKEEPER'; echo \"\$NOTIFY_SESSION\"" 2>&1)"
NOTIFY_SESSION_D="$(cd "$PROJECT_D" && env -u GATEKEEPER_NOTIFY_SESSION -u GATEKEEPER_CANON_DIR -u DISPATCH_CANON_DIR -u DISPATCH_SESSION -u ORC_PROJECT_ROOT bash -c "source '$GATEKEEPER'; echo \"\$NOTIFY_SESSION\"" 2>&1)"

if [ "$NOTIFY_SESSION_C" = "project-c" ]; then
  pass "gatekeeper.sh's default NOTIFY_SESSION derives from project-c's own orchestrator.yaml"
else
  fail "expected project-c, got $NOTIFY_SESSION_C"
fi
if [ -n "$NOTIFY_SESSION_C" ] && [ "$NOTIFY_SESSION_C" != "$NOTIFY_SESSION_D" ]; then
  pass "gatekeeper.sh's default NOTIFY_SESSION differs between two projects (never collides on 'harness')"
else
  fail "CORRECTNESS REGRESSION (issue #19 follow-up): two projects resolved to the same NOTIFY_SESSION ($NOTIFY_SESSION_C / $NOTIFY_SESSION_D)"
fi
rm -rf "$PROJECT_C" "$PROJECT_D"

echo "== T26 VERIFY: zero traffic reached the real harness session across this entire run =="
# A before/after COUNT of leak-marker lines, not a byte-exact snapshot diff
# and not a bare presence check:
# - Not exact-match: the real panes are live, active agent sessions that
#   redraw their own UI independently (cursor blink, spinners, a live
#   token/context counter) regardless of anything this test does, so an
#   exact-match comparison is a guaranteed false positive.
# - Not bare presence: this machine's panes can already contain this text
#   from a real PRIOR incident (confirmed -- the T19/T20 incident this
#   ticket exists to fix left "quota Claude 5h at 98%..." lines sitting
#   live in a pane), so "is the marker present at all" would false-positive
#   forever on a contaminated machine regardless of whether THIS run leaked
#   anything new. Comparing the COUNT catches a genuinely new leak (the
#   count goes up) while tolerating old, already-there contamination.
if [ "$REAL_SESSION_EXISTS" = true ]; then
  REAL_LEAK_COUNT_AFTER="$(for p in 0 1 2 3 4; do tmux capture-pane -p -t "$REAL_SESSION:0.$p" 2>/dev/null; done | grep -Ec "$LEAK_MARKERS")"
  if [ "$REAL_LEAK_COUNT_AFTER" -gt "$REAL_LEAK_COUNT_BEFORE" ]; then
    fail "new gatekeeper/auto-resume alert text appeared in the real harness session's panes (before=$REAL_LEAK_COUNT_BEFORE after=$REAL_LEAK_COUNT_AFTER) -- this test leaked into it"
  else
    pass "no NEW gatekeeper/auto-resume/liveness alert text appeared in the real harness session's panes (before=$REAL_LEAK_COUNT_BEFORE after=$REAL_LEAK_COUNT_AFTER)"
  fi
else
  skip "no real 'harness' tmux session found on this machine to verify against"
fi

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

echo "== issue #60 task D: gatekeeper ROOM dashboard + once-per-crossing alert =="
# Hermetic: real throwaway git repos, never the room's own checkout. Every
# invocation below sources gatekeeper.sh in a FRESH bash -c process (same
# idiom orc.test.sh uses for orc_build_session) rather than sourcing it
# into THIS test script -- gatekeeper.sh's own `set -uo pipefail` would
# otherwise leak into the rest of this file's shell.
rb_gk_mk_repo() {
  local dir
  dir="$(mktemp -d)"
  dir="$(cd "$dir" && pwd -P)"
  git init -q "$dir"
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "test"
  printf 'project: gk-room-test\nintegration_branch: uat\n' > "$dir/orchestrator.yaml"
  echo "$dir"
}

RB_GK_OK_REPO="$(rb_gk_mk_repo)"
git -C "$RB_GK_OK_REPO" checkout -q -b uat
git -C "$RB_GK_OK_REPO" add orchestrator.yaml
git -C "$RB_GK_OK_REPO" commit -q -m init
RB_GK_OK_HEAD="$(git -C "$RB_GK_OK_REPO" rev-parse --short HEAD)"
RB_GK_OK_STATE="$(mktemp)"; rm -f "$RB_GK_OK_STATE"
RB_GK_OK_INBOX_BEFORE=$(ls "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.msg 2>/dev/null | wc -l | tr -d ' ')
RB_GK_OK_OUT="$(GATEKEEPER_ALERT_STATE_FILE="$RB_GK_OK_STATE" GATEKEEPER_ROOM_ROOT="$RB_GK_OK_REPO" \
  bash -c "source '$GATEKEEPER'; gk_check_room_branch; USAGE_PCT=0; WEEKLY_PCT=0; AGY_PCT=0; HEARTBEAT_AGE=''; gatekeeper_render")"
RB_GK_OK_INBOX_AFTER=$(ls "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.msg 2>/dev/null | wc -l | tr -d ' ')
echo "$RB_GK_OK_OUT" | grep -q "== ROOM ==" && pass "ROOM section present on the dashboard" || fail "expected a ROOM section: $RB_GK_OK_OUT"
echo "$RB_GK_OK_OUT" | grep -q "$RB_GK_OK_HEAD" && pass "ROOM section shows the short HEAD when on the integration branch" || fail "expected short HEAD '$RB_GK_OK_HEAD': $RB_GK_OK_OUT"
assert_eq "on integration branch: no room-branch alert dispatched" "$RB_GK_OK_INBOX_BEFORE" "$RB_GK_OK_INBOX_AFTER"
rm -rf "$RB_GK_OK_REPO" "$RB_GK_OK_STATE"

RB_GK_MISMATCH_REPO="$(rb_gk_mk_repo)"
git -C "$RB_GK_MISMATCH_REPO" checkout -q -b uat
git -C "$RB_GK_MISMATCH_REPO" add orchestrator.yaml
git -C "$RB_GK_MISMATCH_REPO" commit -q -m init
git -C "$RB_GK_MISMATCH_REPO" checkout -q -b feature/rb-gk-mismatch
RB_GK_MISMATCH_HEAD="$(git -C "$RB_GK_MISMATCH_REPO" rev-parse --short HEAD)"
RB_GK_MISMATCH_STATE="$(mktemp)"; rm -f "$RB_GK_MISMATCH_STATE"
rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.ack

RB_GK_MISMATCH_OUT1="$(GATEKEEPER_ALERT_STATE_FILE="$RB_GK_MISMATCH_STATE" GATEKEEPER_ROOM_ROOT="$RB_GK_MISMATCH_REPO" \
  bash -c "source '$GATEKEEPER'; gk_check_room_branch; USAGE_PCT=0; WEEKLY_PCT=0; AGY_PCT=0; HEARTBEAT_AGE=''; gatekeeper_render")"
RB_GK_MISMATCH_MSGCOUNT1=$(ls "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.msg 2>/dev/null | wc -l | tr -d ' ')
echo "$RB_GK_MISMATCH_OUT1" | grep -qi "mismatch" && pass "ROOM section flags a branch mismatch" || fail "expected 'mismatch' in ROOM section: $RB_GK_MISMATCH_OUT1"
assert_eq "first mismatch tick dispatches exactly one durable alert" "1" "$RB_GK_MISMATCH_MSGCOUNT1"

# Second tick, SAME alert-state file, still mismatched -- once-per-crossing
# means no second .msg.
GATEKEEPER_ALERT_STATE_FILE="$RB_GK_MISMATCH_STATE" GATEKEEPER_ROOM_ROOT="$RB_GK_MISMATCH_REPO" \
  bash -c "source '$GATEKEEPER'; gk_check_room_branch" >/dev/null
RB_GK_MISMATCH_MSGCOUNT2=$(ls "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.msg 2>/dev/null | wc -l | tr -d ' ')
assert_eq "still mismatched second tick: no additional alert (once-per-crossing)" "1" "$RB_GK_MISMATCH_MSGCOUNT2"

# Return to the integration branch -- re-arms the alert (persisted state
# flips back to not-alerted).
git -C "$RB_GK_MISMATCH_REPO" checkout -q uat
GATEKEEPER_ALERT_STATE_FILE="$RB_GK_MISMATCH_STATE" GATEKEEPER_ROOM_ROOT="$RB_GK_MISMATCH_REPO" \
  bash -c "source '$GATEKEEPER'; gk_check_room_branch" >/dev/null
RB_GK_REARMED="$(jq -r '.room_branch.alerted // false' "$RB_GK_MISMATCH_STATE")"
assert_eq "back on integration branch: alert state re-arms (alerted=false)" "false" "$RB_GK_REARMED"

# Cross back to a mismatch -- re-armed state means a FRESH alert fires.
git -C "$RB_GK_MISMATCH_REPO" checkout -q feature/rb-gk-mismatch
GATEKEEPER_ALERT_STATE_FILE="$RB_GK_MISMATCH_STATE" GATEKEEPER_ROOM_ROOT="$RB_GK_MISMATCH_REPO" \
  bash -c "source '$GATEKEEPER'; gk_check_room_branch" >/dev/null
RB_GK_MISMATCH_MSGCOUNT3=$(ls "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.msg 2>/dev/null | wc -l | tr -d ' ')
assert_eq "re-crossing into mismatch after a re-arm fires a fresh alert" "2" "$RB_GK_MISMATCH_MSGCOUNT3"

rm -f "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.msg "$DISPATCH_CANON_DIR"/inbox/orchestra/*-room-branch.ack
rm -rf "$RB_GK_MISMATCH_REPO" "$RB_GK_MISMATCH_STATE"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
