#!/bin/bash
# .harness/guard-agy.test.sh — TDD tests for guard-agy.sh's single-writer
# denials. Simulates the agy PreToolUse hook payload shape
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

# run_guard_agy_in <cwd> <cmd> -- issue #15: same payload shape as
# run_guard_agy, but runs the guard FROM <cwd> so an orchestrator.yaml
# dropped there (or its absence) drives orc_protected_paths, matching
# guard-write.test.sh's run_guard_write pattern.
run_guard_agy_in() {
  local cwd="$1" cmd="$2"
  (cd "$cwd" && jq -n --arg cmd "$cmd" '{toolCall: {args: {CommandLine: $cmd}}}' | bash "$GUARD")
}

expect_denied_in() {
  local desc="$1" cwd="$2" cmd="$3"
  local out decision
  out="$(run_guard_agy_in "$cwd" "$cmd")"
  decision="$(echo "$out" | jq -r '.decision')"
  if [ "$decision" = "deny" ]; then
    pass "$desc"
  else
    fail "$desc (expected deny, got: $out)"
  fi
}

expect_allowed_in() {
  local desc="$1" cwd="$2" cmd="$3"
  local out decision
  out="$(run_guard_agy_in "$cwd" "$cmd")"
  decision="$(echo "$out" | jq -r '.decision')"
  if [ "$decision" = "allow" ]; then
    pass "$desc"
  else
    fail "$desc (expected allow, got: $out)"
  fi
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

echo "== issue #60 task A: gh pr checkout / git switch denied for agy =="
expect_denied "gh pr checkout is denied"                "gh pr checkout 60"
expect_denied "git switch is denied"                    "git switch main"

echo "== regression: pre-existing G-series bans still work =="
expect_denied "rm -rf is still denied"                "rm -rf /tmp/whatever"
expect_denied "git push --force is still denied"      "git push --force origin uat"
expect_denied "push -f shorthand is still denied"      "git push -f origin uat"
expect_denied "git clean is still denied"              "git clean -fd"

echo "== issue #18 B-i: the OLD project-specific career-ops/ ban is gone (project-agnostic) =="
expect_allowed "write into career-ops/ is no longer specially denied" "echo hi > career-ops/x.txt"

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

echo "== issue #15: protected_paths from orchestrator.yaml is enforced for agy (parameterized, like guard.sh/guard-write.sh) =="
TMP1="$(mktemp -d)"
printf 'protected_paths:\n  - vendor/legacy/\n' > "$TMP1/orchestrator.yaml"
expect_denied_in "a write into a configured protected_paths entry is denied for agy" \
  "$TMP1" "tee vendor/legacy/file.txt"
expect_denied_in "a redirect into a configured protected_paths entry is denied for agy" \
  "$TMP1" "echo hi > vendor/legacy/file.txt"
expect_allowed_in "a write OUTSIDE the configured protected_paths entry is still allowed" \
  "$TMP1" "echo hi > src/feature.txt"
rm -rf "$TMP1"

echo "== issue #15: no orchestrator.yaml / empty protected_paths -> no phantom blocks (issue #18 B-i precedent) =="
TMP2="$(mktemp -d)"
expect_allowed_in "no orchestrator.yaml at all -- an arbitrary write is allowed, not phantom-blocked" \
  "$TMP2" "echo hi > vendor/legacy/file.txt"
rm -rf "$TMP2"
TMP3="$(mktemp -d)"
printf 'project: test\n' > "$TMP3/orchestrator.yaml"
expect_allowed_in "orchestrator.yaml with no protected_paths key -- nothing extra denied" \
  "$TMP3" "echo hi > vendor/legacy/file.txt"
rm -rf "$TMP3"

echo "== issue #15: .claude//.agents/ stay protected BY DEFAULT for agy too (issue #31 precedent -- agy least bound, so most in need of this) =="
TMP4="$(mktemp -d)"
expect_denied_in "write into .claude/settings.json is denied for agy with NO orchestrator.yaml at all" \
  "$TMP4" "echo hi > .claude/settings.json"
expect_denied_in "write into .agents/hooks.json is denied for agy" \
  "$TMP4" "echo hi > .agents/hooks.json"
rm -rf "$TMP4"

echo "== issue #15: cd-then-relative-write into a protected path is still caught (same bypass class guard.sh closes) =="
TMP5="$(mktemp -d)"
mkdir -p "$TMP5/vendor/legacy"
printf 'protected_paths:\n  - vendor/legacy/\n' > "$TMP5/orchestrator.yaml"
expect_denied_in "cd into a protected dir then a relative write is still denied" \
  "$TMP5" "cd vendor/legacy && echo hi > file.txt"
rm -rf "$TMP5"

echo "== issue #15: an unverifiable write target (unresolved variable/substitution) fails closed =="
TMP6="$(mktemp -d)"
printf 'protected_paths:\n  - vendor/legacy/\n' > "$TMP6/orchestrator.yaml"
expect_denied_in "a redirect target hidden behind an untracked variable fails closed" \
  "$TMP6" 'echo hi > $SOME_UNTRACKED_VAR'
rm -rf "$TMP6"

echo "== issue #15: a read-only command merely MENTIONING a protected path text stays allowed (no false positive, #39 precedent) =="
TMP7="$(mktemp -d)"
printf 'protected_paths:\n  - vendor/legacy/\n' > "$TMP7/orchestrator.yaml"
expect_allowed_in "git diff on a path that happens to be configured protected is allowed (read, not write)" \
  "$TMP7" "git diff vendor/legacy/file.txt"
expect_allowed_in "grep mentioning a protected path in its pattern text is allowed" \
  "$TMP7" "grep vendor/legacy vendor/legacy/file.txt"
rm -rf "$TMP7"

echo "== issue #15 agy REQUEST-CHANGES finding 1: a variable in a cd argument must fail closed, not silently evaluate writes against the wrong (unchanged) cwd =="
expect_denied "DIR=.claude && cd \$DIR && echo hi > settings.json fails closed (real shell expands \$DIR into .claude, guard must not silently miss it)" \
  'DIR=.claude && cd $DIR && echo hi > settings.json'

echo "== issue #15 agy REQUEST-CHANGES finding 2: an embedded (non-edge) quote in a cd argument must fail closed =="
expect_denied "cd .clau\"de\" && echo hi > settings.json fails closed (real shell removes the inline quotes and enters .claude)" \
  'cd .clau"de" && echo hi > settings.json'

echo "== issue #15 fix-round regression: guard-agy.sh must never CRASH (no JSON at all) on an ordinary failed cd -- always emit a clean decision =="
OUT="$(run_guard_agy 'cd this-directory-does-not-exist-anywhere && echo hi > foo.txt')"
STATUS=$?
if [ "$STATUS" -eq 0 ] && echo "$OUT" | jq -e '.decision' >/dev/null 2>&1; then
  pass "an ordinary failed cd (no special chars) still emits valid JSON, no crash"
else
  fail "guard-agy.sh crashed or emitted invalid JSON on a plain failed cd (status=$STATUS): $OUT"
fi
DECISION="$(echo "$OUT" | jq -r '.decision' 2>/dev/null)"
if [ "$DECISION" = "deny" ]; then
  pass "an unresolvable cd (even with no special chars) fails closed rather than silently continuing at the wrong cwd"
else
  fail "expected deny for an unresolvable cd target, got: $OUT"
fi

echo "== issue #15 agy REQUEST-CHANGES round 2 finding: cd - must fail closed (guard cannot predict \$OLDPWD across arbitrary commands) =="
TMP8="$(mktemp -d)"
mkdir -p "$TMP8/protected_dir"
printf 'protected_paths:\n  - protected_dir/\n' > "$TMP8/orchestrator.yaml"
expect_denied_in "cd protected_dir; cd /tmp; cd - fails closed (real shell returns to protected_dir via \$OLDPWD)" \
  "$TMP8" 'cd protected_dir; cd /tmp; cd - && echo hi > settings.json'
rm -rf "$TMP8"

echo "== issue #15 fix-round: bare cd (no argument) is the SAME failure class as cd - (targets \$HOME, unpredictable) -- closed proactively =="
expect_denied "a bare cd with no argument fails closed" \
  'cd && echo hi > settings.json'

echo "== issue #15 agy REQUEST-CHANGES round 3 + Orchestra design call: cd-tracking flipped denylist->allowlist -- tilde expansion (and any other unlisted shell metacharacter) fails closed =="
TMP9="$(mktemp -d)"
mkdir -p "$TMP9/~/.claude"
expect_denied_in "cd ~/.claude fails closed even with a REAL literal '~' decoy dir present (guard must not just fall back on 'target does not exist' -- the decoy exists, only the tilde-awareness itself can catch this)" \
  "$TMP9" 'cd ~/.claude && echo hi > settings.json'
rm -rf "$TMP9"
expect_denied "a cd argument containing a space fails closed (allowlist, not a denylist -- err strict per Orchestra's design call)" \
  'cd "some dir" && echo hi > settings.json'
expect_denied "a cd argument containing a glob star fails closed" \
  'cd some*dir && echo hi > settings.json'
expect_denied "a cd argument containing a brace-expansion character fails closed" \
  'cd some{a,b}dir && echo hi > settings.json'

echo "== issue #15 fix-round regression: a normal, resolvable cd (properly quoted, no embedded quotes) still works =="
expect_allowed "cd into a real, edge-quoted directory with an unrelated write still allowed" \
  'cd "lib" && echo hi > /tmp/not-a-real-write-target-just-parsed.txt'

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
