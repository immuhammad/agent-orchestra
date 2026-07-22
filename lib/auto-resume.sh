#!/bin/bash
# .harness/auto-resume.sh — budgeted 5h-window rate-limit auto-resume.
# Sourced by gatekeeper.sh; also directly testable/sourceable on its
# own (see auto-resume.test.sh).
#
# Policy (AGENTS.md Quota Failsafe, Hard Rules):
# - Only the Claude 5h pool auto-resumes. seven_day (weekly) crossings NEVER
#   auto-resume -- they always stop for Ahmad, no exceptions.
# - Max AUTO_RESUME_MAX_PER_DAY (default 2) auto-resumes per UTC day.
# - "Only unblock what you parked" (amux semantics): a pane is only ever
#   auto-resumed if it is still in EXACTLY the parked state gatekeeper left
#   it in. If anything about that pane changed since parking -- Ahmad
#   answered it, it crashed, it moved on some other way -- auto-resume backs
#   off silently (well, loudly in the log) rather than guessing.
# - issue #125: parked-detection and ownership read the pane's own
#   hook-written state file (failsafe + session_id, lib/pane-state-lib.sh),
#   NEVER the screen. The old role-split fingerprint/question-visible
#   machinery (#73/#80) is gone; `role` stays in the state entry for
#   logging/back-compat only.
#
# State machine per tracked pane (persisted in AUTO_RESUME_STATE_FILE so it
# survives a gatekeeper.sh restart -- exactly the kind of restart the
# liveness watchdog exists to catch):
#   (not tracked) --[usage >= threshold]--> pending
#   pending --[pane's own hooks report failsafe]--> parked
#     (session_id + the five_hour resets_at at the moment of parking are
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
# issue #125: ground-truth pane state (busy|idle|failsafe + session_id),
# written by each pane's own hooks -- replaces every screen-scrape this
# file used to do (AR_PARK_MARKER question-spotting, fingerprint
# ownership). gatekeeper-liveness.sh keeps its own inline copy of the
# failsafe-question regex for its stuck-banner SUPPRESSION -- a backup
# detector, not a state source.
# shellcheck source=./pane-state-lib.sh
source "$AR_DIR/pane-state-lib.sh"
PANE_STATE_DIR="${PANE_STATE_DIR:-$(_ar_canon_dir)/state/pane-state}"

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

# issue #125: park detection and ownership moved OFF screen-scrapes onto
# the hook-written pane state file. The machinery this replaces -- tail
# fingerprint hashing (#80's ar_fingerprint/ar_normalize) and the
# question-visible re-check (#73's ar_still_at_failsafe_question) -- was
# assumptions derived from rendered text; the state file is written by
# the parked session's own hooks at the moment it parks, and session_id
# gives ownership an identity comparison instead of a screen hash.
ar_pane_id() { tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null || echo ''; }

ar_pane_state() {
  local pid
  pid="$(ar_pane_id "$1")"
  [ -n "$pid" ] || return 1
  pane_state_read "$pid" 2>/dev/null
}

ar_pane_session() {
  local pid
  pid="$(ar_pane_id "$1")"
  [ -n "$pid" ] || return 1
  pane_state_session "$pid" 2>/dev/null
}

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


# ar_pane_still_owned <pane> <stored session_id> -- the parked-state
# ownership test ("amux: only unblock what you parked"): the pane's hooks
# still report failsafe AND the same session that parked is still the one
# in the pane. A human answering flips the state to busy (drops
# ownership); a restarted session writes a NEW session_id at SessionStart
# (drops ownership) -- both fail toward "do not inject", the same posture
# as the old fingerprint test, with no screen read anywhere (issue #125).
ar_pane_still_owned() { # $1 = pane, $2 = stored session_id
  local pane="$1" stored_sid="$2" state sid
  state="$(ar_pane_state "$pane")" || return 1
  [ "$state" = "failsafe" ] || return 1
  sid="$(ar_pane_session "$pane")" || return 1
  [ -n "$stored_sid" ] && [ "$sid" = "$stored_sid" ]
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

  if [ "$state" = "pending" ]; then
    # issue #125: parked the moment the pane's OWN hooks report failsafe
    # (its Stop fired while the quota-stop flag was up, or a rate_limit
    # StopFailure hit) -- no screen-scrape, no question-spotting.
    if [ "$(ar_pane_state "$pane" || echo '')" = "failsafe" ]; then
      local role sid
      role="$(ar_read --arg p "$pane" '.panes[$p].role // "worker"')"
      sid="$(ar_pane_session "$pane" || echo '')"
      ar_write --arg p "$pane" --arg sid "$sid" --arg r "$current_resets_at" --arg role "$role" \
        '.panes[$p] = {state: "parked", session_id: $sid, resets_at: $r, role: $role}'
      ar_log "parked $pane (failsafe state from its own hooks, session ${sid:-unknown}, 5h window resets at $current_resets_at)"
    fi
    return 0
  fi

  if [ "$state" = "parked" ]; then
    local stored_sid stored_resets_at
    stored_sid="$(ar_read --arg p "$pane" '.panes[$p].session_id // empty')"
    stored_resets_at="$(ar_read --arg p "$pane" '.panes[$p].resets_at')"

    if ! ar_pane_still_owned "$pane" "$stored_sid"; then
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
      # Window has genuinely time-reset. Re-check ownership ONE more time
      # immediately before acting (paranoia: against the freshest state
      # read, not a value computed earlier in this function).
      if ! ar_pane_still_owned "$pane" "$stored_sid"; then
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
        # issue #125: verify delivery by ground truth -- the resumed
        # session's first hook write flips failsafe -> busy -- instead of
        # re-reading the screen. Bounded so the gatekeeper loop never
        # stalls long on an unresponsive pane; AUTO_RESUME_VERIFY_S=0
        # skips the wait outright (tests).
        local ar_waited=0 ar_post_state=""
        while [ "$ar_waited" -lt "${AUTO_RESUME_VERIFY_S:-15}" ]; do
          sleep 3
          ar_waited=$((ar_waited + 3))
          ar_post_state="$(ar_pane_state "$pane" || echo '')"
          [ "$ar_post_state" = "busy" ] && break
        done
        if [ "$ar_post_state" = "busy" ]; then
          ar_log "resumed $pane ($(( AR_MAX_PER_DAY - remaining + 1 ))/${AR_MAX_PER_DAY} today) -- confirmed, state flipped to busy after ${ar_waited}s"
        else
          ar_log "resumed $pane ($(( AR_MAX_PER_DAY - remaining + 1 ))/${AR_MAX_PER_DAY} today) -- WARNING: state still '${ar_post_state:-unknown}' after ${ar_waited}s, check the pane"
        fi
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
