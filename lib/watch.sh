#!/bin/bash
# .harness/watch.sh — pane-5 watch loop. Replaces the old
# ad-hoc `watch -n 60 "gh pr list ...; tail budget.log"` command in
# orc.sh's control room build. Keeps that same human-facing display, and
# adds three background housekeeping jobs Ahmad asked for:
#
#   1. merge-watch: poll gh for newly-merged PRs and comment+close the
#      linked issue directly (mechanical `gh issue comment`+`gh issue
#      close`, no agent dispatch -- issue #85: dispatching the scribe for
#      this never actually got the issue closed since the scribe session
#      doesn't act on dispatched housekeeping), then tear down that PR's
#      worktree + merged branch via `orc-worktree.sh teardown` (issue #85,
#      Task 5), then dispatch a durable "PICK next" nudge to Orchestra
#      (closes the loop-continuity gap where nothing
#      told Orchestra to move on after a merge). Guard rules unchanged
#      elsewhere: this script never merges.
#   2. broker (issue #125, lib/broker.sh): the delivery layer -- verifies
#      every dispatch by its .ack, wakes idle receivers (ground-truth
#      hook state, never a screen guess), holds delivery for parked
#      (failsafe) panes, escalates unresponsive ones, archives acked
#      messages and prunes/rotates history. Replaces the old
#      deferred-nudge retry queue (the #118 failure class).
#   3. pane-liveness: detect an agent pane that has dropped back to a bare
#      shell (its CLI process crashed/exited without anyone noticing)
#      and FLAG orchestra via the inbox.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./dispatch.sh
source "$DIR/dispatch.sh"
# Shared color/clear-screen helpers for the dashboard
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
# Durable event log so the dashboard's EVENTS section can be cleared
# and redrawn every tick without losing history -- gitignored like
# budget.log, this is the "screen clears, file remembers" record.
EVENTS_LOG="${WATCH_EVENTS_LOG:-$CANON_DIR/events.log}"
# Agents expected to have a live CLI running in their pane per the control
# room layout (orc.sh). gatekeeper/watch itself are plain scripts, not
# interactive agents, so they're deliberately not liveness-checked here.
# scribe dropped: pane 3 is retired -- scribe is now an
# on-demand headless spawn (dispatch.sh assign/handoff), not a standing
# pane, so there's no persistent scribe pane left to flag as dead.
LIVENESS_AGENTS="${WATCH_LIVENESS_AGENTS:-orchestra builder agy}"
# issue #134: stuck/long-running detection for the same agent panes
# liveness already watches. Ground truth is each pane's OWN pane-state
# file (busy-age = now minus that file's last recorded transition, see
# lib/pane-state-lib.sh's pane_state_age) -- no separate polling loop,
# just read at broker cadence alongside pane_liveness_check.
STUCK_STATE_FILE="${WATCH_STUCK_STATE_FILE:-$CANON_DIR/stuck-check-state.json}"
# 45 minutes, matching the ticket's own default (#134). Only ever change
# together with a real consumer -- no decorative config knobs (#86
# precedent) -- so this is env-overridable for tests, not a new
# orchestrator.yaml key.
STUCK_THRESHOLD_S="${WATCH_STUCK_THRESHOLD_S:-2700}"

# we_log_event <message> -- appends a timestamped line to EVENTS_LOG. Used
# by merge-watch and pane-liveness so their findings survive the dashboard's
# clear-and-redraw instead of only ever existing on screen for one tick.
we_log_event() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$EVENTS_LOG"
}

# issue #125: delivery layer. Sourced AFTER dispatch.sh (CANON_DIR,
# pane_for_agent, pane_state_read, send_submit) and we_log_event above.
# shellcheck source=./broker.sh
source "$DIR/broker.sh"

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
# first "Closes/Fixes/Resolves #N" match, or nothing if none found. PRs
# #49/#53 were silently skipped by merge-watch because
# their bodies referenced the issue only in the TITLE ("Issue #34" / no
# Closes verb at all) -- broadened to search title+body combined here
# rather than body alone. Retained for anything that only wants the first
# match; merge_watch_check itself uses mw_extract_all_issues below.
mw_extract_issue() {
  echo "$1" | grep -Eio '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -1 | grep -Eo '[0-9]+'
}

