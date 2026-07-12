#!/bin/bash
# SessionStart hook: mark session start + surface quota reminder.
# T22 (issue #27) scope addition: one-line role->skills auto-use reminder,
# since skills must be auto-used per AGENTS.md's Skills table, not just
# invocable on request. Kept role-agnostic (this hook fires identically for
# every session/role) -- full detail lives in AGENTS.md's Skills table.
touch .harness/.session-start
echo '{"additionalContext": "HARNESS ACTIVE. Read .harness/handoff.md before any work. Quota rule: at 80% of any window, stop, update handoff, ask Ahmad about fallback switch. Ahmad: run /usage to check Claude quota, agy quota screen for Google pool. Skills auto-use by role (see AGENTS.md Skills table): Builder -- test-driven-development, systematic-debugging, verification-before-completion, using-git-worktrees; Reviewer -- code-review (applies review-protocol.md); Orchestra -- brainstorming, writing-plans (+ fan-out skills, Orchestra-only). Inbox .msg bodies: caveman mode; handoff.md/decisions.log/PR descriptions/issue comments stay full English."}'
