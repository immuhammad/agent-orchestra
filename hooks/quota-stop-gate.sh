#!/bin/bash
# hooks/quota-stop-gate.sh — PreToolUse gate (issue #10). Makes the
# AGENTS.md Quota Failsafe an actual gate instead of a request: while
# gatekeeper.sh's quota-stop flag (lib/auto-resume.sh's
# AR_QUOTA_STOP_FLAG, see ar_write_quota_stop_flag) exists, every tool
# call is refused except a small allow-list (lib/quota-stop-lib.sh) that
# lets a blocked session still park honestly and report back.
#
# Wired via .claude/settings.json's PreToolUse (matcher ".*") through the
# orc-exec.sh trampoline, same as lib/guard.sh / lib/guard-write.sh.
# House pattern (guard.sh:73): block by echoing the reason to stderr and
# `exit 2` -- Claude Code shows stderr to the model and does not run the
# tool.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="$(cd "$DIR/../lib" >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/harness-root.sh
source "$LIB_DIR/harness-root.sh"
# shellcheck source=../lib/quota-stop-lib.sh
source "$LIB_DIR/quota-stop-lib.sh"

INPUT=$(cat)

# Fail OPEN (allow) if the project root can't be resolved -- unlike
# guard-write.sh's protected-path check (a hard security boundary that
# must fail closed), this is an availability gate: a directory with no
# orchestrator.yaml has no quota-stop flag to check against, and blocking
# every tool call in that case would be a much worse regression than
# occasionally missing the gate. FLAG (per this ticket's instructions):
# confirm this fail-open choice is the intended posture.
CANON_DIR="$(harness_canonical_dir "$PWD" 2>/dev/null)" || exit 0
FLAG_PATH="$CANON_DIR/state/quota-stop"

[ -f "$FLAG_PATH" ] || exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

case "$TOOL_NAME" in
  Write|Edit)
    if [ -n "$FILE_PATH" ] && qsg_path_allowed "$FILE_PATH" "$CANON_DIR"; then
      exit 0
    fi
    ;;
  Bash)
    if [ -n "$COMMAND" ] && qsg_command_allowed "$COMMAND"; then
      exit 0
    fi
    ;;
esac

echo "quota-stop-gate.sh: tool blocked -- an active quota-stop flag means the AGENTS.md Quota Failsafe applies. Update handoff.md, then ask exactly this, verbatim and nothing else:" >&2
qsg_failsafe_message "$FLAG_PATH" >&2
exit 2
