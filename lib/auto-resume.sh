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
# - Each tracked pane carries a role ("driver" for the Orchestra pane,
#   "worker" otherwise -- see ar_mark_pending). The parked-state ownership
#   test differs by role (issue #73): workers use exact raw-fingerprint
#   equality; the driver instead re-checks whether the AGENTS.md failsafe
#   question is STILL present in its tail, since the driver pane keeps
#   accumulating passive output (gatekeeper alerts, watch nudges) while
#   parked -- that would otherwise always drift its raw fingerprint even
#   though it never actually moved past the question (see
#   ar_pane_still_owned).
#
# State machine per tracked pane (persisted in AUTO_RESUME_STATE_FILE so it
# survives a gatekeeper.sh restart -- exactly the kind of restart T19's
# liveness watchdog exists to catch):
#   (not tracked) --[usage >= threshold]--> pending
#   pending --[scrollback shows the AGENTS.md failsafe question]--> parked
#     (fingerprint + the five_hour resets_at at the moment of parking are
#     recorded)
#   parked --[ownership test fails, see ar_pane_still_owned]--> dropped
#     (touched or moved on, not ours to resume anymore)
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
# #11 belt-and-braces: even once the window has time-reset, only resume
# into quota we've confirmed is actually available.
AR_RESUME_USAGE_CEILING="${AUTO_RESUME_USAGE_CEILING:-50}"
# #10: single source of truth for the quota-stop PreToolUse gate's flag
# path -- gatekeeper.sh (writer), this file (auto-clear on real reset), and
# hooks/quota-stop-gate.sh / lib/guard-quota-stop-agy.sh (readers) must
# never resolve this independently or they can drift apart.
AR_QUOTA_STOP_FLAG="${AUTO_RESUME_QUOTA_STOP_FLAG:-$(_ar_canon_dir)/state/quota-stop}"
# The exact wording is mandated by AGENTS.md's Quota Failsafe ("Keep the
# (a)/(b)/(c) structure exactly") -- this regex is deliberately narrow so it
# can't accidentally match ordinary conversation.
AR_PARK_MARKER='Quota .*Options: \(a\).*Pick one\.'

ar_today() { date -u +%Y-%m-%d; }

# ar_now_epoch -- wall-clock "now" as epoch seconds. Overridable
# (AUTO_RESUME_NOW_EPOCH) so tests can pin deterministic values instead of
# racing the real clock against fixed resets_at fixtures.
ar_now_epoch() { echo "${AUTO_RESUME_NOW_EPOCH:-$(date -u +%s)}"; }

