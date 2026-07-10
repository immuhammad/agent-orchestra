#!/bin/bash
# .harness/dispatch.sh <verb> <agent> <issue> <msg> [timeout_s]
#
# Three-verb file-inbox dispatch for ALL agents (orchestra, builder, agy,
# copilot) -- replaces tmux-team/tmt (T17, Q1). A message is always a
# durable file (.harness/inbox/<agent>/<ts>-<issue>.msg); a receiver
# acknowledges by writing the matching .ack next to it.
#
#   handoff  -- write .msg, nudge if idle, then POLL for the matching .ack,
#               bounded by timeout_s (default 120). Use when you must block
#               on the result (e.g. a synchronous review-and-report).
#   assign   -- write .msg, nudge if idle, return immediately. No wait.
#               Use for fire-and-forget work (e.g. a reviewer handover).
#   message  -- write .msg only. No nudge, no ack expected. Use for FYI
#               notes the receiver will pick up on its own schedule.
#
# This script only ever touches its OWN pane's tmux target when nudging a
# DIFFERENT agent's pane -- never call `dispatch.sh <verb> <your-own-agent>`
# from inside that agent's own pane, since a self-nudge types into your own
# live input.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./send-lib.sh
source "$DIR/send-lib.sh"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# issue #99: inbox/deferred-nudges are per-repo STATE, not per-checkout --
# every worktree has its own gitignored .harness/inbox, so a dispatch run
# from inside a worktree must still land in the MAIN checkout's inbox, not
# the worktree's own empty copy. CANON_DIR is that canonical .harness dir
# (falls back to DIR itself outside a git repo, e.g. some test setups).
CANON_DIR="${DISPATCH_CANON_DIR:-$(harness_canonical_dir "$DIR")}"

# T24 (issue #34): deferred nudges used to be fire-and-forget -- if a nudge
# was skipped because the target pane was busy, nothing ever retried it, so
# every busy-pane dispatch (copilot's, in practice) needed a manual
# re-nudge. This file is a durable queue of agent names whose last nudge
# was deferred; watch.sh's retry_deferred_nudges() drains it on each loop
# iteration. DISPATCH_DEFERRED_FILE overrides the path (tests use this to
# avoid touching the real queue).
DEFERRED_FILE="${DISPATCH_DEFERRED_FILE:-$CANON_DIR/deferred-nudges}"

# issue #105: which tmux session pane_for_agent targets. Overridable so a
# caller that's NOT a human at the real control room (gatekeeper.sh's
# quota-crossing alerts, tests) can redirect every pane target to a
# throwaway session instead -- without this, gatekeeper.sh's own
# session-isolation override (GATEKEEPER_NOTIFY_SESSION) had no effect on
# dispatch-routed alerts, since pane_for_agent hardcoded "harness"
# regardless (found writing this ticket's own tests: a real 80%+ crossing
# during a test run would have nudged the REAL harness:0.0 pane).
DISPATCH_SESSION="${DISPATCH_SESSION:-harness}"

# Pane map (see AGENTS.md Dispatch Protocol): tmux session $DISPATCH_SESSION
# (production: "harness"), window 0, tiled. Agents without a live pane in
# the orc.sh layout (or an unmapped/typo'd name) just don't get nudged --
# the .msg is still written and will be picked up whenever the receiver
# polls its inbox. scribe/copilot deliberately have NO entry here (issue
# #89: pane 3 retired) -- dispatch_main special-cases them to
# scribe_spawn_headless before pane_for_agent/nudge_agent are ever
# consulted, so falling through to the empty-mapping default here is
# correct, not a gap.
pane_for_agent() {
  case "$1" in
    orchestra) echo "$DISPATCH_SESSION:0.0" ;;
    builder)   echo "$DISPATCH_SESSION:0.1" ;;
    agy)       echo "$DISPATCH_SESSION:0.2" ;;
    *)         echo "" ;;
  esac
}

# inbox_dir_name <agent> -- resolves the on-disk inbox directory for an
# agent name. `scribe` is the current display name (issue #89), but its
# real inbox history (including the suspect-ack cleanup from #89's own
# scope) lives under the original `copilot` directory -- renaming the
# directory would fragment that history, so both names deliberately
# resolve to the SAME physical inbox instead.
inbox_dir_name() {
  case "$1" in
    scribe) echo "copilot" ;;
    *)      echo "$1" ;;
  esac
}

