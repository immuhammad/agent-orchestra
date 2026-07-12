#!/bin/bash
# .harness/watch.sh — pane-5 watch loop (T24, issue #34). Replaces the old
# ad-hoc `watch -n 60 "gh pr list ...; tail budget.log"` command in
# orc.sh's control room build. Keeps that same human-facing display, and
# adds three background housekeeping jobs Ahmad asked for (see issue #34
# comments):
#
#   1. merge-watch: poll gh for newly-merged PRs and comment+close the
#      linked issue directly (mechanical `gh issue comment`+`gh issue
#      close`, no agent dispatch -- issue #85: dispatching the scribe for
#      this never actually got the issue closed since the scribe session
#      doesn't act on dispatched housekeeping), then tear down that PR's
#      worktree + merged branch via `orc-worktree.sh teardown` (issue #85,
#      Task 5), then dispatch a durable "PICK next" nudge to Orchestra
#      (issue #105, Task 5 -- closes the loop-continuity gap where nothing
#      told Orchestra to move on after a merge). Guard rules unchanged
#      elsewhere: this script never merges.
#   2. deferred-nudge retry: drain dispatch.sh's deferred-nudge queue so a
#      nudge that was skipped because the target pane was busy actually
#      gets retried once that pane goes idle, instead of requiring a
#      manual re-nudge (this was happening on every single copilot
#      dispatch before T24).
#   3. pane-liveness: detect an agent pane that has dropped back to a bare
#      shell (its CLI process crashed/exited without anyone noticing --
#      the T21 case) and FLAG orchestra via the inbox.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./dispatch.sh
source "$DIR/dispatch.sh"
# T33 (issue #77): shared color/clear-screen helpers for the dashboard
# board below. Colors and clearing auto-disable outside a tty, so this
# never changes what a redirected/piped invocation (tests, logs) prints.
# shellcheck source=./tui-lib.sh
source "$DIR/tui-lib.sh"

WATCH_INTERVAL="${WATCH_INTERVAL:-60}"
# issue #99: state files are per-repo, not per-checkout -- CANON_DIR (set by
# dispatch.sh's own harness-root.sh sourcing above) is the MAIN checkout's
# .harness, so these land in the same canonical place regardless of
# whether watch.sh happens to be running from inside a worktree.
MERGE_WATCH_STATE="${MERGE_WATCH_STATE:-$CANON_DIR/merge-watch-state}"
FLAGGED_DEAD_FILE="${WATCH_FLAGGED_DEAD_FILE:-$CANON_DIR/watch-flagged-dead}"
# T33: durable event log so the dashboard's EVENTS section can be cleared
# and redrawn every tick without losing history -- gitignored like
# budget.log, this is the "screen clears, file remembers" record.
EVENTS_LOG="${WATCH_EVENTS_LOG:-$CANON_DIR/events.log}"
# Agents expected to have a live CLI running in their pane per the control
# room layout (orc.sh). gatekeeper/watch itself are plain scripts, not
# interactive agents, so they're deliberately not liveness-checked here.
# scribe dropped (issue #89, T38): pane 3 is retired -- scribe is now an
# on-demand headless spawn (dispatch.sh assign/handoff), not a standing
# pane, so there's no persistent scribe pane left to flag as dead.
LIVENESS_AGENTS="${WATCH_LIVENESS_AGENTS:-orchestra builder agy}"

# we_log_event <message> -- appends a timestamped line to EVENTS_LOG. Used
# by merge-watch and pane-liveness so their findings survive the dashboard's
# clear-and-redraw instead of only ever existing on screen for one tick.
we_log_event() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$EVENTS_LOG"
}

# -- merge-watch ----------------------------------------------------------

# mw_fetch_merged_prs [limit] -- prints "<number><TAB><title-single-line><TAB>
# <body-single-line><TAB><head-branch>" for recently-merged PRs, one per
# line. Split out from merge_watch_check so tests can override this
# function with canned output instead of hitting the real GitHub API.
# limit defaults to 20 (merge_watch_check's own polling need); issue #18
# item 5's seed helper passes a much larger limit to capture this
# project's FULL merged-PR history on a fresh room, not just the last 20.
mw_fetch_merged_prs() {
  local limit="${1:-20}"
  gh pr list --state merged --limit "$limit" --json number,title,body,headRefName \
    --jq '.[] | [.number, (.title // "" | gsub("\n";" ")), (.body // "" | gsub("\n";" ")), .headRefName] | @tsv' 2>/dev/null
}

