#!/bin/bash
# lib/broker.sh — issue #125: the delivery layer of the file-inbox
# dispatch. Senders only ever write durable .msg files; THIS is the one
# place (besides dispatch.sh's single at-send wake) that ever types into
# another agent's pane, and every wake it sends is VERIFIED by the .ack
# appearing within a deadline -- bounded retries, then a durable FLAG
# escalation. No screen-scraping in the decision path: the receiver's own
# hook-written state (busy|idle|failsafe, lib/pane-state-lib.sh) gates
# delivery. Also owns inbox hygiene: acked pairs move to
# inbox/<agent>/archive/, archives are pruned past a retention window,
# and events.log is rotated.
#
# Sourced by watch.sh AFTER dispatch.sh (needs CANON_DIR, pane_for_agent,
# pane_state_read, pane_is_idle, send_submit, dispatch_main, orc-config's
# orc_get_nested) and after we_log_event is defined.
set -uo pipefail

# Fallback so this file can be sourced standalone in tests before/without
# watch.sh's we_log_event; a later real definition overrides it.
if ! declare -F we_log_event >/dev/null 2>&1; then
  we_log_event() { :; }
fi

BROKER_STATE_DIR="${BROKER_STATE_DIR:-$CANON_DIR/state/broker}"
BROKER_PENDING_LIST="${BROKER_PENDING_LIST:-$BROKER_STATE_DIR/pending.list}"
# Overridable inbox root so tests never iterate (or archive!) the live
# room's real inboxes.
BROKER_INBOX_ROOT="${BROKER_INBOX_ROOT:-$CANON_DIR/inbox}"

# Config: orchestrator.yaml `dispatch:` block (issue #86 precedent: every
# key ships with this consumer). Env overrides win for tests.
BROKER_WAKE_GRACE_S="${BROKER_WAKE_GRACE_S:-$(orc_get_nested dispatch wake_grace_s)}"
BROKER_WAKE_GRACE_S="${BROKER_WAKE_GRACE_S:-10}"
BROKER_ACK_DEADLINE_S="${BROKER_ACK_DEADLINE_S:-$(orc_get_nested dispatch ack_deadline_s)}"
BROKER_ACK_DEADLINE_S="${BROKER_ACK_DEADLINE_S:-60}"
BROKER_ARCHIVE_RETENTION_DAYS="${BROKER_ARCHIVE_RETENTION_DAYS:-$(orc_get_nested dispatch archive_retention_days)}"
BROKER_ARCHIVE_RETENTION_DAYS="${BROKER_ARCHIVE_RETENTION_DAYS:-14}"
# Acked pairs younger than this stay in the live inbox: a handoff-verb
# sender may still be polling its .ack path (default poll timeout 120s;
# 300 gives slack), and archiving out from under it would read as a
# timeout.
BROKER_ARCHIVE_MIN_AGE_S="${BROKER_ARCHIVE_MIN_AGE_S:-300}"
# Standing panes only: scribe is headless (acks its own one-shot task,
# nothing to wake).
BROKER_AGENTS="${BROKER_AGENTS:-orchestra builder agy}"
# events.log rotation: the DISPLAY is capped (watch_render events_shown);
# the file itself must not grow forever either. Trim, don't truncate:
# recent history stays greppable, deep history lives in nothing (it never
# did -- events.log is a gitignored convenience record, decisions.log is
# the durable one).
BROKER_EVENTS_MAX_LINES="${BROKER_EVENTS_MAX_LINES:-1000}"
BROKER_EVENTS_KEEP_LINES="${BROKER_EVENTS_KEEP_LINES:-500}"

# issue #130 (from agy's own #129 investigation): Antigravity has no
# lifecycle hooks, but its statusline scratch file (the same one
# gatekeeper reads quota from) carries agent_state + session_id. Polling
# that into the standard pane-state file gives agy's pane the same
# ground truth as Claude panes -- the screen heuristic drops to a
# rarely-taken fallback. Unlike hook-written states (event truth, never
# expires), this is a POLLED copy of another program's file, so
# freshness gates the SOURCE: a missing/stale/unreadable statusline
# CLEARS the translated state outright, restoring the heuristic's
# authority, rather than trusting a snapshot of unknown age.
AGY_STATUSLINE_FILE="${AGY_STATUSLINE_FILE:-$HOME/.gemini/antigravity-cli/scratch/agy-statusline.json}"
AGY_STATUSLINE_MAX_AGE_S="${AGY_STATUSLINE_MAX_AGE_S:-300}"