# mw_extract_all_issues <title+body text> -- prints EVERY distinct issue
# number referenced by a "Closes/Fixes/Resolves #N", one per line, in the
# order first seen. PR #66 had both "Closes #55"
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

# mw_dev_target_root -- (#47) optional override for orc-worktree.sh's
# REPO_ROOT resolution. watch.sh runs from wherever its OWN pane's cwd is
# (the harness root, per orc.sh's pane launch -- no `cd` of its own), and
# orc-worktree.sh defaults to inferring REPO_ROOT from ITS caller's $PWD.
# For a normal (non-nested) consumer those are the same repo and nothing
# needs to change; a self-dogfood room like this one nests the actual dev
# target in a SEPARATE clone (e.g. project/agent-orchestra/), and inferring
# from $PWD silently resolved to the wrong repo -- the root cause of #47's
# false "removed worktree + merged branch" receipts. ORC_WORKTREE_REPO_ROOT
# in the environment wins outright (matches orc-worktree.sh's own existing
# override); otherwise reads an OPTIONAL orchestrator.yaml `dev_target_root`
# key. Neither set -> empty, and mw_teardown_branch below falls back to
# orc-worktree.sh's unchanged $PWD-based default, exactly as before.
mw_dev_target_root() {
  # `${VAR+x}` (existence) rather than `${VAR:-}` (existence-or-empty): an
  # explicitly-exported EMPTY ORC_WORKTREE_REPO_ROOT is a deliberate "don't
  # override" signal from whoever set it, distinct from never having set it
  # at all -- checked precisely so it still short-circuits the config-key
  # fallback below, per agy's dedicated security pass on PR #65.
  if [ -n "${ORC_WORKTREE_REPO_ROOT+x}" ]; then
    echo "$ORC_WORKTREE_REPO_ROOT"
    return 0
  fi
  orc_get_scalar dev_target_root
}

# mw_teardown_branch <issue> -- runs `orc-worktree.sh teardown <issue>` for
# the merged PR's own head-branch issue number, printing whatever it printed
# (its stdout+stderr becomes the honest reason for events.log on failure).
# Split out (like mw_fetch_merged_prs/mw_close_issue above) so tests can
# override this function directly instead of driving a real teardown
# subprocess -- orc-worktree.sh's teardown behavior itself already has its
# own dedicated test coverage in orc-worktree.test.sh.
mw_teardown_branch() {
  local issue="$1" dev_root
  dev_root="$(mw_dev_target_root)"
  if [ -n "$dev_root" ]; then
    ORC_WORKTREE_REPO_ROOT="$dev_root" bash "$DIR/orc-worktree.sh" teardown "$issue" 2>&1
  else
    bash "$DIR/orc-worktree.sh" teardown "$issue" 2>&1
  fi
}