# pane_busy_markers <agent> -- per-agent/per-TUI busy vocabulary (issue #86
# Task 3, finding 3). Claude Code's own TUI vocabulary (thinking/esc to
# interrupt/compacting/generating/running...) doesn't cover agy's real busy
# rendering -- live-confirmed 2026-07-10: agy renders `⣟ Working...` with
# its bare `>` prompt still visible underneath, so with only the Claude-Code
# words the busy check missed it entirely (false-IDLE -> a nudge's
# keystrokes got injected mid-generation and lost). scribe/copilot never
# reach this function in practice (issue #89: they're spawned headless, not
# pane-nudged), kept in the widened branch anyway in case anything ever
# calls pane_is_idle for them directly; an unknown/unmapped agent falls back
# to the Claude-Code-only list (err-toward-busy: an agent this function
# doesn't recognize is exactly the case to be MORE conservative for, not
# less, so the extra 'working' word is added rather than omitted --
# false-busy just delays a nudge, false-idle loses one).
pane_busy_markers() {
  case "${1:-}" in
    agy|scribe|copilot) echo 'thinking|esc to interrupt|compacting|generating|running\.\.\.|working' ;;
    *)                  echo 'thinking|esc to interrupt|compacting|generating|running\.\.\.' ;;
  esac
}

# Idle heuristic (T17 VERIFY: must be documented, not just implemented):
# - pane_current_command is a plain shell (bash/zsh/sh/fish, or empty) ->
#   idle, nothing running in it. NOTE: Claude Code panes report
#   pane_current_command as a version string (e.g. "2.1.206"), not
#   "claude" -- that still falls through to the TUI branch below correctly
#   (it matches none of bash/zsh/sh/fish), just worth knowing when reading
#   this case statement (issue #86 Task 3 live observation).
# - otherwise (a TUI: claude, agy, copilot, node, ...) -> capture the last
#   10 lines and look for busy markers (spinner/status text a TUI shows
#   mid-generation), using that AGENT's own marker set (see
#   pane_busy_markers above). No busy marker AND a bare prompt line
#   present -> idle. A bare prompt is ">" (agy/copilot TUIs) or "❯" (Claude
#   Code) with only whitespace after it; a prompt with pending text stays
#   "busy" so a nudge never appends to someone's half-typed input.
# This is a heuristic on TUI rendering, not a guarantee: different TUI
# versions render idle/busy differently. On doubt this errs toward "busy"
# (skip the nudge) rather than "idle" (nudge) -- a delayed pickup just costs
# time, but a nudge into a genuinely busy pane injects stray keystrokes into
# whatever it's mid-generating.
pane_is_idle() {
  local target="$1" agent="${2:-}" cmd tail markers
  cmd="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || echo '')"
  case "$cmd" in
    ""|bash|zsh|sh|fish) return 0 ;;
  esac
  # send_meaningful_tail (send-lib.sh), not a raw capture-pane|tail -10: a
  # tall pane blank-pads below its real content, and a naive tail on the
  # unfiltered capture can grab pure padding instead of text (issue #86,
  # found dogfooding Task 3's own test).
  tail="$(send_meaningful_tail "$target" 10)"
  markers="$(pane_busy_markers "$agent")"
  if echo "$tail" | grep -Eiq "$markers"; then
    return 1
  fi
  echo "$tail" | grep -Eq '^[[:space:]]*[>❯][[:space:]]*$'
}

nudge_agent() {
  local agent="$1" target
  target="$(pane_for_agent "$agent")"
  if [ -z "$target" ]; then
    echo "dispatch.sh: no pane mapping for agent '$agent', skipping nudge" >&2
    return 0
  fi
  # T24: check the session the TARGET pane actually lives in, not a
  # hardcoded "harness" -- lets tests point pane_for_agent at a throwaway
  # session and exercise the busy/idle branches for real instead of only
  # ever hitting this early "no session" return (production targets are
  # always "harness:0.N" so this is a no-op behavior change there).
  if ! tmux has-session -t "${target%%:*}" 2>/dev/null; then
    echo "dispatch.sh: no tmux '${target%%:*}' session running, skipping nudge" >&2
    return 0
  fi
  if pane_is_idle "$target" "$agent"; then
    # issue #86 finding 1: nudge_agent is the HIGHEST-frequency send path of
    # the three (dispatch/gatekeeper/auto-resume) but was the only one still
    # on a bare send-keys burst with no confirm/retry -- routed through the
    # same shared send_submit (send-lib.sh) as the other two now.
    send_submit "$target" "check inbox"
    echo "dispatch.sh: nudged $agent ($target)"
  else
    echo "dispatch.sh: $agent ($target) is busy, deferred nudge"
    if ! grep -qxF "$agent" "$DEFERRED_FILE" 2>/dev/null; then
      echo "$agent" >> "$DEFERRED_FILE"
    fi
  fi
}

