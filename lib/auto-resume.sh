#!/bin/bash
# .harness/auto-resume.sh — budgeted 5h-window rate-limit auto-resume (T20,
# Q3b). Sourced by gatekeeper.sh; also directly testable/sourceable on its
# own (see auto-resume.test.sh).
#
# Policy (AGENTS.md Quota Failsafe, Hard Rules, T20 spec):
# - Only the Claude 5h pool auto-resumes. seven_day (weekly) crossings NEVER
#   auto-resume -- they always stop for Ahmad, no exceptions.
# - Max AUTO_RESUME_MAX_PER_DAY (default 2) auto-resumes per UTC day.
# - "Only unblock what you parked" (amux semantics): a pane is only ever
#   auto-resumed if it is still in EXACTLY the parked state gatekeeper left
#   it in. If anything about that pane changed since parking -- Ahmad
#   answered it, it crashed, it moved on some other way -- auto-resume backs
#   off silently (well, loudly in the log) rather than guessing.
#
# State machine per tracked pane (persisted in AUTO_RESUME_STATE_FILE so it
# survives a gatekeeper.sh restart -- exactly the kind of restart T19's
# liveness watchdog exists to catch):
#   (not tracked) --[usage >= threshold]--> pending
#   pending --[scrollback shows the AGENTS.md failsafe question]--> parked
#     (fingerprint + the five_hour resets_at at the moment of parking are
#     recorded)
#   parked --[scrollback fingerprint changed]--> dropped (touched, not ours
#     to resume anymore)
#   parked --[five_hour resets_at has advanced past the parked value]-->
#     re-check the fingerprint one more time, then either resume (if budget
#     remains) or skip (budget exhausted) -- either way the pane's tracking
#     entry is cleared, since the window that caused the park has closed.
set -uo pipefail

AR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./send-lib.sh
source "$AR_DIR/send-lib.sh"
# shellcheck source=./harness-root.sh
source "$AR_DIR/harness-root.sh"
# issue #116: state defaults off the CALLER's project root (this script's
# own dir is now agent-orchestra's shared lib/, not the consumer
# project). Resolved lazily/memoized -- a caller pinning every *_FILE/LOG
# var explicitly (tests) never needs orchestrator.yaml/ORC_PROJECT_ROOT.
_ar_canon_dir() {
  if [ -z "${_AR_CANON_DIR_CACHE:-}" ]; then
    if [ -n "${AUTO_RESUME_CANON_DIR:-}" ]; then
      _AR_CANON_DIR_CACHE="$AUTO_RESUME_CANON_DIR"
    elif ! _AR_CANON_DIR_CACHE="$(harness_canonical_dir "$PWD")"; then
      echo "auto-resume.sh: could not resolve project root (see error above); set ORC_PROJECT_ROOT, run from inside a project with orchestrator.yaml, or pin AUTO_RESUME_STATE_FILE/AUTO_RESUME_LOG explicitly" >&2
      exit 1
    fi
  fi
  echo "$_AR_CANON_DIR_CACHE"
}
AR_STATE_FILE="${AUTO_RESUME_STATE_FILE:-$(_ar_canon_dir)/auto-resume-state.json}"
AR_MAX_PER_DAY="${AUTO_RESUME_MAX_PER_DAY:-2}"
AR_LOG="${AUTO_RESUME_LOG:-$(_ar_canon_dir)/budget.log}"
# The exact wording is mandated by AGENTS.md's Quota Failsafe ("Keep the
# (a)/(b)/(c) structure exactly") -- this regex is deliberately narrow so it
# can't accidentally match ordinary conversation.
AR_PARK_MARKER='Quota .*Options: \(a\).*Pick one\.'

ar_today() { date -u +%Y-%m-%d; }

# ar_meaningful_tail -- thin alias for send-lib.sh's send_meaningful_tail
# (issue #86: moved there so dispatch.sh's pane_is_idle gets the same
# blank-padding fix). Kept under its original name since ar_fingerprint/
# ar_poll_pane below already call it by this name.
ar_meaningful_tail() { send_meaningful_tail "$@"; }

# #80: hash a NORMALIZED view of the tail, not the raw bytes. Claude Code's
# TUI repaints volatile chrome (context/token counters, timers, "esc to
# interrupt") even when the human never touched the pane -- that changed the
# raw fingerprint and got a still-blocked parked pane dropped before it could
# resume. Dropping known volatile status lines and collapsing every digit run
# to `#` makes a benign repaint hash identically, while a real new line (a
# human actually answering) still changes the hash and correctly drops the pane.
# stdin -> normalized stdout. Drops known volatile TUI status lines and
# collapses every digit run to `#`, so an in-place counter/timer repaint
# (context %, token count, elapsed time) normalizes to the SAME text while a
# real new line (a human answering) still changes it. Split out from
# ar_fingerprint so it can be unit-tested directly.
ar_normalize() {
  grep -vE 'esc to interrupt|auto-accept edits|ctx:|[0-9]+ tokens|[0-9]+%' \
    | sed -E 's/[0-9]+/#/g; s/[[:space:]]+/ /g'
}

ar_fingerprint() { # $1 = tmux pane target
  ar_meaningful_tail "$1" | ar_normalize | shasum -a 256 | awk '{print $1}'
}

ar_ensure_state_file() {
  if [ ! -f "$AR_STATE_FILE" ]; then
    jq -n --arg today "$(ar_today)" \
      '{budget: {date: $today, count: 0}, panes: {}}' > "$AR_STATE_FILE"
  fi
}

ar_read() { # "$@" = jq args (e.g. --arg p "$pane" '.panes[$p].state')
  ar_ensure_state_file
  jq -r "$@" "$AR_STATE_FILE"
}

