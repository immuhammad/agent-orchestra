#!/bin/bash
# .harness/send-lib.sh — shared "type text into a pane and submit it
# reliably" helper (issue #86 Task 1). Supersedes auto-resume.sh's old
# ar_submit, which only gatekeeper.sh/auto-resume.sh used -- dispatch.sh's
# nudge_agent, the HIGHEST-frequency send path of the three, was still on a
# bare two-event send with no confirm/retry at all (finding 1).
#
# Sourced by auto-resume.sh, dispatch.sh, and gatekeeper.sh -- not meant to
# be run standalone.
set -uo pipefail

# send_meaningful_tail <pane target> [line count, default 20] -- prints the
# last N non-blank lines of a pane's visible capture. `tmux capture-pane`
# returns the pane's FULL visible height, blank-padded below whatever
# content is actually there -- for a tall pane with content only near the
# top, a naive `tail -N` on the raw capture grabs N rows of blank padding,
# not the content. Filtering blanks first fixes this regardless of pane
# height or how little has been printed (originally auto-resume.sh's
# ar_meaningful_tail; moved here in issue #86 so dispatch.sh's pane_is_idle
# gets the same fix -- found dogfooding Task 3's own test, where a 50-row
# pane with content only in its first few rows left a raw tail -10 holding
# nothing but blank lines).
send_meaningful_tail() {
  tmux capture-pane -p -t "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -"${2:-20}"
}

# send_submit <pane target> <text> -- type text into a pane and submit it.
#
# Claude Code's TUI drops an Enter that arrives in the same send-keys burst
# as pasted text, so text and Enter are always separate events
# with a beat between them. `-l --` sends the text literally (issue #86
# finding 4) so a message starting with '-' or matching a tmux key name
# can't be misinterpreted as a flag/key.
#
# If the text is STILL sitting on the pane's input line after the Enter,
# sending MORE Enters doesn't help -- live-proven 2026-07-10 (issue #86):
# three separate Enter attempts on a stuck input all silently dropped,
# while clear (C-u) -> retype -> beat -> one fresh Enter submitted first
# try. So the retry clears and retypes instead of sending another bare
# Enter.
#
# issue #33/#38: C-u ALSO fires before the FIRST type attempt, not only on
# a stuck-input retry. The retry branch above only catches send_submit's
# OWN text getting stuck; it does nothing about content already sitting on
# the input line before send_submit was ever called (ghost/hint-adjacent
# leftovers, a half-typed prior message) -- that stray content silently
# merges with the first attempt's typed text, corrupting whatever gets
# submitted. Live-hit three times. C-u on an already-empty line is a no-op,
# so this is safe on the common case too.
send_submit() {
  local target="$1" text="$2" tail
  tmux send-keys -t "$target" C-u 2>/dev/null
  tmux send-keys -t "$target" -l -- "$text" 2>/dev/null
  sleep 1
  tmux send-keys -t "$target" Enter 2>/dev/null
  sleep 0.3
  # Flatten the captured tail before matching (issue #86 finding 2): tmux
  # hard-wraps at the pane's column width with no reflow-awareness, so a
  # message longer than the pane is split across physical lines and a
  # single-line grep against the raw capture can never match it -- the
  # same trick auto-resume.sh's ar_poll_pane already uses for the failsafe-
  # question match.
  tail="$(tmux capture-pane -p -t "$target" 2>/dev/null | tail -3 | tr -d '\n')"
  if echo "$tail" | grep -qF "$text"; then
    tmux send-keys -t "$target" C-u 2>/dev/null
    tmux send-keys -t "$target" -l -- "$text" 2>/dev/null
    sleep 0.5
    tmux send-keys -t "$target" Enter 2>/dev/null
  fi
}
