#!/bin/bash
# .harness/log-decision.sh "role|model|decision"
# Appends a dated line to decisions.log so logging a decision is one command.
#
# T27 (issue #50): decisions.log is the ONE place every agent (Builder,
# Reviewer, Scribe, Orchestra) is allowed to write in the shared checkout --
# see AGENTS.md's single-writer rule. Multiple agents append concurrently in
# practice, so this is locked: a plain `>>` is atomic per-write on POSIX for
# a single line, but two agents racing to log at the same instant could
# still interleave under load, and there's no portable `flock` binary on
# macOS (only Linux util-linux ships one) -- so this uses `mkdir` as the
# lock primitive instead (mkdir is atomic on every POSIX filesystem this
# repo runs on), not literal flock(1). LOCK_DIR is overridable so tests can
# point it at an isolated location instead of the real decisions.log lock.
set -euo pipefail

ARG="${1:?usage: log-decision.sh \"role|model|decision\"}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# issue #99: decisions.log is per-repo state, not per-checkout -- a T33 case
# already hit this exact bug (an entry got written worktree-local and had
# to be re-logged by hand). Resolves off the CALLER's cwd (issue #116:
# this script no longer lives inside the project it serves), lazily --
# only if LOG_FILE or LOCK_DIR is left to its default -- so a caller
# pinning both explicitly (tests) never needs orchestrator.yaml/
# ORC_PROJECT_ROOT. `set -e` means a resolution failure (bad exit +
# stderr message from harness_canonical_dir) aborts here.
_ld_canon_dir() {
  if [ -z "${_LD_CANON_DIR_CACHE:-}" ]; then
    _LD_CANON_DIR_CACHE="$(harness_canonical_dir "$PWD")"
  fi
  echo "$_LD_CANON_DIR_CACHE"
}
LOG_FILE="${LOG_DECISION_FILE:-$(_ld_canon_dir)/decisions.log}"
LOCK_DIR="${LOG_DECISION_LOCK_DIR:-$(_ld_canon_dir)/.decisions.lock}"

IFS='|' read -r ROLE MODEL DECISION <<< "$ARG"

acquire_lock() {
  local attempts=0
  # 100 * 0.05s = 5s max wait before proceeding unlocked -- a slow/dead
  # holder must never silently swallow a decision.
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      echo "log-decision.sh: lock held after 5s, proceeding unlocked (a delayed append is better than a lost one)" >&2
      return 0
    fi
    sleep 0.05
  done
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap release_lock EXIT

acquire_lock
echo "$(date '+%Y-%m-%d') | ${ROLE} | ${MODEL} | ${DECISION}" >> "$LOG_FILE"
