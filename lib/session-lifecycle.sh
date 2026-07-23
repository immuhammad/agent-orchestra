#!/bin/bash
# lib/session-lifecycle.sh -- issue #6: classifies every Claude Code pane
# start as resumed|rebuilt|fresh instead of always launching a blank
# session and letting it silently masquerade as having no history.
#
# Two pieces:
#   - a tiny per-role registry ("what session_id did this role last run
#     as?") that survives a full room rebuild, since tmux pane_ids (what
#     lib/pane-state-lib.sh keys off) do NOT survive a rebuild -- a fresh
#     tmux server hands out fresh pane_ids every time.
#   - sl_build_launch_cmd, a PURE function that builds the exact shell
#     command bin/orc feeds to `tmux send-keys` for a Claude Code pane
#     (orchestra/builder -- the only two roles that run real Claude Code
#     sessions). Split out and string-built (not executed here) the same
#     way orc-worktree.sh's build_pr_body is, so the exact shape can be
#     asserted directly in tests without needing a real tmux pane or a
#     real `claude` binary for every case.
#
# Classification, decided by the BUILT COMMAND at pane-launch time, never
# guessed after the fact:
#   fresh   -- no prior session_id recorded for this role: launch plain.
#   resumed -- a prior session_id was recorded AND `claude --resume`
#              actually kept running (never assumed from the attempt
#              alone).
#   rebuilt -- a prior session_id was recorded but the resume attempt
#              exited FAST (see SL_RESUME_FAIL_WINDOW_S below): start
#              fresh, but loudly, via ORC_SESSION_CLASS=rebuilt --
#              hooks/session-start.sh reads that env var and flags
#              Orchestra + tells the agent not to trust its own memory.
#
# SL_RESUME_FAIL_WINDOW_S guards against a DIFFERENT failure: a resumed
# session that runs for hours and is later exited normally (a deliberate
# /exit, a crash unrelated to resume) must NOT auto-respawn a fresh claude
# process behind the user's back -- only an exit within this window is
# treated as "the resume attempt itself failed", not a real ended session.
set -uo pipefail

# ROLE_SESSION_DIR override (hooks/session-start.sh sets this from its own
# resolved CANON_DIR before sourcing -- absolute, since a hook can run from
# a worktree cwd where a relative path would land in the wrong place).
# bin/orc always runs from the project root, so the relative default is
# correct there without any override, matching how it writes every other
# .harness/ path.
ROLE_SESSION_DIR="${ROLE_SESSION_DIR:-${CANON_DIR:-.harness}/state/role-session}"

# How long a `claude --resume` attempt can run before an exit is treated
# as "the resume genuinely failed" rather than "the session ended
# normally". Not exposed via orchestrator.yaml (no consumer need for it to
# be tunable yet -- AGENTS.md #86: no new config keys without one).
SL_RESUME_FAIL_WINDOW_S="${SL_RESUME_FAIL_WINDOW_S:-10}"

# sl_role_session_file <role> -- echoes the path to that role's last-known
# session_id file.
sl_role_session_file() {
  echo "$ROLE_SESSION_DIR/$1"
}

# sl_read_role_session <role> -- prints the last-known session_id for a
# role, or nothing if none is recorded (no file, or an empty/whitespace-
# only one -- treated as "no sid to try", i.e. fresh, never rebuilt).
sl_read_role_session() {
  local role="$1" file sid
  file="$(sl_role_session_file "$role")"
  [ -f "$file" ] || return 0
  sid="$(tr -d '[:space:]' < "$file" 2>/dev/null || echo '')"
  # agy PR #135 round 1: this value is interpolated straight into the
  # shell command sl_build_launch_cmd hands `tmux send-keys` to TYPE into
  # a live pane. The file on disk is trusted state we wrote, but reading
  # it back is the last point before that trust turns into code a shell
  # executes -- a tampered/corrupted file (or any future writer that
  # doesn't go through sl_write_role_session) must never carry shell
  # metacharacters that far. A real Claude Code session_id is always
  # UUID-shaped, so this is not a functional restriction; same closed
  # charset PR #133 used for orc_session_name, for the same reason.
  case "$sid" in
    ''|*[!A-Za-z0-9_-]*) return 0 ;;
  esac
  echo "$sid"
  return 0
}

# sl_write_role_session <role> <session_id> -- atomic write (mktemp in the
# SAME directory + mv, same same-filesystem-atomicity pattern used
# throughout this codebase, e.g. dispatch.sh's dispatch_write_msg).
sl_write_role_session() {
  local role="$1" sid="$2" file tmp
  if [ -z "$role" ] || [ -z "$sid" ]; then
    return 0
  fi
  file="$(sl_role_session_file "$role")"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  printf '%s' "$sid" > "$tmp" && mv "$tmp" "$file"
}

# sl_build_launch_cmd <role> <model> [extra claude flags...] -- pure
# string builder (echoes the command, never executes anything). Reads the
# role's last-known session_id via sl_read_role_session.
#
# No prior sid -> plain launch, ORC_SESSION_CLASS=fresh, banner echoed
# first so it survives in tmux scrollback after the TUI paints over it.
#
# A prior sid -> attempt `claude --resume <sid>` with ORC_SESSION_CLASS=
# resumed already set (the OPTIMISTIC classification -- correct the moment
# the process keeps running, which is what "resumed" actually means: it
# ran, under that env var, for real). Only on a FAST exit (< the fail
# window) does the fallback fire: a loud banner, then a plain launch with
# ORC_SESSION_CLASS=rebuilt. An exit past the window is left alone --
# looked like a normal end of session, not a failed resume, so nothing is
# auto-relaunched.
sl_build_launch_cmd() {
  local role="$1" model="$2" sid
  shift 2
  local flags="$*"
  sid="$(sl_read_role_session "$role")"

  if [ -z "$sid" ]; then
    echo "echo '[orc] ${role}: SESSION FRESH (no prior session recorded for this role)'; ORC_ROLE=${role} ORC_SESSION_CLASS=fresh claude --model ${model} ${flags}"
    return 0
  fi

  echo "echo '[orc] ${role}: attempting RESUME of session ${sid}'; SECONDS=0; if ORC_ROLE=${role} ORC_SESSION_CLASS=resumed claude --resume ${sid} --model ${model} ${flags}; then :; elif [ \"\$SECONDS\" -lt ${SL_RESUME_FAIL_WINDOW_S} ]; then echo '[orc] ${role}: RESUME FAILED after '\"\$SECONDS\"'s -- REBUILT (session ${sid} could not be restored), starting fresh'; ORC_ROLE=${role} ORC_SESSION_CLASS=rebuilt claude --model ${model} ${flags}; else echo '[orc] ${role}: session ${sid} ended after running normally ('\"\$SECONDS\"'s) -- NOT auto-relaunching'; fi"
}
