#!/bin/bash
# hooks/room-branch-gate.sh — PreToolUse gate (issue #60 task E). Makes a
# room-branch mismatch (lib/room-branch-lib.sh, task B) an actual gate, not
# just the ROOM dashboard warning gatekeeper.sh (task D) shows. Unlike
# quota-stop-gate.sh, there's no persisted flag file to check -- the room
# root's git branch IS the live state, checked fresh on every call.
#
# On the integration branch (or an active override): allow everything,
# same as quota-stop-gate.sh with no flag. On a mismatch with no override:
# deny everything except the shared qsg park-honestly allow-list
# (lib/quota-stop-lib.sh -- handoff.md/decisions.log/inbox/dispatch/
# log-decision/quota-stop-clear) PLUS one extra escape hatch this gate
# alone needs: the exact restore command (room_branch_restore_command_
# allowed) so a gated session can get itself back onto the integration
# branch without an operator override.
#
# Wired via .claude/settings.json's PreToolUse (matcher ".*"), same
# invocation shape as quota-stop-gate.sh: block by echoing the reason to
# stderr and `exit 2` (Claude Code shows stderr to the model, doesn't run
# the tool); allow via `exit 0`.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="$(cd "$DIR/../lib" >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/quota-stop-lib.sh
source "$LIB_DIR/quota-stop-lib.sh"
# shellcheck source=../lib/room-branch-lib.sh
source "$LIB_DIR/room-branch-lib.sh"

INPUT=$(cat)

# Same fail-CLOSED posture as quota-stop-gate.sh (qsg_resolve_canon_dir):
# an enforcement gate that can't verify state must not silently allow.
CANON_DIR="$(qsg_resolve_canon_dir)" || {
  echo "room-branch-gate.sh: gate cannot verify room-branch state -- project root unresolvable via \$CLAUDE_PROJECT_DIR or \$PWD ancestor walk-up (no orchestrator.yaml found). Failing CLOSED: an enforcement gate that can't check state must not silently allow. Set CLAUDE_PROJECT_DIR or run from inside a project with orchestrator.yaml." >&2
  exit 2
}
ROOT="$(cd "$(dirname "$CANON_DIR")" 2>/dev/null && pwd -P)" || {
  echo "room-branch-gate.sh: could not resolve the project root from canonical dir $CANON_DIR" >&2
  exit 2
}

STATE="$(room_branch_state "$ROOT")"
if [ "$STATE" = "ok" ]; then
  exit 0
fi
if room_branch_override_active "$ROOT"; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

case "$TOOL_NAME" in
  Write|Edit)
    if [ -n "$FILE_PATH" ] && qsg_path_allowed "$FILE_PATH" "$CANON_DIR"; then
      exit 0
    fi
    ;;
  Read)
    if [ -n "$FILE_PATH" ] && qsg_read_allowed "$FILE_PATH" "$CANON_DIR"; then
      exit 0
    fi
    ;;
  Bash)
    if [ -n "$COMMAND" ]; then
      if qsg_command_allowed "$COMMAND" "$CANON_DIR"; then
        exit 0
      fi
      if room_branch_restore_command_allowed "$COMMAND" "$ROOT"; then
        exit 0
      fi
    fi
    ;;
esac

echo "room-branch-gate.sh: tool blocked -- room branch $STATE (expected the integration branch). Restore with 'git checkout <integration-branch>' (or 'git switch'), or set an override: ORC_ALLOW_UNMERGED_HARNESS=1 / write a reason to .harness/state/room-branch-override." >&2
exit 2
