#!/bin/bash
# tests/orc-init.test.sh -- issue #5: orc init (the onboarding wizard).
# Tests drive the non-interactive core (orc_init_core/orc_init_validate)
# directly, per the issue's own design constraint -- the interactive
# wrapper (orc_init_interactive) gets one light smoke test via piped
# stdin, since correctness lives entirely in the core it delegates to.
# Every scratch target is a mktemp dir; nothing here ever touches this
# checkout's own .claude/ (guard-protected) or orchestrator.yaml.
# Run: bash tests/orc-init.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORC="$DIR/../bin/orc"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_answers() { # $1 = path, stdin = KEY=value lines
  cat > "$1"
}

full_answers() { # $1 = path -- a complete, valid answers file
  write_answers "$1" <<'EOF'
PROJECT=smoke-test-project
INTEGRATION_BRANCH=main
GITHUB_REMOTE=git@github.com:example/smoke.git
TICKET_TRACKER=gh-issues
PROTECTED_PATHS=infra/,secrets/
GATE_APPROVER=Ahmad
ROLE_ORCHESTRA_MODEL=opus
ROLE_ORCHESTRA_EFFORT=high
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_IMPLEMENTER_EFFORT=default
ROLE_TESTER_MODEL=sonnet
ROLE_TESTER_EFFORT=default
ROLE_REVIEWER_MODEL=agy
ROLE_REVIEWER_EFFORT=high
ROLE_SCRIBE_MODEL=haiku
ROLE_SCRIBE_EFFORT=low
BUDGET_CLAUDE_PCT=80
BUDGET_AGY_PCT=75
EOF
}

echo "== fresh init from a complete answers file writes every expected file =="
ANSWERS1="$TMP/answers1.txt"
full_answers "$ANSWERS1"
TARGET1="$TMP/room1"
OUT="$(bash "$ORC" init --answers "$ANSWERS1" "$TARGET1" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "orc init --answers exits 0 on a valid answers file"
else
  fail "orc init --answers should exit 0 on a valid answers file, got status=$STATUS: $OUT"
fi
ALL_PRESENT=1
for f in orchestrator.yaml AGENTS.md CLAUDE.md GEMINI.md SOUL.md review-protocol.md \
  .harness/handoff.md .harness/decisions.log .claude/settings.json .agents/hooks.json \
  .claude/skills/test-driven-development/SKILL.md .agents/skills/code-review/SKILL.md; do
  [ -f "$TARGET1/$f" ] || ALL_PRESENT=0
done
if [ "$ALL_PRESENT" -eq 1 ]; then
  pass "every expected file (config, docs, hooks, skills, both targets) was written"
else
  fail "one or more expected files were missing after init"
fi

echo "== orchestrator.yaml round-trips through orc-config.sh's own readers =="
RT="$(
  cd "$TARGET1"
  source "$DIR/../lib/orc-config.sh"
  echo "PROJECT=$(orc_get_scalar project)"
  echo "BRANCH=$(orc_get_scalar integration_branch)"
  echo "ORCH=$(orc_get_role_model orchestra)"
  echo "REVIEWER=$(orc_get_role_model reviewer)"
  echo "CLAUDE_PCT=$(orc_get_budget_pct claude)"
  echo "AGY_PCT=$(orc_get_budget_pct agy)"
  echo "PATHS=$(orc_protected_paths | paste -sd, -)"
)"
if echo "$RT" | grep -q '^PROJECT=smoke-test-project$' \
  && echo "$RT" | grep -q '^BRANCH=main$' \
  && echo "$RT" | grep -q '^ORCH=opus$' \
  && echo "$RT" | grep -q '^REVIEWER=agy$' \
  && echo "$RT" | grep -q '^CLAUDE_PCT=80$' \
  && echo "$RT" | grep -q '^AGY_PCT=75$' \
  && echo "$RT" | grep -q '^PATHS=infra/,secrets/$'; then
  pass "orchestrator.yaml round-trips through every orc-config.sh reader correctly"
else
  fail "orchestrator.yaml did not round-trip correctly, got: $RT"
fi

echo "== AGENTS.md's Roles table reflects the answers, install blockquote stripped =="
if grep -q '| Orchestra   | opus | High' "$TARGET1/AGENTS.md" \
  && grep -q '| Reviewer    | agy | High' "$TARGET1/AGENTS.md" \
  && grep -q '| Scribe      | haiku | Low' "$TARGET1/AGENTS.md"; then
  pass "AGENTS.md's Roles table rows reflect the actual answers"
else
  fail "AGENTS.md's Roles table does not reflect the answers"
fi
if head -3 "$TARGET1/AGENTS.md" | grep -q '^>'; then
  fail "AGENTS.md still has the install blockquote -- orc init should strip it"
else
  pass "AGENTS.md's install blockquote was stripped"
fi

