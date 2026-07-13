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
expect_allowed "no orchestrator.yaml: write anywhere is allowed, no hardcoded default path (issue #18 B-i)" "echo hi > some-dir/x.txt"
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

echo "== T21 / issue #18 B-i: protected paths from orchestrator.yaml, EMPTY default (no hardcoded project name) =="
NO_YAML=""
EXAMPLE_YAML=$'protected_paths:\n  - vendor/legacy/'
CUSTOM_YAML=$'protected_paths:\n  - vendor/legacy/'
INLINE_YAML='protected_paths: [vendor/legacy/, docs/frozen/]'
MALFORMED_YAML='this is not yaml at all {{{ :::'

expect_allowed "missing orchestrator.yaml: the OLD hardcoded default (career-ops/) is gone, write allowed (issue #18 B-i)" \
  "echo hi > career-ops/x.txt" "feature/issue-99" "$NO_YAML"
expect_allowed "malformed orchestrator.yaml: the OLD hardcoded default (career-ops/) is gone, write allowed (issue #18 B-i)" \
  "echo hi > career-ops/x.txt" "feature/issue-99" "$MALFORMED_YAML"
expect_blocked "config explicitly listing a path blocks it" \
  "echo hi > vendor/legacy/x.txt" "feature/issue-99" "$EXAMPLE_YAML"
expect_blocked "custom protected_paths blocks its own path" \
  "echo hi > vendor/legacy/x.txt" "feature/issue-99" "$CUSTOM_YAML"
expect_allowed "custom protected_paths does not widen to anything not listed" \
  "echo hi > some-other-dir/x.txt" "feature/issue-99" "$CUSTOM_YAML"
expect_blocked "inline-list protected_paths blocks a listed path" \
  "cp a docs/frozen/b" "feature/issue-99" "$INLINE_YAML"

echo "== issue #31: .claude/ and .agents/ are protected BY DEFAULT against Bash-redirect writes too, independent of orchestrator.yaml =="
# agy's probe-3 on PR #30: an agent could spoof ORC_ONESHOT by editing
# .claude/settings.json -- guard-write.sh (the Write/Edit tool guard) is one
# path in, but a Bash redirect (`echo ... > .claude/settings.json`) bypasses
# the Write/Edit tool entirely and only guard.sh's command-string inspection
# would ever see it. Both guards must close this, not just one.
expect_blocked "Bash redirect into .claude/settings.json is blocked with NO orchestrator.yaml at all" \
  "echo 'ORC_ONESHOT=1 bash hooks/check-handoff.sh' > .claude/settings.json" "feature/issue-99" "$NO_YAML"
expect_blocked "Bash redirect into .agents/hooks.json is blocked with NO orchestrator.yaml at all" \
  "echo hi > .agents/hooks.json" "feature/issue-99" "$NO_YAML"
expect_blocked ".claude/ default protection (Bash path) is NOT overridden by an orchestrator.yaml that doesn't mention it" \
  "echo hi > .claude/settings.json" "feature/issue-99" "$CUSTOM_YAML"

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

echo "== issue #18 B1 (item 8) + agy REQUEST-CHANGES (PR #17): script-exec trusts the nested project/<name>/ dev-target clone (+ its worktrees) by REAL location, same as .harness/ =="
# A dedicated sandbox (throwaway install root with a COPY of guard.sh and
# real files under project/<name>/...) rather than this repo's own
# checkout: the FIX requires real directory resolution (`cd` + `pwd -P`),
# and this worktree doesn't nest a project/agent-orchestra/ inside itself
# (only the OUTER self-dogfood checkout does), so there's no real path
# here to resolve against.
GUARD_SRC="$GUARD"
ORC_CONFIG_SRC="$DIR/../lib/orc-config.sh"
CMD_INSPECT_SRC="$DIR/../lib/cmd-inspect-lib.sh"

