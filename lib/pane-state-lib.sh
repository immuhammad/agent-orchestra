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

# pane_state_write <pane_id> <busy|idle|failsafe> [session_id] -- called by
# hooks/pane-state.sh and hooks/rate-limit-handoff.sh.
# One line: "<state> <epoch_seconds> [session_id]". Single-writer-per-file
# (only that pane's own hook process ever writes its own file), so no
# locking needed. An invalid pane_id (see pane_state_sanitize) is silently
# refused, not written anywhere -- best-effort feature, never worth failing
# a hook over, and never worth trusting an unvalidated value for a
# filesystem write.
pane_state_write() {
  local pane_id="$1" state="$2" session_id="${3:-}" file safe_id
  [ -z "$pane_id" ] && return 0
  safe_id="$(pane_state_sanitize "$pane_id")" || return 0
  mkdir -p "$PANE_STATE_DIR"
  file="$PANE_STATE_DIR/$safe_id"
  echo "$state $(date '+%s') $session_id" > "$file"
}

# pane_state_read <pane_id> [max_age_s] -- prints "busy", "idle", or
# "failsafe" to stdout; prints nothing and returns 1 if missing,
# malformed, or the pane_id itself is invalid (see pane_state_sanitize).
#
# issue #125: NO age-out by default. The old 30s staleness guard
# self-destructed exactly when ground truth mattered most -- an idle pane
# fires no hooks, so 'idle' expired 30s after Stop and every long-idle
# pane fell back to the screen-scrape heuristics; a long thinking stretch
# with no tool calls did the same to 'busy'. States are transitions:
# valid until the NEXT hook overwrites them. The crash case the old guard
# existed for (hooks stop firing the moment a pane dies mid-generation)
# is covered at the PROCESS level instead: watch.sh's pane-liveness
# detects the dead pane and calls pane_state_clear, so a crashed 'busy'
# can't wedge delivery. An explicit max_age_s still enforces freshness
# for any caller that genuinely wants it.
pane_state_read() {
  local pane_id="$1" max_age="${2:-}" file line state ts rest now age safe_id
  [ -z "$pane_id" ] && return 1
  safe_id="$(pane_state_sanitize "$pane_id")" || return 1
  file="$PANE_STATE_DIR/$safe_id"
  [ -f "$file" ] || return 1
  line="$(cat "$file" 2>/dev/null)"
  state="${line%% *}"
  rest="${line#* }"
  ts="${rest%% *}"
  case "$ts" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$state" in
    busy|idle|failsafe) ;;
    *) return 1 ;;
  esac
  if [ -n "$max_age" ]; then
    now="$(date '+%s')"
    age=$((now - ts))
    [ "$age" -le "$max_age" ] || return 1
  fi
  echo "$state"
}

# pane_state_session <pane_id> -- prints the session_id recorded with the
# pane's current state (issue #125 ownership checks: "is this still the
# session I parked?" compares identities, not screen fingerprints).
# Prints nothing / returns 1 if there is none.
pane_state_session() {
  local pane_id="$1" file line safe_id sid
  [ -z "$pane_id" ] && return 1
  safe_id="$(pane_state_sanitize "$pane_id")" || return 1
  file="$PANE_STATE_DIR/$safe_id"
  [ -f "$file" ] || return 1
  line="$(cat "$file" 2>/dev/null)"
  sid="$(echo "$line" | awk '{print $3}')"
  [ -n "$sid" ] || return 1
  echo "$sid"
}

# pane_state_effective <pane_id> -- pane_state_read with ONE derivation
# (issue #125, Ahmad's post-park question): "failsafe" is only meaningful
# while the quota-stop flag exists. The state file records "this session
# last stopped while the room was gated"; once the gate lifts, a pane
# that hasn't spoken since is simply idle -- and nothing would ever
# rewrite the file, because hooks only fire when the session moves and
# nothing wakes a pane that reads parked (the chicken-and-egg this
# helper breaks). DELIVERY consumers (broker, nudge gating, dashboards)
# use this; auto-resume deliberately keeps the RAW pane_state_read -- its
# ownership test asks "was it parked and untouched", which the raw file
# answers truthfully. PANE_STATE_QUOTA_FLAG overrides the flag path
# (tests); default = the sibling of PANE_STATE_DIR, the same
# state/quota-stop every other reader resolves.
pane_state_effective() {
  local pane_id="$1" state flag
  state="$(pane_state_read "$pane_id")" || return 1
  if [ "$state" = "failsafe" ]; then
    flag="${PANE_STATE_QUOTA_FLAG:-$(dirname "$PANE_STATE_DIR")/quota-stop}"
    [ -f "$flag" ] || state="idle"
  fi
  echo "$state"
}

# pane_state_clear <pane_id> -- removes the pane's state file. Called by
# watch.sh's pane-liveness when a pane's CLI process is DEAD (dropped to a
# plain shell): a dead pane's last-written state is a lie, and clearing it
# is what lets terminal states persist without an age-out (see
# pane_state_read).
pane_state_clear() {
  local pane_id="$1" safe_id
  [ -z "$pane_id" ] && return 0
  safe_id="$(pane_state_sanitize "$pane_id")" || return 0
  rm -f "$PANE_STATE_DIR/$safe_id"
}
