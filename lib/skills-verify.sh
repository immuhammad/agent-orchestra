#!/bin/bash
# .harness/skills-verify.sh — T22 (issue #27) VERIFY: confirm neither
# claude-md-management nor claude-code-setup's marketplace source ever
# references AGENTS.md. claude-md-improver's own file-discovery only
# matches literal "CLAUDE.md"/".claude.local.md" filenames -- this check
# just makes that structural fact reproducible instead of a one-off grep,
# so a future marketplace update to either plugin gets caught if it ever
# starts mentioning AGENTS.md.
# Run: bash .harness/skills-verify.sh
set -uo pipefail

MARKETPLACE="$HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

for plugin in claude-md-management claude-code-setup; do
  dir="$MARKETPLACE/$plugin"
  if [ ! -d "$dir" ]; then
    echo "SKIP: $plugin not found at $dir (marketplace not cloned locally) -- cannot verify, not a failure"
    continue
  fi
  if grep -rq "AGENTS.md" "$dir" 2>/dev/null; then
    fail "$plugin's source mentions AGENTS.md -- re-check before trusting it won't touch this repo's source of truth"
  else
    pass "$plugin's source never mentions AGENTS.md"
  fi
done

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
