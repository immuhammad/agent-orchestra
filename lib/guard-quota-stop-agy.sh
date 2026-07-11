#!/bin/bash
# lib/guard-quota-stop-agy.sh — PreToolUse gate for agy (Antigravity CLI),
# wired via .agents/hooks.json. agy counterpart to
# hooks/quota-stop-gate.sh (issue #10): "a PreToolUse hook in EVERY
# session refuses tools" per the Gate-1 plan means agy sessions gate too,
# not just Claude Code's.
#
# Speaks agy's own protocol (JSON in via .toolCall.args, JSON decision out
# on stdout), same shape guard-agy.sh already established -- mirrors that
# file's precedent of inspecting ONLY CommandLine (this codebase has no
# confirmed agy payload shape for a distinct file-write tool call, so this
# deliberately doesn't guess at one; see PROBE note below).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# shellcheck source=./quota-stop-lib.sh
source "$DIR/quota-stop-lib.sh"

INPUT=$(cat)

# Fail open on an unresolvable project root -- same reasoning as
# hooks/quota-stop-gate.sh.
CANON_DIR="$(harness_canonical_dir "$PWD" 2>/dev/null)" || { echo '{"decision":"allow"}'; exit 0; }
FLAG_PATH="$CANON_DIR/state/quota-stop"

if [ ! -f "$FLAG_PATH" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

# PROBE (flag for agy's own dedicated security pass on this diff, per this
# ticket's REVIEW instructions): this only inspects CommandLine, following
# guard-agy.sh's precedent -- confirm live whether agy's PreToolUse payload
# ever carries a distinct file-write tool call this allow-list would need
# to separately recognize (the Claude Code dialect's Write/Edit + file_path
# branch has no equivalent here).
COMMAND=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // .toolCall.args.commandLine // empty')
if [ -n "$COMMAND" ] && qsg_command_allowed "$COMMAND"; then
  echo '{"decision":"allow"}'
  exit 0
fi

MSG="$(qsg_failsafe_message "$FLAG_PATH")"
REASON="quota-stop-gate: tool blocked -- an active quota-stop flag means the AGENTS.md Quota Failsafe applies. Update handoff.md, then ask exactly: ${MSG}"
echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$REASON" '$m')}"
exit 0
