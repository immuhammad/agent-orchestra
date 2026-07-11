#!/bin/bash
# lib/quota-stop-lib.sh — shared allow-list/message logic for issue #10's
# quota-stop PreToolUse gate. Sourced by BOTH hooks/quota-stop-gate.sh
# (Claude Code's exit-code protocol, wired via .claude/settings.json) and
# lib/guard-quota-stop-agy.sh (agy's JSON-decision protocol, wired via
# .agents/hooks.json) -- mirrors this codebase's existing guard.sh /
# guard-agy.sh split (one protocol per file) rather than inventing a novel
# dual-protocol single file, so the allow-list can't drift between the two
# callers.
set -uo pipefail

# qsg_path_allowed <file_path> -- the ONLY Write/Edit targets a gated
# session may still touch: its own handoff.md update and decisions.log
# append (AGENTS.md Quota Failsafe: "update handoff.md fully" before
# asking), plus inbox .ack/.msg so a blocked agent can still park honestly
# and report back (this ticket's own REPORT-BACK instruction requires
# writing a .msg via dispatch.sh even while gated). Mirrors
# guard-write.sh's protected-path case-pattern style, INVERTED: default
# block, explicit allow for a match.
qsg_path_allowed() {
  case "$1" in
    */handoff.md|handoff.md|*/decisions.log|decisions.log|*/inbox/*/*.ack|*/inbox/*/*.msg) return 0 ;;
    *) return 1 ;;
  esac
}

# qsg_command_allowed <command string> -- the ONLY Bash invocations let
# through: decisions.log append, inbox dispatch (report-back), and the
# explicit manual quota-stop clear (lib/quota-stop-clear.sh -- the "Ahmad's
# a/b/c answer was recorded" signal, see that file's own header for why
# this is a deliberate human action, not an inferred heuristic).
qsg_command_allowed() {
  echo "$1" | grep -Eq '(^|[/[:space:]])lib/log-decision\.sh([[:space:]]|$)' && return 0
  echo "$1" | grep -Eq '(^|[/[:space:]])lib/dispatch\.sh([[:space:]]|$)' && return 0
  echo "$1" | grep -Eq '(^|[/[:space:]])lib/quota-stop-clear\.sh([[:space:]]|$)' && return 0
  return 1
}

# qsg_failsafe_message <flag_path> -- echoes AGENTS.md's Quota Failsafe
# question, verbatim, filled from the flag written by
# ar_write_quota_stop_flag (lib/auto-resume.sh). Keep the (a)/(b)/(c)
# structure EXACTLY (AGENTS.md's own wording requirement) -- this is the
# single source both hook dialects call so the two callers can never drift
# on the exact phrasing.
qsg_failsafe_message() {
  local flag_path="$1" pool pct fallback
  pool="$(jq -r '.pool // "quota"' "$flag_path" 2>/dev/null)"
  pct="$(jq -r '.pct // "?"' "$flag_path" 2>/dev/null)"
  fallback="$(jq -r '.fallback // "none"' "$flag_path" 2>/dev/null)"
  echo "Quota ${pool} at ${pct}%. Options: (a) switch to ${fallback} (b) throttle models (c) continue. Pick one."
}
