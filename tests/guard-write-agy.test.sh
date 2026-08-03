#!/bin/bash
# tests/guard-write-agy.test.sh -- lib/guard-write-agy.sh, the agy
# dialect of lib/guard-write.sh. Full parity coverage (issue #189, agy's
# dedicated security review finding 2: the first cut's narrower agy
# guard -- hooks/lib/bin only -- left orchestrator.yaml's protected_paths
# and .claude/.agents unenforced in software for agy, which matters
# because bin/orc-protect's kernel immutability explicitly skips any
# .git/-rooted protected_paths entry and any target that doesn't exist
# yet at protect-time). Mirrors tests/guard-write.test.sh's structure so
# the two suites can't silently drift apart either.
# Run: bash tests/guard-write-agy.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$DIR/../lib/guard-write-agy.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# run_guard_write <root> <file_path> -- root must already have
# orchestrator.yaml written (or not, for the no-config cases).
run_guard_write() {
  local root="$1" file_path="$2"
  local payload
  payload="$(jq -n --arg fp "$file_path" '{toolCall:{name:"write_to_file",args:{TargetFile:$fp}}}')"
  GATE_OUT="$(cd "$root" && echo "$payload" | bash "$GUARD" 2>&1)"
}
expect_deny() {
  local desc="$1" root="$2" file_path="$3"
  run_guard_write "$root" "$file_path"
  if echo "$GATE_OUT" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (expected a deny decision) -- got: $GATE_OUT"
  fi
}
expect_allow() {
  local desc="$1" root="$2" file_path="$3"
  run_guard_write "$root" "$file_path"
  if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (expected an allow decision) -- got: $GATE_OUT"
  fi
}

echo "== EMPTY default, no hardcoded project name (no config) =="
NOCFG="$(mktemp -d)"
expect_allow "write into career-ops/ is allowed (no config, old default is gone)" "$NOCFG" "career-ops/x.txt"
expect_allow "write outside career-ops/ is allowed (no config)" "$NOCFG" "extension/x.txt"
rm -rf "$NOCFG"

echo "== protected paths from orchestrator.yaml =="
PCFG="$(mktemp -d)"
printf 'protected_paths:\n  - vendor/legacy/\n' > "$PCFG/orchestrator.yaml"
expect_deny "custom protected_paths blocks its own path" "$PCFG" "vendor/legacy/x.txt"
expect_allow "custom protected_paths does not widen to anything not listed" "$PCFG" "career-ops/x.txt"
rm -rf "$PCFG"

echo "== SECURITY (agy's dedicated review, round 2): a protected_paths entry inside a worktree's OWN copy stays editable =="
PPWT_ROOT="$(mktemp -d)"
printf 'protected_paths:\n  - vendor/legacy/\n' > "$PPWT_ROOT/orchestrator.yaml"
expect_deny "root-level vendor/legacy/ (absolute path) still denies" "$PPWT_ROOT" "$PPWT_ROOT/vendor/legacy/x.txt"
expect_allow "a worktree's own vendor/legacy/ copy (absolute path) stays editable" "$PPWT_ROOT" "$PPWT_ROOT/.worktrees/issue-1/vendor/legacy/x.txt"
rm -rf "$PPWT_ROOT"

echo "== .claude/ and .agents/ are protected BY DEFAULT, independent of orchestrator.yaml =="
DCFG="$(mktemp -d)"
expect_deny "write into .claude/settings.json is blocked with NO orchestrator.yaml at all" "$DCFG" ".claude/settings.json"
expect_deny "write into .agents/hooks.json is blocked with NO orchestrator.yaml at all" "$DCFG" ".agents/hooks.json"
expect_deny "write into a nested .claude/ path is blocked" "$DCFG" "some/nested/.claude/settings.local.json"
run_guard_write "$DCFG" ".claude/settings.json"
if echo "$GATE_OUT" | jq -r '.reason' | grep -q "templates/settings.json"; then
  pass "blocked-write reason names the sanctioned edit path (templates/settings.json)"
else
  fail "expected the blocked-write reason to name templates/settings.json, got: $GATE_OUT"
fi
expect_allow "a normal project write (unrelated to .claude//.agents/) is still allowed" "$DCFG" "src/some-feature.js"
rm -rf "$DCFG"

echo "== issue #189: root hooks/lib/bin are protected by default at the room root =="
EROOT="$(mktemp -d)"
printf 'project: enforcement-layer-probe-agy\n' > "$EROOT/orchestrator.yaml"
expect_deny "root hooks/ write is denied" "$EROOT" "$EROOT/hooks/x.sh"
expect_deny "root lib/ write is denied" "$EROOT" "$EROOT/lib/x.sh"
expect_deny "root bin/ write is denied" "$EROOT" "$EROOT/bin/x.sh"

echo "== a worktree's own copies stay editable =="
expect_allow "a worktree's own hooks/ copy stays editable" "$EROOT" "$EROOT/.worktrees/issue-9/hooks/x.sh"
expect_allow "a worktree's own lib/ copy stays editable" "$EROOT" "$EROOT/.worktrees/issue-9/lib/x.sh"
expect_allow "a worktree's own bin/ copy stays editable" "$EROOT" "$EROOT/.worktrees/issue-9/bin/x.sh"

echo "== SECURITY: a .worktrees/../hooks traversal spoof still resolves to root and denies =="
expect_deny "resolved-path check, not string prefix" "$EROOT" "$EROOT/.worktrees/../hooks/x.sh"

echo "== SECURITY (agy's own dedicated review, finding 1): a symlinked directory can't spoof the .worktrees exemption =="
# hooks/ must actually exist at EROOT for this to be a realistic repro --
# see tests/guard-write.test.sh's matching comment.
mkdir -p "$EROOT/hooks" "$EROOT/.worktrees/issue-1"
ln -s ../../hooks "$EROOT/.worktrees/issue-1/myhooks"
expect_deny "a symlinked worktree subdir pointing at root hooks/ still denies (physical resolution, not lexical)" \
  "$EROOT" "$EROOT/.worktrees/issue-1/myhooks/x.sh"

echo "== an unrelated path is unaffected =="
expect_allow "an unrelated root-level path is allowed" "$EROOT" "$EROOT/src/app.js"
rm -rf "$EROOT"

echo "== no FILE_PATH in the payload -> allow (this guard only judges write-shaped calls it can locate a target for) =="
NOTARGET="$(mktemp -d)"
GATE_OUT="$(cd "$NOTARGET" && echo '{"toolCall":{"name":"read_file","args":{}}}' | bash "$GUARD" 2>&1)"
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "no target path -> allow"
else
  fail "expected allow with no target path, got: $GATE_OUT"
fi
rm -rf "$NOTARGET"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]