#!/bin/bash
# hooks/check-inbox-stop.sh — Stop hook (issue #125): deterministic inbox
# pickup at turn boundaries. If this agent's LIVE inbox holds unacked .msg
# files when it tries to go idle, block the stop with a reason listing
# them -- the session reads and acks its inbox before idling, so delivery
# to a busy agent needs NO keystroke injection at all: the sender writes
# the file, and this hook guarantees pickup at the end of the current
# turn. (An agent that was ALREADY idle when the message landed has no
# turn boundary coming -- that case is the broker's typed wake,
# lib/broker.sh.)
#
# stop_hook_active guard: Claude Code sets it when a Stop was already
# blocked once this cycle -- allow the stop then, so an unprocessable
# message reminds once per turn instead of blocking forever.
#
# Failsafe interplay: while the quota-stop flag is up the session is
# parked, and quota-stop-gate blocks its tools anyway -- forcing it to
# process an inbox it cannot act on would just burn the failsafe
# question. Allow the stop; the broker holds delivery until the park
# lifts.
set -uo pipefail

INPUT=$(cat)
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // "false"' 2>/dev/null)" = "true" ]; then
  exit 0
fi
# One-shot/headless sessions (scribe) ack their own single task by
# construction and per AGENTS.md never poll an inbox -- see
# check-handoff.sh's ORC_ONESHOT comment for why this exemption is safe
# (issue #31 protects the hook wiring itself).
[ "${ORC_ONESHOT:-0}" = "1" ] && exit 0

ROLE="${ORC_ROLE:-}"
case "$ROLE" in
  orchestra|builder) ;;
  *) exit 0 ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/harness-root.sh
source "$DIR/../lib/harness-root.sh"
if [ -n "${CHECK_INBOX_CANON_DIR:-}" ]; then
  CANON_DIR="$CHECK_INBOX_CANON_DIR"
else
  CANON_DIR="$(harness_canonical_dir "$PWD")" || exit 0
fi

[ -f "$CANON_DIR/state/quota-stop" ] && exit 0

INBOX="$CANON_DIR/inbox/$ROLE"
[ -d "$INBOX" ] || exit 0

UNACKED=""
for m in "$INBOX"/*.msg; do
  [ -e "$m" ] || break
  [ -f "${m%.msg}.ack" ] || UNACKED="${UNACKED}  ${m}"$'\n'
done
[ -z "$UNACKED" ] && exit 0

{
  echo "Unread inbox message(s) for $ROLE -- read and act on them NOW, before going idle. An assign IS the authorization: start immediately, do not ask permission to begin. Write the one-line receipt .ack next to each .msg (AGENTS.md Dispatch Protocol):"
  printf '%s' "$UNACKED"
} >&2
exit 2
