#!/bin/bash
# tests/room-branch.test.sh — TDD tests for lib/room-branch-lib.sh (issue #60
# task B). Hermetic: every repo is a throwaway mktemp dir with its own
# orchestrator.yaml, never the real project checkout, and ORC_PROJECT_ROOT is
# unset so harness_canonical_dir walks up from each temp root instead of
# picking up whatever real .harness/ the test happens to run under.
set -uo pipefail
unset ORC_PROJECT_ROOT

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/room-branch-lib.sh
source "$DIR/../lib/room-branch-lib.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

mk_repo() {
  local dir
  dir="$(mktemp -d)"
  dir="$(cd "$dir" && pwd -P)"
  git init -q "$dir"
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "test"
  printf 'project: room-branch-test\n' > "$dir/orchestrator.yaml"
  echo "$dir"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

echo "== room_branch_state: ok =="
R1="$(mk_repo)"
git -C "$R1" checkout -q -b uat
assert_eq "HEAD on default integration branch (uat, no config) is ok" "ok" "$(room_branch_state "$R1")"

R2="$(mk_repo)"
git -C "$R2" checkout -q -b release
printf 'integration_branch: release\n' > "$R2/orchestrator.yaml"
assert_eq "HEAD on configured integration branch is ok" "ok" "$(room_branch_state "$R2")"

echo "== room_branch_state: mismatch =="
R3="$(mk_repo)"
git -C "$R3" checkout -q -b feature/issue-60
assert_eq "HEAD on a feature branch is a mismatch" "mismatch feature/issue-60" "$(room_branch_state "$R3")"

echo "== room_branch_state: unknown (fail closed) =="
R4="$(mktemp -d)"
assert_eq "root with no git repo is unknown" "unknown" "$(room_branch_state "$R4")"

R5="$(mk_repo)"
git -C "$R5" commit -q --allow-empty -m "first"
git -C "$R5" checkout -q --detach
assert_eq "detached HEAD is unknown" "unknown" "$(room_branch_state "$R5")"

R6="/nonexistent/path/$(date +%s 2>/dev/null || echo x)"
assert_eq "nonexistent root is unknown" "unknown" "$(room_branch_state "$R6")"

echo "== room_branch_override_reason =="
R7="$(mk_repo)"
assert_eq "no override file -> empty reason" "" "$(room_branch_override_reason "$R7")"
mkdir -p "$R7/.harness/state"
printf 'emergency hotfix, approved by orchestra in #61\n' > "$R7/.harness/state/room-branch-override"
assert_eq "override file content is surfaced as the reason" "emergency hotfix, approved by orchestra in #61" "$(room_branch_override_reason "$R7")"

echo "== room_branch_override_active =="
R8="$(mk_repo)"
if room_branch_override_active "$R8"; then
  fail "no override present -> inactive"
else
  pass "no override present -> inactive"
fi

if room_branch_override_active "$R7"; then
  pass "override file present -> active"
else
  fail "override file present -> active"
fi

if ORC_ALLOW_UNMERGED_HARNESS=1 room_branch_override_active "$R8"; then
  pass "ORC_ALLOW_UNMERGED_HARNESS=1 -> active even without a file"
else
  fail "ORC_ALLOW_UNMERGED_HARNESS=1 -> active even without a file"
fi

echo "== room_branch_integration_branch =="
R9="$(mk_repo)"
assert_eq "no config: falls back to uat" "uat" "$(room_branch_integration_branch "$R9")"
R10="$(mk_repo)"
printf 'integration_branch: release\n' > "$R10/orchestrator.yaml"
assert_eq "configured integration_branch is honored" "release" "$(room_branch_integration_branch "$R10")"

echo "== room_branch_restore_command_allowed (issue #60 task E) =="
R11="$(mk_repo)"
printf 'integration_branch: uat\n' > "$R11/orchestrator.yaml"
if room_branch_restore_command_allowed "git checkout uat" "$R11"; then
  pass "exact 'git checkout <integration>' is allowed"
else
  fail "exact 'git checkout <integration>' should be allowed"
fi
if room_branch_restore_command_allowed "git switch uat" "$R11"; then
  pass "exact 'git switch <integration>' is allowed"
else
  fail "exact 'git switch <integration>' should be allowed"
fi
if room_branch_restore_command_allowed "  git checkout uat  " "$R11"; then
  pass "surrounding whitespace is tolerated"
else
  fail "surrounding whitespace should be tolerated"
fi
if room_branch_restore_command_allowed "git checkout feature/other" "$R11"; then
  fail "checking out a DIFFERENT branch must not be allowed"
else
  pass "checking out a DIFFERENT branch is not allowed"
fi
if room_branch_restore_command_allowed "git checkout uat && rm -rf /" "$R11"; then
  fail "SECURITY: a chained && after the restore command must not be allowed"
else
  pass "a chained && after the restore command is rejected"
fi
if room_branch_restore_command_allowed "git checkout uat; rm -rf /" "$R11"; then
  fail "SECURITY: a chained ; after the restore command must not be allowed"
else
  pass "a chained ; after the restore command is rejected"
fi
if room_branch_restore_command_allowed "git checkout \$(echo uat)" "$R11"; then
  fail "SECURITY: command substitution must not be allowed"
else
  pass "command substitution in the branch arg is rejected"
fi
if room_branch_restore_command_allowed "git checkout uat > /tmp/poc" "$R11"; then
  fail "SECURITY: a trailing redirection must not be allowed"
else
  pass "a trailing redirection is rejected"
fi
if room_branch_restore_command_allowed "git checkout -- uat" "$R11"; then
  fail "extra flags must not be allowed -- exact match only"
else
  pass "extra flags (git checkout -- uat) are rejected -- exact match only"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
