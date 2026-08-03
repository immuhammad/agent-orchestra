#!/bin/bash
# tests/repo-gitignore.test.sh -- issue #171 item 5b: orchestrator.yaml
# and souls/*.md stop being git-tracked in THIS repo, matching how
# AGENTS.md/CLAUDE.md/GEMINI.md/review-protocol.md already work --
# templates/* stays the tracked source of truth, `orc init`/`orc init
# --force`/`orc init --adopt` regenerate the live copies. This test
# inspects the ACTUAL checkout's own git state (not a scratch fixture --
# that's the point: it verifies THIS repo's own tracking, not a
# reimplementation of it), so it must never write into this checkout
# itself, only read `git ls-files`/`git status`/`.gitignore` content.
# Run: bash tests/repo-gitignore.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== .gitignore lists /orchestrator.yaml and /souls/*.md in the per-project-root-files block =="
if grep -qxF '/orchestrator.yaml' "$REPO/.gitignore"; then
  pass ".gitignore contains '/orchestrator.yaml'"
else
  fail ".gitignore is missing '/orchestrator.yaml'"
fi
if grep -qxF '/souls/*.md' "$REPO/.gitignore"; then
  pass ".gitignore contains '/souls/*.md'"
else
  fail ".gitignore is missing '/souls/*.md'"
fi

echo "== orchestrator.yaml is no longer git-tracked in this checkout =="
if git -C "$REPO" ls-files --error-unmatch orchestrator.yaml >/dev/null 2>&1; then
  fail "orchestrator.yaml is STILL tracked (git rm --cached not applied, or reverted)"
else
  pass "orchestrator.yaml is untracked"
fi

echo "== souls/*.md are no longer git-tracked in this checkout =="
for f in souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md; do
  if git -C "$REPO" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    fail "$f is STILL tracked"
  else
    pass "$f is untracked"
  fi
done

echo "== the files still physically exist on disk (git rm --cached, never a real delete) =="
for f in orchestrator.yaml souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md; do
  if [ -f "$REPO/$f" ]; then
    pass "$f still exists on disk"
  else
    fail "$f is missing from disk -- it should have been git rm --cached'd, never actually deleted"
  fi
done

echo "== git status reports them as untracked (??), never as deleted (D) =="
STATUS_OUT="$(git -C "$REPO" status --porcelain -- orchestrator.yaml souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md)"
if echo "$STATUS_OUT" | grep -q '^D '; then
  fail "git status shows a deletion -- expected untracked (??), got: $STATUS_OUT"
else
  pass "git status shows no deletion for these paths"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
