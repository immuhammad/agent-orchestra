#!/bin/bash
# tests/check-hook-wiring.test.sh — issue #10/#31: lib/check-hook-wiring.sh
# is the doctor-style check that verifies the RUNNING (gitignored,
# per-room) .claude/settings.json actually wires hooks/quota-stop-gate.sh.
# This is the only thing that would have caught #10's live incident: the
# gate shipped in PR #17 but was never wired into this room's config, and
# nothing tracked noticed since settings.json is gitignored per-room state.
# Run: bash tests/check-hook-wiring.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CHECK="$DIR/../lib/check-hook-wiring.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== issue #10: missing settings.json fails LOUDLY (exit 2 + explicit message), not silently =="
OUT="$(bash "$CHECK" "$TMP/nonexistent-settings.json" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "does not exist"; then
  pass "missing settings.json fails loudly with exit 2 and an explicit message"
else
  fail "expected exit 2 + explicit message for a missing settings.json (got status=$STATUS): $OUT"
fi

echo "== issue #10: this is EXACTLY the incident -- a settings.json that wires guard.sh/guard-write.sh but NOT quota-stop-gate.sh fails LOUDLY =="
cat > "$TMP/settings-missing-gate.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/lib/guard.sh" } ] },
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/lib/guard-write.sh" } ] }
    ]
  }
}
EOF
OUT="$(bash "$CHECK" "$TMP/settings-missing-gate.json" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "quota-stop-gate"; then
  pass "reproduces issue #10: a settings.json missing the gate hook fails loudly, naming quota-stop-gate.sh"
else
  fail "expected exit 2 naming quota-stop-gate.sh as missing (got status=$STATUS): $OUT"
fi

echo "== issue #60 task E: a settings.json wiring quota-stop-gate.sh but NOT room-branch-gate.sh fails LOUDLY, naming it =="
cat > "$TMP/settings-missing-room-gate.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": ".*", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/hooks/quota-stop-gate.sh" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/lib/guard.sh" } ] },
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/lib/guard-write.sh" } ] }
    ]
  }
}
EOF
OUT="$(bash "$CHECK" "$TMP/settings-missing-room-gate.json" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "room-branch-gate"; then
  pass "a settings.json missing room-branch-gate.sh fails loudly, naming it"
else
  fail "expected exit 2 naming room-branch-gate.sh as missing (got status=$STATUS): $OUT"
fi

echo "== a correctly-wired settings.json (matching templates/settings.json) passes =="
cp "$DIR/../templates/settings.json" "$TMP/settings-correct.json"
OUT="$(bash "$CHECK" "$TMP/settings-correct.json" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "a correctly-wired settings.json (matching templates/settings.json) passes with exit 0"
else
  fail "expected exit 0 for a correctly-wired settings.json (got status=$STATUS): $OUT"
fi

echo "== malformed JSON fails loudly, not silently =="
echo 'this is not json at all {{{' > "$TMP/settings-malformed.json"
OUT="$(bash "$CHECK" "$TMP/settings-malformed.json" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "not valid json\|malformed"; then
  pass "malformed settings.json fails loudly with an explicit message"
else
  fail "expected exit 2 + explicit message for malformed JSON (got status=$STATUS): $OUT"
fi

echo "== defaults to .claude/settings.json relative to cwd when no argument is given =="
mkdir -p "$TMP/room/.claude"
cp "$DIR/../templates/settings.json" "$TMP/room/.claude/settings.json"
OUT="$(cd "$TMP/room" && bash "$CHECK" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "defaults to .claude/settings.json relative to cwd, finds the correctly-wired file"
else
  fail "expected exit 0 when defaulting to a correctly-wired .claude/settings.json (got status=$STATUS): $OUT"
fi

echo "== issue #48: the ACTUAL #33 incident shape -- a settings.json passing every hardcoded check (quota-stop-gate + room-branch-gate + guard/guard-write) but missing ALL THREE pane-state.sh hooks (never in the old hardcoded list) is caught, naming pane-state.sh =="
# This reproduces the live incident precisely: the OLD implementation only
# knew to grep for quota-stop-gate.sh/room-branch-gate.sh, so a config
# exactly like this one -- correct on everything the doctor's author knew
# about, silently missing everything shipped after -- passed with exit 0.
cat > "$TMP/settings-missing-panestate.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": ".*", "hooks": [
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/hooks/quota-stop-gate.sh" },
          { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/hooks/room-branch-gate.sh" }
        ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/lib/guard.sh" } ] },
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/lib/guard-write.sh" } ] }
    ]
  }
}
EOF
OUT="$(bash "$CHECK" "$TMP/settings-missing-panestate.json" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "pane-state.sh"; then
  pass "issue #48: reproduces the #33 incident -- a config missing pane-state.sh (never in the old hardcoded list) is now caught, naming it"
