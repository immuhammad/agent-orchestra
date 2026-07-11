#!/bin/bash
# lib/guard-quota-stop-agy.sh — PreToolUse gate for agy (Antigravity CLI),
# wired via .agents/hooks.json. agy counterpart to
# hooks/quota-stop-gate.sh (issue #10): "a PreToolUse hook in EVERY
# session refuses tools" per the Gate-1 plan means agy sessions gate too,
# not just Claude Code's.
#
# Speaks agy's own protocol (JSON in via .toolCall.args, JSON decision out
# on stdout), same shape guard-agy.sh already established.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./quota-stop-lib.sh
source "$DIR/quota-stop-lib.sh"

INPUT=$(cat)

# FAIL CLOSED on an unresolvable project root (finding 3, agy's dedicated
# security review) -- see qsg_resolve_canon_dir / hooks/quota-stop-gate.sh
# for the full reasoning; same fix, same posture, both dialects.
CANON_DIR="$(qsg_resolve_canon_dir)" || {
  MSG="quota-stop-gate: gate cannot verify quota state -- project root unresolvable. Failing CLOSED per AGENTS.md Quota Failsafe."
  echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$MSG" '$m')}"
  exit 0
}
FLAG_PATH="$CANON_DIR/state/quota-stop"

if [ ! -f "$FLAG_PATH" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // .toolCall.args.commandLine // empty')
if [ -n "$COMMAND" ] && qsg_command_allowed "$COMMAND"; then
  echo '{"decision":"allow"}'
  exit 0
fi

# FLAG/PROBE (finding 4, agy's dedicated security review of PR #17's
# rework request): the CommandLine-only check above traps agy -- its
# file-write tools (e.g. a write_to_file-shaped call) have empty
# CommandLine, so an agy session could never obey the Quota Failsafe's
# "update handoff.md" instruction while gated. No agy PreToolUse payload
# shape for a file-write tool call is confirmed anywhere in this codebase
# or its docs, so this tries SEVERAL plausible field-name conventions
# defensively -- guessing wrong on any one is still strictly better than
# the prior all-or-nothing trap. This is a BEST-EFFORT canary, NOT a
# confirmed fix: tests/quota-stop-gate.test.sh documents the exact shapes
# probed here so a real agy PreToolUse trace for a file-write call can
# confirm or correct them in one diff. MUST be live-verified before Gate
# 2 (matches this repo's canary-verify-each-agy-mechanism rule).
FILE_PATH=$(echo "$INPUT" | jq -r '
  .toolCall.args.FilePath // .toolCall.args.filePath // .toolCall.args.file_path //
  .toolCall.args.TargetFile // .toolCall.args.targetFile //
  .toolCall.args.Path // .toolCall.args.path // empty
')
if [ -n "$FILE_PATH" ] && qsg_path_allowed "$FILE_PATH" "$CANON_DIR"; then
  echo '{"decision":"allow"}'
  exit 0
fi

MSG="$(qsg_failsafe_message "$FLAG_PATH")"
REASON="quota-stop-gate: tool blocked -- an active quota-stop flag means the AGENTS.md Quota Failsafe applies. Update handoff.md, then ask exactly: ${MSG}"
echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$REASON" '$m')}"
exit 0
