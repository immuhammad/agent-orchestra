#!/bin/bash
# .harness/gatekeeper.sh — alert-only quota watchdog. Never kills agents.
set -uo pipefail
THRESHOLD=80
CHECK_INTERVAL="${GATEKEEPER_INTERVAL:-300}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# issue #116: state files default off the CALLER's project root, not this
# script's own directory (these scripts now live in agent-orchestra's
# lib/, separate from any consumer project). Resolved LAZILY (only if at
# least one of the specific *_FILE overrides below is unset) and memoized
# -- a caller that pins every path explicitly (tests, or an advanced
# setup) never needs an orchestrator.yaml/ORC_PROJECT_ROOT to exist at
# all. GATEKEEPER_CANON_DIR overrides the resolution itself outright.
_gk_canon_dir() {
  if [ -z "${_GK_CANON_DIR_CACHE:-}" ]; then
    if [ -n "${GATEKEEPER_CANON_DIR:-}" ]; then
      _GK_CANON_DIR_CACHE="$GATEKEEPER_CANON_DIR"
    elif ! _GK_CANON_DIR_CACHE="$(harness_canonical_dir "$PWD")"; then
      echo "gatekeeper.sh: could not resolve project root (see error above); set ORC_PROJECT_ROOT, run from inside a project with orchestrator.yaml, or pin GATEKEEPER_HEARTBEAT_FILE/GATEKEEPER_BUDGET_LOG/GATEKEEPER_ALERT_STATE_FILE explicitly" >&2
      exit 1
    fi
  fi
  echo "$_GK_CANON_DIR_CACHE"
}
HEARTBEAT="${GATEKEEPER_HEARTBEAT_FILE:-$(_gk_canon_dir)/gatekeeper.heartbeat}"
# Overridable so tests never append real ALERT/EXIT lines into the tracked
# .harness/budget.log (or a worktree's own copy of it).
BUDGET_LOG="${GATEKEEPER_BUDGET_LOG:-$(_gk_canon_dir)/budget.log}"

# issue #105 (T44) Task 3: diagnostics for WHY gatekeeper stopped, not just
# THAT it did (the liveness watchdog already covers detection). Logs to
# budget.log so it's visible on the same dashboard operators already check.
# EXIT (not ERR): this script has no `set -e`, so ERR would also fire on
# routine non-zero exits already handled by a conditional (grep/jq inside an
# `if`) -- pure noise. EXIT fires exactly once, for any actual reason the
# process stops (normal exit, a catchable signal, or a `set -u` unbound-
# variable abort). Can't catch SIGKILL (kill -9 is uncatchable by design) --
# that case is covered by the respawn wrapper (orc.sh) logging the child's
# exit status from the outside instead.
gk_log_exit() {
  echo "$(date) - GATEKEEPER EXIT: exit code $?" >> "$BUDGET_LOG"
}
trap gk_log_exit EXIT
# agy still reports via its own statusline scratch file -- only the Claude
# sensor moved off statusline in T19 (see fetch_claude_usage below).
AGY_STATUSLINE="$HOME/.gemini/antigravity-cli/scratch/agy-statusline.json"

# T20: budgeted 5h-window rate-limit auto-resume. See auto-resume.sh for the
# full state machine and policy (weekly never auto-resumes, max N/day,
# "only unblock what you parked"). auto-resume.sh resolves its own root
# lazily the same way (same $PWD), so this can't diverge from the
# resolution above without also needing to be forced.
source "$DIR/auto-resume.sh"

# T33 (issue #77): shared color/clear-screen helpers for the dashboard
# board below. Colors and clearing auto-disable outside a tty, so this
# never changes what a redirected/piped invocation (tests, logs) prints.
source "$DIR/tui-lib.sh"
GATEKEEPER_STALE_AFTER="${GATEKEEPER_LIVENESS_STALE_AFTER:-660}"

# issue #105 (T44) Task 2: alerts route through dispatch.sh now -- a durable
# inbox .msg to Orchestra (pane 0) plus a nudge, never a raw keystroke burst
# into Builder's (or anyone else's) live input. Orchestra owns parking/
# relaying to Builder per AGENTS.md's failsafe wording; gatekeeper itself
# no longer types the failsafe text into anyone's pane directly.
source "$DIR/dispatch.sh"

