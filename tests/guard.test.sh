#!/bin/bash
# tests/guard.test.sh — tests for the THIN lib/guard.sh (#141 layer 3,
# issue #143). Run: bash tests/guard.test.sh
#
# The old 147-case suite tested parsing machinery (cd-tracking, variable
# tables, write-target extraction) that the redesign DELETED -- those
# cases died with the code. This suite pins the thin contract instead:
# 1. destructive commands deny, anchored at segment start;
# 2. quoted text never false-positives (#139's failure class);
# 3. no input shape crashes the guard (#140's failure class) -- exits
#    are always a clean 0 or 2, never a set -e death;
# 4. protected-path writes are EXPLICITLY allowed through here -- the
#    kernel (bin/orc-protect) owns that wall now. Posture, not a gap.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$(cd "$DIR/../lib" && pwd)/guard.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# run_guard <command string> -- runs guard.sh the way Claude Code does
# (tool_input JSON on stdin); sets GUARD_EXIT / GUARD_ERR.
run_guard() {
  local cmd="$1" json
  json=$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')
  GUARD_ERR="$(printf '%s' "$json" | bash "$GUARD" 2>&1 >/dev/null)"
  GUARD_EXIT=$?
}

expect_block() {
  local desc="$1" cmd="$2"
  run_guard "$cmd"
  if [ "$GUARD_EXIT" -eq 2 ] && [ -n "$GUARD_ERR" ]; then
    pass "$desc"
  else
    fail "$desc (exit=$GUARD_EXIT, err='$GUARD_ERR')"
  fi
}

expect_allow() {
  local desc="$1" cmd="$2"
  run_guard "$cmd"
  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc (exit=$GUARD_EXIT, err='$GUARD_ERR')"
  fi
}

echo "== destructive class: denied, anywhere in the segment chain =="
expect_block "leading rm -rf"                       'rm -rf /tmp/whatever'
expect_block "bare rm -rf"                          'rm -rf'
expect_block "rm -fr spelling"                      'rm -fr build/'
expect_block "rm -rf as a later segment"            'echo cleaning; rm -rf .'
expect_block "rm -rf after &&"                      'make clean && rm -rf dist'
expect_block "git reset --hard"                     'git reset --hard HEAD~1'
expect_block "bare reset --hard"                    'reset --hard origin/main'
expect_block "git clean"                            'git clean -fdx'
expect_block "git push --force"                     'git push --force origin main'
expect_block "git push -f mid-args"                 'git push -f origin main'
expect_block "git push trailing -f"                 'git push origin main -f'
expect_block "git push --force-with-lease"          'git push --force-with-lease origin feature/x'

echo "== anchoring: quoted/argument text never denies (#139 class) =="
expect_allow "banned text inside quoted echo"       'echo "rm -rf is dangerous"'
expect_allow "banned text as commit message"        'git commit -m "never git push --force"'
expect_allow "dispatch template with <verdict> in quotes" 'bash lib/dispatch.sh assign orchestra 100 "APPROVE: <verdict> anchored, see review-protocol.md"'

echo "== no-crash contract (#140 class): always a clean 0 or 2 =="
expect_allow "failing cd + redirect (crash shape)"  'cd /nonexistent_dir_xyz && echo hi > foo.txt'
expect_allow "failing cd ; write (fail-open shape)" 'cd /nonexistent_dir_xyz ; echo hi > foo.txt'
expect_allow "unresolvable var cd"                  'cd "$SOME_UNSET_DIR" && echo hi > out.txt'
expect_allow "empty command"                        ''

echo "== posture: protected-path writes pass HERE (kernel owns the wall) =="
# These were guard.sh denials before #141. They are ALLOWED by the thin
# guard on purpose: bin/orc-protect makes the kernel return EPERM, which
# no command spelling can dodge -- the exact bypasses #98/#84 proved this
# parser could never reliably deny.
expect_allow "#98 shape: cp + trailing redirect"    'cp /tmp/x .claude/settings.json 2>/dev/null'
expect_allow "direct redirect into .claude/"        'echo x > .claude/settings.json'

echo "== routine git stays open =="
expect_allow "plain push"                           'git push origin feature/issue-143'
expect_allow "branch-cleanup delete push"           'git push origin --delete feature/issue-142'
expect_allow "fetch --force (not a push)"           'git fetch --force --tags origin'
expect_allow "script exec"                          'bash tests/guard.test.sh'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
