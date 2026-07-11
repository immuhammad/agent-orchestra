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
# to be re-logged by hand). CANON_DIR resolves to the MAIN checkout's
# .harness regardless of which worktree log-decision.sh happens to run
# from, off the CALLER's cwd (issue #116: this script no longer lives
# inside the project it serves). `set -e` above means a resolution
# failure (bad exit + stderr message from harness_canonical_dir) aborts
# here rather than silently continuing with an empty CANON_DIR.
CANON_DIR="$(harness_canonical_dir "$PWD")"
LOG_FILE="${LOG_DECISION_FILE:-$CANON_DIR/decisions.log}"
LOCK_DIR="${LOG_DECISION_LOCK_DIR:-$CANON_DIR/.decisions.lock}"

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