# T26: which tmux session gk_alert_orchestra's nudge targets. Overridable so
# tests can point every alert at a throwaway session instead of the real
# session -- a test that types into a live agent pane at real quota
# thresholds reads as a genuine user prompt, which is a safety bug, not just
# noise (confirmed live during T19/T20 testing).
#
# issue #19 follow-up: used to hardcode "harness" -- reuse $DISPATCH_SESSION
# (already derived above via dispatch.sh's own orc_session_name-based
# resolution, issue #18 item 7/#19) instead of re-deriving it, so this can't
# drift from dispatch.sh's own session targeting and two clone-per-project
# rooms never collide here either.
NOTIFY_SESSION="${GATEKEEPER_NOTIFY_SESSION:-$DISPATCH_SESSION}"

# issue #105 Task 1: alert state persisted to a JSON file (mirrors
# auto-resume-state.json's pattern) -- an in-memory-only CLAUDE_ALERTED/
# AGY_ALERTED bool forgets everything on restart, so a crash-respawn
# (Task 3) re-sent already-delivered alerts and re-spoke `say` for
# thresholds the operator had already been told about (observed live).
GK_ALERT_STATE_FILE="${GATEKEEPER_ALERT_STATE_FILE:-$(_gk_canon_dir)/gatekeeper-alert-state.json}"

gk_ensure_alert_state() {
  [ -f "$GK_ALERT_STATE_FILE" ] || echo '{}' > "$GK_ALERT_STATE_FILE"
}

gk_alert_read() { gk_ensure_alert_state; jq -r "$@" "$GK_ALERT_STATE_FILE"; }

gk_alert_write() {
  gk_ensure_alert_state
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$GK_ALERT_STATE_FILE" > "$tmp" && mv "$tmp" "$GK_ALERT_STATE_FILE"
}

# gk_is_alerted <pool key> -- true if this pool's CURRENT threshold crossing
# has already been alerted (survives a gatekeeper restart, unlike the old
# in-memory bool).
gk_is_alerted() {
  [ "$(gk_alert_read --arg p "$1" '.[$p].alerted // false')" = "true" ]
}

gk_mark_alerted() {
  gk_alert_write --arg p "$1" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$p] = {alerted: true, alerted_at: $t}'
}

gk_clear_alerted() {
  gk_alert_write --arg p "$1" '.[$p] = {alerted: false}'
}

# issue #105 Task 4: voice is OFF by default -- every restart used to
# re-speak every already-alerted pool with no way to silence it ("keeps on
# saying 80% something" was Ahmad's literal complaint). `voice: on` in
# orchestrator.yaml opts in; persisted alert state (Task 1) means "once per
# crossing" is true across restarts too, not just within one process
# lifetime.
GK_VOICE="${GATEKEEPER_VOICE:-$(orc_get_scalar voice)}"
GK_VOICE="${GK_VOICE:-off}"

gk_say() {
  [ "$GK_VOICE" = "on" ] && say "$1" >/dev/null 2>&1
  return 0
}

# gk_alert_orchestra <tag> <message> -- issue #105 Task 2: the ONLY alert
# delivery path now. Writes a durable inbox .msg to orchestra (via
# dispatch_main's `assign` verb -- write + nudge-if-idle, return
# immediately) instead of typing the alert text into any pane directly.
# Orchestra is the one agent trusted to read/relay this per AGENTS.md's
# Quota Failsafe wording; Builder (or anyone else) never gets alert
# keystrokes injected into their live input again.
gk_alert_orchestra() {
  dispatch_main assign orchestra "$1" "$2" >/dev/null
}

# T19: Claude sensor now reads the OAuth usage endpoint directly instead of
# Claude Code's statusLine scratch file (that file only updates while a
# Claude Code session is actively rendering a statusline -- dead time
# between sessions meant stale/missing numbers). Credentials come from the
# same place Claude Code itself stores them: macOS Keychain first
# ("Claude Code-credentials", the service name Claude Code registers under),
# falling back to ~/.claude/.credentials.json on platforms without a
# Keychain (or if the Keychain entry is missing). Both store the same
# {claudeAiOauth:{accessToken, ...}} shape.
get_claude_token() {
  local token
  token="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  if [ -z "$token" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    token="$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)"
  fi
  echo "$token"
}