echo "== CLAUDE.md / GEMINI.md substitute <PROJECT> and strip the blockquote =="
if grep -q 'smoke-test-project' "$TARGET1/CLAUDE.md" && ! grep -q '<PROJECT>' "$TARGET1/CLAUDE.md" \
  && ! head -3 "$TARGET1/CLAUDE.md" | grep -q '^>'; then
  pass "CLAUDE.md: <PROJECT> substituted, blockquote stripped"
else
  fail "CLAUDE.md was not rendered correctly"
fi
if grep -q 'smoke-test-project' "$TARGET1/GEMINI.md" && ! grep -q '<PROJECT>' "$TARGET1/GEMINI.md" \
  && ! head -3 "$TARGET1/GEMINI.md" | grep -q '^>'; then
  pass "GEMINI.md: <PROJECT> substituted, blockquote stripped"
else
  fail "GEMINI.md was not rendered correctly"
fi

echo "== the target room PASSES both existing post-init verifiers =="
if bash "$DIR/../lib/check-hook-wiring.sh" "$TARGET1/.claude/settings.json" >/dev/null 2>&1; then
  pass "a freshly-initialized room passes check-hook-wiring.sh"
else
  fail "a freshly-initialized room should pass check-hook-wiring.sh"
fi
if bash "$DIR/../bin/orc-install-skills" --check "$TARGET1" >/dev/null 2>&1; then
  pass "a freshly-initialized room passes orc-install-skills --check"
else
  fail "a freshly-initialized room should pass orc-install-skills --check"
fi

echo "== protected_paths defaults to EMPTY (no hardcoded default) when unspecified =="
ANSWERS_MIN="$TMP/answers-min.txt"
write_answers "$ANSWERS_MIN" <<'EOF'
PROJECT=minimal-project
ROLE_ORCHESTRA_MODEL=opus
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_TESTER_MODEL=sonnet
ROLE_REVIEWER_MODEL=agy
ROLE_SCRIBE_MODEL=haiku
EOF
TARGET_MIN="$TMP/room-min"
bash "$ORC" init --answers "$ANSWERS_MIN" "$TARGET_MIN" >/dev/null 2>&1
MIN_PATHS="$(cd "$TARGET_MIN" && source "$DIR/../lib/orc-config.sh" && orc_protected_paths)"
if [ -z "$MIN_PATHS" ]; then
  pass "protected_paths is empty by default (issue #18 B-i: project-agnostic, no hardcoded set)"
else
  fail "protected_paths should default to empty, got: $MIN_PATHS"
fi
MIN_BRANCH="$(cd "$TARGET_MIN" && source "$DIR/../lib/orc-config.sh" && orc_get_scalar integration_branch)"
if [ "$MIN_BRANCH" = "main" ]; then
  pass "integration_branch defaults to main when unspecified"
else
  fail "expected integration_branch default 'main', got '$MIN_BRANCH'"
fi

echo "== FLAG ruling: TICKET_TRACKER shapes the PICK line's prose, GATE_APPROVER is not baked into AGENTS.md =="
# issue #5 FLAG ruling: tickets-location/human-gates answers shape
# GENERATED AGENTS.md prose only, never new orchestrator.yaml keys
# (schema is added together with its first consumer, per issue #86
# precedent). Reviewer's name deliberately stays out of AGENTS.md's
# generic "you approve"/"you merge" language -- it goes in the init
# completion summary instead (checked below).
ANSWERS_TRACKER="$TMP/answers-tracker.txt"
write_answers "$ANSWERS_TRACKER" <<'EOF'
PROJECT=tracker-test
GATE_APPROVER=Ahmad
TICKET_TRACKER=Jira
ROLE_ORCHESTRA_MODEL=opus
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_TESTER_MODEL=sonnet
ROLE_REVIEWER_MODEL=agy
ROLE_SCRIBE_MODEL=haiku
EOF
TARGET_TRACKER="$TMP/room-tracker"
OUT="$(bash "$ORC" init --answers "$ANSWERS_TRACKER" "$TARGET_TRACKER" 2>&1)"
if grep -q 'PICK: Orchestra picks the next ticket from the current milestone (tracked in Jira, not GitHub issues)\.' "$TARGET_TRACKER/AGENTS.md"; then
  pass "a non-default TICKET_TRACKER customizes the PICK line's prose"
else
  fail "TICKET_TRACKER=Jira should have customized the PICK line, got: $(grep 'PICK:' "$TARGET_TRACKER/AGENTS.md")"
fi
if grep -q '^GATE_APPROVER\|Ahmad' "$TARGET_TRACKER/AGENTS.md"; then
  fail "GATE_APPROVER should NOT be baked into AGENTS.md's generic gate language"
else
  pass "GATE_APPROVER is not baked into AGENTS.md -- 'you approve'/'you merge' stays generic"
fi
if echo "$OUT" | grep -q 'Gate 1/Gate 2 approver: Ahmad'; then
  pass "GATE_APPROVER is surfaced in the init completion summary instead"
