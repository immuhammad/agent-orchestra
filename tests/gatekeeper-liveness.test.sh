#!/bin/bash
# tests/gatekeeper-liveness.test.sh -- issue #155: two false stale-heartbeat
# FLAGs in two days, same root class -- a wall-clock GAP (system suspend,
# room downtime) makes a healthy gatekeeper.sh look dead to the watchdog's
# staleness check, because the watchdog's OWN sleep pauses across the exact
# same gap. Run: bash tests/gatekeeper-liveness.test.sh
#
# Black-box against the REAL `bash lib/gatekeeper-liveness.sh` entrypoint
# (background process + real timing, same style as
# tests/gatekeeper-supervisor.test.sh) rather than calling an internal
# function directly -- these tests describe the desired BEHAVIOR (does a
# FLAG land in orchestra's inbox, does budget.log show an ALERT line) and
# are agnostic to whatever internal refactor the fix uses. Run against the
# pre-fix script, both incident-shape tests below fail (red): the current
# code alerts on the very first stale tick with no gap-awareness at all.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIVENESS="$DIR/../lib/gatekeeper-liveness.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

WATCHDOG_PID=""
cleanup() {
  [ -n "$WATCHDOG_PID" ] && kill -CONT "$WATCHDOG_PID" >/dev/null 2>&1
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" >/dev/null 2>&1
  wait "$WATCHDOG_PID" 2>/dev/null
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# start_watchdog -- launches the real entrypoint against a fresh scratch
# inbox, tiny/fast-for-tests intervals, and a nonexistent tmux target (so
# nudge_agent's `tmux has-session` check no-ops instead of erroring). The
# rate-limit-stuck sub-check is pushed out to effectively never, so its own
# dispatch_main calls can't be confused with the heartbeat-staleness alert
# this suite actually watches for.
start_watchdog() {
  GATEKEEPER_HEARTBEAT_FILE="$HEARTBEAT" \
  GATEKEEPER_LIVENESS_LOG="$LOG" \
  GATEKEEPER_LIVENESS_INTERVAL="$CHECK_INTERVAL" \
  GATEKEEPER_LIVENESS_STALE_AFTER="$STALE_AFTER" \
  GATEKEEPER_LIVENESS_GAP_THRESHOLD="$GAP_THRESHOLD" \
  GATEKEEPER_LIVENESS_GAP_GRACE="$GAP_GRACE" \
  GATEKEEPER_LIVENESS_TARGET="nonexistent-test-session:0.0" \
  GATEKEEPER_LIVENESS_RATELIMIT_INTERVAL=999999 \
  DISPATCH_CANON_DIR="$SCRATCH" \
  bash "$LIVENESS" >"$SCRATCH/stdout.log" 2>&1 &
  WATCHDOG_PID=$!
}

stop_watchdog() {
  kill -CONT "$WATCHDOG_PID" >/dev/null 2>&1
  kill "$WATCHDOG_PID" >/dev/null 2>&1
  wait "$WATCHDOG_PID" 2>/dev/null
  WATCHDOG_PID=""
}

alert_count() { grep -c 'ALERT: gatekeeper heartbeat stale' "$LOG" 2>/dev/null || true; }
msg_count() { find "$SCRATCH/inbox/orchestra" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }

# Fast-for-tests timing, generous margins over normal cadence so ordinary
# CI scheduling jitter on a 2s tick never looks like a real gap (only a
# genuine >=8s freeze -- simulated below via SIGSTOP/SIGCONT -- should).
CHECK_INTERVAL=2
STALE_AFTER=5
GAP_THRESHOLD=8
GAP_GRACE=10

echo "== incident 1 shape: fresh watchdog start sees an already-ancient heartbeat (room-downtime rebuild) -- must not alert on tick 1, and self-heals silently if gatekeeper.sh writes fresh within the grace window =="
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/inbox/orchestra"
HEARTBEAT="$SCRATCH/gatekeeper.heartbeat"
LOG="$SCRATCH/budget.log"
: > "$LOG"
echo $(( $(date +%s) - 100000 )) > "$HEARTBEAT"
start_watchdog
sleep 2
if [ "$(alert_count)" -eq 0 ] && [ "$(msg_count)" -eq 0 ]; then
  pass "incident 1: no alert on the watchdog's very first tick despite a 100000s-old heartbeat"
else
  fail "incident 1: expected no alert yet, got $(alert_count) ALERT line(s) / $(msg_count) inbox msg(s): $(cat "$LOG")"
fi
# Simulate a real gatekeeper.sh: refresh the heartbeat repeatedly rather
# than a single write, since a genuinely alive process keeps doing this --
# a one-off write would legitimately go stale again under this test's
# compressed STALE_AFTER and isn't what "self-heals" is meant to exercise.
for _ in 1 2 3 4 5; do
  date +%s > "$HEARTBEAT"
  sleep 2
done
if [ "$(alert_count)" -eq 0 ] && [ "$(msg_count)" -eq 0 ]; then
  pass "incident 1: never alerts once gatekeeper.sh's fresh heartbeat lands inside the grace window"
else
  fail "incident 1: expected zero alerts across the run, got $(alert_count) ALERT line(s) / $(msg_count) inbox msg(s): $(cat "$LOG")"
fi
stop_watchdog

echo "== incident 2 shape: watchdog itself gets frozen mid-run (system suspend) -- its first post-wake tick must not trust the resulting stale reading =="
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/inbox/orchestra"
HEARTBEAT="$SCRATCH/gatekeeper.heartbeat"
LOG="$SCRATCH/budget.log"
: > "$LOG"
date +%s > "$HEARTBEAT"
start_watchdog
sleep 3
if [ "$(alert_count)" -eq 0 ]; then
  pass "incident 2: healthy before the simulated suspend (sanity check)"
else
  fail "incident 2: should not have alerted yet before any gap: $(cat "$LOG")"
fi
kill -STOP "$WATCHDOG_PID"
sleep 12
kill -CONT "$WATCHDOG_PID"
sleep 2
if [ "$(alert_count)" -eq 0 ] && [ "$(msg_count)" -eq 0 ]; then
  pass "incident 2: no alert on the first post-wake tick, even though the heartbeat now reads well past STALE_AFTER"
else
  fail "incident 2: expected the post-wake tick to be suppressed (this is the exact false-alarm tick from the real incident), got $(alert_count) ALERT line(s) / $(msg_count) inbox msg(s): $(cat "$LOG")"
fi
for _ in 1 2 3; do
  date +%s > "$HEARTBEAT"
  sleep 2
done
if [ "$(alert_count)" -eq 0 ] && [ "$(msg_count)" -eq 0 ]; then
  pass "incident 2: never alerts once gatekeeper.sh's delayed post-wake heartbeat lands inside the grace window"
else
  fail "incident 2: expected zero alerts across the run, got $(alert_count) ALERT line(s) / $(msg_count) inbox msg(s): $(cat "$LOG")"
fi
stop_watchdog

echo "== regression: a genuinely dead gatekeeper.sh (heartbeat stale, no gap in the watchdog's own cadence at all) still alerts promptly, exactly once =="
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/inbox/orchestra"
HEARTBEAT="$SCRATCH/gatekeeper.heartbeat"
LOG="$SCRATCH/budget.log"
: > "$LOG"
date +%s > "$HEARTBEAT"
start_watchdog
# Heartbeat is never refreshed again -- simulates gatekeeper.sh dying, with
# the watchdog itself ticking normally throughout (no SIGSTOP anywhere in
# this case), so no gap grace should ever apply.
sleep 8
if [ "$(alert_count)" -eq 1 ] && [ "$(msg_count)" -eq 1 ]; then
  pass "regression: a genuinely dead gatekeeper still alerts (no gap grace applied when there was no gap)"
else
  fail "regression: expected exactly 1 alert within 8s of real staleness, got $(alert_count) ALERT line(s) / $(msg_count) inbox msg(s): $(cat "$LOG")"
fi
sleep 3
if [ "$(alert_count)" -eq 1 ]; then
  pass "regression: the alert dedups -- still exactly 1 after more stale ticks"
else
  fail "regression: expected dedup to hold at 1 alert, got $(alert_count): $(cat "$LOG")"
fi
stop_watchdog

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