broker_translate_agy_state() {
  local target pane_id f state sid age
  target="$(pane_for_agent agy)"
  [ -n "$target" ] || return 0
  pane_id="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || echo '')"
  [ -n "$pane_id" ] || return 0
  f="$AGY_STATUSLINE_FILE"
  if [ ! -f "$f" ]; then
    pane_state_clear "$pane_id"
    return 0
  fi
  age=$(( $(broker_now) - $(broker_mtime "$f") ))
  if [ "$age" -gt "$AGY_STATUSLINE_MAX_AGE_S" ]; then
    pane_state_clear "$pane_id"
    return 0
  fi
  state="$(jq -r '.agent_state // empty' "$f" 2>/dev/null)"
  sid="$(jq -r '.session_id // empty' "$f" 2>/dev/null)"
  if [ -z "$state" ]; then
    pane_state_clear "$pane_id"
    return 0
  fi
  # Value space (observed live: "idle"): only an explicit idle reads
  # idle; every other non-empty value is treated as busy -- failing
  # toward "don't type into it", the room's standing posture.
  case "$state" in
    idle) state="idle" ;;
    *)    state="busy" ;;
  esac
  pane_state_write "$pane_id" "$state" "$sid"
}

broker_now() { date '+%s'; }

# stat portability: GNU (-c %Y) first, BSD (-f %m) fallback. Order is
# load-bearing (caught by the tmux-3.4 Docker verify): on GNU stat,
# `-f %m` is a valid FILESYSTEM query that SUCCEEDS with non-numeric
# output (it never falls through), while on BSD stat `-c` fails cleanly.
# Numeric-validate regardless -- this feeds arithmetic.
broker_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  case "$m" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$m" ;;
  esac
}

# Per-message wake bookkeeping: "<attempts> <last_wake_epoch>" in
# $BROKER_STATE_DIR/<agent>__<msg-basename>. attempts=99 marks escalated.
broker_attempts_file() { echo "$BROKER_STATE_DIR/${1}__${2}"; }

broker_escalate() { # $1 agent, $2 msg path, $3 attempts
  # `message` verb: durable FLAG with NO nudge -- orchestra's own Stop-hook
  # pickup (or the human) sees it; an assign would re-enter this very
  # delivery path against a pane already proven unresponsive.
  dispatch_main message orchestra broker \
    "FLAG: undelivered inbox message for '$1' after $3 verified wakes: $2 -- pane is not busy and not parked, yet never acked. Investigate/restart it." >/dev/null 2>&1
  we_log_event "broker: ESCALATED undelivered msg for $1 ($(basename "$2")) after $3 wakes"
}

