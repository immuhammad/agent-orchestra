#!/bin/bash
# .harness/gatekeeper-liveness.sh — warns pane 0 if gatekeeper.sh's heartbeat
# goes stale (T19; the 2026-07-04 audit found gatekeeper.sh dead at 78%
# usage with nobody noticing). Runs as its own background process, started
# by harness-up.sh independently of gatekeeper.sh -- if gatekeeper.sh
# crashes or hangs, this watchdog is a separate process and keeps running
# to report it, rather than dying alongside it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# #11 secondary gap (invisible death): a rate-limit-stuck Claude CLI never
# drops to a shell, so nothing else in this file's own heartbeat check
# would ever notice it -- gatekeeper.sh is alive and well, it's one
# Builder-type pane that's silently wedged. Detecting that needs a pane
# tail read (send-lib.sh) and a durable FLAG to orchestra's inbox
# (dispatch.sh), neither of which this watchdog needed before.
# shellcheck source=./send-lib.sh
source "$DIR/send-lib.sh"
# shellcheck source=./dispatch.sh
source "$DIR/dispatch.sh"
# issue #116: HEARTBEAT/LOG must resolve to the same place gatekeeper.sh
# itself writes to (the caller's project root), not this script's own
# directory -- nohup preserves cwd from `orc up`, so $PWD is still the
# project root at the time this was launched. Resolved lazily/memoized,
# same as gatekeeper.sh, so a caller pinning both *_FILE vars explicitly
# never needs orchestrator.yaml/ORC_PROJECT_ROOT to exist.
_gkl_canon_dir() {
  if [ -z "${_GKL_CANON_DIR_CACHE:-}" ]; then
    if [ -n "${GATEKEEPER_CANON_DIR:-}" ]; then
      _GKL_CANON_DIR_CACHE="$GATEKEEPER_CANON_DIR"
    elif ! _GKL_CANON_DIR_CACHE="$(harness_canonical_dir "$PWD")"; then
      echo "gatekeeper-liveness.sh: could not resolve project root (see error above); set ORC_PROJECT_ROOT, run from inside a project with orchestrator.yaml, or pin GATEKEEPER_HEARTBEAT_FILE/GATEKEEPER_LIVENESS_LOG explicitly" >&2
      exit 1
    fi
  fi
  echo "$_GKL_CANON_DIR_CACHE"
}
HEARTBEAT="${GATEKEEPER_HEARTBEAT_FILE:-$(_gkl_canon_dir)/gatekeeper.heartbeat}"
LOG="${GATEKEEPER_LIVENESS_LOG:-$(_gkl_canon_dir)/budget.log}"
CHECK_INTERVAL="${GATEKEEPER_LIVENESS_INTERVAL:-60}"
# gatekeeper.sh's own loop period is $GATEKEEPER_INTERVAL (default 300s);
# 2x that plus slack tolerates one slow iteration (e.g. a slow curl to the
# usage endpoint) without a false-positive warning.
STALE_AFTER="${GATEKEEPER_LIVENESS_STALE_AFTER:-660}"
TARGET="${GATEKEEPER_LIVENESS_TARGET:-harness:0.0}"
ALERTED=false