# mw_extract_issue <title+body text> -- prints the issue number from the
# first "Closes/Fixes/Resolves #N" match, or nothing if none found. T30
# (issue #56): PRs #49/#53 were silently skipped by merge-watch because
# their bodies referenced the issue only in the TITLE ("Issue #34" / no
# Closes verb at all) -- broadened to search title+body combined here
# rather than body alone. Retained for anything that only wants the first
# match; merge_watch_check itself uses mw_extract_all_issues below.
mw_extract_issue() {
  echo "$1" | grep -Eio '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -Eo '[0-9]+'
}

# mw_extract_all_issues <title+body text> -- prints EVERY distinct issue
# number referenced by a "Closes/Fixes/Resolves #N", one per line, in the
# order first seen. T31 (issue #68 item B): PR #66 had both "Closes #55"
# and "Closes #56" -- merge-watch only ever closed the first match (#55),
# leaving #56 for Ahmad to close by hand. No match at all still falls
# through to the branch-name fallback in merge_watch_check, same as before.
mw_extract_all_issues() {
  echo "$1" | grep -Eio '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | grep -Eo '[0-9]+' | awk '!seen[$0]++'
}

# mw_extract_issue_from_branch <head-branch> -- fallback when neither title
# nor body has a recognizable "Closes #N" reference: parse it straight out
# of the branch name, since every branch this harness creates follows
# orc-worktree.sh's feature/issue-<N> convention.
mw_extract_issue_from_branch() {
  echo "$1" | grep -Eo '^feature/issue-[0-9]+' | grep -Eo '[0-9]+'
}

mw_already_processed() {
  [ -f "$MERGE_WATCH_STATE" ] && grep -qxF "$1" "$MERGE_WATCH_STATE"
}

mw_mark_processed() {
  echo "$1" >> "$MERGE_WATCH_STATE"
}

# mw_close_issue <issue> <pr> -- comment+close the linked issue directly.
# Split out from merge_watch_check so tests can override this with a canned
# `gh` mock instead of hitting the real GitHub API. Non-fatal: a failed gh
# call (rate limit, network blip, already-closed) is reported to the caller
# via the return code but never aborts the merge-watch pass -- one bad `gh`
# call must not block processing of the rest of the merged-PR list.
mw_close_issue() {
  local issue="$1" pr="$2"
  gh issue comment "$issue" --body "Merged via PR #$pr." >/dev/null 2>&1 \
    && gh issue close "$issue" >/dev/null 2>&1
}

# mw_teardown_branch <issue> -- runs `orc-worktree.sh teardown <issue>` for
# the merged PR's own head-branch issue number, printing whatever it printed
# (its stdout+stderr becomes the honest reason for events.log on failure).
# Split out (like mw_fetch_merged_prs/mw_close_issue above) so tests can
# override this function directly instead of driving a real teardown
# subprocess -- orc-worktree.sh's teardown behavior itself already has its
# own dedicated test coverage in orc-worktree.test.sh.
mw_teardown_branch() {
  local issue="$1"
  bash "$DIR/orc-worktree.sh" teardown "$issue" 2>&1
}

# mw_notify_pick <pr> -- issue #105 (T44) Task 5: after merge-watch finishes
# processing a merged PR (close + teardown), NOTHING previously told
# Orchestra to PICK the next ticket -- the loop stalled until a human
# prodded pane 0 (observed live after both #102 and #103's merges). A
# durable dispatch (write + nudge-if-idle, same `assign` verb gatekeeper's
# alerts use) closes that gap mechanically. Split out so tests can override
# it directly instead of driving a real dispatch_main call.
mw_notify_pick() {
  local pr="$1"
  dispatch_main assign orchestra "$pr" "PR #$pr merged & processed -- PICK next per PHASE-3-PLAN" >/dev/null
}