fetch_claude_usage() {
  local token
  token="$(get_claude_token)"
  [ -z "$token" ] && return 1
  curl -sf --max-time 10 -H "Authorization: Bearer $token" \
    https://api.anthropic.com/api/oauth/usage 2>/dev/null
}

# gatekeeper_render (T33, issue #77) -- clears the pane and redraws the
# fixed board: QUOTA / HEARTBEAT / AUTO-RESUME / LAST ALERT. Display-layer
# only -- reads USAGE_PCT/WEEKLY_PCT/AGY_PCT/HEARTBEAT_AGE from the caller's
# scope, doesn't compute or persist anything itself. Every alert this loop
# fires still appends to $BUDGET_LOG unchanged; this function only
# controls what's currently ON SCREEN.
gatekeeper_render() {
  tui_clear
  echo "$(tui_bold "Gatekeeper") -- $(date '+%Y-%m-%d %H:%M:%S') (threshold ${THRESHOLD}%)"
  echo ""
  echo "$(tui_section QUOTA)"
  echo "  Claude 5h: $(tui_traffic_light "$USAGE_PCT" "${USAGE_PCT}%") | Claude weekly: $(tui_traffic_light "$WEEKLY_PCT" "${WEEKLY_PCT}%") | agy(max pool): $(tui_traffic_light "$AGY_PCT" "${AGY_PCT}%")"
  echo ""
  echo "$(tui_section HEARTBEAT)"
  if [ -n "$HEARTBEAT_AGE" ]; then
    if [ "$HEARTBEAT_AGE" -ge "$GATEKEEPER_STALE_AFTER" ]; then
      echo "  $(tui_red "${HEARTBEAT_AGE}s ago (stale, expected every ~${GATEKEEPER_STALE_AFTER}s)")"
    else
      echo "  $(tui_green "${HEARTBEAT_AGE}s ago")"
    fi
  else
    echo "  never (first tick)"
  fi
  echo ""
  echo "$(tui_section AUTO-RESUME)"
  local parked pending resumes_used
  parked="$(ar_read '[.panes[] | select(.state=="parked")] | length' 2>/dev/null)"
  pending="$(ar_read '[.panes[] | select(.state=="pending")] | length' 2>/dev/null)"
  resumes_used="$(ar_read '.budget.count' 2>/dev/null)"
  echo "  parked: ${parked:-0} | pending: ${pending:-0} | resumes used today: ${resumes_used:-0}/${AR_MAX_PER_DAY}"
  echo ""
  echo "$(tui_section "LAST ALERT")"
  local last_alert
  last_alert="$(grep 'ALERT' "$BUDGET_LOG" 2>/dev/null | tail -1)"
  echo "  ${last_alert:-none}"
}

