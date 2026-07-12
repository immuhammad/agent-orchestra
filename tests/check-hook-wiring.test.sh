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

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
