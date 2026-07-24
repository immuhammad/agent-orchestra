#!/bin/bash
# .harness/gatekeeper-liveness.sh — warns pane 0 if gatekeeper.sh's heartbeat
# goes stale (the 2026-07-04 audit found gatekeeper.sh dead at 78%
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
# issue #155: a wall-clock GAP between this watchdog's own ticks (system
# suspend, or the room/process itself just (re)started after downtime)
# makes a HEALTHY gatekeeper.sh look dead -- this watchdog's own `sleep
# $CHECK_INTERVAL` pauses across the exact same gap (confirmed live twice:
# a suspend-during-sleep, and a fresh process's first tick reading a
# pre-shutdown heartbeat), so the tick immediately following a detected gap
# can't trust its own staleness reading. GAP_THRESHOLD is how large a jump
# between ticks counts as "a gap happened" (2x CHECK_INTERVAL comfortably
# clears ordinary scheduling jitter while catching a real multi-minute
# freeze); GAP_GRACE is how long to withhold judgment afterward -- sized to
# gatekeeper.sh's OWN loop period ($GATEKEEPER_INTERVAL, same env var it
# reads, default 300s) because that's how long its own paused sleep may
# still need to resume and write a fresh heartbeat post-gap (observed: an
# 11-minute suspend needed ~5 more minutes post-wake before gatekeeper.sh's
# heartbeat caught up). A tick with NO detected gap still alerts on the
# very first stale reading, unchanged from before -- this only defers
# judgment on the specific tick(s) a gap actually explains, so a genuinely
# dead gatekeeper.sh (no suspend, no restart involved) is still caught
# promptly.
GAP_THRESHOLD="${GATEKEEPER_LIVENESS_GAP_THRESHOLD:-$((CHECK_INTERVAL * 2))}"
GAP_GRACE="${GATEKEEPER_LIVENESS_GAP_GRACE:-${GATEKEEPER_INTERVAL:-300}}"
# PREV_TICK_EPOCH empty -> "no prior tick in this process" -> the very
# first tick always counts as a gap (issue #155 incident 1: a fresh
# process/room-rebuild can't tell how long it was actually down before this
# tick, so its first reading alone is never trusted).
PREV_TICK_EPOCH=""
GAP_GRACE_UNTIL=""
# issue #19 follow-up: used to hardcode "harness:0.0" -- reuse
# $DISPATCH_SESSION (already derived above via dispatch.sh's own
# orc_session_name-based resolution, issue #18 item 7/#19) instead of
# re-deriving it, so this can't drift from dispatch.sh's own session
# targeting and two clone-per-project rooms never collide here either.
TARGET="${GATEKEEPER_LIVENESS_TARGET:-$DISPATCH_SESSION:0.0}"
ALERTED=false