# #11 secondary gap: which pane(s) to watch for "CLI alive but
# rate-limit-stuck", and the two independent signals that detect it (see
# gkl_check_rate_limit_stuck below). Builder (pane 0.1, per
# lib/dispatch.sh's pane_for_agent) is the pane the confirmed overnight
# incident actually happened to; space-separated so more panes can be added
# without a code change. HANDOFF_FILE is the same handoff.md
# hooks/rate-limit-handoff.sh writes its "## RATE-LIMITED" section into.
RATELIMIT_WATCH_PANES="${GATEKEEPER_LIVENESS_RATELIMIT_PANES:-harness:0.1}"
HANDOFF_FILE="${GATEKEEPER_LIVENESS_HANDOFF_FILE:-$(_gkl_canon_dir)/handoff.md}"
# Best-effort/tunable: the actual raw text a rate-limited Claude Code CLI
# leaves in scrollback hasn't been captured verbatim in this codebase yet
# (FLAG: agy/Ahmad should confirm this against a real occurrence and tune
# it -- the handoff.md marker below is the reliable signal, this is the
# backup for a StopFailure that never got that far). Deliberately excludes
# AR_PARK_MARKER's own wording so this never double-fires on an ordinary,
# expected "parked at the failsafe question" pane -- that case is already
# fully handled by auto-resume.sh.
RATELIMIT_BANNER_RE="${GATEKEEPER_LIVENESS_RATELIMIT_RE:-[Rr]ate.?limit|usage limit reached|try again (later|in)}"
# Own polling cadence, deliberately DECOUPLED from CHECK_INTERVAL: this
# check does a real tmux capture-pane per watched pane, meaningfully
# heavier than the heartbeat file read the main loop does every tick.
# CHECK_INTERVAL gets tuned down to ~1s in tests exercising the tight
# heartbeat-staleness timing budget -- running this extra tmux work on
# every one of those ticks too measurably ate into that budget and made an
# unrelated test flaky. Defaults to the SAME 60s as CHECK_INTERVAL's own
# default so production behavior is unchanged either way.
RATELIMIT_CHECK_INTERVAL="${GATEKEEPER_LIVENESS_RATELIMIT_INTERVAL:-60}"
RATELIMIT_LAST_CHECK_EPOCH=0
# Dedup state, in-memory only (matches this file's existing $ALERTED
# pattern -- a liveness-process restart re-checking once is an acceptable
# reset, same tradeoff already made for the heartbeat alert above).
# RATELIMIT_ALERTED_PANES is a space-padded string used as a poor-man's
# set (via gkl_pane_in_set below), NOT a `declare -A` associative array --
# this codebase's own cross-platform date helper exists because darwin
# ships bash 3.2 by default, which doesn't have associative arrays at all
# (silently no-ops the `declare -A` and corrupts everything downstream
# that indexes into it -- caught live while testing this very change).
RATELIMIT_LAST_HANDOFF_LINE=""
RATELIMIT_ALERTED_PANES=" "