run_guard_in_sandbox() { # $1 = command
  local command="$1"
  local sandbox out status
  sandbox="$(mktemp -d)"
  sandbox="$(cd "$sandbox" && pwd -P)"
  mkdir -p "$sandbox/lib" "$sandbox/project/agent-orchestra/tests" \
    "$sandbox/project/agent-orchestra/.worktrees/issue-11-10/tests"
  cp "$GUARD_SRC" "$sandbox/lib/guard.sh"
  cp "$ORC_CONFIG_SRC" "$sandbox/lib/orc-config.sh"
  cp "$CMD_INSPECT_SRC" "$sandbox/lib/cmd-inspect-lib.sh"
  touch "$sandbox/project/agent-orchestra/tests/real.sh"
  touch "$sandbox/project/agent-orchestra/.worktrees/issue-11-10/tests/real.sh"
  local payload
  payload="$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')"
  out="$(cd "$sandbox" && echo "$payload" | bash lib/guard.sh 2>&1)"
  status=$?
  rm -rf "$sandbox"
  SANDBOX_OUT="$out"
  SANDBOX_STATUS=$status
}

run_guard_in_sandbox "bash project/agent-orchestra/tests/real.sh"
if [ "$SANDBOX_STATUS" -eq 0 ]; then
  echo "PASS: a script under project/<name>/ (the nested clone-per-project dev target) is trusted"; PASS=$((PASS + 1))
else
  echo "FAIL: a script under project/<name>/ should be trusted (status=$SANDBOX_STATUS): $SANDBOX_OUT"; FAIL=$((FAIL + 1))
fi

run_guard_in_sandbox "bash project/agent-orchestra/.worktrees/issue-11-10/tests/real.sh"
if [ "$SANDBOX_STATUS" -eq 0 ]; then
  echo "PASS: a script under a project/<name>/.worktrees/<branch>/ path is also trusted"; PASS=$((PASS + 1))
else
  echo "FAIL: a script under a project/ worktree should be trusted (status=$SANDBOX_STATUS): $SANDBOX_OUT"; FAIL=$((FAIL + 1))
fi
echo "== agy REQUEST-CHANGES (PR #17): project/ trust must resolve the REAL canonicalized directory, not glob-match the raw string (path traversal + symlink-out) =="
# The project/*|./project/*|*/project/* glob used to match the RAW $SCRIPT
# string with no resolution at all -- `bash project/../../../tmp/evil.sh`
# satisfied the glob (starts with "project/") and was trusted outright,
# completely bypassing the ORC_INSTALL_ROOT location check that gates
# every other path.
run_guard_in_sandbox "bash project/../../../../../../../../tmp/evil.sh"
if [ "$SANDBOX_STATUS" -eq 2 ]; then
  echo "PASS: SECURITY -- a project/../../.. traversal escaping the install root is blocked, not trusted by the raw glob"; PASS=$((PASS + 1))
else
  echo "FAIL: SECURITY REGRESSION -- project/../../.. traversal should be blocked (status=$SANDBOX_STATUS): $SANDBOX_OUT"; FAIL=$((FAIL + 1))
fi

run_guard_in_sandbox2() { # $1 = command, builds a sandbox with a symlink + a sibling dir
  local command="$1"
  local sandbox outside out status
  sandbox="$(mktemp -d)"
  sandbox="$(cd "$sandbox" && pwd -P)"
  outside="$(mktemp -d)"
  outside="$(cd "$outside" && pwd -P)"
  mkdir -p "$sandbox/lib" "$sandbox/project"
  cp "$GUARD_SRC" "$sandbox/lib/guard.sh"
  cp "$ORC_CONFIG_SRC" "$sandbox/lib/orc-config.sh"
  cp "$CMD_INSPECT_SRC" "$sandbox/lib/cmd-inspect-lib.sh"
  echo "evil" > "$outside/evil.sh"
  ln -s "$outside" "$sandbox/project/escape"
  ln -s "$outside" "$sandbox/project-evil"
  local payload
  payload="$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')"
  out="$(cd "$sandbox" && echo "$payload" | bash lib/guard.sh 2>&1)"
  status=$?
  rm -rf "$sandbox" "$outside"
  SANDBOX_OUT="$out"
  SANDBOX_STATUS=$status
}

run_guard_in_sandbox2 "bash project/escape/evil.sh"
if [ "$SANDBOX_STATUS" -eq 2 ]; then
  echo "PASS: SECURITY -- a symlink under project/ that resolves OUTSIDE the install root is blocked"; PASS=$((PASS + 1))
else
  echo "FAIL: SECURITY REGRESSION -- a project/ symlink escaping the install root should be blocked (status=$SANDBOX_STATUS): $SANDBOX_OUT"; FAIL=$((FAIL + 1))
fi

