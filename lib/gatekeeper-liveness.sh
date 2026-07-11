#!/bin/bash
# .harness/gatekeeper-liveness.sh — warns pane 0 if gatekeeper.sh's heartbeat
# goes stale (T19; the 2026-07-04 audit found gatekeeper.sh dead at 78%
# usage with nobody noticing). Runs as its own background process, started
# by harness-up.sh independently of gatekeeper.sh -- if gatekeeper.sh
# crashes or hangs, this watchdog is a separate process and keeps running
# to report it, rather than dying alongside it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# issue #116: HEARTBEAT/LOG must resolve to the same place gatekeeper.sh
# itself writes to (the caller's project root), not this script's own
# directory -- nohup preserves cwd from `orc up`, so $PWD is still the
# project root at the time this was launched. Resolved lazily/memoized,
# same as gatekeeper.sh, so a caller pinning both *_FILE vars explicitly
# never needs orchestrator.yaml/ORC_PROJECT_ROOT to exist.
_gkl_canon_dir() {
  if [ -z "${_GKL_CANON_DIR_CACHE:-}" ]; then
    if [ -n "${GATEKEEPER_CANON_DIR:-}" ]; then
      _GKL_CANON_DIR_CACHE="$GATEKEEPER_CANON_DIR"
    elif ! _GKL_CANON_DIR_CACHE="$(harness_canonical_dir "$PWD")"; then
      echo "gatekeeper-liveness.sh: could not resolve project root (see error above); set ORC_PROJECT_ROOT, run from inside a project with orchestrator.yaml, or pin GATEKEEPER_HEARTBEAT_FILE/GATEKEEPER_LIVENESS_LOG explicitly" >&2
      exit 1
    fi
  fi
  echo "$_GKL_CANON_DIR_CACHE"
}
HEARTBEAT="${GATEKEEPER_HEARTBEAT_FILE:-$(_gkl_canon_dir)/gatekeeper.heartbeat}"
LOG="${GATEKEEPER_LIVENESS_LOG:-$(_gkl_canon_dir)/budget.log}"
CHECK_INTERVAL="${GATEKEEPER_LIVENESS_INTERVAL:-60}"
# gatekeeper.sh's own loop period is $GATEKEEPER_INTERVAL (default 300s);
# 2x that plus slack tolerates one slow iteration (e.g. a slow curl to the
# usage endpoint) without a false-positive warning.
STALE_AFTER="${GATEKEEPER_LIVENESS_STALE_AFTER:-660}"
TARGET="${GATEKEEPER_LIVENESS_TARGET:-harness:0.0}"
ALERTED=false

liveness_main() {
echo "Gatekeeper liveness watchdog active (stale after ${STALE_AFTER}s, target $TARGET)"
while true; do
  now=$(date +%s)
  last=0
  [ -f "$HEARTBEAT" ] && last=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
  age=$((now - last))

  if [ "$age" -ge "$STALE_AFTER" ]; then
    if [ "$ALERTED" = false ]; then
      echo "$(date) - ALERT: gatekeeper heartbeat stale (${age}s, expected every ~${STALE_AFTER}s)" >> "$LOG"
      tmux send-keys -t "$TARGET" "gatekeeper watchdog: no heartbeat for ${age}s -- gatekeeper.sh may have died. Check pane 4." C-m 2>/dev/null
      ALERTED=true
    fi
  else
    ALERTED=false
  fi
  sleep "$CHECK_INTERVAL"
done
}

# Guard so this file can be sourced (for tests) without running the
# infinite loop as a side effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  liveness_main
fi
