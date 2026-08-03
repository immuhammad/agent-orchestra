#!/bin/bash
# tests/gatekeeper-quota-gate.test.sh -- #173 quota-gate coverage audit:
# verifies agy's OWN standalone threshold crossing actually writes the
# shared quota-stop flag (the real PreToolUse enforcement both
# hooks/quota-stop-gate.sh and lib/guard-quota-stop-agy.sh read), not just
# an advisory alert. Every OTHER threshold branch in gatekeeper.sh's main
# loop already did this (Claude 5h, weekly, both) -- the standalone "agy
# over" branch was the one gap, found auditing lib/gatekeeper.sh's
# budgets.agy.failsafe_pct wiring against the Claude lanes' quota-stop-gate
# (Gate-1 plan item 4). Fixed by adding the same ar_write_quota_stop_flag
# call the other branches already make.
#
# gatekeeper.sh's main loop has no other existing unit-test seam (it's a
# single `while true` body, never previously exercised outside
# gatekeeper-supervisor.test.sh's crash-loop respawn wrapper) -- this test
# runs the REAL gatekeeper_main in the background for a couple of ticks
# (GATEKEEPER_INTERVAL=1) against a scratch project root, then kills it,
# same background+sleep+kill pattern tests/gatekeeper-supervisor.test.sh
# already established. fetch_claude_usage is overridden to a fixed low
# value so this never touches the real macOS Keychain or makes a live
# network call.
# Run: bash tests/gatekeeper-quota-gate.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GATEKEEPER="$DIR/../lib/gatekeeper.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

GK_PID=""
cleanup() {
  [ -n "$GK_PID" ] && kill "$GK_PID" >/dev/null 2>&1
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

SCRATCH="$(mktemp -d)"
cat > "$SCRATCH/orchestrator.yaml" <<'YAML'
project: gk-quota-test
integration_branch: main
budgets:
  claude:
    failsafe_pct: 80
  agy:
    failsafe_pct: 80
YAML

DISPATCH_CALLS="$SCRATCH/dispatch-calls.log"
QUOTA_FLAG="$SCRATCH/quota-stop"
: > "$DISPATCH_CALLS"

# "source, then override" -- same pattern tests/watch.test.sh already uses
# for wsc_write/dispatch_main. AGY_STATUSLINE has no env override (a plain
# assignment off $HOME in gatekeeper.sh, not ${VAR:-default}), so it's
# reassigned here directly after sourcing instead.
cat > "$SCRATCH/run-gatekeeper.sh" <<RUNNER
#!/bin/bash
set -uo pipefail
source "$GATEKEEPER"
AGY_STATUSLINE="$SCRATCH/agy-statusline.json"
fetch_claude_usage() { echo '{"five_hour":{"utilization":5},"seven_day":{"utilization":5}}'; }
dispatch_main() { echo "\$*" >> "$DISPATCH_CALLS"; }
gatekeeper_main
RUNNER
chmod +x "$SCRATCH/run-gatekeeper.sh"

run_gatekeeper_briefly() {
  GATEKEEPER_INTERVAL=1 \
    GATEKEEPER_HEARTBEAT_FILE="$SCRATCH/hb" \
    GATEKEEPER_BUDGET_LOG="$SCRATCH/budget.log" \
    GATEKEEPER_ALERT_STATE_FILE="$SCRATCH/alert-state.json" \
    AUTO_RESUME_QUOTA_STOP_FLAG="$QUOTA_FLAG" \
    ORC_CONFIG_FILE="$SCRATCH/orchestrator.yaml" \
    ORC_PROJECT_ROOT="$SCRATCH" \
    bash "$SCRATCH/run-gatekeeper.sh" >/dev/null 2>&1 &
  GK_PID=$!
  sleep 2
  kill "$GK_PID" >/dev/null 2>&1
  wait "$GK_PID" 2>/dev/null
  GK_PID=""
}

echo "== agy alone over its own failsafe_pct writes the shared quota-stop flag (not just an advisory alert) =="
echo '{"quota":{"gemini-5h":{"remaining_fraction":0.02},"3p-5h":{"remaining_fraction":1}}}' > "$SCRATCH/agy-statusline.json"
rm -f "$QUOTA_FLAG"
: > "$SCRATCH/budget.log"
: > "$DISPATCH_CALLS"
run_gatekeeper_briefly

if [ -f "$QUOTA_FLAG" ]; then
  pass "agy alone crossing its failsafe_pct wrote the shared quota-stop flag"
else
  fail "expected the quota-stop flag to exist after agy alone crossed its failsafe_pct (budget.log: $(cat "$SCRATCH/budget.log" 2>/dev/null))"
fi

if [ -f "$QUOTA_FLAG" ] && [ "$(jq -r '.pool' "$QUOTA_FLAG")" = "agy" ] && [ "$(jq -r '.fallback' "$QUOTA_FLAG")" = "claude" ]; then
  pass "the flag records pool=agy, fallback=claude"
else
  fail "expected pool=agy/fallback=claude, got: $(cat "$QUOTA_FLAG" 2>/dev/null)"
fi

if [ -f "$QUOTA_FLAG" ] && [ -z "$(jq -r '.resets_at_epoch' "$QUOTA_FLAG")" -o "$(jq -r '.resets_at_epoch' "$QUOTA_FLAG")" = "null" ]; then
  pass "the flag carries no resets_at_epoch (agy's pool has no epoch to auto-clear against -- human-clear-only, same as weekly)"
else
  fail "expected resets_at_epoch to be null for an agy-pool flag, got: $(cat "$QUOTA_FLAG" 2>/dev/null)"
fi

if grep -q "^assign orchestra quota-agy" "$DISPATCH_CALLS"; then
  pass "the advisory alert to orchestra still fires too (not replaced, just no longer the ONLY effect)"
else
  fail "expected the existing quota-agy alert to still fire: $(cat "$DISPATCH_CALLS")"
fi

echo "== agy under threshold never writes the flag or alerts =="
echo '{"quota":{"gemini-5h":{"remaining_fraction":0.9},"3p-5h":{"remaining_fraction":0.95}}}' > "$SCRATCH/agy-statusline.json"
rm -f "$QUOTA_FLAG"
: > "$SCRATCH/budget.log"
: > "$SCRATCH/alert-state.json"
: > "$DISPATCH_CALLS"
run_gatekeeper_briefly

if [ ! -f "$QUOTA_FLAG" ]; then
  pass "agy under threshold never writes the quota-stop flag"
else
  fail "agy under threshold should not have written a flag: $(cat "$QUOTA_FLAG")"
fi
if ! grep -q "quota-agy" "$DISPATCH_CALLS"; then
  pass "agy under threshold never alerts"
else
  fail "agy under threshold should not have alerted: $(cat "$DISPATCH_CALLS")"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
