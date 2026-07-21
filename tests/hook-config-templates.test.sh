#!/bin/bash
# tests/hook-config-templates.test.sh — issue #10 / #31: templates/settings.json
# and templates/agents-hooks.json are the tracked, canonical source of truth
# for .claude/settings.json and .agents/hooks.json (both gitignored per-room
# artifacts). This is what would have caught #10's live incident: the
# quota-stop-gate hook shipped in PR #17 but was never wired into this
# room's .claude/settings.json, because #18 removed the trampoline that had
# wired it and the direct rewire dropped it -- nothing tracked caught the
# omission.
# Run: bash tests/hook-config-templates.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
SETTINGS_TEMPLATE="$REPO_ROOT/templates/settings.json"
AGENTS_HOOKS_TEMPLATE="$REPO_ROOT/templates/agents-hooks.json"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== templates/settings.json exists and is valid JSON =="
if [ -f "$SETTINGS_TEMPLATE" ]; then
  pass "templates/settings.json exists"
else
  fail "templates/settings.json does not exist"
fi
if [ -f "$SETTINGS_TEMPLATE" ] && jq empty "$SETTINGS_TEMPLATE" >/dev/null 2>&1; then
  pass "templates/settings.json is valid JSON"
else
  fail "templates/settings.json is missing or not valid JSON"
fi

echo "== issue #10: quota-stop-gate.sh is wired as the FIRST PreToolUse hook (matcher .*) =="
if [ -f "$SETTINGS_TEMPLATE" ]; then
  FIRST_PRETOOLUSE_MATCHER="$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$SETTINGS_TEMPLATE")"
  FIRST_PRETOOLUSE_CMD="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$SETTINGS_TEMPLATE")"
  if [ "$FIRST_PRETOOLUSE_MATCHER" = ".*" ] && echo "$FIRST_PRETOOLUSE_CMD" | grep -q "quota-stop-gate.sh"; then
    pass "quota-stop-gate.sh is the first PreToolUse hook, matcher .*"
  else
    fail "expected the FIRST PreToolUse entry to be matcher '.*' running quota-stop-gate.sh, got matcher='$FIRST_PRETOOLUSE_MATCHER' command='$FIRST_PRETOOLUSE_CMD'"
  fi
fi

echo "== templates/settings.json still wires the existing guards + lifecycle hooks (no regression) =="
if [ -f "$SETTINGS_TEMPLATE" ]; then
  ALL_PRETOOLUSE="$(jq -r '.hooks.PreToolUse[].hooks[0].command' "$SETTINGS_TEMPLATE" 2>/dev/null)"
  for expected in guard.sh guard-write.sh; do
    if echo "$ALL_PRETOOLUSE" | grep -q "$expected"; then
      pass "PreToolUse still wires $expected"
    else
      fail "expected PreToolUse to still wire $expected, got: $ALL_PRETOOLUSE"
    fi
  done
  for hook_event in SessionStart PreCompact Stop StopFailure; do
    CMD="$(jq -r ".hooks.${hook_event}[0].hooks[0].command // empty" "$SETTINGS_TEMPLATE")"
    if [ -n "$CMD" ]; then
      pass "$hook_event hook is still wired ($CMD)"
    else
      fail "expected $hook_event hook to still be wired"
    fi
  done
fi

echo "== issue #31: templates/agents-hooks.json exists, guard-quota-stop-agy.sh wired FIRST =="
if [ -f "$AGENTS_HOOKS_TEMPLATE" ] && jq empty "$AGENTS_HOOKS_TEMPLATE" >/dev/null 2>&1; then
  pass "templates/agents-hooks.json exists and is valid JSON"
else
  fail "templates/agents-hooks.json is missing or not valid JSON"
fi
if [ -f "$AGENTS_HOOKS_TEMPLATE" ]; then
  FIRST_AGY_CMD="$(jq -r '."agy-guard".PreToolUse[0].hooks[0].command // empty' "$AGENTS_HOOKS_TEMPLATE")"
  SECOND_AGY_CMD="$(jq -r '."agy-guard".PreToolUse[0].hooks[1].command // empty' "$AGENTS_HOOKS_TEMPLATE")"
  if echo "$FIRST_AGY_CMD" | grep -q "guard-quota-stop-agy.sh"; then
    pass "guard-quota-stop-agy.sh is wired FIRST under agy-guard's PreToolUse"
  else
    fail "expected guard-quota-stop-agy.sh to be the FIRST agy-guard hook, got: $FIRST_AGY_CMD"
  fi
  if echo "$SECOND_AGY_CMD" | grep -q "guard-agy.sh"; then
    pass "guard-agy.sh still wired second under agy-guard's PreToolUse (no regression)"
  else
    fail "expected guard-agy.sh to still be wired second, got: $SECOND_AGY_CMD"
  fi
  THIRD_AGY_CMD="$(jq -r '."agy-guard".PreToolUse[0].hooks[2].command // empty' "$AGENTS_HOOKS_TEMPLATE")"
  if echo "$THIRD_AGY_CMD" | grep -q "guard-room-branch-agy.sh"; then
    pass "issue #60: guard-room-branch-agy.sh wired third under agy-guard's PreToolUse"
  else
    fail "expected guard-room-branch-agy.sh to be wired third, got: $THIRD_AGY_CMD"
  fi
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