# mw_notify_pick <pr> -- after merge-watch finishes
# processing a merged PR (close + teardown), NOTHING previously told
# Orchestra to PICK the next ticket -- the loop stalled until a human
# prodded pane 0 (observed live after both #102 and #103's merges). A
# durable dispatch (write + nudge-if-idle, same `assign` verb gatekeeper's
# alerts use) closes that gap mechanically. Split out so tests can override
# it directly instead of driving a real dispatch_main call.
#
# #49 (bonus, picked up alongside #47): the old message pointed at a named
# plan document that never existed in this project -- career-ops-harness
# vocabulary carried over by copy-paste, and tests/watch.test.sh used to
# actively PIN that ghost wording. Points at the two durable sources that
# actually exist instead.
mw_notify_pick() {
  local pr="$1"
  dispatch_main assign orchestra "$pr" "PR #$pr merged & processed -- PICK next per handoff.md / decisions.log" >/dev/null
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
          # (the dispatch went nowhere and the issue stayed open).
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

# -- review-watch ----------------------------------------------------------
# issue #96: a reviewer's PR comment must not be the ONLY delivery path for
# its verdict. Live-confirmed: agy posted a proper APPROVE on PR #95 (full
# security pass, probe list, the works) but never ran the push-back
# dispatch the review template tells it to -- Builder never learned the
# verdict, never ran `gh pr ready`, and the PR sat draft for two hours
# until Ahmad noticed by hand. Same #85 lesson: don't depend on an agent
# to relay a mechanical step; have the harness observe and act.
REVIEW_WATCH_STATE="${REVIEW_WATCH_STATE:-$CANON_DIR/review-watch-state}"

# rw_fetch_open_draft_prs -- prints "<number>\t<title>\t<body>\t<headRefName>"
# for every OPEN, DRAFT PR, one per line. Filtered in jq (`select(.isDraft)`)
# rather than relying solely on gh's own `--draft` CLI flag, so the filter
# is exercised the same way whether real `gh` or a test's canned JSON is
# behind it. Split out so tests can mock `gh` instead of hitting the real
# API -- same pattern as mw_fetch_merged_prs. Scoping the fetch to OPEN+
# DRAFT is also the race-safety mechanism for "already ready" / "already
# merged" (issue #96's own no-op requirement): a PR Orchestra has already
# flipped ready (Gate-2-waived sessions do this directly) or merged simply
# stops appearing here on the next tick -- no separate state check needed,
# the same structural guarantee merge_watch_check relies on for "already
# merged".
#
# BOUNDARY (review round 2, agy finding 2): this scope cuts both ways. A
# REQUEST-CHANGES comment posted AFTER a PR has already gone ready is
# deliberately never delivered -- the PR no longer matches open+draft, so
# it simply isn't in this list. This is in-protocol, not an oversight: a
# PR only ever goes ready via this same script's own APPROVE branch, and
# from that point on it's human-bound (Gate 2), not draft-review-loop-
# bound -- there is no "reject an already-ready PR back to draft" state
# in AGENTS.md's flow for review-watch to observe or act on.
rw_fetch_open_draft_prs() {
  gh pr list --state open --json number,title,body,headRefName,isDraft \
    --jq '.[] | select(.isDraft) | [.number, (.title // "" | gsub("\n";" ")), (.body // "" | gsub("\n";" ")), .headRefName] | @tsv' 2>/dev/null
}

# rw_fetch_pr_comments <pr> -- prints "<createdAt>\t<body, newlines -> a
# literal U+0001 (SOH)>" per comment, one per line, in gh's own
# (chronological, oldest-first) order -- verified empirically against a
# real reviewed PR before writing this. The SOH byte stands in for a real
# newline so a multi-line comment body still survives the TSV/line-based
# pipeline intact; rw_latest_verdict restores it (`tr '\001' '\n'`) before
# anchoring the match -- this is what makes the anchor apply to the
# comment's TRUE first line only, not a flattened whole-body string a
# later line's own "APPROVE:"/"REQUEST-CHANGES:" prefix could otherwise
# be mistaken to start.
#
# review round 2 (agy, PR #111 finding 1): built via jq's own `([1] |
# implode)` (an array containing the integer codepoint 1, turned into a
# 1-character string at RUNTIME) rather than a jq string-escape spelling
# of that same codepoint, or a raw control byte typed directly into this
# file -- both of the latter render as invisible/empty in ordinary text
# tools (confirmed live: it fooled a source read AND a code review, both
# reported the sentinel as silently missing when a raw byte was actually
# sitting there and working correctly). `implode` keeps this script's own
# source 100% printable ASCII with identical runtime behavior, so nothing
# here is invisible to a diff, an editor, or the next reader. Split out
# for the same reason as mw_fetch_merged_prs.
rw_fetch_pr_comments() {
  gh pr view "$1" --json comments \
    --jq '.comments[] | [.createdAt, (.body | gsub("\n"; ([1] | implode)))] | @tsv' 2>/dev/null
}

# rw_latest_verdict <pr> -- prints "APPROVE" or "REQUEST-CHANGES" for the
# MOST RECENT comment whose body starts with that literal word, colon,
# ANCHORED (review-protocol.md's own format) -- never a substring match
# anywhere in prose, so "I approve of this approach" or a verdict word
# buried mid-sentence never counts. Iterates ALL comments in order and
# keeps overwriting the result on each match, so the LAST (most recent)
# match naturally wins with no separate sort needed. Prints nothing if no
# comment matches at all -- still under review, or every comment is
# prose/ambiguous -- the caller treats that as "nothing to deliver yet",
# never guessing at an unanchored comment.
rw_latest_verdict() {
  local pr="$1" created body verdict=""
  while IFS=$'\t' read -r created body; do
    [ -z "$body" ] && continue
    body="$(printf '%s' "$body" | tr '\001' '\n')"
    case "$body" in
      "APPROVE:"*) verdict="APPROVE" ;;
      "REQUEST-CHANGES:"*) verdict="REQUEST-CHANGES" ;;
    esac
  done <<< "$(rw_fetch_pr_comments "$pr")"
  echo "$verdict"
}

