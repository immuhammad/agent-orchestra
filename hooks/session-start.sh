#!/bin/bash
# SessionStart hook: mark session start + surface quota reminder.
# T22 (issue #27) scope addition: one-line role->skills auto-use reminder,
# since skills must be auto-used per AGENTS.md's Skills table, not just
# invocable on request. Kept role-agnostic (this hook fires identically for
# every session/role) -- full detail lives in AGENTS.md's Skills table.
# issue #23: a one-shot/headless spawn (e.g. the dispatched scribe) must
# run with MINIMAL context -- just its dispatched task, already given
# directly in its own prompt -- not this pane-agent room-state briefing. A
# scribe spawn was observed booting, reading the "read handoff.md" + quota
# rule instructions below, concluding from a STALE handoff.md that the room
# was quota-parked, and self-aborting instead of doing its dispatched task.
# A one-shot has no standing pane and no handoff.md duty (its own Stop hook
# already exempts it via this same ORC_ONESHOT marker, see
# check-handoff.sh), so it should never see this briefing at all.
if [ "${ORC_ONESHOT:-0}" = "1" ]; then
  echo '{}'
  exit 0
fi

touch .harness/.session-start
echo '{"additionalContext": "HARNESS ACTIVE. Read .harness/handoff.md (current task state, ephemeral -- replaced each session) and .harness/decisions.log (durable cross-session context, append-only) before any work. Quota rule: at 80% of any window, stop, update handoff, ask Ahmad about fallback switch. Ahmad: run /usage to check Claude quota, agy quota screen for Google pool. Skills auto-use by role (see AGENTS.md Skills table): Builder -- test-driven-development, systematic-debugging, verification-before-completion, using-git-worktrees; Reviewer -- code-review (applies review-protocol.md); Orchestra -- brainstorming, writing-plans (+ fan-out skills, Orchestra-only). Inbox .msg bodies: caveman mode; handoff.md/decisions.log/PR descriptions/issue comments stay full English."}'
