#!/bin/bash
# .harness/gatekeeper-supervisor.test.sh — tests for the respawn wrapper
# (issue #105 Task 3). Run: bash .harness/gatekeeper-supervisor.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SUPERVISOR="$DIR/../lib/gatekeeper-supervisor.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SUP_PID=""
cleanup() {
  [ -n "$SUP_PID" ] && kill "$SUP_PID" >/dev/null 2>&1
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

SCRATCH="$(mktemp -d)"
BUDGET_LOG="$SCRATCH/budget.log"
: > "$BUDGET_LOG"
RUN_COUNT_FILE="$SCRATCH/run-count"
echo 0 > "$RUN_COUNT_FILE"

# A fake "gatekeeper.sh" that exits immediately every time -- exercises
# crash-loop respawning without ever hitting a live OAuth call.
CRASHER="$SCRATCH/crasher.sh"
cat > "$CRASHER" <<'CRASHERSH'
#!/bin/bash
count=$(cat "$RUN_COUNT_FILE")
count=$((count + 1))
echo "$count" > "$RUN_COUNT_FILE"
exit 1
CRASHERSH
chmod +x "$CRASHER"

echo "== supervisor respawns a crashing target multiple times =="
GATEKEEPER_BUDGET_LOG="$BUDGET_LOG" GATEKEEPER_SUPERVISOR_TARGET="$CRASHER" \
  RUN_COUNT_FILE="$RUN_COUNT_FILE" \
  bash "$SUPERVISOR" >/dev/null 2>&1 &
SUP_PID=$!
sleep 4
kill "$SUP_PID" >/dev/null 2>&1
wait "$SUP_PID" 2>/dev/null
SUP_PID=""
RUNS="$(cat "$RUN_COUNT_FILE")"
if [ "$RUNS" -ge 2 ]; then
  pass "supervisor respawned the crashing target multiple times ($RUNS runs)"
else
  fail "expected at least 2 respawns, got $RUNS"
fi
if grep -q "GATEKEEPER SUPERVISOR: starting" "$BUDGET_LOG" && grep -q "exited (code 1)" "$BUDGET_LOG"; then
  pass "supervisor logged its start and each respawn with the exit code"
else
  fail "expected start + respawn log lines: $(cat "$BUDGET_LOG")"
fi

echo "== supervisor's backoff actually grows across rapid respawns =="
FIRST_BACKOFF="$(grep -o 'respawning in [0-9]*s' "$BUDGET_LOG" | head -1 | grep -o '[0-9]*')"
LAST_BACKOFF="$(grep -o 'respawning in [0-9]*s' "$BUDGET_LOG" | tail -1 | grep -o '[0-9]*')"
if [ -n "$FIRST_BACKOFF" ] && [ -n "$LAST_BACKOFF" ] && [ "$LAST_BACKOFF" -ge "$FIRST_BACKOFF" ]; then
  pass "backoff grew (or held at cap) across rapid crash-loop respawns ($FIRST_BACKOFF -> $LAST_BACKOFF)"
else
  fail "expected backoff to grow, got first=$FIRST_BACKOFF last=$LAST_BACKOFF"
fi

echo "== a target that runs long enough resets backoff on its next exit =="
: > "$BUDGET_LOG"
echo 0 > "$RUN_COUNT_FILE"
LONG_RUNNER="$SCRATCH/long-runner.sh"
cat > "$LONG_RUNNER" <<'LONGSH'
#!/bin/bash
sleep 2
exit 0
LONGSH
chmod +x "$LONG_RUNNER"
GATEKEEPER_BUDGET_LOG="$BUDGET_LOG" GATEKEEPER_SUPERVISOR_TARGET="$LONG_RUNNER" \
  GATEKEEPER_SUPERVISOR_RESET_AFTER=1 \
  bash "$SUPERVISOR" >/dev/null 2>&1 &
SUP_PID=$!
sleep 5
kill "$SUP_PID" >/dev/null 2>&1
wait "$SUP_PID" 2>/dev/null
SUP_PID=""
if grep -q "respawning in 1s" "$BUDGET_LOG"; then
  pass "backoff reset to 1s after the target ran past RESET_AFTER"
else
  fail "expected backoff to reset to 1s: $(cat "$BUDGET_LOG")"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
