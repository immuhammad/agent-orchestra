#!/bin/bash
# .harness/rate-limit-handoff.sh — StopFailure hook (matcher: rate_limit).
# Auto-appends a note to handoff.md when a session ends because it hit a
# rate limit mid-task, so the AGENTS.md Quota Failsafe has something to
# resume from even if the session died before it could write its own
# handoff update.
set -euo pipefail

INPUT=$(cat)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./handoff-lib.sh
source "$DIR/handoff-lib.sh"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

# T31 (issue #68 item A): replace this hook's own section instead of
# appending a new dated one every time -- handoff.md is a ≤80-line
# current-state file now, not an append log.
handoff_replace_section "$DIR/handoff.md" "## RATE-LIMITED"
{
  echo ""
  echo "## RATE-LIMITED — $(date '+%Y-%m-%d %H:%M:%S') (session $SESSION_ID)"
  echo "This session ended on a rate_limit StopFailure, possibly before it could"
  echo "write its own handoff update. Follow AGENTS.md's Quota Failsafe: confirm"
  echo "current quota status with Ahmad before resuming, and check for a"
  echo "partial/stale task state above this line."
} >> "$DIR/handoff.md"
