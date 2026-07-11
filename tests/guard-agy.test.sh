#!/bin/bash
# .harness/guard-agy.test.sh — TDD tests for guard-agy.sh's single-writer
# denials (T27, issue #50). Simulates the agy PreToolUse hook payload shape
# (.toolCall.args.CommandLine -> {"decision": "allow"|"deny", ...}).
# Run: bash .harness/guard-agy.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$DIR/../lib/guard-agy.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_guard_agy() {
  local cmd="$1"
  jq -n --arg cmd "$cmd" '{toolCall: {args: {CommandLine: $cmd}}}' | bash "$GUARD"
}

expect_denied() {
  local desc="$1" cmd="$2"
  local out decision
  out="$(run_guard_agy "$cmd")"
  decision="$(echo "$out" | jq -r '.decision')"
  if [ "$decision" = "deny" ]; then
    pass "$desc"
  else
    fail "$desc (expected deny, got: $out)"
  fi
}

expect_allowed() {
  local desc="$1" cmd="$2"
  local out decision
  out="$(run_guard_agy "$cmd")"
  decision="$(echo "$out" | jq -r '.decision')"
  if [ "$decision" = "allow" ]; then
    pass "$desc"
  else
    fail "$desc (expected allow, got: $out)"
  fi
}

echo "== T27: single-writer rule -- git WRITE ops denied for agy =="
expect_denied "git restore is denied"                "git restore .harness/decisions.log"
expect_denied "git checkout (discard) is denied"      "git checkout -- .harness/handoff.md"
expect_denied "git checkout (branch switch) is denied" "git checkout uat"
expect_denied "git commit is denied"                  "git commit -m 'agy note'"
expect_denied "git reset is denied"                    "git reset HEAD~1"
expect_denied "git reset --hard is still denied (pre-existing rule)" "git reset --hard origin/uat"

echo "== regression: pre-existing G-series bans still work =="
expect_denied "rm -rf is still denied"                "rm -rf /tmp/whatever"
expect_denied "git push --force is still denied"      "git push --force origin uat"
expect_denied "push -f shorthand is still denied"      "git push -f origin uat"
expect_denied "git clean is still denied"              "git clean -fd"
expect_denied "write into career-ops/ is still denied" "echo hi > career-ops/x.txt"

echo "== T27: read ops remain allowed for review =="
expect_allowed "git diff is allowed"                  "git diff origin/uat...feature/issue-50"
expect_allowed "git log is allowed"                   "git log --oneline -10"
expect_allowed "git show is allowed"                   "git show HEAD"
expect_allowed "git status is allowed"                 "git status"
expect_allowed "git branch --contains is allowed"      "git branch --contains abc123"
expect_allowed "gh pr diff is allowed"                 "gh pr diff 50"
expect_allowed "gh pr view is allowed"                  "gh pr view 50"
expect_allowed "gh pr review (the actual review action) is allowed" "gh pr review 50 --approve -b 'LGTM'"
expect_allowed "ordinary read command is allowed"      "ls -la"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