gatekeeper_main() {
echo "Gatekeeper active (threshold ${THRESHOLD}%)"
while true; do
  # VERIFY jq path: fetch_claude_usage | jq '.five_hour, .seven_day'
  CLAUDE_USAGE_JSON="$(fetch_claude_usage)"
  USAGE_PCT=$(echo "$CLAUDE_USAGE_JSON" | jq -r '.five_hour.utilization // 0' 2>/dev/null | cut -d. -f1)
  [ -z "$USAGE_PCT" ] && USAGE_PCT=0
  WEEKLY_PCT=$(echo "$CLAUDE_USAGE_JSON" | jq -r '.seven_day.utilization // 0' 2>/dev/null | cut -d. -f1)
  [ -z "$WEEKLY_PCT" ] && WEEKLY_PCT=0
  # T20: only ever used for the 5h pool's auto-resume tracking -- never for
  # seven_day. Weekly crossings intentionally never touch auto-resume.sh.
  FIVE_HOUR_RESETS_AT=$(echo "$CLAUDE_USAGE_JSON" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)

  # --- agy 5h pools (VERIFIED T10 keys: cat "$AGY_STATUSLINE" | jq '.quota') ---
  AGY_PCT=$(jq 'if type=="object" and .quota then
      [ (1-(.quota."gemini-5h".remaining_fraction // 1)),
        (1-(.quota."3p-5h".remaining_fraction // 1)) ] | max*100
    else 0 end' "$AGY_STATUSLINE" 2>/dev/null | cut -d. -f1)
  [ -z "$AGY_PCT" ] && AGY_PCT=0

  # T33: heartbeat age computed from the PREVIOUS tick's file, before it's
  # overwritten further down -- "how long since gatekeeper last confirmed
  # it was alive", same signal gatekeeper-liveness.sh watches externally.
  #
  # Ahmad fold-in: `[ -z "$HB_VAL" ] && HB_VAL=0` looks like a safe
  # fallback but IS the false-alert bug in disguise -- treating an
  # empty/transiently-corrupt read as epoch 0 makes HEARTBEAT_AGE ~= now
  # (~1.78 billion seconds), which the display below renders as stale/red
  # even though gatekeeper is actively computing this exact line right
  # now. Same validation as gatekeeper-liveness.sh's independent read:
  # only compute an age from an actually-numeric value; otherwise show
  # "never (first tick)" rather than a manufactured huge number.
  HEARTBEAT_AGE=""
  if [ -f "$HEARTBEAT" ]; then
    HB_VAL="$(cat "$HEARTBEAT" 2>/dev/null)"
    case "$HB_VAL" in
      ''|*[!0-9]*) : ;; # leave HEARTBEAT_AGE unset -- see comment above
      *) HEARTBEAT_AGE=$(( $(date +%s) - HB_VAL )) ;;
    esac
  fi

  gatekeeper_render

  # --- both exhausted: everything pauses ---
  if [ "$USAGE_PCT" -ge "$THRESHOLD" ] && [ "$AGY_PCT" -ge "$THRESHOLD" ]; then
    if ! gk_is_alerted claude_5h || ! gk_is_alerted agy; then
      echo "$(date) - ALERT: BOTH pools >=${THRESHOLD}% (C:${USAGE_PCT}% A:${AGY_PCT}%)" >> "$BUDGET_LOG"
      gk_alert_orchestra "quota-both" "quota critical — BOTH pools >=${THRESHOLD}%. Follow AGENTS.md failsafe: update handoff, then HOLD. No fallback available."
      gk_say "Both quota pools exhausted"
      gk_mark_alerted claude_5h; gk_mark_alerted agy
      ar_mark_pending "$NOTIFY_SESSION:0.0"
      # #10 (rework finding 5): carry the 5h resets_at even for "both" --
      # agy's pool still has no epoch to auto-clear against, so this alone
      # can't fully lift the gate, but ar_clear_quota_stop_flag_if_reset
      # uses it to DOWNGRADE both -> weekly once the 5h window resets,
      # rather than leaving a stale "both" flag permanently stuck even
      # after Claude quota returns (the bug: a flag with no resets_at_epoch
      # at all is invisible to the clear check forever).
      ar_write_quota_stop_flag "both" "$USAGE_PCT" "none" "$FIVE_HOUR_RESETS_AT"
    fi
  else
    # --- Claude 5h over: fallback = agy ---
    if [ "$USAGE_PCT" -ge "$THRESHOLD" ] && ! gk_is_alerted claude_5h; then
      echo "$(date) - ALERT: Claude 5h ${USAGE_PCT}%" >> "$BUDGET_LOG"
      gk_alert_orchestra "quota-5h" "quota Claude 5h at ${USAGE_PCT}% — follow AGENTS.md failsafe. Fallback available: agy."
      gk_say "Claude quota threshold"
      gk_mark_alerted claude_5h
      ar_mark_pending "$NOTIFY_SESSION:0.0"
      # #10: 5h is the one pool with a resets_at we can epoch-compare, so
      # this flag auto-clears on the real window reset (see
      # ar_clear_quota_stop_flag_if_reset, called below every iteration).
      ar_write_quota_stop_flag "5h" "$USAGE_PCT" "agy" "$FIVE_HOUR_RESETS_AT"
    fi
    # --- agy over: fallback = Claude (or throttle) ---
    if [ "$AGY_PCT" -ge "$THRESHOLD" ] && ! gk_is_alerted agy; then
      echo "$(date) - ALERT: agy ${AGY_PCT}%" >> "$BUDGET_LOG"
      gk_alert_orchestra "quota-agy" "quota agy at ${AGY_PCT}% — follow AGENTS.md failsafe. Fallback: hand work back to Claude Code."
      gk_say "Antigravity quota threshold"
      gk_mark_alerted agy
    fi
  fi

  # --- Claude weekly (seven_day) over: same failsafe, no separate fallback pool ---
  if [ "$WEEKLY_PCT" -ge "$THRESHOLD" ] && ! gk_is_alerted claude_weekly; then
    echo "$(date) - ALERT: Claude weekly ${WEEKLY_PCT}%" >> "$BUDGET_LOG"
    gk_alert_orchestra "quota-weekly" "quota Claude WEEKLY at ${WEEKLY_PCT}% — follow AGENTS.md failsafe (pool: weekly)."
    gk_say "Claude weekly quota threshold"
    gk_mark_alerted claude_weekly
    # #10: weekly never auto-clears (same "always stop for Ahmad, no
    # exceptions" policy as auto-resume.sh's own header comment) -- stays
    # gated until the manual clear (lib/quota-stop-clear.sh).
    ar_write_quota_stop_flag "weekly" "$WEEKLY_PCT" "none"
  fi

  # T20: advance every currently-tracked pane's auto-resume state machine.
  # Deliberately unconditional (not gated on USAGE_PCT still being over
  # threshold) -- the reset we're watching for only shows up AFTER usage
  # has already dropped back down, and weekly (seven_day) never reaches
  # this function at all since nothing above ever calls ar_mark_pending
  # for it.
  ar_poll_all "$FIVE_HOUR_RESETS_AT" "$USAGE_PCT"

  # #10: lift the quota-stop PreToolUse gate on a genuine time-based window
  # reset -- unconditional every iteration, independent of whether any pane
  # is currently tracked (the #11<->#10 seam). WEEKLY_PCT is passed so a
  # "both" -> "weekly" downgrade (finding 5) shows the CURRENT weekly%,
  # not whatever stale 5h% the "both" flag happened to be written with.
  ar_clear_quota_stop_flag_if_reset "$WEEKLY_PCT"

  # --- per-pool re-arm after reset (persisted, survives a restart) ---
  [ "$USAGE_PCT" -lt 50 ] && gk_clear_alerted claude_5h
  [ "$WEEKLY_PCT" -lt 50 ] && gk_clear_alerted claude_weekly
  [ "$AGY_PCT" -lt 50 ] && gk_clear_alerted agy

  # T19 liveness: heartbeat every iteration so gatekeeper-liveness.sh (a
  # separate process, so a gatekeeper crash can't also silence its own
  # watchdog) can detect a dead/hung gatekeeper and warn pane 0.
  #
  # Write-to-temp-then-mv (Ahmad fold-in, caught LIVE: a false "no
  # heartbeat" death alert fired while gatekeeper was alive). A direct
  # `date +%s > "$HEARTBEAT"` truncates the file before writing the new
  # value -- a reader (gatekeeper-liveness.sh, or this file's own render
  # below) that opens the file in that exact window sees EMPTY content,
  # not a missing file, so an `[ -f ... ]` existence check doesn't catch
  # it. `mv` is only atomic WITHIN the same filesystem -- a bare
  # `mktemp` defaults to $TMPDIR/tmp, which can be a different mount than
  # $HEARTBEAT's own directory, silently downgrading `mv` to a
  # non-atomic copy+delete. `mktemp "${HEARTBEAT}.XXXXXX"` creates the
  # temp file IN THE SAME DIRECTORY, guaranteeing same-filesystem `mv`.
  _hb_tmp="$(mktemp "${HEARTBEAT}.XXXXXX")"
  date +%s > "$_hb_tmp" && mv "$_hb_tmp" "$HEARTBEAT"
  sleep "$CHECK_INTERVAL"
done
}

# Guard so this file can be sourced (for get_claude_token/fetch_claude_usage
# in tests) without running the infinite loop as a side effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  gatekeeper_main
fi