else
  fail "expected the completion summary to name the Gate approver, got: $OUT"
fi

ANSWERS_DEFAULT_TRACKER="$TMP/answers-default-tracker.txt"
write_answers "$ANSWERS_DEFAULT_TRACKER" <<'EOF'
PROJECT=default-tracker-test
ROLE_ORCHESTRA_MODEL=opus
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_TESTER_MODEL=sonnet
ROLE_REVIEWER_MODEL=agy
ROLE_SCRIBE_MODEL=haiku
EOF
TARGET_DEFAULT_TRACKER="$TMP/room-default-tracker"
bash "$ORC" init --answers "$ANSWERS_DEFAULT_TRACKER" "$TARGET_DEFAULT_TRACKER" >/dev/null 2>&1
if grep -qF 'PICK: Orchestra picks the next issue from the current milestone.' "$TARGET_DEFAULT_TRACKER/AGENTS.md"; then
  pass "the default tracker (gh-issues, or unspecified) leaves the PICK line unchanged"
else
  fail "the default tracker should leave the original PICK line unchanged"
fi

echo "== garbage answers fail validation LOUDLY and write NOTHING (all errors at once) =="
ANSWERS_BAD="$TMP/answers-bad.txt"
write_answers "$ANSWERS_BAD" <<'EOF'
PROJECT=
INTEGRATION_BRANCH=bad..branch
BUDGET_CLAUDE_PCT=150
PROTECTED_PATHS=/absolute/path,ok/
ROLE_ORCHESTRA_MODEL=opus
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_TESTER_MODEL=sonnet
ROLE_REVIEWER_MODEL=agy
ROLE_SCRIBE_MODEL=haiku
EOF
TARGET_BAD="$TMP/room-bad"
mkdir -p "$TARGET_BAD"
OUT="$(bash "$ORC" init --answers "$ANSWERS_BAD" "$TARGET_BAD" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  pass "garbage answers exit non-zero"
else
  fail "garbage answers should exit non-zero"
fi
if echo "$OUT" | grep -q "PROJECT is required" \
  && echo "$OUT" | grep -q "not a valid git branch name" \
  && echo "$OUT" | grep -q "must be an integer 0-100" \
  && echo "$OUT" | grep -q "not a valid relative path"; then
  pass "ALL FOUR validation errors are reported in one pass, not just the first"
else
  fail "expected all 4 validation errors reported together, got: $OUT"
fi
if [ -z "$(ls -A "$TARGET_BAD" 2>/dev/null)" ]; then
  pass "nothing was written to the target -- never a half-room"
else
  fail "garbage answers should write NOTHING, but the target has content: $(ls -A "$TARGET_BAD")"
fi

echo "== re-init on an already-initialized target refuses loudly, touches nothing =="
BEFORE_HASH="$(cd "$TARGET1" && find . -type f -exec shasum -a 256 {} \; | sort | shasum -a 256)"
OUT="$(bash "$ORC" init --answers "$ANSWERS1" "$TARGET1" 2>&1)"
STATUS=$?
AFTER_HASH="$(cd "$TARGET1" && find . -type f -exec shasum -a 256 {} \; | sort | shasum -a 256)"
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi "REFUSE"; then
  pass "re-init on an already-initialized target refuses loudly (exit non-zero, explicit REFUSE)"
else
  fail "expected a loud REFUSE + non-zero exit on re-init, got status=$STATUS: $OUT"
fi
if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  pass "re-init made zero changes to the already-initialized room"
else
  fail "re-init should never touch an already-initialized room, but files changed"
fi

echo "== a nonexistent answers file errors clearly =="
OUT="$(bash "$ORC" init --answers "$TMP/does-not-exist.txt" "$TMP/room-noanswers" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi "no such answers file"; then
  pass "a nonexistent answers file errors clearly"
else
  fail "expected a clear error for a missing answers file, got status=$STATUS: $OUT"
fi

echo "== the interactive wrapper collects the same answers via stdin and produces a working room =="
# orc_init_interactive isn't independently re-validated here (correctness
# lives in orc_init_core, already covered above) -- this just confirms
# the prompt sequence wires through to the core end to end.
TARGET_INT="$TMP/room-interactive"
INTERACTIVE_OUT="$(
  printf 'interactive-project\nmain\n\ngh-issues\n\nAhmad\nopus\nsonnet\nsonnet\nagy\nhaiku\n80\n80\n' \
    | bash "$ORC" init "$TARGET_INT" 2>&1
)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -f "$TARGET_INT/orchestrator.yaml" ] && grep -q 'project: interactive-project' "$TARGET_INT/orchestrator.yaml"; then
  pass "interactive wrapper collects piped answers and produces a working room"
else
  fail "interactive wrapper did not produce the expected room, status=$STATUS: $INTERACTIVE_OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