# scribe_spawn_headless <msg_file> <ack_file> -- issue #89 (T38): scribe has
# no standing pane anymore (pane 3 retired -- no recurring scribe job
# remained after #85's mechanical issue-close). A dispatch to scribe/copilot
# spawns a ONE-SHOT headless run instead of nudging a pane: `claude -p
# --model haiku` reads the .msg content, does the judgment task, and writes
# its own one-line receipt to the .ack path, then exits. The inbox stays
# the durable record either way -- this just changes who/what performs the
# task, not where the record lives. Split out (like mw_fetch_merged_prs
# etc. elsewhere in this harness) so tests can override this function
# directly instead of spawning a real `claude` process. Runs in the
# background: `assign` returns immediately regardless, and `handoff`'s
# existing poll loop below already waits for the .ack to appear no matter
# who writes it.
scribe_spawn_headless() {
  local msg_file="$1" ack_file="$2" msg_body prompt
  msg_body="$(cat "$msg_file" 2>/dev/null)"
  # Plain concatenation, not a heredoc: an unquoted heredoc's lexer tracks
  # quote state while scanning for $(...)/`...`, and a stray apostrophe in
  # prose (e.g. "doesn't") opens an unterminated single-quote from its
  # point of view -- breaks the WHOLE script's parse, not just this
  # function (found the hard way writing this very function).
  prompt="You are the scribe agent for career-ops-harness, spawned one-shot to handle a single dispatched task (issue #89: scribe has no standing pane -- this headless run IS the scribe for this one message).

Dispatch message:
$msg_body

Do the judgment task described above. When finished, write exactly one line -- what you did, or SKIPPED: <reason> if it does not apply -- to this file: $ack_file
Do nothing else outside the scope of this message."
  ( claude -p --model haiku "$prompt" >/dev/null 2>&1 & )
}

# retry_deferred_nudges (T24) -- drains DEFERRED_FILE, re-attempting a nudge
# for each queued agent. An agent whose pane is idle now gets nudged (and
# drops out of the queue); one still busy gets re-queued by the same
# nudge_agent() call above, so nothing is lost across iterations.
retry_deferred_nudges() {
  [ -s "$DEFERRED_FILE" ] || return 0
  local agents
  agents="$(sort -u "$DEFERRED_FILE")"
  : > "$DEFERRED_FILE"
  local agent
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    nudge_agent "$agent"
  done <<< "$agents"
}

dispatch_main() {
  local VERB="${1:?usage: dispatch.sh <handoff|assign|message> <agent> <issue> <msg> [timeout_s]}"
  local AGENT="${2:?usage: dispatch.sh <handoff|assign|message> <agent> <issue> <msg> [timeout_s]}"
  local ISSUE="${3:?usage: dispatch.sh <handoff|assign|message> <agent> <issue> <msg> [timeout_s]}"
  local MSG="${4:?usage: dispatch.sh <handoff|assign|message> <agent> <issue> <msg> [timeout_s]}"
  local TIMEOUT="${5:-120}"
  local INBOX="$CANON_DIR/inbox/$(inbox_dir_name "$AGENT")"

  case "$VERB" in
    handoff|assign|message) ;;
    *)
      echo "dispatch.sh: unknown verb '$VERB' (expected handoff|assign|message)" >&2
      return 1
      ;;
  esac

  if [ ! -d "$INBOX" ]; then
    echo "dispatch.sh: no inbox for agent '$AGENT' (expected $INBOX)" >&2
    return 1
  fi

  local ts file ack
  ts=$(date '+%Y%m%d%H%M%S')
  file="$INBOX/${ts}-${ISSUE}.msg"
  ack="${file%.msg}.ack"
  echo "$MSG" > "$file"
  echo "dispatch.sh: wrote $file"

  [ "$VERB" = "message" ] && return 0

  # issue #89: scribe/copilot has no standing pane to nudge -- spawn its
  # one-shot headless run instead. Every other agent still goes through the
  # normal pane nudge.
  case "$AGENT" in
    scribe|copilot)
      echo "dispatch.sh: spawning one-shot headless scribe for $ISSUE"
      scribe_spawn_headless "$file" "$ack"
      ;;
    *)
      nudge_agent "$AGENT"
      ;;
  esac

  [ "$VERB" = "assign" ] && return 0

  # T30 (issue #56): an .ack is meant to be a RECEIPT -- a one-line "what was
  # done / SKIPPED because X" -- not just a marker file. An empty (or
  # whitespace-only) .ack has been seen in the wild (15 stale backfill acks
  # found across agy/copilot's real inboxes, from before this rule
  # existed) and tells the sender nothing. Treat it as suspect: keep
  # polling instead of accepting it, so a genuinely non-empty ack still
  # unblocks handoff normally, but a bare `touch`/`echo "" >` doesn't.
  local elapsed=0 warned_empty=0
  while true; do
    if [ -e "$ack" ]; then
      if [ -n "$(tr -d '[:space:]' < "$ack" 2>/dev/null)" ]; then
        break
      elif [ "$warned_empty" -eq 0 ]; then
        echo "dispatch.sh: $ack exists but is empty/whitespace-only (suspect, not a real receipt) -- still waiting" >&2
        warned_empty=1
      fi
    fi
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      echo "dispatch.sh: timeout waiting for $ack after ${TIMEOUT}s" >&2
      return 2
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "dispatch.sh: received $ack"
}

# Guard so this file can be sourced (for pane_is_idle etc. in tests /
# dispatch-tester.sh) without running dispatch_main as a side effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  dispatch_main "$@"
  exit $?
fi
