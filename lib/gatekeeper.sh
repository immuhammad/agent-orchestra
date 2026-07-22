#!/bin/bash
# .harness/gatekeeper.sh — alert-only quota watchdog. Never kills agents.
set -uo pipefail
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

# Diagnostics for WHY gatekeeper stopped, not just
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
# sensor moved off statusline (see fetch_claude_usage below).
AGY_STATUSLINE="$HOME/.gemini/antigravity-cli/scratch/agy-statusline.json"

# Budgeted 5h-window rate-limit auto-resume. See auto-resume.sh for the
# full state machine and policy (weekly never auto-resumes, max N/day,
# "only unblock what you parked"). auto-resume.sh resolves its own root
# lazily the same way (same $PWD), so this can't diverge from the
# resolution above without also needing to be forced.
source "$DIR/auto-resume.sh"

# Shared color/clear-screen helpers for the dashboard
# board below. Colors and clearing auto-disable outside a tty, so this
# never changes what a redirected/piped invocation (tests, logs) prints.
source "$DIR/tui-lib.sh"
# issue #60 task D: room-branch-lib.sh (task B) backs the ROOM dashboard
# section + once-per-crossing alert below.
source "$DIR/room-branch-lib.sh"
GATEKEEPER_STALE_AFTER="${GATEKEEPER_LIVENESS_STALE_AFTER:-660}"

# Alerts route through dispatch.sh now -- a durable
# inbox .msg to Orchestra (pane 0) plus a nudge, never a raw keystroke burst
# into Builder's (or anyone else's) live input. Orchestra owns parking/
# relaying to Builder per AGENTS.md's failsafe wording; gatekeeper itself
# no longer types the failsafe text into anyone's pane directly.
source "$DIR/dispatch.sh"

# Which tmux session gk_alert_orchestra's nudge targets. Overridable so
# tests can point every alert at a throwaway session instead of the real
# session -- a test that types into a live agent pane at real quota
# thresholds reads as a genuine user prompt, which is a safety bug, not just
# noise (confirmed live during testing).
#
# issue #19 follow-up: used to hardcode "harness" -- reuse $DISPATCH_SESSION
# (already derived above via dispatch.sh's own orc_session_name-based
# resolution, issue #18 item 7/#19) instead of re-deriving it, so this can't
# drift from dispatch.sh's own session targeting and two clone-per-project
# rooms never collide here either.
NOTIFY_SESSION="${GATEKEEPER_NOTIFY_SESSION:-$DISPATCH_SESSION}"

# Alert state persisted to a JSON file (mirrors
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

# gk_check_room_branch -- issue #60 task D: sets the ROOM_BRANCH_STATE /
# ROOM_BRANCH_HEAD globals gatekeeper_render reads, and fires (at most) one
# durable orchestra alert per mismatch CROSSING -- reuses the same
# gk_is_alerted/gk_mark_alerted persisted-state pattern the quota pools
# already use, keyed "room_branch", so a gatekeeper restart mid-mismatch
# doesn't re-alert. Returning to the integration branch clears the
# alerted flag (re-arm) so the NEXT mismatch crossing alerts again,
# mirroring the quota pools' own re-arm-below-50% behavior.
# GATEKEEPER_ROOM_ROOT overrides the room root for tests; defaults to
# $PWD (gatekeeper.sh always runs from the project root, same assumption
# _gk_canon_dir already makes).
gk_check_room_branch() {
  local root="${GATEKEEPER_ROOM_ROOT:-$PWD}"
  ROOM_BRANCH_STATE="$(room_branch_state "$root")"
  ROOM_BRANCH_HEAD="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)"

  if [ "$ROOM_BRANCH_STATE" = "ok" ]; then
    gk_clear_alerted room_branch
  elif ! gk_is_alerted room_branch; then
    local reason=""
    reason="$(room_branch_override_reason "$root")"
    echo "$(date) - ALERT: room branch $ROOM_BRANCH_STATE (root: $root)" >> "$BUDGET_LOG"
    gk_alert_orchestra "room-branch" "room branch $ROOM_BRANCH_STATE (HEAD ${ROOM_BRANCH_HEAD:-?}, root: $root) -- see AGENTS.md's Dispatch Protocol.${reason:+ override reason on file: $reason}"
    gk_mark_alerted room_branch
  fi
}

# Voice is OFF by default -- every restart used to
# re-speak every already-alerted pool with no way to silence it ("keeps on
# saying 80% something" was Ahmad's literal complaint). `voice: on` in
# orchestrator.yaml opts in; persisted alert state (Task 1) means "once per
# crossing" is true across restarts too, not just within one process
# lifetime.
GK_VOICE="${GATEKEEPER_VOICE:-$(orc_get_scalar voice)}"
GK_VOICE="${GK_VOICE:-off}"

