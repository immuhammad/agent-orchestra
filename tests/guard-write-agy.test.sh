#!/bin/bash
# tests/guard-write-agy.test.sh -- issue #189: lib/guard-write-agy.sh, the
# agy dialect of lib/guard-write.sh's <root>/hooks, <root>/lib, <root>/bin
# default protection. Mirrors tests/guard-write.test.sh's enforcement-layer
# section, speaking agy's JSON in/out protocol (see
# tests/room-branch-gate.test.sh's run_agy_gate for the established
# pattern this follows). Deliberately narrow -- this guard checks ONLY
# hooks/lib/bin, not .claude/.agents/protected_paths (see the guard's own
# header for why that's out of scope here).
# Run: bash tests/guard-write-agy.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$DIR/../lib/guard-write-agy.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

EROOT="$(mktemp -d)"
trap 'rm -rf "$EROOT"' EXIT
printf 'project: enforcement-layer-probe-agy\n' > "$EROOT/orchestrator.yaml"

run_guard_at() {
  local file_path="$1"
  local payload
  payload="$(jq -n --arg fp "$file_path" '{toolCall:{name:"write_to_file",args:{TargetFile:$fp}}}')"
  GATE_OUT="$(cd "$EROOT" && echo "$payload" | bash "$GUARD" 2>&1)"
}
expect_deny() {
  local desc="$1" file_path="$2"
  run_guard_at "$file_path"
  if echo "$GATE_OUT" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (expected a deny decision) -- got: $GATE_OUT"
  fi
}
expect_allow() {
  local desc="$1" file_path="$2"
  run_guard_at "$file_path"
  if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (expected an allow decision) -- got: $GATE_OUT"
  fi
}

echo "== root hooks/lib/bin are protected by default at the room root =="
expect_deny "root hooks/ write is denied" "$EROOT/hooks/x.sh"
expect_deny "root lib/ write is denied" "$EROOT/lib/x.sh"
expect_deny "root bin/ write is denied" "$EROOT/bin/x.sh"

echo "== a worktree's own copies stay editable =="
expect_allow "a worktree's own hooks/ copy stays editable" "$EROOT/.worktrees/issue-9/hooks/x.sh"
expect_allow "a worktree's own lib/ copy stays editable" "$EROOT/.worktrees/issue-9/lib/x.sh"
expect_allow "a worktree's own bin/ copy stays editable" "$EROOT/.worktrees/issue-9/bin/x.sh"

echo "== SECURITY: a .worktrees/../hooks traversal spoof still resolves to root and denies =="
expect_deny "resolved-path check, not string prefix" "$EROOT/.worktrees/../hooks/x.sh"

echo "== an unrelated path is unaffected =="
expect_allow "an unrelated root-level path is allowed" "$EROOT/src/app.js"

echo "== no FILE_PATH in the payload -> allow (this guard only judges write-shaped calls it can locate a target for) =="
GATE_OUT="$(cd "$EROOT" && echo '{"toolCall":{"name":"read_file","args":{}}}' | bash "$GUARD" 2>&1)"
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "no target path -> allow"
else
  fail "expected allow with no target path, got: $GATE_OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]