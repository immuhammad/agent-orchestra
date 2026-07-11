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
# shellcheck source=../lib/quota-stop-lib.sh
source "$LIB_DIR/quota-stop-lib.sh"

INPUT=$(cat)

# FAIL CLOSED if the project root can't be resolved (finding 3, agy's
# dedicated security review): the original fail-OPEN posture here meant
# `cd /tmp` (or anywhere with no discoverable orchestrator.yaml) bypassed
# the gate entirely, flag or no flag -- an enforcement gate must fail
# closed on "can't tell", not allow. qsg_resolve_canon_dir tries
# $CLAUDE_PROJECT_DIR first specifically so this stays rare in practice
# (Claude Code always sets it for the session). The message is specific
# enough to diagnose (not a silent brick) if it does fire.
CANON_DIR="$(qsg_resolve_canon_dir)" || {
  echo "quota-stop-gate.sh: gate cannot verify quota state -- project root unresolvable via \$CLAUDE_PROJECT_DIR or \$PWD ancestor walk-up (no orchestrator.yaml found). Failing CLOSED per AGENTS.md Quota Failsafe: an enforcement gate that can't check state must not silently allow. Set CLAUDE_PROJECT_DIR or run from inside a project with orchestrator.yaml." >&2
  exit 2
}
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