# broker_check -- one delivery pass. Called from watch.sh's main loop.
broker_check() {
  mkdir -p "$BROKER_STATE_DIR"
  local now pending_tmp agent inbox target pane_id state m ack base af attempts last_wake age
  local agent_woke agent_escalated
  now="$(broker_now)"
  pending_tmp="$(mktemp "${BROKER_PENDING_LIST}.XXXXXX")" || return 0
  for agent in $BROKER_AGENTS; do
    inbox="$BROKER_INBOX_ROOT/$agent"
    [ -d "$inbox" ] || continue
    agent_woke=0
    agent_escalated=0
    target="$(pane_for_agent "$agent")"
    pane_id=""; state=""
    if [ -n "$target" ]; then
      pane_id="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || echo '')"
      # effective, not raw: a stale 'failsafe' whose quota flag already
      # lifted reads as idle here, so delivery resumes without needing
      # the pane to somehow wake itself first (issue #125 follow-up).
      [ -n "$pane_id" ] && state="$(pane_state_effective "$pane_id" 2>/dev/null || echo '')"
    fi
    for m in "$inbox"/*.msg; do
      [ -e "$m" ] || continue
      ack="${m%.msg}.ack"
      base="$(basename "$m" .msg)"
      af="$(broker_attempts_file "$agent" "$base")"
      if [ -f "$ack" ]; then
        if [ $(( now - $(broker_mtime "$ack") )) -ge "$BROKER_ARCHIVE_MIN_AGE_S" ]; then
          mkdir -p "$inbox/archive"
          mv "$m" "$ack" "$inbox/archive/" 2>/dev/null
          rm -f "$af"
        fi
        continue
      fi
      age=$(( now - $(broker_mtime "$m") ))
      [ "$age" -lt "$BROKER_WAKE_GRACE_S" ] && continue
      echo "$agent $base ${age}s ${state:-?}" >> "$pending_tmp"
      case "$state" in
        busy)     continue ;;  # check-inbox Stop hook delivers at turn end
        failsafe) continue ;;  # parked on quota: hold, no deadline clock
      esac
      attempts=0; last_wake=0
      if [ -f "$af" ]; then
        read -r attempts last_wake < "$af" 2>/dev/null || { attempts=0; last_wake=0; }
      fi
      case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
      case "$last_wake" in ''|*[!0-9]*) last_wake=0 ;; esac
      [ "$attempts" -ge 99 ] && continue  # already escalated
      if [ "$last_wake" -gt 0 ] && [ $(( now - last_wake )) -lt "$BROKER_ACK_DEADLINE_S" ]; then
        continue  # a wake is in flight; give the .ack its deadline
      fi
      if [ "$attempts" -ge 2 ]; then
        # issue #127: ONE FLAG per agent per pass, not one per stuck
        # message -- the FLAG names the first; the rest are visible in
        # the pending list.
        if [ "$agent_escalated" -eq 0 ]; then
          broker_escalate "$agent" "$m" "$attempts"
          agent_escalated=1
        fi
        echo "99 $now" > "$af"
        continue
      fi
      if [ -z "$state" ] && [ "$agent_woke" -eq 0 ]; then
        # No hook ground truth (agy's pane): only type into a
        # heuristically-idle pane -- the one place the screen heuristic
        # legitimately survives (#125 audit: no hook-based replacement).
        # Skipped once woken this pass: the wake itself makes the pane
        # look busy to the heuristic.
        if [ -z "$target" ] || ! pane_is_idle "$target" "$agent"; then
          continue
        fi
      fi
      if [ -n "$target" ]; then
        # issue #127 (live-hit: 13 wakes typed into builder, one per
        # stale message): an agent is woken AT MOST ONCE per pass -- a
        # single 'check inbox' covers the WHOLE inbox -- but the shared
        # wake is stamped against EVERY pending message's attempt file,
        # since it delivers all of them and each still gets its own
        # ack-deadline/escalation clock.
        if [ "$agent_woke" -eq 0 ]; then
          send_submit "$target" "check inbox"
          agent_woke=1
          echo "watch.sh: broker woke $agent ($(basename "$m") + all pending, attempt $(( attempts + 1 )))"
        fi
        echo "$(( attempts + 1 )) $now" > "$af"
      fi
    done
    if [ -d "$inbox/archive" ]; then
      find "$inbox/archive" -type f -mtime +"$BROKER_ARCHIVE_RETENTION_DAYS" -delete 2>/dev/null
    fi
  done
  mv "$pending_tmp" "$BROKER_PENDING_LIST" 2>/dev/null || rm -f "$pending_tmp"

  if [ -f "${EVENTS_LOG:-}" ] && [ "$(wc -l < "$EVENTS_LOG" | tr -d ' ')" -gt "$BROKER_EVENTS_MAX_LINES" ]; then
    tail -"$BROKER_EVENTS_KEEP_LINES" "$EVENTS_LOG" > "$EVENTS_LOG.tmp" && mv "$EVENTS_LOG.tmp" "$EVENTS_LOG"
    we_log_event "broker: rotated events.log (kept last $BROKER_EVENTS_KEEP_LINES lines)"
  fi
}

# broker_states_summary -- one-line ground-truth readout for the watch
# header: "orchestra:idle builder:busy agy:?" ('?' = no hook state; agy
# always reads '?' by construction).
broker_states_summary() {
  local agent target pane_id state out=""
  for agent in $BROKER_AGENTS; do
    target="$(pane_for_agent "$agent")"
    state="?"
    if [ -n "$target" ]; then
      pane_id="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || echo '')"
      if [ -n "$pane_id" ]; then
        state="$(pane_state_effective "$pane_id" 2>/dev/null || echo '?')"
        [ -z "$state" ] && state="?"
      fi
    fi
    out="${out}${agent}:${state} "
  done
  echo "${out% }"
}