# #11 secondary gap: which pane(s) to watch for "CLI alive but
# rate-limit-stuck", and the two independent signals that detect it (see
# gkl_check_rate_limit_stuck below). Builder (pane 0.1, per
# lib/dispatch.sh's pane_for_agent) is the pane the confirmed overnight
# incident actually happened to; space-separated so more panes can be added
# without a code change. HANDOFF_FILE is the same handoff.md
# hooks/rate-limit-handoff.sh writes its "## RATE-LIMITED" section into.
RATELIMIT_WATCH_PANES="${GATEKEEPER_LIVENESS_RATELIMIT_PANES:-$DISPATCH_SESSION:0.1}"
HANDOFF_FILE="${GATEKEEPER_LIVENESS_HANDOFF_FILE:-$(_gkl_canon_dir)/handoff.md}"
# Best-effort/tunable: the actual raw text a rate-limited Claude Code CLI
# leaves in scrollback hasn't been captured verbatim in this codebase yet
# (FLAG: agy/Ahmad should confirm this against a real occurrence and tune
# it -- the handoff.md marker below is the reliable signal, this is the
# backup for a StopFailure that never got that far). Deliberately excludes
# AR_PARK_MARKER's own wording so this never double-fires on an ordinary,
# expected "parked at the failsafe question" pane -- that case is already
# fully handled by auto-resume.sh.
#
# issue #41: a bare `[Rr]ate.?limit` alternative here matched Anthropic's
# startup MOTD ("...keeping Claude Code's weekly rate limits 50% higher,
# through July 19") on every freshly-started pane, firing a false
# rate-limit-stuck alert on a completely idle, healthy session. Promotional
# copy talks ABOUT rate limits; a real banner reports a limit actually being
# HIT ("5-hour limit reached" / "weekly limit reached") -- narrowed to that
# shape so vendor-controlled marketing text can't trigger this again.
RATELIMIT_BANNER_RE="${GATEKEEPER_LIVENESS_RATELIMIT_RE:-(5-hour|weekly) limit reached|usage limit reached|try again (later|in)}"
# issue #41 layer 1b: the MOTD sits at the TOP of a fresh pane's visible
# screen; a real banner (if the CLI is actually stuck on one) sits at the
# BOTTOM, right above the parked prompt. send_meaningful_tail's default of
# 20 non-blank lines is wide enough to still catch the MOTD on a pane with
# little else rendered yet -- narrowed so scanning is anchored at the tail,
# not "anywhere visible".
#
# review round 2 (agy, PR #101 finding 1): an initial 5-line window was too
# narrow -- a real banner can sit behind a few CLI hint lines (e.g. a retry
# prompt), pushing it past the window and producing a FALSE NEGATIVE on a
# genuinely stuck pane, which is worse than the false positive this issue
# started from. Widened to 10: still meaningfully bounded vs. the old
# unbounded-in-practice 20-on-an-~18-row-pane default (#87) -- a banner
# quoted deep in mid-scrollback conversation still falls outside it -- while
# covering banner + several hint lines + the prompt. The usage-corroboration
# layer below is the real backstop against a wide window catching stray
# text; this number doesn't have to be exact.
RATELIMIT_TAIL_LINES="${GATEKEEPER_LIVENESS_RATELIMIT_TAIL_LINES:-10}"
# issue #41 layer 2: prefer real state over scraping. GATEKEEPER_SH is
# sourced in a SEPARATE subshell (gkl_usage_pcts below), never inline into
# this process -- gatekeeper.sh defines its own CHECK_INTERVAL (the
# unrelated 300s quota-poll cadence) which would silently clobber this
# file's own CHECK_INTERVAL (the 60s heartbeat-poll cadence) if sourced
# directly here.
GATEKEEPER_SH="${GATEKEEPER_LIVENESS_GATEKEEPER_SCRIPT:-$DIR/gatekeeper.sh}"
# A rate-limit-stuck conclusion from pane text alone is unreliable (that's
# the MOTD bug above); require real usage to actually be near the cap
# before trusting it -- "a pane at 5h:0% cannot be rate-limited whatever its
# text says". Same THRESHOLD gatekeeper.sh itself alerts at (80).
RATELIMIT_USAGE_MIN="${GATEKEEPER_LIVENESS_RATELIMIT_USAGE_MIN:-80}"
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