run_guard_in_sandbox2 "bash project-evil/evil.sh"
if [ "$SANDBOX_STATUS" -eq 2 ]; then
  echo "PASS: a sibling dir merely NAMED project-evil/ (prefix collision, not actually project/) is still resolved by real location, not trusted by name"; PASS=$((PASS + 1))
else
  echo "FAIL: project-evil/ (prefix collision, resolves outside the install root) should still be blocked (status=$SANDBOX_STATUS): $SANDBOX_OUT"; FAIL=$((FAIL + 1))
fi

echo "== issue #39: the protected-path check inspects the RESOLVED write target, not the raw command TEXT =="
# The #31 protection (above) substring-grepped the WHOLE command string for
# a literal protected-path string. Two failure directions, both live before
# this fix: (a) a variable or a leading `cd` makes the literal text vanish
# while the shell still writes exactly there (a real trust-boundary bypass
# -- an agent could rewrite its own hook wiring); (b) it blocks ANY command
# whose TEXT merely MENTIONS a protected path, including read-only commands
# and unrelated write DATA that happens to describe the path -- it was
# actively corrupting decisions.log by forcing a reworded historical record
# to get a legitimate append past it. Fixed by resolving the ACTUAL write
# target (redirect target / write-verb file argument), tracking `cd` and
# simple `VAR=value` assignments across the command's own segments, and
# comparing the resolved, lexically-normalized target against the
# protected paths -- reusing lib/cmd-inspect-lib.sh's quote-aware scanner,
# the same machinery lib/quota-stop-lib.sh's qsg_command_allowed already
# proved through two rounds of agy security review, not a third
# hand-rolled parser.

# run_guard_protected_dir <command> -- like run_guard, but the tmp repo
# has a REAL .claude/ directory on disk so a `cd .claude && ...` in the
# command under test has somewhere real to land (guard.sh's own existing
# cd-tracking silently no-ops a `cd` into a directory that doesn't exist,
# same as a real shell would fail to cd there).
run_guard_protected_dir() {
  local command="$1"
  local tmp
  tmp="$(mktemp -d)"
  git init -q "$tmp"
  git -C "$tmp" config user.email "test@test.local"
  git -C "$tmp" config user.name "test"
  git -C "$tmp" commit -q --allow-empty -m init
  git -C "$tmp" checkout -q -b feature/issue-99
  mkdir -p "$tmp/.claude"
  local payload out status
  payload="$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')"
  out="$(cd "$tmp" && echo "$payload" | bash "$GUARD" 2>&1)"
  status=$?
  rm -rf "$tmp"
  GUARD_OUT="$out"
  GUARD_STATUS=$status
}

echo "-- required case 1: a variable hides the literal path text from the raw string, but the shell still writes there --"
run_guard_protected_dir 'V=.claude; echo x > $V/settings.json'
if [ "$GUARD_STATUS" -eq 2 ]; then
  echo "PASS: SECURITY -- 'V=.claude; echo x > \$V/settings.json' is blocked (resolved target, not raw text)"; PASS=$((PASS + 1))
else
  echo "FAIL: SECURITY REGRESSION (#39 bypass 1) -- a variable-hidden write into .claude/ should be blocked (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

echo "-- required case 2: a leading cd hides the literal path text, but the shell still writes there --"
run_guard_protected_dir 'cd .claude && echo x > settings.json'
if [ "$GUARD_STATUS" -eq 2 ]; then
  echo "PASS: SECURITY -- 'cd .claude && echo x > settings.json' is blocked (resolved via tracked cwd)"; PASS=$((PASS + 1))
else
  echo "FAIL: SECURITY REGRESSION (#39 bypass 2) -- a cd-hidden write into .claude/ should be blocked (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

echo "-- required case 3: a read-only command merely NAMING a protected path must pass --"
expect_allowed "read-only grep naming a protected path is allowed (no write at all)" \
  "grep -n 'pane-state' .claude/settings.json"
expect_allowed "read-only cat naming a protected path is allowed" \
  "cat .claude/settings.json"

echo "-- required case 4: a write to an UNPROTECTED path whose DATA merely mentions a protected path must pass -- this is the bug that was corrupting decisions.log --"
expect_allowed "appending decision text that DESCRIBES a protected path, to an unprotected file, is allowed" \
  'echo "found a bug: writes into .claude/settings.json were bypassable" >> notes.log'
expect_allowed "log-decision.sh-shaped call whose TEXT mentions .claude/ is allowed (the exact corruption case from the ticket)" \
  'bash .harness/log-decision.sh "builder|sonnet|fixed the .claude/settings.json bypass"'