# issue #86: threshold now READ from orchestrator.yaml's
# budgets.<pool>.failsafe_pct (previously a hardcoded literal -- the yaml
# key was entirely decorative; Ahmad set it and it had zero effect). Falls
# back to 80 (the prior hardcoded value) so a room with no budgets: block
# behaves exactly as before -- but falls back LOUDLY, not silently, so a
# missing/mistyped key is visible rather than only discoverable by reading
# source. Claude and agy are independently configurable: the Claude
# branches (5h, weekly, and its half of "both") use CLAUDE_THRESHOLD; the
# agy branch (and its half of "both") uses AGY_THRESHOLD.
#
# Value computation only here -- no I/O. Sourcing this file (tests that
# just want e.g. NOTIFY_SESSION's default, or gatekeeper-liveness.sh's
# gkl_usage_pcts sourcing it in a subshell just for fetch_claude_usage)
# must stay side-effect-free, same lesson as issue #41 finding B's EXIT-
# trap leak -- the loud warning itself (to budget.log AND stderr) is
# deferred to gatekeeper_main below, which only actually runs when this
# script is EXECUTED, not merely sourced (see the BASH_SOURCE guard at the
# bottom of this file).
GK_THRESHOLD_DEFAULT=80
CLAUDE_THRESHOLD="$(orc_get_budget_pct claude)"
GK_CLAUDE_THRESHOLD_WARN=""
case "$CLAUDE_THRESHOLD" in
  ''|*[!0-9]*)
    GK_CLAUDE_THRESHOLD_WARN="budgets.claude.failsafe_pct missing/invalid in orchestrator.yaml -- defaulting to ${GK_THRESHOLD_DEFAULT}%"
    CLAUDE_THRESHOLD="$GK_THRESHOLD_DEFAULT"
    ;;
esac
AGY_THRESHOLD="$(orc_get_budget_pct agy)"
GK_AGY_THRESHOLD_WARN=""
case "$AGY_THRESHOLD" in
  ''|*[!0-9]*)
    GK_AGY_THRESHOLD_WARN="budgets.agy.failsafe_pct missing/invalid in orchestrator.yaml -- defaulting to ${GK_THRESHOLD_DEFAULT}%"
    AGY_THRESHOLD="$GK_THRESHOLD_DEFAULT"
    ;;
esac

gk_say() {
  [ "$GK_VOICE" = "on" ] && say "$1" >/dev/null 2>&1
  return 0
}

# gk_alert_orchestra <tag> <message> -- the ONLY alert
# delivery path now. Writes a durable inbox .msg to orchestra (via
# dispatch_main's `assign` verb -- write + nudge-if-idle, return
# immediately) instead of typing the alert text into any pane directly.
# Orchestra is the one agent trusted to read/relay this per AGENTS.md's
# Quota Failsafe wording; Builder (or anyone else) never gets alert
# keystrokes injected into their live input again.
gk_alert_orchestra() {
  dispatch_main assign orchestra "$1" "$2" >/dev/null
}

# Claude sensor now reads the OAuth usage endpoint directly instead of
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

# gatekeeper_render -- clears the pane and redraws the
# fixed board: QUOTA / HEARTBEAT / AUTO-RESUME / LAST ALERT. Display-layer
# only -- reads USAGE_PCT/WEEKLY_PCT/AGY_PCT/HEARTBEAT_AGE from the caller's
# scope, doesn't compute or persist anything itself. Every alert this loop
# fires still appends to $BUDGET_LOG unchanged; this function only
# controls what's currently ON SCREEN.
gatekeeper_render() {
  tui_clear
  echo "$(tui_bold "Gatekeeper") -- $(date '+%Y-%m-%d %H:%M:%S') (threshold claude ${CLAUDE_THRESHOLD}% / agy ${AGY_THRESHOLD}%)"
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
  echo ""
  echo "$(tui_section ROOM)"
  if [ "${ROOM_BRANCH_STATE:-}" = "ok" ]; then
    echo "  $(tui_green "${ROOM_BRANCH_HEAD:-?} (integration branch)")"
  else
    echo "  $(tui_red "${ROOM_BRANCH_STATE:-unknown} (HEAD ${ROOM_BRANCH_HEAD:-?})")"
  fi
}