# merge_watch_check -- one pass over currently-merged PRs, closing the
# linked issue mechanically for any not already processed (issue #85: this
# used to dispatch the scribe to do it, but the scribe session doesn't act
# on dispatched housekeeping, so the close never actually happened -- doing
# it inline here is mechanical and needs no agent in the loop). Marks every
# merged PR seen as processed (even with no linked issue found, or a failed
# close) so we never retry it again -- a PR without a recognizable
# "Closes #N" is a skip, not a pending retry, and a failed gh call is
# logged and moved past rather than retried forever. Also tears down the
# worktree/branch for the PR's own head branch (issue #85, Task 5) once the
# close is done -- gated on the head branch actually matching the
# feature/issue-<N> convention (a PR with no such branch has no worktree to
# tear down in the first place).
merge_watch_check() {
  local pr title body branch issues issue branch_issue td_out
  while IFS=$'\t' read -r pr title body branch; do
    [ -z "$pr" ] && continue
    mw_already_processed "$pr" && continue
    issues="$(mw_extract_all_issues "$title $body")"
    [ -z "$issues" ] && issues="$(mw_extract_issue_from_branch "$branch")"
    if [ -n "$issues" ]; then
      while IFS= read -r issue; do
        [ -z "$issue" ] && continue
        if mw_close_issue "$issue" "$pr"; then
          echo "watch.sh: merge-watch commented+closed issue #$issue (PR #$pr)"
          # Honest wording: we actually closed it ourselves here, unlike the
          # old "-> dispatched scribe" text which only ever recorded intent
          # (T23/#28: the dispatch went nowhere and the issue stayed open).
          we_log_event "PR #$pr merged -> commented+closed issue #$issue"
        else
          echo "watch.sh: merge-watch failed to close issue #$issue (PR #$pr), gh call failed -- check manually" >&2
          we_log_event "PR #$pr merged -> FAILED to close issue #$issue (gh error, check manually)"
        fi
      done <<< "$issues"
    else
      echo "watch.sh: merge-watch PR #$pr merged but no linked issue found in body, skipping"
      we_log_event "PR #$pr merged, no linked issue found"
    fi
    branch_issue="$(mw_extract_issue_from_branch "$branch")"
    if [ -n "$branch_issue" ]; then
      if td_out="$(mw_teardown_branch "$branch_issue")"; then
        echo "watch.sh: merge-watch removed worktree + merged branch for issue #$branch_issue (PR #$pr)"
        we_log_event "PR #$pr merged -> removed worktree + merged branch for issue #$branch_issue"
      else
        echo "watch.sh: merge-watch teardown skipped for issue #$branch_issue (PR #$pr): $td_out" >&2
        we_log_event "PR #$pr merged -> teardown skipped: $td_out"
      fi
    fi
    mw_notify_pick "$pr"
    mw_mark_processed "$pr"
  done <<< "$(mw_fetch_merged_prs)"
}

# -- pane liveness ----------------------------------------------------------

# pw_pane_is_dead <target> -- true if the pane has dropped back to a plain
# shell instead of the CLI process the control room launched there. This is
# a real, mechanically-checkable signal: orc.sh starts each agent pane with
# `claude ...`/`agy ...`/`copilot` directly, so if that process exits
# (crash, `exit`, an unhandled restart) the pane reverts to the underlying
# shell -- exactly the T21 case (a builder session died mid-ticket with no
# automated detection). It's deliberately NOT trying to distinguish a
# "fresh CLI splash with no task" from a genuinely idle CLI -- splash-screen
# text is tool/version-specific and fragile to match; "reverted to a shell"
# is the one signal that's stable across tool versions.
pw_pane_is_dead() {
  local target="$1" cmd
  cmd="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || echo '')"
  case "$cmd" in
    ""|bash|zsh|sh|fish) return 0 ;;
    *) return 1 ;;
  esac
}

