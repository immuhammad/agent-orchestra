#!/bin/bash
# tests/room-branch-gate.test.sh — tests for issue #60 task E's room-branch
# PreToolUse gate: hooks/room-branch-gate.sh (Claude Code dialect) and
# lib/guard-room-branch-agy.sh (agy dialect), both thin wrappers over
# lib/room-branch-lib.sh (task B). Unlike quota-stop-gate.sh (a persisted
# flag file), this gate is a LIVE per-call git check -- no state file --
# mirrors tests/quota-stop-gate.test.sh's structure (both dialects, the
# shared qsg park-honestly allow-list, path-traversal/redirection/
# chaining security regressions) scoped to what's actually new here: the
# live branch check plus the restore-command escape hatch.
# Run: bash tests/room-branch-gate.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
HOOKS="$(cd "$DIR/../hooks" && pwd)"
CLAUDE_GATE="$HOOKS/room-branch-gate.sh"
AGY_GATE="$LIB/guard-room-branch-agy.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

mk_repo() { # $1 = branch to check out (defaults to uat, the integration branch)
  local dir branch="${1:-uat}"
  dir="$(mktemp -d)"
  dir="$(cd "$dir" && pwd -P)"
  git init -q "$dir"
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "test"
  printf 'project: rbgate-test\nintegration_branch: uat\n' > "$dir/orchestrator.yaml"
  git -C "$dir" checkout -q -b uat
  git -C "$dir" add orchestrator.yaml
  git -C "$dir" commit -q -m init
  mkdir -p "$dir/lib" "$dir/.harness"
  touch "$dir/lib/dispatch.sh" "$dir/lib/log-decision.sh" "$dir/lib/quota-stop-clear.sh"
  if [ "$branch" != "uat" ]; then
    git -C "$dir" checkout -q -b "$branch"
  fi
  echo "$dir"
}

run_claude_gate() { # $1 = TMP root, $2 = JSON payload
  local root="$1" payload="$2" out status
  out="$(cd "$root" && echo "$payload" | bash "$CLAUDE_GATE" 2>&1)"
  status=$?
  GATE_OUT="$out"
  GATE_STATUS="$status"
}

run_agy_gate() { # $1 = TMP root, $2 = JSON payload
  local root="$1" payload="$2" out status
  out="$(cd "$root" && echo "$payload" | bash "$AGY_GATE" 2>&1)"
  status=$?
  GATE_OUT="$out"
  GATE_STATUS="$status"
}

echo "== Claude Code dialect: on the integration branch -> always allowed =="
OK_REPO="$(mk_repo)"
run_claude_gate "$OK_REPO" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "on integration branch: ordinary Bash allowed" || fail "expected allow on integration branch, got $GATE_STATUS: $GATE_OUT"
rm -rf "$OK_REPO"

echo "== Claude Code dialect: branch mismatch blocks an ordinary Bash command =="
MM_REPO="$(mk_repo feature/mismatch)"
run_claude_gate "$MM_REPO" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "mismatch: ordinary Bash command blocked (exit 2)" || fail "expected exit 2 on mismatch, got $GATE_STATUS: $GATE_OUT"
echo "$GATE_OUT" | grep -qi "mismatch" && pass "blocked message names the mismatch" || fail "expected 'mismatch' in the blocked message: $GATE_OUT"

