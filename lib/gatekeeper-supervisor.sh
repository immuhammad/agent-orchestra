#!/bin/bash
# .harness/gatekeeper-supervisor.sh — issue #105 (T44) Task 3: respawns
# gatekeeper.sh with bounded backoff if it ever exits (crash, kill -9,
# uncaught `set -u` abort) instead of silently leaving the control room
# without a quota watchdog until a human happens to notice. Launched by
# orc.sh in place of gatekeeper.sh directly.
#
# gatekeeper-liveness.sh stays as the independent backstop it always was
# (a separate process, so a gatekeeper hang can't also silence its own
# watchdog) -- this script is the PRIMARY recovery path; liveness is what
# still catches it if this respawn loop itself somehow dies too.
#
# Backoff: doubles each time gatekeeper.sh exits again within
# GATEKEEPER_SUPERVISOR_RESET_AFTER seconds of its last start (crash-loop
# protection -- a gatekeeper that's immediately failing over and over
# shouldn't be respawned in a tight loop hammering the OAuth endpoint),
# capped at GATEKEEPER_SUPERVISOR_MAX_BACKOFF. Resets to 1s once
# gatekeeper.sh has run for at least that long -- a gatekeeper that ran
# fine for hours before one crash shouldn't be penalized with a long wait
# on its very next (likely unrelated) restart.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BUDGET_LOG="${GATEKEEPER_BUDGET_LOG:-.harness/budget.log}"
MAX_BACKOFF="${GATEKEEPER_SUPERVISOR_MAX_BACKOFF:-60}"
RESET_AFTER="${GATEKEEPER_SUPERVISOR_RESET_AFTER:-60}"
# Overridable so tests can point this at a stand-in script instead of the
# real gatekeeper.sh (which makes live OAuth calls and never voluntarily
# exits, neither of which a respawn-loop unit test wants).
TARGET="${GATEKEEPER_SUPERVISOR_TARGET:-$DIR/gatekeeper.sh}"

echo "$(date) - GATEKEEPER SUPERVISOR: starting" >> "$BUDGET_LOG"
backoff=1
while true; do
  start_ts=$(date +%s)
  "$TARGET"
  code=$?
  ran_for=$(( $(date +%s) - start_ts ))
  echo "$(date) - GATEKEEPER SUPERVISOR: gatekeeper.sh exited (code $code) after ${ran_for}s, respawning in ${backoff}s" >> "$BUDGET_LOG"
  if [ "$ran_for" -ge "$RESET_AFTER" ]; then
    backoff=1
  fi
  sleep "$backoff"
  backoff=$(( backoff * 2 ))
  [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"
done