gatekeeper_main() {
echo "Gatekeeper active (threshold claude ${CLAUDE_THRESHOLD}% / agy ${AGY_THRESHOLD}%)"
[ -n "$GK_CLAUDE_THRESHOLD_WARN" ] && echo "$(date) - WARN: $GK_CLAUDE_THRESHOLD_WARN" | tee -a "$BUDGET_LOG" >&2
[ -n "$GK_AGY_THRESHOLD_WARN" ] && echo "$(date) - WARN: $GK_AGY_THRESHOLD_WARN" | tee -a "$BUDGET_LOG" >&2
while true; do
  # VERIFY jq path: fetch_claude_usage | jq '.five_hour, .seven_day'
  CLAUDE_USAGE_JSON="$(fetch_claude_usage)"
  USAGE_PCT=$(echo "$CLAUDE_USAGE_JSON" | jq -r '.five_hour.utilization // 0' 2>/dev/null | cut -d. -f1)
  [ -z "$USAGE_PCT" ] && USAGE_PCT=0
  WEEKLY_PCT=$(echo "$CLAUDE_USAGE_JSON" | jq -r '.seven_day.utilization // 0' 2>/dev/null | cut -d. -f1)
  [ -z "$WEEKLY_PCT" ] && WEEKLY_PCT=0

  gk_check_room_branch
  # Only ever used for the 5h pool's auto-resume tracking -- never for
  # seven_day. Weekly crossings intentionally never touch auto-resume.sh.
  FIVE_HOUR_RESETS_AT=$(echo "$CLAUDE_USAGE_JSON" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)

  # --- agy 5h pools (VERIFIED keys: cat "$AGY_STATUSLINE" | jq '.quota') ---
  AGY_PCT=$(jq 'if type=="object" and .quota then
      [ (1-(.quota."gemini-5h".remaining_fraction // 1)),
        (1-(.quota."3p-5h".remaining_fraction // 1)) ] | max*100
    else 0 end' "$AGY_STATUSLINE" 2>/dev/null | cut -d. -f1)
  [ -z "$AGY_PCT" ] && AGY_PCT=0

  # Heartbeat age computed from the PREVIOUS tick's file, before it's
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
  if [ "$USAGE_PCT" -ge "$CLAUDE_THRESHOLD" ] && [ "$AGY_PCT" -ge "$AGY_THRESHOLD" ]; then
    if ! gk_is_alerted claude_5h || ! gk_is_alerted agy; then
      echo "$(date) - ALERT: BOTH pools over threshold (C:${USAGE_PCT}%>=${CLAUDE_THRESHOLD}% A:${AGY_PCT}%>=${AGY_THRESHOLD}%)" >> "$BUDGET_LOG"
      gk_alert_orchestra "quota-both" "quota critical — BOTH pools over threshold (claude>=${CLAUDE_THRESHOLD}% agy>=${AGY_THRESHOLD}%). Follow AGENTS.md failsafe: update handoff, then HOLD. No fallback available."
      gk_say "Both quota pools exhausted"
      gk_mark_alerted claude_5h; gk_mark_alerted agy
      ar_mark_pending "$NOTIFY_SESSION:0.0" "driver"
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
    if [ "$USAGE_PCT" -ge "$CLAUDE_THRESHOLD" ] && ! gk_is_alerted claude_5h; then
      echo "$(date) - ALERT: Claude 5h ${USAGE_PCT}%" >> "$BUDGET_LOG"
      gk_alert_orchestra "quota-5h" "quota Claude 5h at ${USAGE_PCT}% — follow AGENTS.md failsafe. Fallback available: agy."
      gk_say "Claude quota threshold"
      gk_mark_alerted claude_5h
      ar_mark_pending "$NOTIFY_SESSION:0.0" "driver"
      # #10: 5h is the one pool with a resets_at we can epoch-compare, so
      # this flag auto-clears on the real window reset (see
      # ar_clear_quota_stop_flag_if_reset, called below every iteration).
      ar_write_quota_stop_flag "5h" "$USAGE_PCT" "agy" "$FIVE_HOUR_RESETS_AT"
    fi
    # --- agy over: fallback = Claude (or throttle) ---
    if [ "$AGY_PCT" -ge "$AGY_THRESHOLD" ] && ! gk_is_alerted agy; then
      echo "$(date) - ALERT: agy ${AGY_PCT}%" >> "$BUDGET_LOG"
      gk_alert_orchestra "quota-agy" "quota agy at ${AGY_PCT}% — follow AGENTS.md failsafe. Fallback: hand work back to Claude Code."
      gk_say "Antigravity quota threshold"
      gk_mark_alerted agy
    fi
  fi

  # --- Claude weekly (seven_day) over: same failsafe, no separate fallback pool ---
  if [ "$WEEKLY_PCT" -ge "$CLAUDE_THRESHOLD" ] && ! gk_is_alerted claude_weekly; then
    echo "$(date) - ALERT: Claude weekly ${WEEKLY_PCT}%" >> "$BUDGET_LOG"
    gk_alert_orchestra "quota-weekly" "quota Claude WEEKLY at ${WEEKLY_PCT}% — follow AGENTS.md failsafe (pool: weekly)."
    gk_say "Claude weekly quota threshold"
    gk_mark_alerted claude_weekly
    # #10: weekly never auto-clears (same "always stop for Ahmad, no
    # exceptions" policy as auto-resume.sh's own header comment) -- stays
    # gated until the manual clear (lib/quota-stop-clear.sh).
    ar_write_quota_stop_flag "weekly" "$WEEKLY_PCT" "none"
  fi

  # Advance every currently-tracked pane's auto-resume state machine.
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

  # Liveness: heartbeat every iteration so gatekeeper-liveness.sh (a
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