ar_write() { # "$@" = jq args, filter transforms current state -> new state
  ar_ensure_state_file
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$AR_STATE_FILE" > "$tmp" && mv "$tmp" "$AR_STATE_FILE"
}

ar_roll_budget_if_new_day() {
  local today stored_date
  today="$(ar_today)"
  stored_date="$(ar_read '.budget.date')"
  if [ "$stored_date" != "$today" ]; then
    ar_write --arg today "$today" '.budget = {date: $today, count: 0}'
  fi
}

ar_budget_remaining() {
  ar_roll_budget_if_new_day
  local count
  count="$(ar_read '.budget.count')"
  echo $((AR_MAX_PER_DAY - count))
}

ar_log() { # $1 = message
  echo "$(date) - AUTO-RESUME: $1" >> "$AR_LOG"
}

# Start (or no-op if already) tracking a pane as a threshold-crossing
# candidate. Idempotent: never clobbers an existing pending/parked entry,
# so calling this every gatekeeper iteration while over threshold is safe.
ar_mark_pending() { # $1 = pane target
  local pane="$1" existing
  existing="$(ar_read --arg p "$pane" '.panes[$p].state // empty')"
  if [ -z "$existing" ]; then
    ar_write --arg p "$pane" '.panes[$p] = {state: "pending", fingerprint: null, resets_at: null}'
    ar_log "watching $pane (usage over threshold, waiting for the failsafe question to appear before treating it as parked)"
  fi
}

# Advance one tracked pane's state machine. Called every gatekeeper
# iteration for every pane currently present in the state file, regardless
# of current usage% (the reset that matters happens AFTER usage has already
# dropped back down, so this must not be gated on still being over
# threshold).
ar_poll_pane() { # $1 = pane target, $2 = current five_hour resets_at
  local pane="$1" current_resets_at="$2"
  local state
  state="$(ar_read --arg p "$pane" '.panes[$p].state // empty')"
  [ -z "$state" ] && return 0

  local tail_fp
  tail_fp="$(ar_fingerprint "$pane")"

  if [ "$state" = "pending" ]; then
    local tail_text
    # Flatten to a single line before matching: tmux hard-wraps at the
    # pane's column width with no reflow-awareness, so a narrow pane can
    # split the failsafe question's words mid-character across physical
    # lines (e.g. "Pick" -> "Pi\nck"). Deleting the newlines outright (NOT
    # replacing them with a space) exactly undoes that hard-wrap and
    # reconstructs the original unbroken text.
    tail_text="$(ar_meaningful_tail "$pane" | tr -d '\n')"
    if echo "$tail_text" | grep -Eq "$AR_PARK_MARKER"; then
      ar_write --arg p "$pane" --arg fp "$tail_fp" --arg r "$current_resets_at" \
        '.panes[$p] = {state: "parked", fingerprint: $fp, resets_at: $r}'
      ar_log "parked $pane (failsafe question detected, 5h window resets at $current_resets_at)"
    fi
    return 0
  fi

  if [ "$state" = "parked" ]; then
    local stored_fp stored_resets_at
    stored_fp="$(ar_read --arg p "$pane" '.panes[$p].fingerprint')"
    stored_resets_at="$(ar_read --arg p "$pane" '.panes[$p].resets_at')"

    if [ "$tail_fp" != "$stored_fp" ]; then
      ar_log "$pane changed since parking -- not ours to resume anymore (amux: only unblock what you parked), dropping tracking"
      ar_write --arg p "$pane" 'del(.panes[$p])'
      return 0
    fi

    if [ "$current_resets_at" != "$stored_resets_at" ] && [ -n "$current_resets_at" ]; then
      # 5h window has rolled over since we parked this pane. Re-check the
      # scrollback ONE more time immediately before acting (paranoia
      # matches the spec wording -- we already confirmed tail_fp ==
      # stored_fp above, but re-fingerprint right here so the check is
      # against the freshest possible read, not a value computed earlier
      # in this function).
      local recheck_fp
      recheck_fp="$(ar_fingerprint "$pane")"
      if [ "$recheck_fp" != "$stored_fp" ]; then
        ar_log "$pane changed between reset-detection and re-check -- skipping resume, dropping tracking"
        ar_write --arg p "$pane" 'del(.panes[$p])'
        return 0
      fi

      local remaining
      remaining="$(ar_budget_remaining)"
      if [ "$remaining" -gt 0 ]; then
        # #80/#81/#86: submit via the shared send_submit (send-lib.sh) --
        # text and Enter as separate key events with a beat, a wrap-safe
        # confirm, and clear-and-retype on a still-stuck input.
        send_submit "$pane" "Quota window reset (5h) -- auto-resuming per AGENTS.md T20 budgeted auto-resume ($(( AR_MAX_PER_DAY - remaining + 1 ))/${AR_MAX_PER_DAY} today). Continuing (option c)."
        ar_write '.budget.count += 1'
        ar_log "resumed $pane ($(( AR_MAX_PER_DAY - remaining + 1 ))/${AR_MAX_PER_DAY} today)"
      else
        ar_log "5h window reset for $pane but daily auto-resume budget (${AR_MAX_PER_DAY}) is exhausted -- not resuming, Ahmad must resume it manually"
      fi
      ar_write --arg p "$pane" 'del(.panes[$p])'
    fi
  fi
}

# Convenience: poll every currently-tracked pane. Call once per gatekeeper
# iteration with the latest five_hour.resets_at.
ar_poll_all() { # $1 = current five_hour resets_at
  local current_resets_at="$1" pane
  ar_ensure_state_file
  while IFS= read -r pane; do
    [ -z "$pane" ] && continue
    ar_poll_pane "$pane" "$current_resets_at"
  done < <(ar_read '.panes | keys[]')
}
