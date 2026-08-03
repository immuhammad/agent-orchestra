#!/bin/bash
# Stop hook: block session end if handoff.md wasn't touched this session.
INPUT=$(cat)
# infinite-loop guard (required — see Claude Code docs)
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // "false"')" = "true" ]; then
  exit 0
fi
# A one-shot/headless session (e.g. the spawned scribe) sets its
# OWN .session-start marker on boot, which is by construction always newer
# than any handoff.md written before it spawned -- the exact stale state
# this hook exists to catch for a stage-owning PANE agent. A one-shot
# session is not one, and per AGENTS.md's single-writer rule must NEVER
# write handoff.md anyway, so the hook must not order it to. The handoff
# rule is for stage-owning pane agents only.
#
# SECURITY (agy's probe-3): ORC_ONESHOT is an env var, in
# principle spoofable by any pane agent that can edit the command THIS hook
# is invoked with in .claude/settings.json (e.g. rewriting the Stop hook
# entry to `ORC_ONESHOT=1 bash hooks/check-handoff.sh`). This exemption is
# safe ONLY because .claude/ (and .agents/) are now protected as a
# write-protected-by-default path in guard.sh/guard-write.sh, independent
# of orchestrator.yaml -- no agent, including this one, can edit that
# wiring to inject the flag. Do not reintroduce this exemption without that
# protection in place. A pane agent's own Bash-tool env exports do not
# reach this hook either way: Claude Code invokes each PreToolUse/Stop hook
# as a fresh subprocess reading its command from settings.json at fire
# time, not by inheriting the agent's own shell environment.
[ "${ORC_ONESHOT:-0}" = "1" ] && exit 0

HANDOFF=".harness/handoff.md"
MARKER=".harness/.session-start"
# If no session marker exists, don't block (first run / manual session)
[ -f "$MARKER" ] || exit 0

# rider 8 (issue #171): a handoff.md that was NEVER initialised (no such
# file at all) is a materially different problem from one that merely
# went stale this session -- the room itself was likely never properly
# `orc init`'d. bash's -ot is true when file1 (HANDOFF) doesn't exist but
# file2 (MARKER) does, so the block below already fired for this case --
# just with the STALE case's own wording, which misleadingly implies a
# session let an existing handoff.md go out of date rather than the file
# never having existed. Split the two so orchestra gets a distinct,
# actionable signal for each. Both still block (exit 2): the never-
# initialised case is at least as actionable/severe as the merely-stale
# one (a room with no handoff.md at all has nothing for the NEXT session
# to read either), so it gets the same severity, not a downgrade to a
# warning.
if [ "${ORC_ROLE:-}" = "orchestra" ] && [ ! -f "$HANDOFF" ]; then
  echo "handoff.md not initialised -- run 'orc init' (or otherwise create .harness/handoff.md) before finishing this session." >&2
  exit 2
fi

# handoff.md is Orchestra's file -- the room-level state of
# record, and only Orchestra has the room-level view to write it honestly.
# This nag used to fire for EVERY agent's Stop, and Builder clobbered the
# file 3x with stale, ticket-scoped state as a result (worst case: a PR
# described as "awaiting merge" two hours after Ahmad had merged it).
# ORC_ROLE is exported by bin/orc when it launches each pane's `claude`
# process; Claude Code spawns every hook invocation as a child of that
# SAME process, so the var reaches this hook via ordinary environment
# inheritance -- unlike an agent's own mid-session `export`s, which never
# reach a hook subprocess at all (see the ORC_ONESHOT comment above, same
# reasoning). A session with no ORC_ROLE (started outside the room, or an
# older pane launched before this fix shipped) is UNKNOWN, not orchestra.
# Unknown must NEVER nag: a missed nag here just means a session finishes
# without a nudge, but nagging the WRONG role into writing this file is
# exactly the clobber this issue exists to stop -- fail toward silence,
# not toward instructing the wrong agent to do Orchestra's job.
if [ "${ORC_ROLE:-}" = "orchestra" ] && [ "$HANDOFF" -ot "$MARKER" ]; then
  echo "handoff.md not updated this session. Update .harness/handoff.md (task, branch, done, next, gotchas) before finishing." >&2
  exit 2
fi

# handoff.md is now a REPLACED ≤80-line
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
