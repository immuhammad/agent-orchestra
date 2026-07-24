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
if [ -n "$COMMAND" ] && qsg_command_allowed "$COMMAND" "$CANON_DIR"; then
  echo '{"decision":"allow"}'
  exit 0
fi

# FLAG/PROBE (finding 4, agy's dedicated security review of PR #17's
# rework request): the CommandLine-only check above traps agy -- its
# file-write tools (e.g. write_to_file) have empty CommandLine, so an agy
# session could never obey the Quota Failsafe's "update handoff.md"
# instruction while gated.
#
# CONFIRMED live 2026-07-12 (real agy PreToolUse trace, a genuine native
# write): the payload shape is
# {"toolCall":{"name":"write_to_file","args":{"CodeContent":"...",
# "Description":"...","Overwrite":true,"TargetFile":"/abs/path"}}} --
# `.toolCall.args.TargetFile` (CapitalCase) is the confirmed primary key,
# same capitalization convention as the already-confirmed
# `.toolCall.args.CommandLine` above. FilePath/file_path are kept as
# minimal defensive fallbacks ONLY for other write-shaped agy tools
# (edit/replace) that haven't been traced yet -- not because TargetFile
# itself is still in doubt.
FILE_PATH=$(echo "$INPUT" | jq -r '
  .toolCall.args.TargetFile //
  .toolCall.args.FilePath // .toolCall.args.file_path // empty
')
if [ -n "$FILE_PATH" ] && qsg_path_allowed "$FILE_PATH" "$CANON_DIR"; then
  echo '{"decision":"allow"}'
  exit 0
fi

# #40 round 2 (agy's own dedicated security pass on PR #52): the write-only
# check above traps agy on READS too -- its PreToolUse matcher is ".*"
# (templates/agents-hooks.json), so a gated agy session's read/view tool
# calls were falling through to the deny at the bottom exactly like
# Claude Code's Read tool did before qsg_read_allowed existed. Per agy's
# report, the read-tool payload carries the target as
# .toolCall.args.AbsolutePath (file read) or .toolCall.args.DirectoryPath
# (directory-shaped read) -- NOT yet independently trace-captured in this
# codebase the way TargetFile above was; upgrade this comment to CONFIRMED
# once a live payload is captured. Gated on a read/view-shaped tool NAME
# (not just key presence) so a wrongly-guessed key on some OTHER tool
# can't accidentally reach into qsg_read_allowed's superset (it additionally
# allows the flag path itself, which must never be write-reachable).
TOOL_NAME=$(echo "$INPUT" | jq -r '.toolCall.name // empty')
case "$TOOL_NAME" in
  *[Rr]ead*|*[Vv]iew*)
    READ_FILE_PATH=$(echo "$INPUT" | jq -r '
      .toolCall.args.AbsolutePath // .toolCall.args.DirectoryPath // empty
    ')
    if [ -n "$READ_FILE_PATH" ] && qsg_read_allowed "$READ_FILE_PATH" "$CANON_DIR"; then
      echo '{"decision":"allow"}'
      exit 0
    fi
    ;;
esac

MSG="$(qsg_failsafe_message "$FLAG_PATH")"
REASON="quota-stop-gate: tool blocked -- an active quota-stop flag means the AGENTS.md Quota Failsafe applies. Update handoff.md, then ask exactly: ${MSG} (clearing this flag is human-directed, not something to infer or resolve on your own -- once Ahmad answers, ask Ahmad to run lib/quota-stop-clear.sh, or run it yourself ONLY once you actually have that answer)"
echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$REASON" '$m')}"
exit 0