echo "-- traversal: a .. that returns to an UNPROTECTED area must still pass (no over-blocking) --"
expect_allowed "a .. that lexically resolves OUT of .claude/ back to an unprotected path is allowed" \
  "echo x > .claude/sub/../../notprotected/file"

echo "-- traversal: a .. that resolves INTO a protected dir from an innocent-looking prefix must still block --"
expect_blocked "a .. that lexically resolves INTO .claude/ is blocked even though it starts under an unprotected dir" \
  "echo x > safe/../.claude/settings.json"

echo "-- quoting trick: splitting the literal path across an empty quoted section defeats a raw substring grep but not a real tokenizer --"
run_guard_protected_dir "echo x > .cla''ude/settings.json"
if [ "$GUARD_STATUS" -eq 2 ]; then
  echo "PASS: SECURITY -- a quote-split '.cla''ude/settings.json' still resolves to .claude/settings.json and is blocked"; PASS=$((PASS + 1))
else
  echo "FAIL: SECURITY REGRESSION (#39 quoting bypass) -- quote-split protected path should still resolve and block (status=$GUARD_STATUS): $GUARD_OUT"; FAIL=$((FAIL + 1))
fi

echo "-- agy's probe list: fd-prefixed redirects, tee, dd of=, cp/mv into the dir --"
expect_blocked "stderr redirect (2>) into a protected path is blocked" \
  "some-command 2> .claude/settings.json"
expect_blocked "&> redirect into a protected path is blocked" \
  "some-command &> .claude/settings.json"
expect_blocked "tee into a protected path is blocked" \
  "echo x | tee .claude/settings.json"
expect_blocked "dd of= into a protected path is blocked" \
  "dd if=/dev/zero of=.claude/settings.json"
expect_blocked "cp INTO a protected dir is blocked" \
  "cp notes.log .claude/settings.json"
expect_blocked "mv INTO a protected dir is blocked" \
  "mv notes.log .claude/settings.json"
expect_allowed "cp FROM a protected dir to an unprotected dest is allowed (only the destination is the write target)" \
  "cp .claude/settings.json /tmp/backup.json"

echo "-- unresolvable target fails CLOSED, same posture as the rest of this codebase --"
expect_blocked "a write target built from an UNTRACKED variable cannot be verified and fails closed" \
  'echo x > $UNTRACKED_VAR/settings.json'
expect_blocked "a write target built from command substitution cannot be verified and fails closed" \
  'echo x > "$(echo .claude)/settings.json"'

echo "-- sed without -i is read-only (prints to stdout); a bare '-i' substring inside the SCRIPT text must not be mistaken for the flag --"
expect_allowed "sed with no -i flag naming a protected path is allowed (read-only, prints to stdout)" \
  "sed 's/x/y/' .claude/settings.json"
expect_allowed "sed whose SCRIPT ARGUMENT merely contains the two characters '-i' is not mistaken for an in-place edit" \
  "sed 's/find-item/replace/' .claude/settings.json"
expect_blocked "sed -i (real in-place edit) into a protected path is still blocked" \
  "sed -i 's/x/y/' .claude/settings.json"

echo "== issue #39 round 2: agy's dedicated security pass on PR #57 found 4 further parser bypasses -- all confirmed real =="

echo "-- finding 1: a single & (background operator) was appended to the current segment instead of splitting it, hiding a second command from the verb check --"
expect_blocked "SECURITY -- 'echo a & tee .claude/settings.json' is blocked (bare & splits into its own segment, same as ;)" \
  "echo a & tee .claude/settings.json"
expect_allowed "a literal '&' inside quotes is still just data, not a segment split" \
  "echo 'a & b'"

echo "-- finding 2: command substitution can hide a write verb, or mangle a redirect target's suffix, past the tokenizer entirely --"
expect_blocked "SECURITY -- 'echo \$(tee .claude/settings.json)' is blocked (write verb hidden inside \$())" \
  'echo $(tee .claude/settings.json)'
expect_blocked "SECURITY -- 'echo \$(echo x > .claude/settings.json)' is blocked (redirect hidden inside \$())" \
  'echo $(echo x > .claude/settings.json)'
expect_blocked "SECURITY -- backtick form of the same hidden-write bypass is blocked" \
  'echo `tee .claude/settings.json`'
