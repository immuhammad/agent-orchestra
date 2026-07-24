#!/bin/bash
# hooks/check-inbox-stop-agy.sh — Antigravity adapter for check-inbox-stop.sh
# Because agy's Stop hook contract does not provide a stop_hook_active flag,
# we must build our own remind-once guard to prevent unbounded re-entry by
# construction. This script calls check-inbox-stop.sh, intercepts its exit-2,
# checks a marker file keyed by conversationId against the current unacked set,
# and emits agy's JSON continuation format {"decision":"continue","reason":"..."}
# only once per set of unacked messages.
set -euo pipefail

INPUT=$(cat)
CONV_ID="$(echo "$INPUT" | jq -r '.conversationId // empty' 2>/dev/null || echo '')"

if [ -z "$CONV_ID" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Run the Claude script and capture its stderr
set +e
STDERR=$(echo "$INPUT" | bash "$DIR/check-inbox-stop.sh" 2>&1)
RC=$?
set -e

if [ $RC -eq 2 ]; then
  # check-inbox-stop.sh wants to block. Check our remind-once marker.
  # We use the unacked set listed in the stderr message to detect state changes.
  HASH=$(echo "$STDERR" | shasum -a 256 | awk '{print $1}')
  
  # Harness state directory for markers
  # shellcheck source=../lib/harness-root.sh
  source "$DIR/../lib/harness-root.sh"
  CANON_DIR="$(harness_canonical_dir "$PWD")" || exit 0
  mkdir -p "$CANON_DIR/state/agy-inbox-markers"
  MARKER_FILE="$CANON_DIR/state/agy-inbox-markers/${CONV_ID}.marker"
  
  if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE")" = "$HASH" ]; then
    # Already reminded for this exact set of messages; allow stop.
    echo '{"decision":"allow"}'
    exit 0
  fi
  
  # New set of messages; save marker and block.
  echo "$HASH" > "$MARKER_FILE"
  # JSON encode the stderr reason
  REASON=$(echo "$STDERR" | jq -Rs .)
  echo "{\"decision\":\"continue\",\"reason\":$REASON}"
  exit 0
fi

# check-inbox-stop.sh did not block (rc=0 or other)
echo '{"decision":"allow"}'
exit 0
