#!/bin/bash
# .harness/guard.test.sh — TDD tests for guard.sh (T15 merge-discipline guard,
# plus regression coverage for pre-existing G-series behaviors).
# Run: bash .harness/guard.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$DIR/../lib/guard.sh"

PASS=0
FAIL=0

# run_guard <command> <cwd-branch> [orchestrator.yaml contents]
# Simulates the PreToolUse hook payload and runs guard.sh with HEAD checked
# out on <cwd-branch> in a throwaway repo, so the current-branch checks
# (git merge, bare git push) have something real to read. If a third arg is
# given, it's written as orchestrator.yaml in that throwaway repo so T21's
# config-driven protected_paths has something to read; otherwise the repo
# has no orchestrator.yaml, exercising the fail-closed default.
run_guard() {
  local command="$1"
  local branch="$2"
  local yaml_content="${3:-}"

  local tmp
  tmp="$(mktemp -d)"
  git init -q "$tmp"
  # A fresh CI runner has no global git identity configured (unlike a dev
  # machine, which always happened to have one already) -- set it locally
  # so `git commit` doesn't fail with "empty ident name".
  git -C "$tmp" config user.email "test@test.local"
  git -C "$tmp" config user.name "test"
  git -C "$tmp" commit -q --allow-empty -m init
  git -C "$tmp" branch -f "$branch" HEAD >/dev/null 2>&1 || true
  git -C "$tmp" checkout -q "$branch" 2>/dev/null || git -C "$tmp" checkout -q -b "$branch"

  if [ -n "$yaml_content" ]; then
    printf '%s\n' "$yaml_content" > "$tmp/orchestrator.yaml"
  fi

  local payload
  payload="$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')"

  local out status
  out="$(cd "$tmp" && echo "$payload" | bash "$GUARD" 2>&1)"
  status=$?

  rm -rf "$tmp"
  GUARD_OUT="$out"
  GUARD_STATUS=$status
}