expect_allowed "an ordinary, non-write command substitution is NOT over-blocked (only fails closed when write-suggestive)" \
  'echo "branch: $(git branch --show-current)"'

echo "== issue #61: the suspicious-substitution scanner is escape/quote-aware -- INERT \$()/backtick text must not fail closed =="
# Root cause: the scanner used to gate on a raw substring match for '$(' or
# a backtick ANYWHERE in the segment text, with no regard for whether that
# text could ever actually expand. A single-quoted bare-verb example like
# '$(tee)' -- exactly the shape a decisions.log entry or a --title would use
# to CITE an example command, not run one -- reads identically to a live,
# unquoted $(tee) once quotes are stripped, so it tripped the same
# write-verb heuristic as a real bypass. Real bash never expands $(...)/`` `
# inside single quotes or after a backslash escape; it DOES still expand
# them inside double quotes and when unquoted -- the fix (orc_string_has_
# live_command_substitution in cmd-inspect-lib.sh) matches that exactly,
# gating the whole heuristic on there being at least one LIVE occurrence
# before ever looking for a write verb.
SQ="'"
expect_allowed "issue #61 -- a SINGLE-QUOTED \$(tee) is inert text (single quotes suppress expansion), not a live substitution" \
  "echo ${SQ}\$(tee)${SQ}"
expect_allowed "issue #61 -- a SINGLE-QUOTED backtick-tee-backtick is inert text, not a live substitution" \
  "echo ${SQ}\`tee\`${SQ}"
expect_allowed "issue #61 -- a BACKSLASH-ESCAPED \$(tee) is inert text (the backslash escapes the \$, so it never expands), not a live substitution" \
  'echo \$(tee)'
expect_blocked "SECURITY -- escape-awareness must NOT weaken real detection: an UNQUOTED, unescaped \$(tee) is still a live, write-suggestive substitution and stays blocked" \
  'echo $(tee)'
expect_blocked "SECURITY -- a write-verb \$() inside DOUBLE quotes is STILL live (double quotes do not suppress command substitution in real bash) and must stay blocked" \
  'echo "$(tee)"'
expect_blocked "SECURITY -- agy's PR #70 finding: a LITERAL single-quote INSIDE double quotes must not re-enter single-quote mode -- real bash treats it as a plain character, so the \$() right after it is still LIVE and must stay blocked" \
  'echo "'"'"'$(tee .claude/settings.json)'"'"'"'

echo "== issue #72: write-verb detection inside a LIVE substitution resolves the actually-executed token, not just an exact bare-word match =="
# agy's dedicated security pass on PR #70 round 2 (and Orchestra's
# independent live re-verification against merged main) found the
# word-based verb check was blind to anything but a bare, unquoted,
# unescaped verb as the immediate next word: an absolute path, a quoted
# or backslash-escaped verb, and a verb reached through a NESTED
# substitution all evaded it, on main, since #39 round 2 shipped -- not a
# #59/#61 regression, confirmed by testing the identical payloads against
# lib/cmd-inspect-lib.sh as it existed before any of those changes. Fix:
# resolve the actually-executed leading token of each live substitution's
# content (quote removal, backslash-unescaping, basename-of-path), fail
# CLOSED if that resolution hits another live construct (a nested
# substitution or an unresolvable variable) rather than guessing.
expect_blocked "SECURITY -- issue #72: an ABSOLUTE PATH to a write verb inside a live substitution is still write-suggestive (basename resolves to a known verb)" \
  'echo x | $(/usr/bin/tee .claude/settings.json)'
expect_blocked "SECURITY -- issue #72: the BACKTICK form of an absolute-path write verb is still write-suggestive" \
  'echo x | `/usr/bin/tee .claude/settings.json`'
expect_blocked "SECURITY -- issue #72: a BACKSLASH-ESCAPED verb character (\\tee, unescapes to the literal word 'tee') inside a live substitution is still write-suggestive" \
  'echo x | $(\tee .claude/settings.json)'
expect_blocked "SECURITY -- issue #72: a NESTED substitution used AS the verb itself cannot be resolved without executing it -- fails CLOSED rather than guessing" \
  'echo x | $( $(echo tee) .claude/settings.json )'
SQ="'"
expect_blocked "SECURITY -- issue #72: a SINGLE-QUOTED verb inside a live (unquoted) substitution still resolves to the literal verb" \
  "echo x | \$(${SQ}tee${SQ} .claude/settings.json)"
