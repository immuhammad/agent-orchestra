#!/bin/bash
# .harness/pre-compact-checkpoint.sh — PreCompact hook (T25, issue #40).
#
# Gap this closes: auto-compact is lossy (it distills the conversation into
# a summary and drops the rest), and nothing forced a disk write before
# that happened. If the session's own handoff.md update was still pending
# when compaction fired, that nuance was gone.
#
# What this CAN and can't do: a hook script has no access to the model's
# own understanding of "what's done / what's next" -- that's the session's
# job per AGENTS.md's Handoff Protocol, not something a bash script can
# synthesize. What it CAN do reliably is pin, on disk, the exact moment
# compaction happened against whatever git/session state is mechanically
# checkable at that instant -- session id, trigger (manual/auto), branch,
# inferred issue number, and whether the tree is dirty. That's the floor:
# if handoff.md is already current, this is a harmless breadcrumb; if it's
# stale, this at least proves WHEN the loss window opened and what state
# the repo was in, so a resumed session isn't reasoning from nothing.
#
# No post-compact companion file: compaction's own summary already covers
# in-context continuity going forward; the risk here is only pre-loss disk
# truth, so only a PreCompact hook is needed (see issue #40).
set -euo pipefail

INPUT=$(cat)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# issue #116: hooks fire with cwd = the consumer project (Claude Code
# invokes them from the project root), so HANDOFF stays cwd-relative, not
# anchored to this hook script's own directory. handoff-lib.sh moved to
# ../lib/ (a sibling of hooks/) in the new layout.
HANDOFF="${PRE_COMPACT_HANDOFF_FILE:-.harness/handoff.md}"
# shellcheck source=../lib/handoff-lib.sh
source "$DIR/../lib/handoff-lib.sh"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
ISSUE=""
case "$BRANCH" in
  feature/issue-*) ISSUE="${BRANCH#feature/issue-}" ;;
esac

DIRTY_NOTE=""
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
  DIRTY_NOTE=" (uncommitted changes present)"
fi

# T31 (issue #68 item A): replace this hook's own section instead of
# appending a new dated one on every compaction -- handoff.md is a
# ≤80-line current-state file now, not an append log.
handoff_replace_section "$HANDOFF" "## COMPACT CHECKPOINT"
{
  echo ""
  echo "## COMPACT CHECKPOINT — $(date '+%Y-%m-%d %H:%M:%S') (session $SESSION_ID, trigger: $TRIGGER)"
  echo "Branch: $BRANCH${ISSUE:+ (issue #$ISSUE)}${DIRTY_NOTE}"
  echo "Compaction is about to distill/drop raw context. If the 'Current"
  echo "state' section above does not already reflect what's done, what's"
  echo "next, and any open threads for this branch as of right now, update"
  echo "it before continuing -- this checkpoint only pins WHEN compaction"
  echo "happened and what the git state was, not the actual task progress"
  echo "(a hook script has no access to that; see AGENTS.md Handoff"
  echo "Protocol)."
} >> "$HANDOFF"