# ar_epoch_from_iso8601 <ISO-8601 timestamp> -- cross-platform epoch-seconds
# parse. Handles both the plain shape our own fixtures use
# (2026-07-11T18:00:00Z) and the REAL Claude usage-API shape, which carries
# fractional seconds AND a numeric offset (2026-07-12T20:39:59.719039+00:00)
# -- BSD `date -j -f` cannot be handed either of those (its format string
# would need to match exactly, and a literal "Z" doesn't match "+00:00"),
# and GNU `date -d` isn't available on darwin at all. #32: this one function
# is the ONLY resets_at parser in this codebase (both ar_write_quota_stop_flag
# and ar_poll_pane's resume comparison call it) -- there is no second,
# "working" parse path to collapse into it.
#
# Approach: regex out the date/time separately from any fractional seconds
# and offset, parse the bare "YYYY-MM-DDTHH:MM:SS" as UTC (both GNU and BSD
# date handle that shape fine once fraction/offset are stripped), then
# apply the offset as plain arithmetic. Echoes the epoch on success; returns
# 1 with nothing on stdout if the input doesn't match (caller must treat
# empty output as "unknown", never guess).
ar_epoch_from_iso8601() {
  local ts="$1" base offset epoch off_sign off_h off_m off_sec
  [ -z "$ts" ] && return 1

  if [[ "$ts" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?$ ]]; then
    base="${BASH_REMATCH[1]}"
    offset="${BASH_REMATCH[3]:-Z}"
  else
    return 1
  fi

  if epoch="$(date -u -d "${base}Z" +%s 2>/dev/null)"; then
    :
  elif epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${base}Z" +%s 2>/dev/null)"; then
    :
  else
    return 1
  fi

  if [ "$offset" != "Z" ]; then
    off_sign="${offset:0:1}"
    off_h="${offset:1:2}"
    off_m="${offset: -2}"
    off_h=$((10#$off_h))
    off_m=$((10#$off_m))
    off_sec=$((off_h * 3600 + off_m * 60))
    if [ "$off_sign" = "+" ]; then
      epoch=$((epoch - off_sec))
    else
      epoch=$((epoch + off_sec))
    fi
  fi

  echo "$epoch"
  return 0
}

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

# ar_still_at_failsafe_question <pane target> -- true if the AGENTS.md
# failsafe question is STILL present in the pane's meaningful tail right
# now. Same flatten-then-match as the pending->parked transition below
# (tmux hard-wraps mid-word, so newlines are deleted rather than replaced
# with a space to undo that). Issue #73: this is the driver pane's
# parked-state ownership test -- a substring search means interleaved
# passive output above/around the question doesn't count as "changed",
# while a human actually answering (question no longer in the tail at
# all) still correctly reads as moved-on.
ar_still_at_failsafe_question() { # $1 = pane target
  local tail_text
  tail_text="$(ar_meaningful_tail "$1" | tr -d '\n')"
  echo "$tail_text" | grep -Eq "$AR_PARK_MARKER"
}

# ar_pane_still_owned <pane> <role> <stored fingerprint> <current tail
# fingerprint> -- the parked-state ownership test ("amux: only unblock
# what you parked"). Workers: exact raw-fingerprint equality, unchanged
# since #80. Driver (issue #73): anchored to whether the failsafe question
# is still visible instead, since the driver's raw fingerprint never
# stays stable while parked (gatekeeper alerts/watch nudges land in the
# same pane) even when it never moved past the question. Shared by both
# the initial ownership check and the pre-resume re-check below so the two
# can't drift apart.
ar_pane_still_owned() { # $1 = pane, $2 = role, $3 = stored fp, $4 = current fp
  local pane="$1" role="$2" stored_fp="$3" current_fp="$4"
  if [ "$role" = "driver" ]; then
    ar_still_at_failsafe_question "$pane"
  else
    [ "$current_fp" = "$stored_fp" ]
  fi
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
ar_mark_pending() { # $1 = pane target, $2 = role ("driver" for the Orchestra pane -- see ar_pane_still_owned; omitted/anything else keeps today's worker semantics)
  local pane="$1" role="${2:-worker}" existing
  existing="$(ar_read --arg p "$pane" '.panes[$p].state // empty')"
  if [ -z "$existing" ]; then
    ar_write --arg p "$pane" --arg role "$role" '.panes[$p] = {state: "pending", fingerprint: null, resets_at: null, role: $role}'
    ar_log "watching $pane (usage over threshold, waiting for the failsafe question to appear before treating it as parked)"
  fi
}

# Advance one tracked pane's state machine. Called every gatekeeper
# iteration for every pane currently present in the state file, regardless
# of current usage% (the reset that matters happens AFTER usage has already
# dropped back down, so this must not be gated on still being over
# threshold).
ar_poll_pane() { # $1 = pane target, $2 = current five_hour resets_at, $3 = current 5h usage_pct (belt-and-braces, #11)
  local pane="$1" current_resets_at="$2" usage_pct="${3:-}"
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
      local role
      role="$(ar_read --arg p "$pane" '.panes[$p].role // "worker"')"
      ar_write --arg p "$pane" --arg fp "$tail_fp" --arg r "$current_resets_at" --arg role "$role" \
        '.panes[$p] = {state: "parked", fingerprint: $fp, resets_at: $r, role: $role}'
      ar_log "parked $pane (failsafe question detected, 5h window resets at $current_resets_at)"
    fi
    return 0
  fi

  if [ "$state" = "parked" ]; then
    local stored_fp stored_resets_at role
    stored_fp="$(ar_read --arg p "$pane" '.panes[$p].fingerprint')"
    stored_resets_at="$(ar_read --arg p "$pane" '.panes[$p].resets_at')"
    role="$(ar_read --arg p "$pane" '.panes[$p].role // "worker"')"

    if ! ar_pane_still_owned "$pane" "$role" "$stored_fp" "$tail_fp"; then
      ar_log "$pane changed since parking -- not ours to resume anymore (amux: only unblock what you parked), dropping tracking"
      ar_write --arg p "$pane" 'del(.panes[$p])'
      return 0
    fi

    # #11: trigger is a TIME comparison against the resets_at we recorded
    # AT PARKING TIME, never a string inequality against the freshest
    # poll's resets_at. A rolling 5h window's resets_at drifts continuously
    # as usage moves through it -- comparing strings meant a few minutes of
    # drift read as a rollover and resumed a pane mid-window into a still-
    # exhausted pool (the incident this fix exists for). Once real wall-
    # clock time has reached the stored deadline, that window has
    # necessarily elapsed regardless of what the freshest resets_at says.
    local stored_epoch
    stored_epoch=""
    if [ -n "$stored_resets_at" ] && [ "$stored_resets_at" != "null" ]; then
      stored_epoch="$(ar_epoch_from_iso8601 "$stored_resets_at" 2>/dev/null || echo "")"
    fi
    if [ -z "$stored_epoch" ]; then
      return 0 # nothing parseable to compare against yet -- stay parked
    fi

    if [ "$(ar_now_epoch)" -ge "$stored_epoch" ]; then
      # Window has genuinely time-reset. Re-check the scrollback ONE more
      # time immediately before acting (paranoia matches the spec wording
      # -- we already confirmed tail_fp == stored_fp above, but
      # re-fingerprint right here so the check is against the freshest
      # possible read, not a value computed earlier in this function).
      local recheck_fp
      recheck_fp="$(ar_fingerprint "$pane")"
      if ! ar_pane_still_owned "$pane" "$role" "$stored_fp" "$recheck_fp"; then
        ar_log "$pane changed between reset-detection and re-check -- skipping resume, dropping tracking"
        ar_write --arg p "$pane" 'del(.panes[$p])'
        return 0
      fi

      # Belt-and-braces (#11): only resume into quota we've confirmed is
      # actually available. An unreadable/missing usage_pct fails SAFE (not
      # resumed) rather than guessing -- same "never guess" posture as the
      # epoch parse above. Tracking is deliberately KEPT (not dropped) so
      # the next gatekeeper iteration re-checks usage again once it (likely
      # briefly) drops back down, rather than permanently handing a still-
      # throttled pane back to Ahmad the way a real budget exhaustion does.
      if [ -z "$usage_pct" ] || ! [ "$usage_pct" -lt "$AR_RESUME_USAGE_CEILING" ] 2>/dev/null; then
        ar_log "$pane's window reset at $stored_resets_at but usage is still ${usage_pct:-unknown}% (>= ${AR_RESUME_USAGE_CEILING}% ceiling) -- not resuming yet, will re-check next iteration"
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
# iteration with the latest five_hour.resets_at and current 5h usage_pct.
ar_poll_all() { # $1 = current five_hour resets_at, $2 = current 5h usage_pct
  local current_resets_at="$1" usage_pct="${2:-}" pane
  ar_ensure_state_file
  while IFS= read -r pane; do
    [ -z "$pane" ] && continue
    ar_poll_pane "$pane" "$current_resets_at" "$usage_pct"
  done < <(ar_read '.panes | keys[]')
}

# --- #10: quota-stop PreToolUse gate flag -----------------------------
# gatekeeper.sh (writer) and the quota-stop-gate hooks (readers) share
# AR_QUOTA_STOP_FLAG above as the single path. This file only ever WRITES
# via ar_write_quota_stop_flag and CLEARS via
# ar_clear_quota_stop_flag_if_reset -- the hooks only ever read it.

# ar_write_quota_stop_flag <pool> <pct> <fallback> [resets_at ISO-8601]
# -- pool is one of "5h" | "weekly" | "both" (matches AGENTS.md's [pool]
# fill-in). resets_at is OPTIONAL and, when given, is converted to an
# epoch up front and stored as resets_at_epoch -- this is what lets
# ar_clear_quota_stop_flag_if_reset auto-lift the gate on a genuine
# time-based window reset (the #11<->#10 seam) without re-parsing anything
# later or depending on any pane being tracked. Gate-1 only calls this with
# a resets_at for the "5h" pool: weekly crossings never auto-anything per
# existing policy (see file header), and "both" needs a human regardless
# (agy's pool has no comparable resets_at this codebase can read yet) --
# both of those pools are FLAGGED as leaving resets_at_epoch null, which
# means only the explicit manual clear (lib/quota-stop-clear.sh) lifts
# them. FLAG (per this ticket's own instructions): this asymmetry --
# "5h" auto-clears, "weekly"/"both" require a human -- was a deliberate
# call made while implementing, not an explicit line in the Gate-1 plan;
# confirm it matches intent.
ar_write_quota_stop_flag() {
  local pool="$1" pct="$2" fallback="$3" resets_at="${4:-}" epoch="" tmp
  mkdir -p "$(dirname "$AR_QUOTA_STOP_FLAG")"
  if [ -n "$resets_at" ]; then
    epoch="$(ar_epoch_from_iso8601 "$resets_at" 2>/dev/null || echo "")"
    if [ -z "$epoch" ]; then
      ar_log "quota-stop flag: could not parse resets_at '$resets_at' for pool=$pool -- auto-clear disabled for this crossing, manual clear (lib/quota-stop-clear.sh) required"
    fi
  fi
  # Write-to-temp-then-mv: `mv` is only atomic WITHIN the same filesystem
  # -- a bare `mktemp` defaults to $TMPDIR, which can be a different
  # mount than AR_QUOTA_STOP_FLAG's own directory, silently downgrading
  # `mv` to a non-atomic copy+delete (same class of bug as the heartbeat
  # write Ahmad caught live -- fixed here too while touching this code
  # for the #10-rework). `mktemp "${AR_QUOTA_STOP_FLAG}.XXXXXX"` creates
  # the temp file IN THE SAME DIRECTORY, guaranteeing a same-filesystem
  # `mv` a concurrent reader (the PreToolUse hooks) can never observe
  # partially-written.
  tmp="$(mktemp "${AR_QUOTA_STOP_FLAG}.XXXXXX")"
  jq -n --arg pool "$pool" --arg pct "$pct" --arg fallback "$fallback" \
    --arg epoch "$epoch" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pool: $pool, pct: (($pct|tonumber?) // 0), fallback: $fallback,
      resets_at_epoch: (if $epoch == "" then null else ($epoch|tonumber) end),
      at: $at}' > "$tmp" && mv "$tmp" "$AR_QUOTA_STOP_FLAG"
  ar_log "quota-stop flag written (pool=$pool pct=$pct fallback=$fallback)"
}

# ar_clear_quota_stop_flag_if_reset [current weekly usage_pct] -- the
# #11<->#10 seam: lifts the PreToolUse gate ONLY once the window that
# triggered it has genuinely time-reset (epoch comparison against
# resets_at_epoch captured when the flag was written), never a
# usage-percentage heuristic -- dropping below some % mid-window is not
# the same as the window actually rolling over, and clearing on that
# would reopen the exact drift bug #11 exists to fix. A flag with no
# resets_at_epoch at all (a pure "weekly" crossing has none, see
# ar_write_quota_stop_flag) is left alone here; only
# lib/quota-stop-clear.sh's explicit manual clear lifts it. Call once per
# gatekeeper iteration, unconditionally (same posture as ar_poll_all).
#
# "both" is a special case (#10-rework finding 5, agy's dedicated
# security review): it DOES carry a resets_at_epoch (the 5h reset time,
# since gatekeeper.sh now passes it), but agy's own pool has no comparable
# epoch this codebase can read -- once the 5h portion resets, this can't
# tell whether agy is ALSO clear. Rather than either fully clearing (would
# silently un-gate agy while it may still be exhausted) or leaving the
# flag stuck forever with a stale "both" pool/fallback in the failsafe
# text (the original bug -- a "both" flag with no resets_at_epoch at all
# was invisible to this function permanently), DOWNGRADE it to a plain
# "weekly" flag: still human-clear-only (matches "weekly always stops for
# Ahmad, no exceptions"), but no longer permanently silently stuck once
# Claude's own quota has genuinely returned. $1, if given, is the CURRENT
# weekly usage_pct (gatekeeper.sh has it fresh every iteration) so the
# downgraded flag shows an accurate %, not whatever stale 5h% the "both"
# flag happened to be written with; falls back to the flag's own stored
# pct if omitted (e.g. a caller that hasn't been updated, or a test).
ar_clear_quota_stop_flag_if_reset() {
  local current_weekly_pct="${1:-}"
  [ -f "$AR_QUOTA_STOP_FLAG" ] || return 0
  local flag_epoch pool
  flag_epoch="$(jq -r '.resets_at_epoch // empty' "$AR_QUOTA_STOP_FLAG" 2>/dev/null)"
  [ -z "$flag_epoch" ] && return 0
  if [ "$(ar_now_epoch)" -ge "$flag_epoch" ]; then
    pool="$(jq -r '.pool // "?"' "$AR_QUOTA_STOP_FLAG" 2>/dev/null)"
    if [ "$pool" = "both" ]; then
      local pct
      pct="${current_weekly_pct:-$(jq -r '.pct // 0' "$AR_QUOTA_STOP_FLAG" 2>/dev/null)}"
      ar_write_quota_stop_flag "weekly" "$pct" "none"
      ar_log "quota-stop flag downgraded both -> weekly (5h window reset; agy's pool has no epoch to auto-clear against, weekly still requires the manual clear)"
    else
      rm -f "$AR_QUOTA_STOP_FLAG"
      ar_log "quota-stop flag cleared -- window reset (pool=$pool)"
    fi
  fi
}