echo "== Claude Code dialect: the shared qsg park-honestly allow-list still works while mismatched =="
run_claude_gate "$MM_REPO" '{"tool_name":"Write","tool_input":{"file_path":".harness/handoff.md"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "Write to handoff.md allowed while mismatched" || fail "handoff.md write should be allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate "$MM_REPO" '{"tool_name":"Read","tool_input":{"file_path":".harness/decisions.log"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "Read of decisions.log allowed while mismatched" || fail "decisions.log read should be allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate "$MM_REPO" '{"tool_name":"Bash","tool_input":{"command":"bash lib/dispatch.sh assign orchestra x DONE"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "dispatch.sh invocation allowed while mismatched" || fail "dispatch.sh should be allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate "$MM_REPO" '{"tool_name":"Write","tool_input":{"file_path":"src/app.py"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "a NON-allow-listed Write is still blocked while mismatched" || fail "unrelated write should be blocked, got $GATE_STATUS: $GATE_OUT"

echo "== Claude Code dialect: the restore command is the one extra escape hatch =="
run_claude_gate "$MM_REPO" '{"tool_name":"Bash","tool_input":{"command":"git checkout uat"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "'git checkout uat' (the integration branch) is allowed while mismatched" || fail "restore command should be allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate "$MM_REPO" '{"tool_name":"Bash","tool_input":{"command":"git switch uat"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "'git switch uat' is also allowed while mismatched" || fail "restore command (switch) should be allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate "$MM_REPO" '{"tool_name":"Bash","tool_input":{"command":"git checkout feature/other-branch"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "checking out a DIFFERENT (non-integration) branch is still blocked" || fail "checkout of a non-integration branch should stay blocked, got $GATE_STATUS: $GATE_OUT"

echo "== SECURITY: the restore command can't be used to smuggle a chained command =="
run_claude_gate "$MM_REPO" '{"tool_name":"Bash","tool_input":{"command":"git checkout uat && rm -rf /tmp/whatever"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "'git checkout uat && ...' is rejected outright" || fail "SECURITY REGRESSION: chained restore command bypass allowed, got $GATE_STATUS: $GATE_OUT"

rm -rf "$MM_REPO"

echo "== Claude Code dialect: an active override (file) proceeds despite the mismatch =="
OV_REPO="$(mk_repo feature/mismatch)"
mkdir -p "$OV_REPO/.harness/state"
echo "approved hotfix" > "$OV_REPO/.harness/state/room-branch-override"
run_claude_gate "$OV_REPO" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "file override: ordinary command allowed despite the mismatch" || fail "file override should allow through, got $GATE_STATUS: $GATE_OUT"
rm -rf "$OV_REPO"

echo "== Claude Code dialect: an active override (env) proceeds despite the mismatch =="
OV2_REPO="$(mk_repo feature/mismatch)"
GATE_OUT="$(cd "$OV2_REPO" && echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | ORC_ALLOW_UNMERGED_HARNESS=1 bash "$CLAUDE_GATE" 2>&1)"
GATE_STATUS=$?
[ "$GATE_STATUS" -eq 0 ] && pass "ORC_ALLOW_UNMERGED_HARNESS=1: ordinary command allowed despite the mismatch" || fail "env override should allow through, got $GATE_STATUS: $GATE_OUT"
rm -rf "$OV2_REPO"

echo "== Claude Code dialect: unresolvable project root fails CLOSED =="
NOROOT="$(mktemp -d)"
OUT="$(cd "$NOROOT" && env -u CLAUDE_PROJECT_DIR bash -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}" | bash "'"$CLAUDE_GATE"'"' 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] && pass "unresolvable root -> fails closed (exit 2)" || fail "SECURITY: expected fail-closed (exit 2), got $STATUS: $OUT"
rm -rf "$NOROOT"

echo "== agy dialect: on the integration branch -> allow decision =="
AGY_OK_REPO="$(mk_repo)"
run_agy_gate "$AGY_OK_REPO" '{"toolCall":{"args":{"CommandLine":"ls -la"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: on integration branch -> allow decision"
else
  fail "agy: expected an allow decision on the integration branch, got: $GATE_OUT"
fi
rm -rf "$AGY_OK_REPO"

echo "== agy dialect: branch mismatch -> deny decision =="
AGY_MM_REPO="$(mk_repo feature/mismatch)"
run_agy_gate "$AGY_MM_REPO" '{"toolCall":{"args":{"CommandLine":"ls -la"}}}'
DECISION="$(echo "$GATE_OUT" | jq -r '.decision // empty' 2>/dev/null)"
REASON="$(echo "$GATE_OUT" | jq -r '.reason // empty' 2>/dev/null)"
[ "$DECISION" = "deny" ] && pass "agy: mismatch -> deny decision" || fail "agy: expected a deny decision on mismatch, got: $GATE_OUT"
echo "$REASON" | grep -qi "mismatch" && pass "agy: deny reason names the mismatch" || fail "agy: expected 'mismatch' in the deny reason, got: $REASON"

echo "== agy dialect: allow-listed command and restore command pass while mismatched =="
run_agy_gate "$AGY_MM_REPO" '{"toolCall":{"args":{"CommandLine":"bash lib/dispatch.sh assign orchestra x DONE"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: dispatch.sh invocation allowed while mismatched"
else
  fail "agy: dispatch.sh should be allowed, got: $GATE_OUT"
fi

run_agy_gate "$AGY_MM_REPO" '{"toolCall":{"args":{"CommandLine":"git checkout uat"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: restore command ('git checkout uat') allowed while mismatched"
else
  fail "agy: restore command should be allowed, got: $GATE_OUT"
fi

run_agy_gate "$AGY_MM_REPO" '{"toolCall":{"args":{"CommandLine":"rm -rf /tmp/whatever"}}}'
DECISION="$(echo "$GATE_OUT" | jq -r '.decision // empty' 2>/dev/null)"
[ "$DECISION" = "deny" ] && pass "agy: a NON-allow-listed command is still denied while mismatched" || fail "agy: unrelated command should be denied, got: $GATE_OUT"
rm -rf "$AGY_MM_REPO"

echo "== agy dialect: real write_to_file payload (TargetFile) respects the allow-list while mismatched =="
AGY_WRITE_REPO="$(mk_repo feature/mismatch)"
run_agy_gate "$AGY_WRITE_REPO" '{"toolCall":{"name":"write_to_file","args":{"TargetFile":".harness/handoff.md"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: write_to_file targeting handoff.md allowed while mismatched"
else
  fail "agy: handoff.md write should be allowed, got: $GATE_OUT"
fi
run_agy_gate "$AGY_WRITE_REPO" '{"toolCall":{"name":"write_to_file","args":{"TargetFile":"src/app.py"}}}'
DECISION="$(echo "$GATE_OUT" | jq -r '.decision // empty' 2>/dev/null)"
[ "$DECISION" = "deny" ] && pass "agy: write_to_file to a NON-allow-listed path is still denied while mismatched" || fail "agy: unrelated write should be denied, got: $GATE_OUT"
rm -rf "$AGY_WRITE_REPO"

echo "== agy dialect: an active override (file) proceeds despite the mismatch =="
AGY_OV_REPO="$(mk_repo feature/mismatch)"
mkdir -p "$AGY_OV_REPO/.harness/state"
echo "approved hotfix" > "$AGY_OV_REPO/.harness/state/room-branch-override"
run_agy_gate "$AGY_OV_REPO" '{"toolCall":{"args":{"CommandLine":"ls -la"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: file override allows through despite the mismatch"
else
  fail "agy: file override should allow through, got: $GATE_OUT"
fi
rm -rf "$AGY_OV_REPO"

echo "== agy dialect: unresolvable project root fails CLOSED (deny) =="
NOROOT2="$(mktemp -d)"
OUT="$(cd "$NOROOT2" && env -u CLAUDE_PROJECT_DIR bash -c 'echo "{\"toolCall\":{\"args\":{\"CommandLine\":\"ls -la\"}}}" | bash "'"$AGY_GATE"'"' 2>&1)"
rm -rf "$NOROOT2"
DECISION="$(echo "$OUT" | jq -r '.decision // empty' 2>/dev/null)"
[ "$DECISION" = "deny" ] && pass "agy: unresolvable root -> deny decision (fails closed)" || fail "SECURITY: agy expected a deny decision, got: $OUT"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]