expect_blocked "SECURITY -- issue #72: a DOUBLE-QUOTED verb inside a live substitution still resolves to the literal verb" \
  'echo x | $("tee" .claude/settings.json)'
expect_blocked "SECURITY -- issue #72: a leading NAME=value ENV-PREFIX before the real verb (FOO=bar tee ...) does not hide the verb -- real bash still runs tee" \
  'echo x | $(FOO=bar tee .claude/settings.json)'
expect_allowed "issue #72 regression -- a resolvable, non-write leading token (git) inside a live substitution stays allowed (the #39-round-2 / #61 goal, must not be collateral damage)" \
  'echo "branch: $(git branch --show-current)"'
expect_blocked "issue #72 -- a write verb appearing LATER inside substitution content (not just as the immediate leading word) is still caught by the recursive content scan" \
  'echo $(git log; tee .claude/settings.json)'

echo "== issue #72 round 3 (agy): _orc_verb_is_write_suggestive must fail closed on grouping/executors, same as the top-level orc_segment_leading_verb check =="
# agy's dedicated security pass on PR #78: the new recursive verb
# resolver only compared against the tee/cp/mv/... write-verb list --
# it never inherited the SIBLING top-level check's fail-closed list for
# grouping ({, () and command executors (eval/env/time/sudo/nice/nohup/
# exec/xargs/command/builtin), first added in #39 round 2 specifically
# because those wrap/hide a real verb from word-based inspection. Verified
# live by agy: $({ tee .claude/settings.json; }) and $(eval "tee ...")
# both resolved their leading "verb" to "{"/"eval" -- neither is on the
# write-verb list, so the substitution was declared safe even though it
# writes.
expect_blocked "SECURITY -- issue #72 round 3: '{ ... }' BRACE GROUPING inside a live substitution hides the real verb from write-verb matching -- must fail closed like the top-level check does" \
  'echo $({ tee .claude/settings.json; })'
expect_blocked "SECURITY -- issue #72 round 3: '( ... )' SUBSHELL GROUPING inside a live substitution hides the real verb -- must fail closed (spaced like the existing top-level '( tee ... )' test so this isn't \$(( arithmetic expansion or a '(tee' fused word)" \
  'echo $( ( tee .claude/settings.json ) )'
expect_blocked "SECURITY -- issue #72 round 3: 'eval' inside a live substitution hides the real verb -- must fail closed" \
  'echo $(eval "tee .claude/settings.json")'
expect_blocked "SECURITY -- issue #72 round 3: 'time' inside a live substitution hides the real verb -- must fail closed" \
  'echo $(time tee .claude/settings.json)'
expect_blocked "SECURITY -- issue #72 round 3: 'env' inside a live substitution hides the real verb -- must fail closed" \
  'echo $(env tee .claude/settings.json)'
expect_blocked "SECURITY -- issue #72 round 3: 'sudo' inside a live substitution hides the real verb -- must fail closed" \
  'echo $(sudo tee .claude/settings.json)'
expect_allowed "issue #72 round 3 regression -- an ordinary, non-grouping, non-executor command inside a live substitution is NOT mistaken for one of these" \
  'echo $(echo hello)'

echo "== issue #72 round 3 (agy): PROCESS SUBSTITUTION >(...)/<(...) is a live command context this scanner didn't recognize at all =="
# agy's dedicated security pass on PR #78: >(...) and <(...) run their
# content as a live process exactly like $(...) does -- the redirect
# DIRECTION only decides whether the substitution's fd is fed TO or FROM
# the surrounding command, it has no bearing on whether the content
# executes (verified live by agy: `echo hello < <(tee .claude/settings.json)`
# still runs tee as a side effect of opening the process substitution,
# even though its output is only ever used as echo's stdin, never
# written anywhere). The scanner only ever looked for '$(' and a
# backtick, so this construct sailed through both this function AND
# (separately, pre-existing, unrelated to this PR) orc_segment_write_
# targets, which misreads ">(...)"'s content as an ordinary redirect
# TARGET path -- a harmless-looking nonexistent filename, not a live
# command -- and finds no protected-path match. This fix closes it at
# the substitution-scanner layer: '>(' / '<(' now open a live command
# context exactly like '$(' does (same matching-paren tracking, same
# recursive verb/content check), which blocks it before write-target
# resolution is ever reached. Unlike \$(...), process substitution is
# NOT recognized inside ANY quotes in real bash (not even double) -- it
# is UNQUOTED-ONLY syntax, so this only triggers in the unquoted branch.
expect_blocked "SECURITY -- issue #72 round 3: output process substitution '> >(tee ...)' runs tee as a live process regardless of what reads its output" \
  'echo hello > >(tee .claude/settings.json)'
