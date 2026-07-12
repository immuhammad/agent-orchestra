#!/bin/bash
# Stop hook: block session end if handoff.md wasn't touched this session.
INPUT=$(cat)
# infinite-loop guard (required — see Claude Code docs)
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // "false"')" = "true" ]; then
  exit 0
fi
# issue #23: a one-shot/headless session (e.g. the spawned scribe) sets its
# OWN .session-start marker on boot, which is by construction always newer
# than any handoff.md written before it spawned -- the exact stale state
# this hook exists to catch for a stage-owning PANE agent. A one-shot
# session is not one, and per AGENTS.md's single-writer rule must NEVER
# write handoff.md anyway, so the hook must not order it to. The handoff
# rule is for stage-owning pane agents only.
[ "${ORC_ONESHOT:-0}" = "1" ] && exit 0

HANDOFF=".harness/handoff.md"
MARKER=".harness/.session-start"
# If no session marker exists, don't block (first run / manual session)
[ -f "$MARKER" ] || exit 0
if [ "$HANDOFF" -ot "$MARKER" ]; then
  echo "handoff.md not updated this session. Update .harness/handoff.md (task, branch, done, next, gotchas) before finishing." >&2
  exit 2
fi

# T31 (issue #68 item A): handoff.md is now a REPLACED ≤80-line
# current-state file, not an append log -- git history is the archive. This
# only WARNS (doesn't block finishing) since a warning-based nudge is
# enough to catch drift back toward append-forever without risking a false
# block on a legitimately larger one-off update.
if [ -f "$HANDOFF" ]; then
  LINES="$(wc -l < "$HANDOFF" 2>/dev/null | tr -d ' ')"
  if [ -n "$LINES" ] && [ "$LINES" -gt 100 ]; then
    echo "WARNING: handoff.md is $LINES lines (>100). It should be REPLACED each session as a ≤80-line current-state file, not appended to -- see AGENTS.md's handoff rule." >&2
  fi
fi
exit 0
