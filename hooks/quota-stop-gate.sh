#!/bin/bash
# hooks/quota-stop-gate.sh — PreToolUse gate. Makes the
# AGENTS.md Quota Failsafe an actual gate instead of a request: while
# gatekeeper.sh's quota-stop flag (lib/auto-resume.sh's
# AR_QUOTA_STOP_FLAG, see ar_write_quota_stop_flag) exists, every tool
# call is refused except a small allow-list (lib/quota-stop-lib.sh) that
# lets a blocked session still park honestly and report back.
#
# Wired via .claude/settings.json's PreToolUse (matcher ".*"), invoked
# directly (`bash "$CLAUDE_PROJECT_DIR"/hooks/quota-stop-gate.sh`), same as
# lib/guard.sh / lib/guard-write.sh. House pattern (guard.sh:73): block by
# echoing the reason to stderr and
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
  echo "quota-stop-gate.sh: gate cannot verify quota state -- project root unresolvable via \$CLAUDE_PROJECT_DIR or \$PWD ancestor walk-up (no orchestrator.yaml found). Failing CLOSED per AGENTS.md Quota Failsafe: an enforcement gate that can't check state must not silently allow. Set CLAUDE_PROJECT_DIR or run from inside a project with orchestrator.yaml.$(qsg_deleted_marker_hint)" >&2
  exit 2
}
FLAG_PATH="$CANON_DIR/state/quota-stop"

[ -f "$FLAG_PATH" ] || exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Intent normalization BEFORE dispatch (issue #172): an MCP tool that
# performs the same write/read operation as a built-in (woz's Edit/Search,
# or any other tool whose name ends in __Edit/__Write/__Read/__Search/
# __Grep/__Glob) is judged on WHAT IT DOES, not on matching a literal
# built-in name. The original allow-list only recognized the four
# built-in names (Write/Edit/Read/Bash) -- an MCP write/read tool fell
# through to the same catch-all deny as a genuinely random tool, even when
# its target path was itself allow-listed (this deadlocked the exact same
# "gated agent must be able to write handoff.md" case the 2026-07-12 Read
# fix already closed, just via woz's MCP Edit instead of the host Edit).
# FAIL CLOSED is preserved at two layers: (1) only a name matching one of
# these specific exact/suffix patterns gets an intent at all -- anything
# else (a hostile name like mcp__evil__NotAnEdit_Write does NOT match
# *__Write as a whole-name suffix -- it ends "_Write", one underscore, not
# the required "__Write", two) still falls through every case below to
# the deny at the bottom; (2) even a name that DID over-match still only
# reaches qsg_write_intent_allowed/qsg_read_intent_allowed, which deny
# unless the call's actual target path(s) are themselves on the fixed
# path allow-list -- misclassified intent can broaden WHICH CHECK runs,
# never WHICH PATHS pass it.
INTENT=""
case "$TOOL_NAME" in
  Write|Edit|NotebookEdit|*__Edit|*__Write) INTENT="write" ;;
  Read|*__Read|*__Search|*__Grep|*__Glob) INTENT="read" ;;
  Bash) INTENT="bash" ;;
esac

case "$INTENT" in
  write)
    # Covers both a single top-level tool_input.file_path (every built-in
    # call) and woz Edit's batched tool_input.edits[] (see
    # qsg_write_intent_allowed's header) -- the path checks themselves
    # (qsg_path_allowed) are untouched.
    if qsg_write_intent_allowed "$INPUT" "$CANON_DIR"; then
      exit 0
    fi
    ;;
  read)
    # A gated agent must be able to READ the state it's ordered to
    # act on (handoff.md, decisions.log, the inbox, the flag itself) --
    # without this, "update handoff.md" is an order the agent has no way
    # to obey (see qsg_read_allowed's header for the live deadlock this
    # closes). Also covers woz Search's batched
    # tool_input.file_glob_patterns[] (see qsg_read_intent_allowed).
    if qsg_read_intent_allowed "$INPUT" "$CANON_DIR"; then
      exit 0
    fi
    ;;
  bash)
    if [ -n "$COMMAND" ] && qsg_command_allowed "$COMMAND" "$CANON_DIR"; then
      exit 0
    fi
    ;;
esac

echo "quota-stop-gate.sh: tool blocked -- an active quota-stop flag means the AGENTS.md Quota Failsafe applies. Update handoff.md, then ask exactly this, verbatim and nothing else (clearing this flag is human-directed, not something to infer or resolve on your own -- once Ahmad answers, ask Ahmad to run lib/quota-stop-clear.sh, or run it yourself ONLY once you actually have that answer):" >&2
qsg_failsafe_message "$FLAG_PATH" >&2
exit 2
