#!/bin/bash
# lib/review-protocol-verify.sh — VERIFY, updated for
# issue #18 item 4: structural checks for the review protocol + agy skill
# wrapper. The live canary (fresh agy session lists /code-review) was run
# by hand; this script makes the reproducible, mechanical part of the check
# re-runnable, not the live agy interaction itself.
# Run: bash lib/review-protocol-verify.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# issue #18: the ONE canonical runtime path every reviewer/skill/template
# references is project-root `review-protocol.md` -- gitignored per-project
# (each project customizes its own rubric), seeded from this repo's tracked
# `templates/review-protocol.md`. This script verifies the CHECKOUT it runs
# in: a consumer project that has copied the templates to its root, OR (as
# here) agent-orchestra's own dev checkout, which hasn't onboarded itself
# with root AGENTS.md/GEMINI.md/review-protocol.md yet -- so each check
# falls back to the templates/ source when the root copy doesn't exist.
# No check anywhere in this script should require the legacy
# `.harness/review-protocol.md` path; that layout is dead.
REPO_ROOT="${REVIEW_PROTOCOL_REPO_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$REPO_ROOT" ]; then
  echo "review-protocol-verify.sh: not inside a git repo (run from the repo to verify, or set REVIEW_PROTOCOL_REPO_ROOT)" >&2
  exit 1
fi

pick_first_existing() {
  for f in "$@"; do
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  done
  echo "$1"
  return 1
}

PROTOCOL="$(pick_first_existing "$REPO_ROOT/review-protocol.md" "$REPO_ROOT/templates/review-protocol.md")"
SKILL="$(pick_first_existing "$REPO_ROOT/.agents/skills/code-review/SKILL.md" "$REPO_ROOT/skills/code-review/SKILL.md")"
AGENTS_FILE="$(pick_first_existing "$REPO_ROOT/AGENTS.md" "$REPO_ROOT/templates/AGENTS.md")"
GEMINI_FILE="$(pick_first_existing "$REPO_ROOT/GEMINI.md" "$REPO_ROOT/templates/GEMINI.md")"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== review-protocol.md exists and covers the required rubric lenses =="
if [ -f "$PROTOCOL" ]; then
  pass "review-protocol.md exists ($PROTOCOL)"
else
  fail "expected a review-protocol.md at project root or templates/"
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

echo "== SKILL.md has valid frontmatter and points at the ONE canonical review-protocol.md path =="
if [ -f "$SKILL" ]; then
  pass "SKILL.md exists ($SKILL)"
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
if grep -qF "review-protocol.md" "$SKILL" 2>/dev/null; then
  pass "SKILL.md references review-protocol.md as the source of truth"
else
  fail "SKILL.md should reference review-protocol.md, not duplicate its content"
fi
if grep -qF ".harness/review-protocol.md" "$SKILL" 2>/dev/null; then
  fail "SKILL.md should reference the project-root review-protocol.md, not the legacy .harness/ path"
else
  pass "SKILL.md has no legacy .harness/review-protocol.md reference"
fi

echo "== AGENTS.md's review-dispatch template mentions the skill, the risky-diff rule, and the canonical path =="
if grep -qF "/code-review" "$AGENTS_FILE" 2>/dev/null; then
  pass "AGENTS.md's review-dispatch template names /code-review"
else
  fail "AGENTS.md should tell dispatchers to invoke /code-review"
fi
if grep -qi "risky diff" "$AGENTS_FILE" 2>/dev/null; then
  pass "AGENTS.md documents the risky-diff dedicated-security-pass rule"
else
  fail "AGENTS.md should document the risky-diff rule"
fi
if grep -qF ".harness/review-protocol.md" "$AGENTS_FILE" 2>/dev/null; then
  fail "AGENTS.md should reference the project-root review-protocol.md, not the legacy .harness/ path"
else
  pass "AGENTS.md has no legacy .harness/review-protocol.md reference"
fi

echo "== GEMINI.md's Reviewer section points at the ONE canonical review-protocol.md path =="
if grep -qF "review-protocol.md" "$GEMINI_FILE" 2>/dev/null; then
  pass "GEMINI.md's Reviewer section references review-protocol.md"
else
  fail "GEMINI.md should reference review-protocol.md"
fi
if grep -qF ".harness/review-protocol.md" "$GEMINI_FILE" 2>/dev/null; then
  fail "GEMINI.md should reference the project-root review-protocol.md, not the legacy .harness/ path"
else
  pass "GEMINI.md has no legacy .harness/review-protocol.md reference"
fi

echo "== issue #38: review-gated flow PUSHES the verdict back (assign), not a bounded handoff poll =="
# The old flow dispatched the reviewer via `handoff` (a synchronous,
# ~120s-bounded poll for the .ack) -- a review that legitimately outran
# the timeout (agy's PR #30 security review did, live) left the verdict
# stranded: the reviewer HAD approved, but the requester gave up waiting
# and never saw it. Fix per the ratified design: dispatch the reviewer via
# `assign` (fire-and-forget, no timeout to outrun), and on completion the
# reviewer pushes its own verdict back as a durable `assign` message to
# the requester's inbox instead of the requester polling a bounded wait.
if grep -qF 'dispatch.sh handoff <reviewer>' "$AGENTS_FILE" 2>/dev/null; then
  fail "issue #38: AGENTS.md's review-gated flow still dispatches the reviewer via a bounded 'handoff' poll -- use 'assign' plus a pushed-back verdict instead"
else
  pass "issue #38: review-gated flow no longer dispatches the reviewer via 'handoff'"
fi
if grep -qF 'dispatch.sh assign <reviewer>' "$AGENTS_FILE" 2>/dev/null; then
  pass "issue #38: review-gated flow dispatches the reviewer via 'assign' (fire-and-forget)"
else
  fail "issue #38: expected AGENTS.md to dispatch the reviewer via 'dispatch.sh assign <reviewer>'"
fi
if grep -qi "push.*verdict\|verdict.*push" "$AGENTS_FILE" 2>/dev/null; then
  pass "issue #38: AGENTS.md documents the reviewer pushing its verdict back on completion"
else
  fail "issue #38: expected AGENTS.md to instruct the reviewer to PUSH its verdict back on completion, not leave the requester polling a bounded handoff"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