# pane_liveness_check -- flags each dead agent pane exactly once (tracked in
# FLAGGED_DEAD_FILE so it doesn't spam on every loop iteration), and clears
# the flag once the pane is alive again so a future death re-alerts.
# orchestra's own death can't be nudged (nobody to nudge), so it's recorded
# via the "message" verb instead of "assign" -- a durable inbox note
# orchestra will see on restart, with no nudge attempted into a dead pane.
pane_liveness_check() {
  local agent target
  for agent in $LIVENESS_AGENTS; do
    target="$(pane_for_agent "$agent")"
    [ -z "$target" ] && continue
    tmux has-session -t "${target%%:*}" 2>/dev/null || continue

    if pw_pane_is_dead "$target"; then
      if ! grep -qxF "$agent" "$FLAGGED_DEAD_FILE" 2>/dev/null; then
        echo "$agent" >> "$FLAGGED_DEAD_FILE"
        if [ "$agent" = "orchestra" ]; then
          dispatch_main message orchestra liveness \
            "FLAG: this orchestra pane looks dead (dropped to a plain shell). If you're reading this after a restart, check what happened before it." >/dev/null
        else
          dispatch_main assign orchestra liveness \
            "FLAG: pane '$agent' ($target) looks dead -- dropped to a plain shell, no CLI running. Investigate/restart." >/dev/null
        fi
        echo "watch.sh: pane-liveness FLAGGED $agent ($target) as dead"
        we_log_event "FLAGGED $agent ($target) as dead"
      fi
    elif [ -f "$FLAGGED_DEAD_FILE" ] && grep -qxF "$agent" "$FLAGGED_DEAD_FILE"; then
      # grep -v exits 1 (its "no match" status) when the result is empty --
      # e.g. clearing the last/only flagged agent -- so the `|| true` here
      # is load-bearing: without it, `&&`-gating the mv on grep's exit
      # status would silently skip clearing the very last entry.
      grep -vxF "$agent" "$FLAGGED_DEAD_FILE" > "$FLAGGED_DEAD_FILE.tmp" || true
      mv "$FLAGGED_DEAD_FILE.tmp" "$FLAGGED_DEAD_FILE"
      we_log_event "$agent pane alive again, cleared dead flag"
    fi
  done
}

# -- main loop ----------------------------------------------------------

# watch_render (T33, issue #77) -- clears the pane and redraws the fixed
# board: PRs / DEFERRED NUDGES / PANE LIVENESS / EVENTS. Display-layer
# only -- every section reads from a file that already persists the data
# (merge-watch's own EVENTS_LOG, the deferred-nudge queue, the flagged-dead
# file), so clearing the screen each tick loses nothing.
watch_render() {
  tui_clear
  echo "$(tui_bold "Watch") -- $(date '+%Y-%m-%d %H:%M:%S') (interval ${WATCH_INTERVAL}s)"
  echo ""
  echo "$(tui_section PRs)"
  if grep -q 'PR #' "$EVENTS_LOG" 2>/dev/null; then
    grep 'PR #' "$EVENTS_LOG" | tail -5 | sed 's/^/  /'
  else
    echo "  (none processed yet)"
  fi
  echo ""
  echo "$(tui_section "DEFERRED NUDGES")"
  if [ -s "$DEFERRED_FILE" ]; then
    sed 's/^/  /' "$DEFERRED_FILE"
  else
    echo "  (empty)"
  fi
  echo ""
  echo "$(tui_section "PANE LIVENESS")"
  if [ -s "$FLAGGED_DEAD_FILE" ]; then
    sed 's/^/  DEAD: /' "$FLAGGED_DEAD_FILE"
  else
    echo "  all agents alive"
  fi
  echo ""
  echo "$(tui_section EVENTS)"
  if [ -f "$EVENTS_LOG" ] && [ -s "$EVENTS_LOG" ]; then
    tail -10 "$EVENTS_LOG" | sed 's/^/  /'
  else
    echo "  (no events yet)"
  fi
}

watch_main() {
  echo "watch.sh active (interval ${WATCH_INTERVAL}s)"
  while true; do
    merge_watch_check
    retry_deferred_nudges
    pane_liveness_check

    watch_render

    sleep "$WATCH_INTERVAL"
  done
}

# Guard so this file can be sourced (for tests -- merge_watch_check,
# pane_liveness_check, etc.) without running the infinite loop as a side
# effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  watch_main
fi