expect_blocked "SECURITY -- issue #72 round 3: input process substitution '< <(tee ...)' STILL runs tee as a side effect of opening it, even though only its output is read" \
  'echo hello < <(tee .claude/settings.json)'
expect_allowed "issue #72 round 3 regression -- an ordinary, non-write process substitution stays allowed" \
  'diff <(echo a) <(echo b)'
expect_allowed "issue #72 round 3 regression -- '>(' / '<(' are literal text once double-quoted (real bash does not recognize process substitution inside quotes at all) and must not be over-blocked" \
  'echo "not a process sub: >(tee) <(tee)"'

echo "-- finding 3: grouping ({ }, ( )) and command executors (eval/env/time/sudo/...) hid the real verb from the leading-word check --"
expect_blocked "SECURITY -- '{ tee .claude/settings.json; }' brace-grouping bypass is blocked" \
  "{ tee .claude/settings.json; }"
expect_blocked "SECURITY -- '( tee .claude/settings.json )' subshell-grouping bypass is blocked" \
  "( tee .claude/settings.json )"
expect_blocked "SECURITY -- 'eval \"tee .claude/settings.json\"' is blocked" \
  'eval "tee .claude/settings.json"'
expect_blocked "SECURITY -- 'time tee .claude/settings.json' is blocked" \
  "time tee .claude/settings.json"
expect_blocked "SECURITY -- 'env tee .claude/settings.json' is blocked" \
  "env tee .claude/settings.json"
expect_blocked "SECURITY -- 'sudo tee .claude/settings.json' is blocked" \
  "sudo tee .claude/settings.json"
expect_allowed "an ordinary command is NOT mistaken for a grouping/executor wrapper" \
  "echo hello"

echo "-- finding 4: GNU cp/mv -t DIR (and --target-directory=DIR) inverts which argument is the destination -- the parser must not always trust 'last non-flag arg' --"
expect_blocked "SECURITY -- 'cp -t .claude/settings.json innocent_source' (-t target inversion) is blocked" \
  "cp -t .claude/settings.json innocent_source"
expect_blocked "SECURITY -- 'cp --target-directory=.claude/settings.json innocent_source' is blocked" \
  "cp --target-directory=.claude/settings.json innocent_source"
expect_blocked "SECURITY -- 'mv -t .claude/settings.json innocent_source' (-t target inversion) is blocked" \
  "mv -t .claude/settings.json innocent_source"
expect_allowed "an ordinary 'cp src dest' (no -t) still resolves dest as the LAST argument, unaffected" \
  "cp innocent_source /tmp/backup.json"

echo "== issue #59: an agent can still do its OWN documented job through this guard =="
# The point of #59 isn't "make the guard more permissive" -- it's "the
# guard's own designers never asserted their own workflows survive it".
# These two lock in the specific workarounds handoff.md had to document by
# hand: the brace-free inbox-check idiom, and dispatching via --body-file
# instead of command substitution.
expect_allowed "the documented brace-free inbox-check idiom (a 'for' loop with no { } grouping) is not blocked -- an agent can still check its own inbox" \
  'for m in .harness/inbox/builder/*.msg; do echo "$m"; cat "$m"; done'
REPO_ROOT="$(cd "$DIR/.." >/dev/null 2>&1 && pwd)"
run_guard_dispatch_bodyfile() {
  local payload out status
  payload="$(jq -n --arg cmd "bash lib/dispatch.sh assign builder 59 --body-file /tmp/scratch/dispatch-59.txt" '{tool_input: {command: $cmd}}')"
  out="$(cd "$REPO_ROOT" && echo "$payload" | bash "$GUARD" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "PASS: issue #59 -- dispatching via 'bash lib/dispatch.sh ... --body-file <path>' (no command substitution) is not blocked -- Orchestra can still dispatch a large body"; PASS=$((PASS + 1))
  else
    echo "FAIL: issue #59 -- --body-file dispatch should not be blocked (status=$status): $out"; FAIL=$((FAIL + 1))
  fi
}
run_guard_dispatch_bodyfile

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