else
  fail "CORRECTNESS REGRESSION (issue #48): expected exit 2 naming pane-state.sh as missing (got status=$STATUS): $OUT"
fi
# All three missing pane-state.sh occurrences (UserPromptSubmit busy,
# PreToolUse busy, Stop idle) should each be named, not just the first.
MISSING_COUNT="$(echo "$OUT" | grep -ci "pane-state.sh")"
if [ "$MISSING_COUNT" -ge 3 ]; then
  pass "issue #48: all three missing pane-state.sh hooks (UserPromptSubmit/PreToolUse/Stop) are named individually, not just one"
else
  fail "expected at least 3 pane-state.sh mentions (one per missing event), got $MISSING_COUNT: $OUT"
fi

echo "== issue #48: an ALTERED hook command (same script, different invocation) fails LOUDLY, distinguished from a MISSING one =="
ALTERED_TMP="$(mktemp)"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command) |= . + " --extra-flag"' "$DIR/../templates/settings.json" > "$ALTERED_TMP"
OUT="$(bash "$CHECK" "$ALTERED_TMP" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "ALTERED" && echo "$OUT" | grep -q "guard.sh"; then
  pass "issue #48: an altered guard.sh invocation is caught and reported as ALTERED, naming guard.sh"
else
  fail "expected exit 2 reporting an ALTERED guard.sh hook (got status=$STATUS): $OUT"
fi
rm -f "$ALTERED_TMP"

echo "== issue #48: an EXTRA live-only hook (not in the template) passes with a NOTE, does not fail =="
EXTRA_TMP="$(mktemp)"
jq '.hooks.PreToolUse += [{"matcher": "Read", "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/hooks/room-specific-extra.sh"}]}]' "$DIR/../templates/settings.json" > "$EXTRA_TMP"
OUT="$(bash "$CHECK" "$EXTRA_TMP" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "issue #48: an extra live-only hook does not fail the check (a room may legitimately layer extras)"
else
  fail "expected exit 0 for an extra live-only hook, not a failure (got status=$STATUS): $OUT"
fi
if echo "$OUT" | grep -qi "NOTE.*room-specific-extra.sh\|room-specific-extra.sh.*NOTE\|extra hook"; then
  pass "issue #48: the extra hook is still surfaced as a NOTE, not silently ignored"
else
  fail "expected a NOTE about the extra hook even though it passes: $OUT"
fi
rm -f "$EXTRA_TMP"

echo "== issue #48: kills the hardcoded list -- adding a brand-new hook to the template is caught automatically, no doctor code change needed =="
# Simulates "a future issue ships hook #N, nobody remembers to update this
# doctor" -- the whole point of diffing against the template instead of a
# list. A synthetic template with a hook this script has NEVER heard of by
# name proves the check is generic, not hardcoded to today's hook set.
FUTURE_TEMPLATE="$(mktemp)"
cat > "$FUTURE_TEMPLATE" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": ".*", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/hooks/totally-hypothetical-future-hook.sh" } ] }
    ]
  }
}
EOF
FUTURE_LIVE="$(mktemp)"
echo '{"hooks": {}}' > "$FUTURE_LIVE"
OUT="$(CHECK_HOOK_WIRING_TEMPLATE="$FUTURE_TEMPLATE" bash "$CHECK" "$FUTURE_LIVE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "totally-hypothetical-future-hook.sh"; then
  pass "issue #48: a hook this script has never heard of by name is still caught, purely from diffing against the template"
else
  fail "expected exit 2 naming the unknown-to-the-script future hook, purely from the template diff (got status=$STATUS): $OUT"
fi
rm -f "$FUTURE_TEMPLATE" "$FUTURE_LIVE"

echo "== issue #48: missing/unreadable TEMPLATE file fails loudly too (not just a missing live file) =="
OUT="$(CHECK_HOOK_WIRING_TEMPLATE="$TMP/nonexistent-template.json" bash "$CHECK" "$DIR/../templates/settings.json" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -qi "template.*does not exist"; then
  pass "issue #48: a missing template file fails loudly with an explicit message"
else
  fail "expected exit 2 + explicit message for a missing template file (got status=$STATUS): $OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
