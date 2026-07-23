#!/bin/bash
# lib/guard-room-branch-agy.sh — PreToolUse gate for agy (Antigravity CLI),
# wired via .agents/hooks.json. agy counterpart to
# hooks/room-branch-gate.sh (issue #60 task E): a room-branch mismatch
# gates agy sessions too, not just Claude Code's. See that file's header
# for the full reasoning (live per-call check, no persisted flag, shared
# qsg park-honestly allow-list plus the restore-command escape hatch).
#
# Speaks agy's own protocol (JSON in via .toolCall.args, JSON decision out
# on stdout), same shape guard-quota-stop-agy.sh already established.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./quota-stop-lib.sh
source "$DIR/quota-stop-lib.sh"
# shellcheck source=./room-branch-lib.sh
source "$DIR/room-branch-lib.sh"

INPUT="${ANTIGRAVITY_SOURCE_METADATA:-}"

CANON_DIR="$(qsg_resolve_canon_dir)" || {
  MSG="room-branch-gate: gate cannot verify room-branch state -- project root unresolvable. Failing CLOSED."
  echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$MSG" '$m')}"
  exit 0
}
ROOT="$(cd "$(dirname "$CANON_DIR")" 2>/dev/null && pwd -P)" || {
  MSG="room-branch-gate: could not resolve the project root from canonical dir $CANON_DIR. Failing CLOSED."
  echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$MSG" '$m')}"
  exit 0
}

STATE="$(room_branch_state "$ROOT")"
if [ "$STATE" = "ok" ] || room_branch_override_active "$ROOT"; then
  echo '{"decision":"allow"}'
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool.toolCall.argumentsJson | fromjson? | .CommandLine // .commandLine // empty')
if [ -n "$COMMAND" ]; then
  if qsg_command_allowed "$COMMAND" "$CANON_DIR"; then
    echo '{"decision":"allow"}'
    exit 0
  fi
  if room_branch_restore_command_allowed "$COMMAND" "$ROOT"; then
    echo '{"decision":"allow"}'
    exit 0
  fi
fi

# Same confirmed agy write-tool payload shape as guard-quota-stop-agy.sh
# (TargetFile primary, FilePath/file_path defensive fallbacks).
FILE_PATH=$(echo "$INPUT" | jq -r '
  .tool.toolCall.argumentsJson | fromjson? |
  .TargetFile // .FilePath // .file_path // empty
')
if [ -n "$FILE_PATH" ] && qsg_path_allowed "$FILE_PATH" "$CANON_DIR"; then
  echo '{"decision":"allow"}'
  exit 0
fi

# Same read-tool payload shape as guard-quota-stop-agy.sh
# (AbsolutePath/DirectoryPath), gated on a read/view-shaped tool name.
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool.toolCall.name // empty')
case "$TOOL_NAME" in
  *[Rr]ead*|*[Vv]iew*)
    READ_FILE_PATH=$(echo "$INPUT" | jq -r '
      .tool.toolCall.argumentsJson | fromjson? |
      .AbsolutePath // .DirectoryPath // empty
    ')
    if [ -n "$READ_FILE_PATH" ] && qsg_read_allowed "$READ_FILE_PATH" "$CANON_DIR"; then
      echo '{"decision":"allow"}'
      exit 0
    fi
    ;;
esac

MSG="room-branch-gate: tool blocked -- room branch $STATE (expected the integration branch). Restore with 'git checkout <integration-branch>' (or 'git switch'), or set an override: ORC_ALLOW_UNMERGED_HARNESS=1 / write a reason to .harness/state/room-branch-override."
echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$MSG" '$m')}"
exit 0