# gkl_usage_pcts -- issue #41 corroboration signal. Runs
# get_claude_token/fetch_claude_usage (defined in gatekeeper.sh) in a
# subprocess via `bash -c "source ...; ..."`, same idiom this test suite
# already uses elsewhere to source gatekeeper.sh without its top-level vars
# leaking into the caller. Prints "<five_hour_pct> <seven_day_pct>" (either
# half empty on a partial JSON shape); prints nothing at all on total
# fetch failure (no token, no network, malformed JSON, gatekeeper.sh
# missing). One fetch covers both -- callers must treat an empty half as
# UNKNOWN for that quota class, not 0%.
#
# review round 2 (agy, PR #101 finding 2): checking five_hour alone wrongly
# suppressed a genuinely stuck pane hitting the WEEKLY (seven_day) limit --
# that pane's five_hour reading can easily be low (e.g. 5%) even though it
# is actually rate-limited. Both quota classes must be confirmed low before
# treating a banner match as a false positive.
gkl_usage_pcts() {
  [ -f "$GATEKEEPER_SH" ] || return 1
  # review round 2 (claude cross-check, PR #101 finding B): gatekeeper.sh
  # registers `trap gk_log_exit EXIT` unconditionally at source time, not
  # gated behind its own BASH_SOURCE guard -- sourcing it here without
  # disarming that trap fires it on THIS subshell's own exit, appending a
  # phantom "GATEKEEPER EXIT: exit code 0" line to the REAL, tracked
  # budget.log on every single corroboration check. `trap - EXIT`
  # immediately after sourcing clears it before it can fire.
  bash -c "source '$GATEKEEPER_SH' 2>/dev/null; trap - EXIT; json=\$(fetch_claude_usage 2>/dev/null) || exit 1; fh=\$(echo \"\$json\" | jq -r '.five_hour.utilization // empty' 2>/dev/null | cut -d. -f1); sd=\$(echo \"\$json\" | jq -r '.seven_day.utilization // empty' 2>/dev/null | cut -d. -f1); echo \"\$fh \$sd\""
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
# convention (durable .msg + nudge-if-idle, not raw keystrokes).
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
    tail_text="$(send_meaningful_tail "$pane" "$RATELIMIT_TAIL_LINES" 2>/dev/null)"
    # review round 2 (claude cross-check, PR #101 finding A): a
    # case-sensitive match missed real renderings like "Weekly limit
    # reached" or "Try again in 2 hours." (capitalized mid-sentence/at a
    # sentence start) -- -i so the specific phrase shape still has to
    # match, just regardless of case.
    if [ -n "$tail_text" ] && echo "$tail_text" | grep -Eiq "$RATELIMIT_BANNER_RE" \
      && ! echo "$tail_text" | tr -d '\n' | grep -Eq 'Quota .*Options: \(a\).*Pick one\.'; then
      if ! gkl_pane_in_set "$RATELIMIT_ALERTED_PANES" "$pane"; then
        # issue #41 layer 2: only SUPPRESS on positive contrary evidence --
        # BOTH quota classes confirmed low. An unfetchable/unknown reading
        # (either half) is not evidence against a real banner, so this errs
        # toward alerting on doubt, same bias as pane_is_idle elsewhere in
        # this harness (a missed alert is worse than one extra false one).
        local usage_pair five_pct seven_pct suppress
        usage_pair="$(gkl_usage_pcts)"
        five_pct="${usage_pair%% *}"
        seven_pct="${usage_pair#* }"
        suppress=false
        if [ -n "$five_pct" ] && [ -n "$seven_pct" ] \
          && [ "$five_pct" -lt "$RATELIMIT_USAGE_MIN" ] 2>/dev/null \
          && [ "$seven_pct" -lt "$RATELIMIT_USAGE_MIN" ] 2>/dev/null; then
          suppress=true
        fi
        if [ "$suppress" = true ]; then
          echo "$(date) - DEBUG: $pane matched the rate-limit banner shape but real usage is only 5h=${five_pct}% weekly=${seven_pct}% (both < ${RATELIMIT_USAGE_MIN}%) -- treating as a false positive, not alerting" >> "$LOG"
        else
          RATELIMIT_ALERTED_PANES="${RATELIMIT_ALERTED_PANES}${pane} "
          echo "$(date) - ALERT: rate-limit-stuck signal (pane tail banner) on $pane (5h=${five_pct:-unknown}% weekly=${seven_pct:-unknown}%)" >> "$LOG"
          dispatch_main assign orchestra "rate-limit-stuck" "gatekeeper-liveness: $pane's scrollback matches a rate-limit banner but never reached the normal parked failsafe question -- CLI alive but stuck, pane-liveness would otherwise miss this. Check and resume/park it per AGENTS.md's Quota Failsafe." >/dev/null 2>&1
        fi
      fi
    else
      RATELIMIT_ALERTED_PANES="${RATELIMIT_ALERTED_PANES/ $pane / }"
    fi
  done
}

