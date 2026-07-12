#!/bin/bash
# hooks/pane-state.sh <busy|idle> — issue #33: records this pane's
# busy/idle transition, keyed by $TMUX_PANE, so dispatch.sh's pane_is_idle
# can read ground truth instead of guessing from a tmux capture-pane
# screen-scrape. Wired via templates/settings.json:
#   UserPromptSubmit          -> pane-state.sh busy
#   PreToolUse (matcher ".*") -> pane-state.sh busy
#   Stop                      -> pane-state.sh idle
#
# A session with no $TMUX_PANE isn't running inside a tracked tmux pane
# (e.g. a headless scribe one-shot, issue #89) -- nothing to track, so this
# is a silent no-op, not an error. Same for a session outside any
# orchestrator.yaml-rooted project: best-effort feature, never blocks the
# hook pipeline.
set -uo pipefail

STATE="${1:?usage: pane-state.sh <busy|idle>}"

# Claude Code always sends hook JSON on stdin -- drain it so this process
# never blocks the hook pipeline waiting on input it doesn't use.
cat >/dev/null

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

pane_state_write "$TMUX_PANE" "$STATE"
