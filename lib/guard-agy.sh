#!/bin/bash
# .harness/guard-agy.sh — PreToolUse guard for agy (Antigravity CLI), wired
# via .agents/hooks.json. Denies any command matching a line in
# banned-patterns.txt.
#
# banned-patterns.txt now also denies `git restore`, `git
# checkout`, `git commit`, and `git reset` for agy specifically -- the
# single-writer rule (see AGENTS.md Dispatch Protocol) makes Reviewer/Scribe
# output-only to the PR, the inbox .ack, and decisions.log (via
# log-decision.sh); they never write to the shared checkout's git state or
# edit handoff.md. This follows a confirmed live collision: agy edited
# handoff.md concurrently with the Builder, then `git restore`d
# decisions.log mid-append (destroying two uncommitted Builder lines), then
# briefly committed onto local uat. Read ops (diff/log/show/status/branch
# --contains, gh pr diff/view) are deliberately NOT banned -- review needs
# those.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // .toolCall.args.commandLine // empty')

if [ -z "$COMMAND" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

# Find the directory where this script resides to locate banned-patterns.txt
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BANNED_FILE="$DIR/banned-patterns.txt"

if echo "$COMMAND" | grep -Eq -f "$BANNED_FILE"; then
  echo '{"decision":"deny", "reason":"guard-agy.sh: Command blocked by banned patterns"}'
  exit 0
fi

echo '{"decision":"allow"}'
exit 0