# rw_already_delivered <pr> -- prints the LAST verdict delivered for this
# PR ("APPROVE"/"REQUEST-CHANGES"), or nothing if never delivered.
# Append-only state file (same file discipline as MERGE_WATCH_STATE) --
# `tail -1` on the matching lines means a later rw_mark_delivered call for
# the same PR naturally supersedes an earlier one with no rewrite/prune
# needed.
rw_already_delivered() {
  [ -f "$REVIEW_WATCH_STATE" ] && grep "^$1 " "$REVIEW_WATCH_STATE" 2>/dev/null | tail -1 | cut -d' ' -f2
}

rw_mark_delivered() {
  echo "$1 $2" >> "$REVIEW_WATCH_STATE"
}

# rw_notify <agent> <issue> <message> -- split out so tests can override
# this ONE function instead of the real dispatch_main (which would attempt
# a real inbox write + pane nudge) -- same pattern as mw_notify_pick.
rw_notify() {
  dispatch_main assign "$1" "$2" "$3" >/dev/null
}

# review_watch_check -- one pass over every OPEN DRAFT PR: find its latest
# anchored verdict comment (if any), and if it DIFFERS from what was last
# delivered for that PR, deliver it. "Differs", not "has never been
# delivered": idempotent per DISTINCT verdict, not merely per PR -- a
# re-tick with the SAME verdict already delivered is silently skipped, but
# a PR that moves from an earlier REQUEST-CHANGES to a LATER APPROVE (the
# normal fix-loop shape) delivers that new APPROVE too. "Latest verdict
# wins", not "first verdict wins".
#   APPROVE: `gh pr ready` -- the ONLY state flip this script may ever
#     make (guard rule, same as merge_watch_check never merging) -- plus a
#     durable dispatch to BOTH builder and orchestra so AGENTS.md's
#     APPROVE branch proceeds without either of them polling for it.
#   REQUEST-CHANGES: a durable dispatch to builder only, no ready flip --
#     the PR stays draft through the fix loop.
# A PR with comments but no anchored match at all is logged once per tick
# (not per comment) as ambiguous/malformed and skipped -- never guessed at.
review_watch_check() {
  local pr title body branch issue verdict delivered
  while IFS=$'\t' read -r pr title body branch; do
    [ -z "$pr" ] && continue
    issue="$(mw_extract_all_issues "$title $body" | head -1)"
    [ -z "$issue" ] && issue="$(mw_extract_issue_from_branch "$branch")"
    if [ -z "$issue" ]; then
      echo "watch.sh: review-watch PR #$pr is draft but has no resolvable issue (no Closes/Fixes/Resolves, no feature/issue-N branch) -- skipping" >&2
      continue
    fi

    verdict="$(rw_latest_verdict "$pr")"
    if [ -z "$verdict" ]; then
      if [ -n "$(rw_fetch_pr_comments "$pr")" ]; then
        echo "watch.sh: review-watch PR #$pr (issue #$issue) has comments but none match the APPROVE:/REQUEST-CHANGES: format -- skipping, not guessing" >&2
      fi
      continue
    fi

    delivered="$(rw_already_delivered "$pr")"
    [ "$verdict" = "$delivered" ] && continue

    case "$verdict" in
      APPROVE)
        gh pr ready "$pr" >/dev/null 2>&1
        rw_notify builder "$issue" "PR #$pr APPROVED by reviewer -- marked ready; proceed with Gate-2 handoff."
        rw_notify orchestra "$issue" "PR #$pr (issue #$issue) APPROVED by reviewer and marked ready."
        echo "watch.sh: review-watch delivered APPROVE for PR #$pr (issue #$issue) -- marked ready, notified builder+orchestra"
        we_log_event "PR #$pr (issue #$issue) APPROVED -> marked ready, notified builder+orchestra"
        ;;
      REQUEST-CHANGES)
        rw_notify builder "$issue" "PR #$pr (issue #$issue): reviewer requested changes -- see the PR comment for details, fix in the same worktree and re-assign the reviewer when done."
        echo "watch.sh: review-watch delivered REQUEST-CHANGES for PR #$pr (issue #$issue) -- notified builder"
        we_log_event "PR #$pr (issue #$issue) REQUEST-CHANGES -> notified builder"
        ;;
    esac
    rw_mark_delivered "$pr" "$verdict"
  done <<< "$(rw_fetch_open_draft_prs)"
}