expect_blocked() {
  local desc="$1" command="$2" branch="${3:-main}" yaml="${4:-}"
  run_guard "$command" "$branch" "$yaml"
  if [ "$GUARD_STATUS" -eq 2 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 2, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

expect_allowed() {
  local desc="$1" command="$2" branch="${3:-feature/issue-99}" yaml="${4:-}"
  run_guard "$command" "$branch" "$yaml"
  if [ "$GUARD_STATUS" -eq 0 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 0, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

echo "== T15: git merge into protected branches =="
expect_blocked "git merge while on main is blocked"        "git merge feature/issue-1" "main"
expect_blocked "git merge while on uat is blocked"         "git merge feature/issue-1" "uat"
expect_allowed "git merge while on a feature branch is ok" "git merge origin/uat"      "feature/issue-99"

echo "== T15: git push targeting protected branches =="
expect_blocked "git push origin main is blocked"                 "git push origin main"
expect_blocked "git push origin HEAD:main is blocked"             "git push origin HEAD:main"
expect_blocked "git push origin feature/x:uat is blocked"         "git push origin feature/x:uat"
expect_blocked "bare git push while on main is blocked"           "git push" "main"
expect_blocked "bare git push while on uat is blocked"            "git push" "uat"
expect_allowed "git push origin feature/issue-20 is allowed"      "git push origin feature/issue-20"
expect_allowed "bare git push on a feature branch is allowed"     "git push" "feature/issue-20"
expect_allowed "git push -u origin feature/issue-20 is allowed"   "git push -u origin feature/issue-20"

echo "== T15: gh pr merge =="
expect_blocked "gh pr merge is always blocked"           "gh pr merge 20"
expect_blocked "gh pr merge --squash is blocked"         "gh pr merge 20 --squash"
expect_allowed "gh pr create is allowed"                 "gh pr create --base uat --title x --body y"

echo "== regression: pre-existing G-series behaviors =="
expect_blocked "rm -rf is still blocked"                 "rm -rf /tmp/foo"
expect_blocked "git push --force is still blocked"       "git push --force origin feature/x"
expect_blocked "git reset --hard is still blocked"       "git reset --hard HEAD~1"
expect_blocked "write into career-ops/ is still blocked" "echo hi > career-ops/x.txt"
expect_blocked "script exec outside .harness/ is still blocked" "bash /tmp/whatever.sh"
expect_allowed "script exec inside .harness/ is still allowed"  "bash .harness/log-decision.sh 'a|b|c'"
expect_allowed "ordinary read command is allowed"        "ls -la"

echo "== T29 (issue #55): git push resolves branch from a leading 'cd' in the command, not the hook's own CWD =="
# run_guard_worktree_push <command> <expect: blocked|allowed>
# Reproduces the real-world shape of the bug: the hook process's own CWD is
# a main checkout on a protected branch, but the guarded command itself
# leads with `cd <worktree> &&` into a real git worktree on a feature
# branch before running git push. Unlike run_guard (which always invokes
# guard.sh already sitting in the branch-under-test's directory), this
# keeps guard.sh's CWD fixed at the main checkout and lets the command
# string's own `cd` be the only way to reach the worktree -- exactly what
# a bare `cd .claude/worktrees/issue-N && git push` from a real session
# looks like to the hook.
run_guard_worktree_push() {
  local command="$1"

  local main_repo worktree_dir
  main_repo="$(mktemp -d)"
  git init -q "$main_repo"
  git -C "$main_repo" config user.email "test@test.local"
  git -C "$main_repo" config user.name "test"
  git -C "$main_repo" commit -q --allow-empty -m init
  git -C "$main_repo" branch -f uat HEAD >/dev/null 2>&1 || true
  git -C "$main_repo" checkout -q uat 2>/dev/null || git -C "$main_repo" checkout -q -b uat

  worktree_dir="$(mktemp -d)"
  rmdir "$worktree_dir"
  git -C "$main_repo" worktree add -q -b feature/issue-99 "$worktree_dir" uat >/dev/null 2>&1

  local resolved_command="${command//WORKTREE_DIR/$worktree_dir}"
  local payload
  payload="$(jq -n --arg cmd "$resolved_command" '{tool_input: {command: $cmd}}')"

  local out status
  out="$(cd "$main_repo" && echo "$payload" | bash "$GUARD" 2>&1)"
  status=$?

  git -C "$main_repo" worktree remove -f "$worktree_dir" >/dev/null 2>&1
  rm -rf "$main_repo" "$worktree_dir"
  GUARD_OUT="$out"
  GUARD_STATUS=$status
}

expect_worktree_allowed() {
  local desc="$1" command="$2"
  run_guard_worktree_push "$command"
  if [ "$GUARD_STATUS" -eq 0 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 0, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

expect_worktree_blocked() {
  local desc="$1" command="$2"
  run_guard_worktree_push "$command"
  if [ "$GUARD_STATUS" -eq 2 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 2, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

expect_worktree_allowed "bare push from 'cd worktree && git push' is allowed (hook CWD stays on main checkout/uat)" \
  "cd WORKTREE_DIR && git push"
expect_worktree_blocked "'cd worktree && git push origin main' still blocked (explicit protected refspec)" \
  "cd WORKTREE_DIR && git push origin main"
expect_worktree_blocked "bare 'git push' with NO cd still blocked (hook CWD itself is on uat)" \
  "git push"

echo "== T21: protected paths from orchestrator.yaml =="
NO_YAML=""
CAREER_OPS_YAML=$'protected_paths:\n  - career-ops/'
CUSTOM_YAML=$'protected_paths:\n  - vendor/legacy/'
INLINE_YAML='protected_paths: [vendor/legacy/, docs/frozen/]'
MALFORMED_YAML='this is not yaml at all {{{ :::'

expect_blocked "missing orchestrator.yaml still blocks career-ops/ (fail closed)" \
  "echo hi > career-ops/x.txt" "feature/issue-99" "$NO_YAML"
expect_blocked "malformed orchestrator.yaml still blocks career-ops/ (fail closed)" \
  "echo hi > career-ops/x.txt" "feature/issue-99" "$MALFORMED_YAML"
expect_blocked "config explicitly listing career-ops/ blocks it" \
  "echo hi > career-ops/x.txt" "feature/issue-99" "$CAREER_OPS_YAML"
expect_blocked "custom protected_paths blocks its own path" \
  "echo hi > vendor/legacy/x.txt" "feature/issue-99" "$CUSTOM_YAML"
expect_allowed "custom protected_paths no longer blocks career-ops/" \
  "echo hi > career-ops/x.txt" "feature/issue-99" "$CUSTOM_YAML"
expect_blocked "inline-list protected_paths blocks a listed path" \
  "cp a docs/frozen/b" "feature/issue-99" "$INLINE_YAML"

echo "== issue #116 follow-up (agy REQUEST-CHANGES on PR #3): protected branches include the CONFIGURED integration_branch =="
DEVELOP_YAML=$'integration_branch: develop'
expect_blocked "git push targeting a CONFIGURED custom integration_branch is blocked, not just main/uat" \
  "git push origin develop" "feature/issue-99" "$DEVELOP_YAML"
expect_blocked "git merge while ON the configured custom integration_branch is blocked" \
  "git merge feature/issue-1" "develop" "$DEVELOP_YAML"
expect_blocked "main/uat protection is NOT lost when a different custom integration_branch is configured" \
  "git push origin main" "feature/issue-99" "$DEVELOP_YAML"
expect_allowed "pushing a branch that is neither main/uat nor the configured integration_branch stays allowed" \
  "git push origin feature/issue-20" "feature/issue-99" "$DEVELOP_YAML"

echo "== issue #116 follow-up (agy REQUEST-CHANGES on PR #3): script-exec trusts THIS orc installation's own bin/lib/hooks/tests, not just .harness/ =="
# run_guard's throwaway scratch repo has no tests/lib/ subdirs of its own,
# so it can't exercise "does SCRIPT resolve under ORC_INSTALL_ROOT" --
# this repo (agent-orchestra) IS an orc installation, so run guard.sh with
# CWD at the real REPO_ROOT to check against the real bin/lib/hooks/tests.
run_guard_at_repo_root() {
  local command="$1"
  local payload out status
  payload="$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')"
  out="$(cd "$REPO_ROOT" && echo "$payload" | bash "$GUARD" 2>&1)"
  status=$?
  GUARD_OUT="$out"
  GUARD_STATUS=$status
}
REPO_ROOT="$(cd "$DIR/.." >/dev/null 2>&1 && pwd)"

run_guard_at_repo_root "bash tests/guard.test.sh"
if [ "$GUARD_STATUS" -eq 0 ]; then
  echo "PASS: running this repo's OWN test suite (bash tests/foo.test.sh) is trusted, not just .harness/*"; PASS=$((PASS + 1))
else
  echo "FAIL: running this repo's OWN test suite should be trusted (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

run_guard_at_repo_root "bash lib/orc-worktree.sh finish 116"
if [ "$GUARD_STATUS" -eq 0 ]; then
  echo "PASS: running this repo's OWN lib script (bash lib/foo.sh) is trusted"; PASS=$((PASS + 1))
else
  echo "FAIL: running this repo's OWN lib script should be trusted (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

run_guard_at_repo_root "bash /tmp/whatever.sh"
if [ "$GUARD_STATUS" -eq 2 ]; then
  echo "PASS: a script OUTSIDE both .harness/ and this orc installation is still blocked"; PASS=$((PASS + 1))
else
  echo "FAIL: a script outside both trusted locations should still be blocked (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

run_guard_at_repo_root "bash /tmp/some-other-place/lib/evil.sh"
if [ "$GUARD_STATUS" -eq 2 ]; then
  echo "PASS: a directory merely NAMED lib/ elsewhere (not this installation) is still blocked, not trusted by name alone"; PASS=$((PASS + 1))
else
  echo "FAIL: a directory named lib/ outside this installation should still be blocked (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

echo "== issue #18 B1 (item 8): script-exec trusts the nested project/<name>/ dev-target clone (+ its worktrees), same as .harness/ =="
run_guard_at_repo_root "bash project/agent-orchestra/tests/guard.test.sh"
if [ "$GUARD_STATUS" -eq 0 ]; then
  echo "PASS: a script under project/<name>/ (the nested clone-per-project dev target) is trusted"; PASS=$((PASS + 1))
else
  echo "FAIL: a script under project/<name>/ should be trusted (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

run_guard_at_repo_root "bash project/agent-orchestra/.worktrees/issue-11-10/tests/guard.test.sh"
if [ "$GUARD_STATUS" -eq 0 ]; then
  echo "PASS: a script under a project/<name>/.worktrees/<branch>/ path is also trusted"; PASS=$((PASS + 1))
else
  echo "FAIL: a script under a project/ worktree should be trusted (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
