#!/bin/bash
# tests/orc-install-skills.test.sh -- issue #8: bin/orc-install-skills
# dual-installs the tracked skills/ source tree into .claude/skills/ and
# .agents/skills/, is idempotent/convergent on re-run, and has a --check
# mode (no writes) that reports missing/stale skills, following
# lib/check-hook-wiring.sh's precedent. Run: bash tests/orc-install-skills.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
INSTALLER="$DIR/../bin/orc-install-skills"
SKILLS_SRC="$DIR/../skills"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

EXPECTED_COUNT="$(ls -1 "$SKILLS_SRC" | wc -l | tr -d ' ')"

echo "== fresh-tree install produces the exact expected skill set in BOTH targets =="
TARGET1="$TMP/fresh"
mkdir -p "$TARGET1"
OUT="$(bash "$INSTALLER" "$TARGET1" 2>&1)"
STATUS=$?
CLAUDE_COUNT="$(ls -1 "$TARGET1/.claude/skills" 2>/dev/null | wc -l | tr -d ' ')"
AGENTS_COUNT="$(ls -1 "$TARGET1/.agents/skills" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$STATUS" -eq 0 ] && [ "$CLAUDE_COUNT" = "$EXPECTED_COUNT" ] && [ "$AGENTS_COUNT" = "$EXPECTED_COUNT" ]; then
  pass "fresh install lands exactly $EXPECTED_COUNT skills in both .claude/skills/ and .agents/skills/"
else
  fail "expected $EXPECTED_COUNT skills in both targets, got claude=$CLAUDE_COUNT agents=$AGENTS_COUNT status=$STATUS: $OUT"
fi
if diff <(ls -1 "$SKILLS_SRC") <(ls -1 "$TARGET1/.claude/skills") >/dev/null 2>&1 \
  && diff <(ls -1 "$SKILLS_SRC") <(ls -1 "$TARGET1/.agents/skills") >/dev/null 2>&1; then
  pass "installed skill NAMES match skills/ source exactly (not just the count) in both targets"
else
  fail "installed skill names diverge from skills/ source"
fi
if [ -f "$TARGET1/.claude/skills/dispatching-parallel-agents/SKILL.md" ] && [ -f "$TARGET1/.agents/skills/subagent-driven-development/SKILL.md" ]; then
  pass "issue #8: the two newly-vendored skills (dispatching-parallel-agents, subagent-driven-development) install correctly"
else
  fail "issue #8: the two newly-vendored skills did not install correctly"
fi

echo "== re-running the installer on an already-installed target is a no-op (same resulting skill set) =="
BEFORE_HASH="$(find "$TARGET1/.claude/skills" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256)"
bash "$INSTALLER" "$TARGET1" >/dev/null 2>&1
AFTER_HASH="$(find "$TARGET1/.claude/skills" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256)"
AFTER_COUNT="$(ls -1 "$TARGET1/.claude/skills" | wc -l | tr -d ' ')"
if [ "$BEFORE_HASH" = "$AFTER_HASH" ] && [ "$AFTER_COUNT" = "$EXPECTED_COUNT" ]; then
  pass "re-running the installer converges to the identical skill set -- no duplication, no drift"
else
  fail "re-running the installer changed the resulting file set (not idempotent)"
fi

echo "== --check mode passes (exit 0) on a freshly-installed target, and writes nothing =="
BEFORE_MTIME="$(stat -f %m "$TARGET1/.claude/skills/brainstorming/SKILL.md" 2>/dev/null || stat -c %Y "$TARGET1/.claude/skills/brainstorming/SKILL.md" 2>/dev/null)"
OUT="$(bash "$INSTALLER" --check "$TARGET1" 2>&1)"
STATUS=$?
AFTER_MTIME="$(stat -f %m "$TARGET1/.claude/skills/brainstorming/SKILL.md" 2>/dev/null || stat -c %Y "$TARGET1/.claude/skills/brainstorming/SKILL.md" 2>/dev/null)"
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -qi "check passed"; then
  pass "check mode passes cleanly on a target that matches skills/ exactly"
else
  fail "expected check mode to pass on a clean target (got status=$STATUS): $OUT"
fi
if [ "$BEFORE_MTIME" = "$AFTER_MTIME" ]; then
  pass "check mode made no writes (file mtime unchanged)"
else
  fail "check mode modified a file it should have only inspected"
fi

echo "== --check mode is RED (exit 2) and names the skill when one is missing from the target =="
rm -rf "$TARGET1/.claude/skills/brainstorming"
OUT="$(bash "$INSTALLER" --check "$TARGET1" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "MISSING" && echo "$OUT" | grep -q "brainstorming"; then
  pass "check mode fails loudly (exit 2) and names the missing skill"
else
  fail "expected exit 2 naming the missing 'brainstorming' skill (got status=$STATUS): $OUT"
fi

echo "== --check mode is RED and names the skill when a STALE (removed-from-source) skill is still installed =="
bash "$INSTALLER" "$TARGET1" >/dev/null 2>&1 # restore the missing skill first, isolate this case
mkdir -p "$TARGET1/.agents/skills/totally-made-up-skill"
OUT="$(bash "$INSTALLER" --check "$TARGET1" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "STALE" && echo "$OUT" | grep -q "totally-made-up-skill"; then
  pass "check mode fails loudly (exit 2) and names the stale skill"
else
  fail "expected exit 2 naming the stale 'totally-made-up-skill' (got status=$STATUS): $OUT"
fi

echo "== a real install run PRUNES a stale skill and RESTORES a missing one -- convergent, not just additive =="
rm -rf "$TARGET1/.claude/skills/systematic-debugging" # simulate missing again, on the OTHER target dir
bash "$INSTALLER" "$TARGET1" >/dev/null 2>&1
if [ ! -d "$TARGET1/.agents/skills/totally-made-up-skill" ] && [ -d "$TARGET1/.claude/skills/systematic-debugging" ]; then
  pass "install run pruned the stale skill and restored the missing one in the same pass"
else
  fail "install run did not converge target state to match skills/ source"
fi
OUT="$(bash "$INSTALLER" --check "$TARGET1" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "check mode confirms the target is clean again after the convergent install"
else
  fail "check mode still reports drift after a real install run should have fixed it: $OUT"
fi

echo "== a nonexistent target directory errors clearly, in both install and --check mode =="
OUT="$(bash "$INSTALLER" "$TMP/does-not-exist" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi "no such directory"; then
  pass "install mode errors clearly on a nonexistent target directory"
else
  fail "expected a clear 'no such directory' error for install mode (got status=$STATUS): $OUT"
fi
OUT="$(bash "$INSTALLER" --check "$TMP/does-not-exist" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi "no such directory"; then
  pass "check mode errors clearly on a nonexistent target directory"
else
  fail "expected a clear 'no such directory' error for check mode (got status=$STATUS): $OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
