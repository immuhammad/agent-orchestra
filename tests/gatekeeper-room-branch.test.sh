#!/bin/bash
# tests/gatekeeper-room-branch.test.sh -- issue #189 fix 3: gk_check_room_branch's
# orchestra alert (lib/gatekeeper.sh, "the watcher dispatch" emitter) must
# name BOTH the current and the expected integration branch plus the exact
# checkout command -- ambiguous wording here (alongside
# hooks/room-branch-gate.sh's deny line, covered in
# tests/room-branch-gate.test.sh) caused two destructive actions in the
# field. Both emitters now share lib/room-branch-lib.sh's
# room_branch_mismatch_message so they can't drift apart again.
#
# Calls gk_check_room_branch directly rather than spinning up the full
# gatekeeper_main loop -- the alert fires from one function call, no
# polling needed (tests/gatekeeper-quota-gate.test.sh already covers the
# background-spawn+kill pattern for a different concern).
# Run: bash tests/gatekeeper-room-branch.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GATEKEEPER="$DIR/../lib/gatekeeper.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

git init -q "$SCRATCH"
git -C "$SCRATCH" config user.email "test@test.local"
git -C "$SCRATCH" config user.name "test"
printf 'project: gk-room-branch-test\nintegration_branch: main\n' > "$SCRATCH/orchestrator.yaml"
git -C "$SCRATCH" checkout -q -b main
git -C "$SCRATCH" commit -q --allow-empty -m init
git -C "$SCRATCH" checkout -q -b feature/mismatch

DISPATCH_CALLS="$SCRATCH/dispatch-calls.log"
: > "$DISPATCH_CALLS"

RUNNER="$SCRATCH/run-check.sh"
cat > "$RUNNER" <<RUNNEREOF
#!/bin/bash
set -uo pipefail
source "$GATEKEEPER"
dispatch_main() { echo "\$*" >> "$DISPATCH_CALLS"; }
gk_check_room_branch
RUNNEREOF
chmod +x "$RUNNER"

GATEKEEPER_ROOM_ROOT="$SCRATCH" \
  GATEKEEPER_HEARTBEAT_FILE="$SCRATCH/hb" \
  GATEKEEPER_BUDGET_LOG="$SCRATCH/budget.log" \
  GATEKEEPER_ALERT_STATE_FILE="$SCRATCH/alert-state.json" \
  bash "$RUNNER" >/dev/null 2>&1

echo "== the orchestra alert fired once for this mismatch crossing =="
if [ -s "$DISPATCH_CALLS" ]; then
  pass "gk_check_room_branch dispatched an orchestra alert"
else
  fail "expected gk_check_room_branch to dispatch an alert, dispatch-calls.log is empty"
fi

echo "== the orchestra alert names the CURRENT branch =="
grep -q "room branch is 'feature/mismatch'" "$DISPATCH_CALLS" && pass "alert names the current branch" || fail "expected \"room branch is 'feature/mismatch'\" in: $(cat "$DISPATCH_CALLS")"

echo "== the orchestra alert names the EXPECTED (integration) branch =="
grep -q "the integration branch is 'main'" "$DISPATCH_CALLS" && pass "alert names the integration branch" || fail "expected \"the integration branch is 'main'\" in: $(cat "$DISPATCH_CALLS")"

echo "== the orchestra alert gives the exact remedy command =="
grep -q "run: git checkout main" "$DISPATCH_CALLS" && pass "alert names the exact checkout command" || fail "expected 'run: git checkout main' in: $(cat "$DISPATCH_CALLS")"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]