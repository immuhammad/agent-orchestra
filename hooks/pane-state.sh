#!/bin/bash
# hooks/pane-state.sh <busy|idle|failsafe> — issue #33 + #125: records this
# pane's state transition, keyed by $TMUX_PANE, so dispatch.sh/broker.sh/
# auto-resume.sh read ground truth instead of guessing from a tmux
# capture-pane screen-scrape. Wired via templates/settings.json:
#   SessionStart              -> pane-state.sh idle  (a fresh session
#                                claims the pane: its new session_id
#                                breaks any stale ownership, #125)
#   UserPromptSubmit          -> pane-state.sh busy
#   PreToolUse (matcher ".*") -> pane-state.sh busy
#   Stop                      -> pane-state.sh idle
#
# issue #125: the "idle" transition self-corrects to "failsafe" while the
# quota-stop flag is up -- a session that stops while the room is
# quota-gated is PARKED, not idle, and every consumer (broker delivery
# hold, auto-resume ownership, liveness display) needs that distinction.
# The session_id from the hook's own stdin JSON is recorded alongside so
# ownership checks compare identities, not screen fingerprints.
#
# A session with no $TMUX_PANE isn't running inside a tracked tmux pane
# (e.g. a headless scribe one-shot, issue #89) -- nothing to track, so this
# is a silent no-op, not an error. Same for a session outside any
# orchestrator.yaml-rooted project: best-effort feature, never blocks the
# hook pipeline.
set -uo pipefail

STATE="${1:?usage: pane-state.sh <busy|idle|failsafe>}"

# Claude Code always sends hook JSON on stdin -- read it for session_id
# (never block the pipeline: jq failure degrades to an empty id).
INPUT="$(cat)"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // .conversationId // empty' 2>/dev/null || echo '')"

[ -z "${TMUX_PANE:-}" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/harness-root.sh
source "$DIR/../lib/harness-root.sh"

if [ -n "${PANE_STATE_CANON_DIR:-}" ]; then
  CANON_DIR="$PANE_STATE_CANON_DIR"
else
  CANON_DIR="$(harness_canonical_dir "$PWD")" || exit 0
fi
PANE_STATE_DIR="$CANON_DIR/state/pane-state"
# shellcheck source=../lib/pane-state-lib.sh
source "$DIR/../lib/pane-state-lib.sh"

if [ "$STATE" = "idle" ] && [ -f "$CANON_DIR/state/quota-stop" ]; then
  STATE="failsafe"
fi

pane_state_write "$TMUX_PANE" "$STATE" "$SESSION_ID"
