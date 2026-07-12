#!/bin/bash
# lib/pane-state-lib.sh — per-pane BUSY/IDLE state, written by Claude
# Code's own hooks (UserPromptSubmit/PreToolUse -> busy, Stop -> idle) and
# read by dispatch.sh's pane_is_idle (issue #33).
#
# Why: screen-scraping (tmux capture-pane) cannot tell Claude Code's input
# HINT/ghost text from real content, so it misreads busy/idle and nudges
# misfire. A hook fires exactly when Claude Code itself transitions
# busy/idle -- it needs no guessing, so it's authoritative for any pane it
# covers.
#
# Scope: hooks only fire for CLAUDE CODE sessions. A pane running a
# different TUI (e.g. agy/Gemini) never writes a state file, so a caller
# MUST fall back to screen-scraping when no fresh state file exists for a
# pane -- this lib is just the write/read primitives; the fallback policy
# lives in dispatch.sh's pane_is_idle.
set -uo pipefail

# PANE_STATE_DIR override for tests / explicit callers. Callers that
# already resolved CANON_DIR (dispatch.sh, hooks/pane-state.sh) should set
# this to "$CANON_DIR/state/pane-state" before sourcing/calling in.
PANE_STATE_DIR="${PANE_STATE_DIR:-${CANON_DIR:-.}/state/pane-state}"

# pane_state_sanitize <pane_id> -- validates AND normalizes a tmux
# pane_id. A real tmux pane_id always looks like "%<digits>" -- anything
# else is REJECTED outright (no stdout, exit 1), not stripped-and-passed-
# through.
#
# SECURITY (issue #33 PR #45 REQUEST-CHANGES, agy): hooks/pane-state.sh
# trusts $TMUX_PANE verbatim, and it's an ordinary inherited env var an
# agent can `export` before any tool call -- tmux never re-verifies it per
# hook invocation. The original strip-only sanitizer (`${1#%}`) let a
# traversal payload like "../../../../tmp/hacked" reach
# pane_state_write's `$PANE_STATE_DIR/<result>` untouched, letting an
# agent overwrite an arbitrary file outside PANE_STATE_DIR (e.g.
# .git/config, .harness/handoff.md) merely by tampering with its own
# environment. Strict allow-list validation (digits only after an
# optional leading '%') closes this outright, rather than trying to
# enumerate every dangerous character.
pane_state_sanitize() {
  local id="${1#%}"
  case "$id" in
    ''|*[!0-9]*) return 1 ;;
  esac
  echo "$id"
}

# pane_state_write <pane_id> <busy|idle> -- called by hooks/pane-state.sh.
# One line: "<state> <epoch_seconds>". Single-writer-per-file (only that
# pane's own hook process ever writes its own file), so no locking needed.
# An invalid pane_id (see pane_state_sanitize) is silently refused, not
# written anywhere -- best-effort feature, never worth failing a hook over,
# and never worth trusting an unvalidated value for a filesystem write.
pane_state_write() {
  local pane_id="$1" state="$2" file safe_id
  [ -z "$pane_id" ] && return 0
  safe_id="$(pane_state_sanitize "$pane_id")" || return 0
  mkdir -p "$PANE_STATE_DIR"
  file="$PANE_STATE_DIR/$safe_id"
  echo "$state $(date '+%s')" > "$file"
}

# pane_state_read <pane_id> [max_age_s, default 30] -- prints "busy" or
# "idle" to stdout if a FRESH state file exists; prints nothing and
# returns 1 if missing, malformed, stale, or the pane_id itself is
# invalid (see pane_state_sanitize). Staleness guards against trusting a
# crashed/killed pane's last-known state forever (hooks stop firing the
# moment the pane dies mid-generation) -- 30s is generously above the
# sub-second cadence hooks fire at during any real session activity.
pane_state_read() {
  local pane_id="$1" max_age="${2:-30}" file line state ts now age safe_id
  [ -z "$pane_id" ] && return 1
  safe_id="$(pane_state_sanitize "$pane_id")" || return 1
  file="$PANE_STATE_DIR/$safe_id"
  [ -f "$file" ] || return 1
  line="$(cat "$file" 2>/dev/null)"
  state="${line%% *}"
  ts="${line#* }"
  case "$ts" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -z "$state" ] && return 1
  now="$(date '+%s')"
  age=$((now - ts))
  [ "$age" -le "$max_age" ] || return 1
  echo "$state"
}
