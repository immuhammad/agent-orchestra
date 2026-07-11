#!/bin/bash
# .harness/inbox-poll.sh <agent>
# Lists pending (un-ack'd) messages in an agent's file inbox: any <ts>-<issue>.msg
# without a matching <ts>-<issue>.ack is still outstanding.
set -euo pipefail

AGENT="${1:?usage: inbox-poll.sh <agent>}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# issue #116: the inbox lives under the CALLER's project root, not this
# script's own directory (this script now lives in agent-orchestra's
# shared lib/). INBOX_POLL_CANON_DIR overrides outright for tests.
if [ -n "${INBOX_POLL_CANON_DIR:-}" ]; then
  CANON_DIR="$INBOX_POLL_CANON_DIR"
else
  CANON_DIR="$(harness_canonical_dir "$PWD")"
fi
INBOX="$CANON_DIR/inbox/$AGENT"

if [ ! -d "$INBOX" ]; then
  echo "inbox-poll.sh: no inbox for agent '$AGENT' (expected $INBOX)" >&2
  exit 1
fi

PENDING=0
SUSPECT=0
for msg in "$INBOX"/*.msg; do
  [ -e "$msg" ] || continue
  ack="${msg%.msg}.ack"
  if [ ! -e "$ack" ]; then
    echo "PENDING: $msg"
    PENDING=$((PENDING + 1))
  # T30 (issue #56): an .ack should be a one-line receipt (what was done /
  # SKIPPED because X), not just a marker file -- an empty or
  # whitespace-only .ack tells the sender nothing and is suspect, not a
  # real acknowledgement, even though a .msg/.ack pairing exists.
  elif [ -z "$(tr -d '[:space:]' < "$ack" 2>/dev/null)" ]; then
    echo "SUSPECT (empty ack): $msg -> $ack"
    SUSPECT=$((SUSPECT + 1))
  fi
done

if [ "$PENDING" -eq 0 ] && [ "$SUSPECT" -eq 0 ]; then
  echo "inbox-poll.sh: no pending messages for '$AGENT'"
elif [ "$SUSPECT" -gt 0 ]; then
  echo "inbox-poll.sh: $SUSPECT suspect (empty) ack(s) for '$AGENT' -- these acked with no status, treat as unconfirmed"
fi