# -- pane liveness ----------------------------------------------------------

# pw_pane_is_dead <target> -- true if the pane has dropped back to a plain
# shell instead of the CLI process the control room launched there. This is
# a real, mechanically-checkable signal: orc.sh starts each agent pane with
# `claude ...`/`agy ...`/`copilot` directly, so if that process exits
# (crash, `exit`, an unhandled restart) the pane reverts to the underlying
# shell -- exactly this case (a builder session died mid-ticket with no
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
      # issue #125: a dead pane's last hook-written state is a lie -- clear
      # it (every pass, not just the first flag) so terminal states can
      # persist without an age-out; the broker/nudge gating must never
      # trust a crashed pane's stale 'busy'/'idle'.
      pw_dead_pane_id="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || echo '')"
      [ -n "$pw_dead_pane_id" ] && pane_state_clear "$pw_dead_pane_id"
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

# -- stuck / long-running pane detection (issue #134) --------------------

# wsc_hash_pane <target> -- a cheap, deterministic digest of what's
# currently on screen, used only to detect "has this pane's terminal
# output changed since the last check" -- never anything security-
# sensitive. `cksum` (not md5/md5sum/shasum) is POSIX and ships identically
# on both BSD (macOS) and GNU (Linux CI) with no flag differences to
# reconcile -- the exact BSD/GNU split the ticket flagged, sidestepped by
# not needing md5 at all. Hashes are only ever compared within the SAME
# running watch.sh process, so cross-machine digest-format stability
# (cksum's actual portability gap) is irrelevant here.
wsc_hash_pane() {
  tmux capture-pane -p -t "$1" 2>/dev/null | cksum
}

wsc_ensure_state_file() {
  [ -f "$STUCK_STATE_FILE" ] || echo '{}' > "$STUCK_STATE_FILE"
}

wsc_read() { # jq args, e.g. --arg a "$agent" '.[$a].flagged // false'
  wsc_ensure_state_file
  jq -r "$@" "$STUCK_STATE_FILE"
}

wsc_write() { # jq args, filter transforms current state -> new state
  wsc_ensure_state_file
  local tmp
  tmp="$(mktemp "${STUCK_STATE_FILE}.XXXXXX")" || return 1
  jq "$@" "$STUCK_STATE_FILE" > "$tmp" && mv "$tmp" "$STUCK_STATE_FILE"
}