# gkl_pane_in_set <space-padded set string> <pane> -- bash-3.2-safe
# membership check (no associative arrays).
gkl_pane_in_set() {
  case "$1" in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# gkl_check_rate_limit_stuck -- #11 secondary gap. Two INDEPENDENT signals,
# either alone is sufficient (per Gate-1 plan):
#   1. handoff.md gets a fresh "## RATE-LIMITED" section (written by
#      hooks/rate-limit-handoff.sh on a real StopFailure/rate_limit hook
#      firing) -- the reliable, confirmed signal. Dedup by the exact header
#      line, which embeds a timestamp+session id, so it naturally changes
#      on every new occurrence and never re-fires on the same one.
#   2. a watched pane's tail matches RATELIMIT_BANNER_RE -- a heuristic
#      backup for a stuck CLI that never got as far as the StopFailure
#      hook. Explicitly does NOT match if the pane shows the ordinary
#      failsafe-question wording (auto-resume.sh already owns that case).
# Either firing writes ONE durable FLAG to orchestra's inbox (never a
# silent drop -- that invisibility is exactly the bug being fixed) via
# dispatch_main assign, matching gatekeeper.sh's own gk_alert_orchestra
# convention (issue #105: durable .msg + nudge-if-idle, not raw keystrokes).
gkl_check_rate_limit_stuck() {
  if [ -f "$HANDOFF_FILE" ]; then
    local marker_line
    marker_line="$(grep '^## RATE-LIMITED' "$HANDOFF_FILE" 2>/dev/null | tail -1)"
    if [ -n "$marker_line" ] && [ "$marker_line" != "$RATELIMIT_LAST_HANDOFF_LINE" ]; then
      RATELIMIT_LAST_HANDOFF_LINE="$marker_line"
      echo "$(date) - ALERT: rate-limit-stuck signal (handoff.md marker): $marker_line" >> "$LOG"
      dispatch_main assign orchestra "rate-limit-stuck" "gatekeeper-liveness: handoff.md shows a fresh '$marker_line' -- a session may have died on a rate limit before parking. Check the affected pane and resume/park it per AGENTS.md's Quota Failsafe." >/dev/null 2>&1
    fi
  fi

  local pane
  for pane in $RATELIMIT_WATCH_PANES; do
    local tail_text
    tail_text="$(send_meaningful_tail "$pane" 2>/dev/null)"
    if [ -n "$tail_text" ] && echo "$tail_text" | grep -Eq "$RATELIMIT_BANNER_RE" \
      && ! echo "$tail_text" | tr -d '\n' | grep -Eq 'Quota .*Options: \(a\).*Pick one\.'; then
      if ! gkl_pane_in_set "$RATELIMIT_ALERTED_PANES" "$pane"; then
        RATELIMIT_ALERTED_PANES="${RATELIMIT_ALERTED_PANES}${pane} "
        echo "$(date) - ALERT: rate-limit-stuck signal (pane tail banner) on $pane" >> "$LOG"
        dispatch_main assign orchestra "rate-limit-stuck" "gatekeeper-liveness: $pane's scrollback matches a rate-limit banner but never reached the normal parked failsafe question -- CLI alive but stuck, pane-liveness would otherwise miss this. Check and resume/park it per AGENTS.md's Quota Failsafe." >/dev/null 2>&1
      fi
    else
      RATELIMIT_ALERTED_PANES="${RATELIMIT_ALERTED_PANES/ $pane / }"
    fi
  done
}

liveness_main() {
echo "Gatekeeper liveness watchdog active (stale after ${STALE_AFTER}s, target $TARGET)"
while true; do
  now=$(date +%s)
  # Ahmad fold-in (caught LIVE: a false "no heartbeat for 1783784949s"
  # death alert fired while gatekeeper was alive and well). gatekeeper.sh
  # now writes the heartbeat atomically (temp+mv), but this reader must
  # ALSO guard against the pre-existing race independently -- a `cat` of
  # a file mid-truncate-then-write, or any other transient empty/corrupt
  # read, returns an EMPTY string with a SUCCESSFUL exit status, so the
  # old `|| echo 0` fallback (which only fires on a `cat` FAILURE) never
  # caught it: `last=""`, and `$((now - last))` treats "" as 0 in bash
  # arithmetic, making age ~= now (~1.78 billion seconds) -- always past
  # any real STALE_AFTER. Validate the read is actually numeric; if not,
  # skip this tick's staleness check entirely (no age computed, no
  # alert, no state change) rather than guessing.
  last_raw=""
  [ -f "$HEARTBEAT" ] && last_raw="$(cat "$HEARTBEAT" 2>/dev/null)"
  case "$last_raw" in
    ''|*[!0-9]*)
      echo "$(date) - DEBUG: heartbeat file empty/non-numeric this tick ('${last_raw}') -- skipping staleness check rather than treating it as epoch 0" >> "$LOG"
      ;;
    *)
      age=$((now - last_raw))
      if [ "$age" -ge "$STALE_AFTER" ]; then
        if [ "$ALERTED" = false ]; then
          echo "$(date) - ALERT: gatekeeper heartbeat stale (${age}s, expected every ~${STALE_AFTER}s)" >> "$LOG"
          tmux send-keys -t "$TARGET" "gatekeeper watchdog: no heartbeat for ${age}s -- gatekeeper.sh may have died. Check pane 4." C-m 2>/dev/null
          ALERTED=true
        fi
      else
        ALERTED=false
      fi
      ;;
  esac
  if [ "$((now - RATELIMIT_LAST_CHECK_EPOCH))" -ge "$RATELIMIT_CHECK_INTERVAL" ]; then
    gkl_check_rate_limit_stuck
    RATELIMIT_LAST_CHECK_EPOCH="$now"
  fi
  sleep "$CHECK_INTERVAL"
done
}

# Guard so this file can be sourced (for tests) without running the
# infinite loop as a side effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  liveness_main
fi
