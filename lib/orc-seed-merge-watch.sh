#!/bin/bash
# lib/orc-seed-merge-watch.sh — issue #18 item 5 (C1): seeds
# merge-watch-state with every currently-merged PR number so a FRESH room
# starts caught-up. Without this, lib/watch.sh's mw_already_processed
# reads an ABSENT state file as "nothing has been seen yet" -- every
# already-merged PR then replays comment+close on its linked issue and
# fires a stale "PR #N merged -- PICK next" nudge (this bit Ahmad live:
# the "PICK next per PHASE-3-PLAN" ghost against an absent/wrong plan
# doc). mw_mark_processed only ever APPENDS, so seeding once up front is
# enough -- nothing here needs to run again after the first time.
#
# Idempotent: only does real work when MERGE_WATCH_STATE doesn't already
# exist -- safe to call unconditionally from `orc up`'s build path every
# time, not just on a literal first invocation.
# Non-fatal: a failed/unavailable `gh` (network blip, not logged in, rate
# limit) never aborts the caller -- it still seeds an EMPTY state file, so
# the ABSENT-file replay bug can't recur just because gh didn't answer.
#
# Run: bash lib/orc-seed-merge-watch.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./watch.sh
source "$DIR/watch.sh"

# A high ceiling, not "unlimited" (gh pr list has no such option) -- well
# above any real project's merged-PR count, comfortably larger than
# merge_watch_check's own routine 20-PR polling window.
ORC_SEED_MERGE_WATCH_LIMIT="${ORC_SEED_MERGE_WATCH_LIMIT:-5000}"

orc_seed_merge_watch() {
  if [ -f "$MERGE_WATCH_STATE" ]; then
    echo "orc-seed-merge-watch.sh: $MERGE_WATCH_STATE already exists, not reseeding" >&2
    return 0
  fi

  mkdir -p "$(dirname "$MERGE_WATCH_STATE")"

  local prs count=0 pr_number
  prs="$(mw_fetch_merged_prs "$ORC_SEED_MERGE_WATCH_LIMIT" 2>/dev/null || true)"
  if [ -z "$prs" ]; then
    : > "$MERGE_WATCH_STATE"
    echo "orc-seed-merge-watch.sh: no merged PRs found (or gh unavailable) -- seeded an empty state file" >&2
    return 0
  fi

  while IFS=$'\t' read -r pr_number _rest; do
    [ -z "$pr_number" ] && continue
    mw_mark_processed "$pr_number"
    count=$((count + 1))
  done <<< "$prs"
  echo "orc-seed-merge-watch.sh: seeded $count already-merged PR(s) into $MERGE_WATCH_STATE" >&2
}

# Guard so this file can be sourced (for tests) without running the seed
# as a side effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  orc_seed_merge_watch
fi
