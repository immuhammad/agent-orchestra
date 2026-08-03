#!/bin/bash
# .harness/guard-write.test.sh — TDD tests for guard-write.sh, including its
# config-driven protected_paths. No prior test file existed for
# this hook; added alongside the config-loading change.
# Run: bash .harness/guard-write.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$DIR/../lib/guard-write.sh"

PASS=0
FAIL=0

# run_guard_write <file_path> [orchestrator.yaml contents]
run_guard_write() {
  local file_path="$1"
  local yaml_content="${2:-}"

  local tmp
  tmp="$(mktemp -d)"

  if [ -n "$yaml_content" ]; then
    printf '%s\n' "$yaml_content" > "$tmp/orchestrator.yaml"
  fi

  local payload
  payload="$(jq -n --arg fp "$file_path" '{tool_input: {file_path: $fp}}')"

  local out status
  out="$(cd "$tmp" && echo "$payload" | bash "$GUARD" 2>&1)"
  status=$?

  rm -rf "$tmp"
  GUARD_OUT="$out"
  GUARD_STATUS=$status
}

expect_blocked() {
  local desc="$1" file_path="$2" yaml="${3:-}"
  run_guard_write "$file_path" "$yaml"
  if [ "$GUARD_STATUS" -eq 2 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 2, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

expect_allowed() {
  local desc="$1" file_path="$2" yaml="${3:-}"
  run_guard_write "$file_path" "$yaml"
  if [ "$GUARD_STATUS" -eq 0 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 0, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

echo "== EMPTY default, no hardcoded project name (no config) =="
expect_allowed "write into career-ops/ is allowed (no config, old default is gone)"        "career-ops/x.txt"
expect_allowed "write into nested career-ops/ is allowed (no config, old default is gone)" "src/career-ops/x.txt"
expect_allowed "write outside career-ops/ is allowed (no config)"                          "extension/x.txt"

echo "== T21: protected paths from orchestrator.yaml =="
CUSTOM_YAML=$'protected_paths:\n  - vendor/legacy/'
MALFORMED_YAML='this is not yaml at all {{{ :::'

expect_allowed "malformed config: no protected paths" \
  "career-ops/x.txt" "$MALFORMED_YAML"
expect_blocked "custom protected_paths blocks its own path" \
  "vendor/legacy/x.txt" "$CUSTOM_YAML"
expect_allowed "custom protected_paths does not widen to anything not listed" \
  "career-ops/x.txt" "$CUSTOM_YAML"

echo "== .claude/ and .agents/ are protected BY DEFAULT, independent of orchestrator.yaml =="
expect_blocked "write into .claude/settings.json is blocked with NO orchestrator.yaml at all" \
  ".claude/settings.json"
expect_blocked "write into .agents/hooks.json is blocked with NO orchestrator.yaml at all" \
  ".agents/hooks.json"
expect_blocked "write into a nested .claude/ path is blocked" \
  "some/nested/.claude/settings.local.json"
expect_blocked ".claude/ default protection is NOT overridden by an orchestrator.yaml that doesn't mention it" \
  ".claude/settings.json" "$CUSTOM_YAML"

run_guard_write ".claude/settings.json"
if echo "$GUARD_OUT" | grep -q "templates/settings.json"; then
  echo "PASS: blocked-write message names the sanctioned edit path (templates/settings.json)"
  PASS=$((PASS + 1))
else
  echo "FAIL: expected the blocked-write message to name templates/settings.json as the sanctioned edit path, got: $GUARD_OUT"
  FAIL=$((FAIL + 1))
fi

expect_allowed "a normal project write (unrelated to .claude//.agents/) is still allowed" \
  "src/some-feature.js"

echo "== issue #189: <root>/hooks, <root>/lib, <root>/bin are protected by default at the room root =="
# A dedicated fixture with a real orchestrator.yaml (so qsg_resolve_canon_dir
# can resolve ROOT) -- run_guard_write/expect_* above deliberately use a
# THROWAWAY tmp dir per call with no fixed root, so this needs its own
# helper that reuses ONE root across every case in this section.
EROOT="$(mktemp -d)"
printf 'project: enforcement-layer-probe\n' > "$EROOT/orchestrator.yaml"

run_guard_write_at() {
  local file_path="$1"
  local payload
  payload="$(jq -n --arg fp "$file_path" '{tool_input: {file_path: $fp}}')"
  local out st
  out="$(cd "$EROOT" && echo "$payload" | bash "$GUARD" 2>&1)"
  st=$?
  GUARD_OUT="$out"
  GUARD_STATUS=$st
}
expect_blocked_at() {
  local desc="$1" file_path="$2"
  run_guard_write_at "$file_path"
  if [ "$GUARD_STATUS" -eq 2 ]; then
    echo "PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 2, got $GUARD_STATUS) -- output: $GUARD_OUT"; FAIL=$((FAIL + 1))
  fi
}
expect_allowed_at() {
  local desc="$1" file_path="$2"
  run_guard_write_at "$file_path"
  if [ "$GUARD_STATUS" -eq 0 ]; then
    echo "PASS: $desc"; PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 0, got $GUARD_STATUS) -- output: $GUARD_OUT"; FAIL=$((FAIL + 1))
  fi
}

expect_blocked_at "root hooks/ write is blocked (absolute path)" "$EROOT/hooks/x.sh"
expect_blocked_at "root lib/ write is blocked (absolute path)" "$EROOT/lib/x.sh"
expect_blocked_at "root bin/ write is blocked (absolute path)" "$EROOT/bin/x.sh"
expect_blocked_at "root hooks/ write is blocked (relative path, cwd=root)" "hooks/x.sh"

expect_allowed_at "a worktree's own hooks/ copy stays editable (absolute path)" "$EROOT/.worktrees/issue-9/hooks/x.sh"
expect_allowed_at "a worktree's own lib/ copy stays editable (absolute path)" "$EROOT/.worktrees/issue-9/lib/x.sh"
expect_allowed_at "a worktree's own bin/ copy stays editable (absolute path)" "$EROOT/.worktrees/issue-9/bin/x.sh"
expect_allowed_at "a worktree's own hooks/ copy stays editable (relative path, cwd=root)" ".worktrees/issue-9/hooks/x.sh"

expect_blocked_at "a .worktrees/../hooks traversal spoof still resolves to root and blocks (resolved-path check, not string prefix)" \
  "$EROOT/.worktrees/../hooks/x.sh"

expect_allowed_at "an unrelated root-level path is unaffected" "$EROOT/src/app.js"

echo "== SECURITY (agy's dedicated review, finding 1): a symlinked directory can't spoof the .worktrees exemption =="
# ln -s ../../hooks .worktrees/issue-1/myhooks -- a write through
# myhooks/x.sh lexically looks like it's under .worktrees/ (exempt), but
# the kernel follows the symlink into the ROOT's real hooks/. Only a
# PHYSICAL resolution (orc_physical_normalize) catches this.
# hooks/ must actually exist at EROOT for this to be a realistic repro --
# a real room always has it by the time this guard matters; a symlink to
# a target that doesn't exist yet can't be exploited anyway (the OS
# itself refuses to create a file under a dangling directory symlink).
mkdir -p "$EROOT/hooks" "$EROOT/.worktrees/issue-1"
ln -s ../../hooks "$EROOT/.worktrees/issue-1/myhooks"
expect_blocked_at "a symlinked worktree subdir pointing at root hooks/ still blocks (physical resolution, not lexical)" \
  "$EROOT/.worktrees/issue-1/myhooks/x.sh"

rm -rf "$EROOT"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
