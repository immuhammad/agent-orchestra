#!/bin/bash
# .harness/harness-root.sh — resolves the CANONICAL .harness directory for
# inbox/state/log writes (issue #99).
#
# Every worktree orc-worktree.sh creates gets its OWN full checkout of
# .harness/ (tracked files, not shared) -- inbox/*.msg, inbox/*.ack,
# decisions.log's lock, and merge-watch/deferred-nudge state are all
# gitignored, so each worktree's copy silently starts as its own empty
# mailbox/state. dispatch.sh, watch.sh, and log-decision.sh used to anchor
# these paths to `dirname ${BASH_SOURCE[0]}`, which resolves to wherever
# THAT script happens to be running from -- correct from the main
# checkout, silently wrong from any worktree (found live 2026-07-10: a
# Builder's re-review dispatch from inside .claude/worktrees/issue-85
# landed in that worktree's own inbox, not the real one agy polls).
#
# `git rev-parse --git-common-dir` returns the shared .git directory
# regardless of which worktree it's invoked from (every worktree's own
# --git-dir is a subdirectory of the main repo's .git, but
# --git-common-dir always points at that shared root) -- its parent is the
# main checkout's working tree, and .harness lives directly under that.
set -uo pipefail

# harness_canonical_dir <script's own dir> -- echoes the canonical
# .harness directory to use for inbox/state/log files. Falls back to the
# given script dir unchanged if it isn't inside a git repo at all (no
# --git-common-dir to resolve), so behavior outside a repo is unaffected.
harness_canonical_dir() {
  local script_dir="$1" common_dir main_root
  common_dir="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common_dir" ]; then
    main_root="$(dirname "$common_dir")"
    echo "$main_root/.harness"
  else
    echo "$script_dir"
  fi
}
