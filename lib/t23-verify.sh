#!/usr/bin/env bash
# .harness/t23-verify.sh -- T23 end-to-end loop acceptance checker (issue #28).
# Auto-asserts the MECHANICAL receipts the full agentic loop should leave.
# Judgment scenarios (single-writer held, agy did not edit handoff, no
# force-push, quota failsafe honored) stay a human/Orchestra checklist -- see
# the T23 plan's Acceptance section.
#
# Usage: .harness/t23-verify.sh [issue_number]   (default 28)
# Exit 0 only if every mechanical check passes.
set -uo pipefail

ISSUE="${1:-28}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0
fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skip() { printf '  SKIP %s\n' "$1"; }

echo "T23 acceptance -- issue #$ISSUE ($(date '+%Y-%m-%d %H:%M:%S'))"

# #6 payload files present
for f in extension/careerops_ext/runner.py extension/careerops_ext/__init__.py \
  extension/pyproject.toml extension/tests/test_runner.py; do
  [ -f "$f" ] && ok "payload file $f" || no "missing payload file $f"
done

# #8 upstream untouched (no tracked modifications)
if [ -z "$(git status --porcelain -- career-ops 2>/dev/null)" ]; then
  ok "upstream career-ops/ has no uncommitted changes"
else
  no "upstream career-ops/ shows modifications"
fi

# #9 lint + tests green
if command -v ruff >/dev/null 2>&1; then
  ruff check extension/ >/dev/null 2>&1 && ok "ruff clean on extension/" || no "ruff reported issues"
else
  skip "ruff not installed"
fi
if command -v pytest >/dev/null 2>&1; then
  pytest extension/tests -q >/dev/null 2>&1 && ok "pytest extension/tests green" || no "pytest failed"
else
  skip "pytest not installed"
fi

# #4 worktree gone after merge
if git worktree list --porcelain | grep -q "issue-$ISSUE\$"; then
  no "worktree for issue-$ISSUE still present"
else
  ok "worktree for issue-$ISSUE removed"
fi

# #5 merged branch gone
if git show-ref --verify --quiet "refs/heads/feature/issue-$ISSUE"; then
  no "local branch feature/issue-$ISSUE still present"
else
  ok "local branch feature/issue-$ISSUE deleted"
fi

# #16 decisions.log receipt
if grep -qiE "issue #?$ISSUE|T23" .harness/decisions.log 2>/dev/null; then
  ok "decisions.log has a T23/issue-$ISSUE receipt"
else
  no "no decisions.log receipt for T23/issue-$ISSUE"
fi

# GitHub-side receipts (need gh + network)
if command -v gh >/dev/null 2>&1; then
  state="$(gh issue view "$ISSUE" --json state -q .state 2>/dev/null)"
  [ "$state" = "CLOSED" ] && ok "issue #$ISSUE is CLOSED" || no "issue #$ISSUE state=${state:-unknown} (want CLOSED)"

  merged="$(gh pr list --state merged --json number,body,headRefName \
    --jq 'map(select((.body|test("(?i)(closes|fixes|resolves) #'"$ISSUE"'\\b")) or (.headRefName=="feature/issue-'"$ISSUE"'")))|length' 2>/dev/null)"
  if [ "${merged:-0}" -ge 1 ] 2>/dev/null; then
    ok "a merged PR closes #$ISSUE (Closes-ref or feature/issue-$ISSUE branch)"
  else
    no "no merged PR found closing #$ISSUE"
  fi
else
  skip "gh not installed -- issue/PR receipts unchecked"
fi

echo "-- $pass passed, $fail failed --"
[ "$fail" -eq 0 ]
