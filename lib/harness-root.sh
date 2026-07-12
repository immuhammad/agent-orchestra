#!/bin/bash
# lib/harness-root.sh — resolves the CANONICAL .harness directory for
# inbox/state/log writes.
#
# Generalized for epic #91a (issue #116): every project runs its own clone
# of agent-orchestra (clone-per-project, issue #18 item 8) with these
# scripts in its own lib/, so resolving off the SCRIPT's own directory (the
# old `dirname ${BASH_SOURCE[0]}` / "$script_dir" pattern) would anchor
# state to whichever clone happens to be invoked instead of the project it
# was invoked FOR (relevant even within a single clone-per-project setup
# when one clone nests another as a dev target, e.g. this repo's own
# project/agent-orchestra/). Resolution is now caller-cwd-based instead:
#
#   1. ORC_PROJECT_ROOT env var, if set, wins outright (explicit override
#      for hooks/CI/tests that can't rely on cwd).
#   2. Otherwise walk UP from the given start dir (default: $PWD) looking
#      for orchestrator.yaml — the per-project marker file (git-style
#      ancestor discovery, same shape as git's own walk-up for `.git`).
#   3. If that discovered root sits inside a git worktree, redirect to the
#      worktree's MAIN checkout instead (via --git-common-dir) — every
#      worktree gets its own tracked copy of orchestrator.yaml, so a naive
#      walk-up alone would re-split mailboxes/state across worktrees
#      (issue #99, still a live risk under the new discovery rule).
#   4. FAILS LOUD if no orchestrator.yaml is found and ORC_PROJECT_ROOT is
#      unset: prints to stderr, returns 1, prints NOTHING to stdout. A
#      caller must treat empty output as an error, never silently fall
#      back to its own script directory (that silent fallback was the
#      #116 bug this replaces).
set -uo pipefail

# harness_canonical_dir [start_dir] — echoes the canonical .harness
# directory to use for inbox/state/log files, or fails loud (see above).
harness_canonical_dir() {
  local start_dir="${1:-$PWD}" dir root common_dir main_root

  if [ -n "${ORC_PROJECT_ROOT:-}" ]; then
    echo "${ORC_PROJECT_ROOT%/}/.harness"
    return 0
  fi

  dir="$(cd "$start_dir" >/dev/null 2>&1 && pwd)"
  if [ -z "$dir" ]; then
    echo "harness_canonical_dir: no such directory: $start_dir" >&2
    return 1
  fi

  root=""
  while :; do
    if [ -f "$dir/orchestrator.yaml" ]; then
      root="$dir"
      break
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done

  if [ -z "$root" ]; then
    echo "harness_canonical_dir: no orchestrator.yaml found walking up from $start_dir, and ORC_PROJECT_ROOT is unset" >&2
    return 1
  fi

  common_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common_dir" ]; then
    main_root="$(dirname "$common_dir")"
    echo "$main_root/.harness"
  else
    echo "$root/.harness"
  fi
}