# pane_stuck_check -- complementary to pane_liveness_check: that catches a
# pane DYING (dropped to a plain shell); this catches one that's alive but
# hung, retry-looping, or just burning quota unattended for a very long
# stretch (Ahmad's overnight ask, #134). NEVER auto-kills or auto-
# interrupts -- this only ever flags Orchestra, who decides.
#
# Per busy pane over STUCK_THRESHOLD_S: needs TWO consecutive over-
# threshold observations before flagging at all -- the first merely
# records a baseline screen hash (there's nothing to compare yet), the
# second classifies by comparing hashes: unchanged -> "looping/stuck"
# (upgrade), changed -> "long-running" (still just busy, screen is moving).
# Exactly ONE flag fires per busy EPISODE (tracked in STUCK_STATE_FILE,
# keyed by agent) -- a pane that flips away from busy (idle/failsafe, or
# dies and pane_liveness_check clears its state) ends the episode and
# clears tracking, so a later busy stretch can flag again.
pane_stuck_check() {
  local agent target pane_id state age
  for agent in $LIVENESS_AGENTS; do
    target="$(pane_for_agent "$agent")"
    [ -z "$target" ] && continue
    tmux has-session -t "${target%%:*}" 2>/dev/null || continue
    pane_id="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || echo '')"
    [ -z "$pane_id" ] && continue
    state="$(pane_state_effective "$pane_id" 2>/dev/null || echo '')"

    if [ "$state" != "busy" ]; then
      # Episode over (or never started) -- drop any tracking so the next
      # busy stretch starts clean. agy PR #136 round 1: only write if this
      # agent is ACTUALLY tracked -- jq's `del` on a missing key is a
      # harmless no-op, but wsc_write still does a full mktemp+jq+mv every
      # call, and this branch runs for every idle agent on every watch
      # tick. An unconditional call here means constant disk churn while
      # the room is simply idle, for zero effect.
      if [ "$(wsc_read --arg a "$agent" 'has($a)')" = "true" ]; then
        wsc_write --arg a "$agent" 'del(.[$a])'
      fi
      continue
    fi

    age="$(pane_state_age "$pane_id" 2>/dev/null || echo '')"
    case "$age" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$age" -lt "$STUCK_THRESHOLD_S" ] && continue

    local already_flagged prev_hash cur_hash
    already_flagged="$(wsc_read --arg a "$agent" '.[$a].flagged // false')"
    if [ "$already_flagged" = "true" ]; then
      continue
    fi

    prev_hash="$(wsc_read --arg a "$agent" '.[$a].hash // empty')"
    cur_hash="$(wsc_hash_pane "$target")"

    if [ -z "$prev_hash" ]; then
      # First over-threshold observation this episode: not enough data to
      # classify yet -- record the baseline, wait for the next check.
      wsc_write --arg a "$agent" --arg h "$cur_hash" '.[$a] = {flagged: false, hash: $h}'
      continue
    fi

    local minutes kind changed_desc
    minutes=$(( age / 60 ))
    if [ "$cur_hash" = "$prev_hash" ]; then
      kind="looping/stuck"
      changed_desc="unchanged"
    else
      kind="long-running"
      changed_desc="changed"
    fi

    local tail msg
    tail="$(tmux capture-pane -p -t "$target" 2>/dev/null | tail -5)"
    msg="FLAG: STUCK?: pane '${agent}' busy ${minutes}m, classified ${kind} (screen ${changed_desc} since the last check). Tail:
${tail}"
    if [ "$agent" = "orchestra" ]; then
      dispatch_main message orchestra stuck "$msg" >/dev/null
    else
      dispatch_main assign orchestra stuck "$msg" >/dev/null
    fi
    wsc_write --arg a "$agent" --arg h "$cur_hash" '.[$a] = {flagged: true, hash: $h}'
    we_log_event "FLAGGED $agent as STUCK? (${kind}, busy ${minutes}m)"
  done
}

# -- main loop ----------------------------------------------------------

# watch_pane_lines -- how many rows watch_render has to work with.
# WATCH_PANE_LINES overrides outright (tests: deterministic sizing without
# a real controlling tty); otherwise `tput lines` when stdout is a real
# tty, else a sane fixed fallback (the monitor strip's own row count --
# see bin/orc's monitor_rows) for a non-tty invocation (piped/redirected).
watch_pane_lines() {
  if [ -n "${WATCH_PANE_LINES:-}" ]; then
    echo "$WATCH_PANE_LINES"
  elif [ -t 1 ]; then
    tput lines 2>/dev/null || echo 14
  else
    echo 14
  fi
}