# gkl_check_heartbeat_tick <now> -- one tick of the heartbeat-staleness
# check, factored out of liveness_main's loop (issue #155) so it's callable
# standalone (tests pass an explicit epoch instead of needing real sleeps).
# Mutates the global PREV_TICK_EPOCH/GAP_GRACE_UNTIL/ALERTED state.
gkl_check_heartbeat_tick() {
  local now="$1" last_raw="" age is_gap=false

  # issue #155: detect a wall-clock GAP since this watchdog's own previous
  # tick -- either this is the process's first tick ever (PREV_TICK_EPOCH
  # unset: a fresh start can't know how long it was actually down before
  # now, incident 1), or the elapsed time since the last tick vastly
  # exceeds CHECK_INTERVAL (this process itself was frozen -- e.g. system
  # suspend paused its own `sleep`, incident 2). Either way, THIS tick's
  # staleness reading can't be trusted alone.
  if [ -z "$PREV_TICK_EPOCH" ]; then
    is_gap=true
  elif [ "$((now - PREV_TICK_EPOCH))" -ge "$GAP_THRESHOLD" ]; then
    is_gap=true
  fi
  PREV_TICK_EPOCH="$now"

  if [ "$is_gap" = true ]; then
    GAP_GRACE_UNTIL=$((now + GAP_GRACE))
    echo "$(date) - DEBUG: tick gap detected (>= ${GAP_THRESHOLD}s since the previous tick, or the watchdog's first tick) -- granting ${GAP_GRACE}s staleness grace before trusting this reading" >> "$LOG"
  fi

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
  [ -f "$HEARTBEAT" ] && last_raw="$(cat "$HEARTBEAT" 2>/dev/null)"
  case "$last_raw" in
    ''|*[!0-9]*)
      echo "$(date) - DEBUG: heartbeat file empty/non-numeric this tick ('${last_raw}') -- skipping staleness check rather than treating it as epoch 0" >> "$LOG"
      return
      ;;
  esac

  age=$((now - last_raw))
  if [ "$age" -lt "$STALE_AFTER" ]; then
    ALERTED=false
    GAP_GRACE_UNTIL=""
    return
  fi

  # issue #155: stale, but if a gap was recently detected, withhold
  # judgment until GAP_GRACE has actually elapsed -- gatekeeper.sh's own
  # paused sleep needs roughly its own loop period to catch back up (both
  # confirmed incidents self-healed inside this window).
  if [ -n "$GAP_GRACE_UNTIL" ] && [ "$now" -lt "$GAP_GRACE_UNTIL" ]; then
    echo "$(date) - DEBUG: heartbeat stale (${age}s) but still within post-gap grace -- deferring alert" >> "$LOG"
    return
  fi

  if [ "$ALERTED" = false ]; then
    echo "$(date) - ALERT: gatekeeper heartbeat stale (${age}s, expected every ~${STALE_AFTER}s)" >> "$LOG"
    # issue #24: this used to be a raw one-shot `send-keys` with text
    # and C-m in the SAME burst -- exactly the pattern send-lib.sh's
    # send_submit() exists to prevent (Claude Code's TUI drops an
    # Enter that arrives in the same burst as pasted text), and it
    # was also keystroke-only with no durable copy, so a busy or dead
    # pane lost the alert entirely (the #105 lesson, missed on this
    # one path). dispatch_main assign orchestra (already used above
    # in gkl_check_rate_limit_stuck) gives both for free: a durable
    # .msg is the guarantee, the nudge is only the doorbell.
    dispatch_main assign orchestra "gatekeeper-stale-heartbeat" "gatekeeper watchdog: no heartbeat for ${age}s -- gatekeeper.sh may have died. Check pane 4." >/dev/null 2>&1
    ALERTED=true
  fi
}

liveness_main() {
echo "Gatekeeper liveness watchdog active (stale after ${STALE_AFTER}s, target $TARGET)"
while true; do
  now=$(date +%s)
  gkl_check_heartbeat_tick "$now"
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
