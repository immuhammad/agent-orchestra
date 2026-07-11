#!/bin/bash
# .harness/review-protocol-verify.sh — T45 (issue #106) VERIFY: structural
# checks for the review protocol + agy skill wrapper. The live canary
# (fresh agy session lists /code-review) was run by hand for this ticket
# -- see the PR description for that proof; this script makes the
# reproducible, mechanical part of the check re-runnable, not the live
# agy interaction itself.
# Run: bash .harness/review-protocol-verify.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# issue #116: this verifies the CHECKOUT it runs in (this repo's own
# templates/skills, or a consumer project's, depending on cwd) -- not the
# directory above this script (this script now lives in agent-orchestra's
# own lib/). Paths below updated for the new layout: review-protocol.md
# moved .harness/ -> templates/, the skill's dual-install target is
# .agents/skills/ (unchanged -- that's still the consumer-facing path).
REPO_ROOT="${REVIEW_PROTOCOL_REPO_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$REPO_ROOT" ]; then
  echo "review-protocol-verify.sh: not inside a git repo (run from the repo to verify, or set REVIEW_PROTOCOL_REPO_ROOT)" >&2
  exit 1
fi
PROTOCOL="$REPO_ROOT/templates/review-protocol.md"
SKILL="$REPO_ROOT/.agents/skills/code-review/SKILL.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== review-protocol.md exists and covers the required rubric lenses =="
if [ -f "$PROTOCOL" ]; then
  pass "review-protocol.md exists"
else
  fail "expected $PROTOCOL to exist"
fi
for lens in "Edge-case correctness" "Failure modes" "Test honesty" "Security" "Deletion candidates" "Guard / single-writer"; do
  if grep -qF "$lens" "$PROTOCOL" 2>/dev/null; then
    pass "rubric mentions '$lens'"
  else
    fail "rubric should mention '$lens'"
  fi
done
if grep -qi "adversarial" "$PROTOCOL" 2>/dev/null; then
  pass "protocol states the adversarial stance"
else
  fail "expected the protocol to state an adversarial stance"
fi
if grep -qi "risky diff" "$PROTOCOL" 2>/dev/null && grep -qi "security pass" "$PROTOCOL" 2>/dev/null; then
  pass "protocol documents the risky-diff dedicated security pass"
else
  fail "expected a risky-diff / dedicated security pass section"
fi

echo "== SKILL.md has valid frontmatter and points at the protocol =="
if [ -f "$SKILL" ]; then
  pass "SKILL.md exists at .agents/skills/code-review/SKILL.md"
else
  fail "expected $SKILL to exist"
fi
if head -1 "$SKILL" 2>/dev/null | grep -q '^---$'; then
  pass "SKILL.md opens with YAML frontmatter"
else
  fail "SKILL.md should open with a --- frontmatter block"
fi
if grep -q '^name: code-review$' "$SKILL" 2>/dev/null; then
  pass "frontmatter declares name: code-review"
else
  fail "expected 'name: code-review' in the frontmatter"
fi
if grep -q '^description:' "$SKILL" 2>/dev/null; then
  pass "frontmatter has a description field"
else
  fail "expected a description field in the frontmatter"
fi
if grep -qF ".harness/review-protocol.md" "$SKILL" 2>/dev/null; then
  pass "SKILL.md references .harness/review-protocol.md as the source of truth"
else
  fail "SKILL.md should reference .harness/review-protocol.md, not duplicate its content"
fi

echo "== AGENTS.md's review-dispatch template mentions the skill and the risky-diff rule =="
if grep -qF "/code-review" "$REPO_ROOT/AGENTS.md" 2>/dev/null; then
  pass "AGENTS.md's review-dispatch template names /code-review"
else
  fail "AGENTS.md should tell dispatchers to invoke /code-review"
fi
if grep -qi "risky-diff" "$REPO_ROOT/AGENTS.md" 2>/dev/null; then
  pass "AGENTS.md documents the risky-diff dedicated-security-pass rule"
else
  fail "AGENTS.md should document the risky-diff rule"
fi

echo "== GEMINI.md's Reviewer section points at the protocol =="
if grep -qF ".harness/review-protocol.md" "$REPO_ROOT/GEMINI.md" 2>/dev/null; then
  pass "GEMINI.md's Reviewer section references review-protocol.md"
else
  fail "GEMINI.md should reference .harness/review-protocol.md"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