# watch_render -- clears the pane and redraws a compact 1-line header
# (interval + nudge count + liveness summary) followed by an ADAPTIVE
# EVENTS tail that fills whatever rows are left (issue #120: the old
# 4-section fixed frame was ~26 lines tall -- taller than any realistic
# monitor strip, so the header/PRs/liveness sections scrolled off and only
# EVENTS ever showed). PR lines are already appended to EVENTS_LOG by
# merge_watch_check, so they fold into the EVENTS tail instead of getting
# their own section. NUDGE:/DEAD: lines list the actual pending agents
# (rare + important, per the no-silent-caps rule) and are omitted entirely
# when both counts are zero. Display-layer only -- every value here reads
# from a file that already persists the data, so clearing the screen each
# tick loses nothing.
watch_render() {
  tui_clear
  local pending_count=0 dead_count=0 dyn_lines=0 dead_str
  [ -s "$BROKER_PENDING_LIST" ] && pending_count="$(wc -l < "$BROKER_PENDING_LIST" | tr -d ' ')"
  [ -s "$FLAGGED_DEAD_FILE" ] && dead_count="$(wc -l < "$FLAGGED_DEAD_FILE" | tr -d ' ')"
  if [ "$dead_count" -eq 0 ]; then
    dead_str="all alive"
  else
    dead_str="${dead_count} dead"
  fi
  # Header carries the ground-truth agent states (issue #125: liveness AND
  # state, so a parked pane reads 'failsafe', never confused with dead).
  echo "Watch $(date '+%H:%M:%S')  ${WATCH_INTERVAL}s | $(broker_states_summary) | pending ${pending_count} | ${dead_str}"
  echo ""
  if [ "$pending_count" -gt 0 ]; then
    sed 's/^/PENDING: /' "$BROKER_PENDING_LIST"
    dyn_lines=$(( dyn_lines + pending_count ))
  fi
  if [ "$dead_count" -gt 0 ]; then
    sed 's/^/DEAD: /' "$FLAGGED_DEAD_FILE"
    dyn_lines=$(( dyn_lines + dead_count ))
  fi

  local pane_lines events_budget total_events shown events_shown_cap
  # Ahmad-configurable display cap (orchestrator.yaml `watch: events_shown`,
  # default 5); WATCH_EVENTS_SHOWN env overrides for tests.
  events_shown_cap="${WATCH_EVENTS_SHOWN:-$(orc_get_nested watch events_shown)}"
  events_shown_cap="${events_shown_cap:-5}"
  pane_lines="$(watch_pane_lines)"
  # issue #124: -3, not -2 -- header + blank separator + the cursor row the
  # final newline scrolls onto. The old budget was off by one the moment
  # the frame exactly filled the pane, which pushed the header off-screen
  # precisely when PENDING/DEAD lines were present.
  events_budget=$(( pane_lines - 3 - dyn_lines ))
  [ "$events_budget" -lt 0 ] && events_budget=0
  [ "$events_budget" -gt "$events_shown_cap" ] && events_budget="$events_shown_cap"
  total_events=0
  [ -f "$EVENTS_LOG" ] && total_events="$(wc -l < "$EVENTS_LOG" | tr -d ' ')"

  if [ "$total_events" -eq 0 ]; then
    echo "(no events yet)"
  elif [ "$total_events" -gt "$events_budget" ] && [ "$events_budget" -gt 0 ]; then
    shown=$(( events_budget - 1 ))
    [ "$shown" -lt 0 ] && shown=0
    echo "(last ${shown} of ${total_events})"
    tail -"$shown" "$EVENTS_LOG" | sed 's/^/  /'
  else
    tail -"$events_budget" "$EVENTS_LOG" | sed 's/^/  /'
  fi
}

watch_main() {
  echo "watch.sh active (interval ${WATCH_INTERVAL}s)"
  while true; do
    merge_watch_check
    review_watch_check
    broker_translate_agy_state
    broker_check
    pane_liveness_check
    pane_stuck_check

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
