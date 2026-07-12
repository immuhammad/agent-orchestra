# agent-orchestra

`orc` — the multi-agent tmux orchestration harness, extracted from
[career-ops-harness](https://github.com/immuhammad/career-ops-harness) (epic #91).

Coordinates Claude, agy (Antigravity CLI), and other panes in a tmux
session: file-based inbox dispatch with `.ack` receipts, gatekeeper quota
failsafe, post-merge teardown automation, and a capped, dual-installed
skill pack (`.claude/skills/` + `.agents/skills/`).

Status: **scaffolding in progress (issue #116 / epic #91a)**. Source of
truth for the harness logic remains
[career-ops-harness `.harness/`](https://github.com/immuhammad/career-ops-harness/tree/main/.harness)
until #91b (career-ops-harness becomes consumer #1) lands.

## Layout
- `bin/orc` — entry point
- `lib/` — send-lib, tui-lib, handoff-lib, harness-root, guards
- `hooks/` — session-start, check-handoff, pre-compact-checkpoint, rate-limit-handoff
- `templates/` — AGENTS.md, CLAUDE.md, GEMINI.md, orchestrator.yaml, handoff seed, review-protocol.md, SOUL.md placeholder
- `skills/` — capped skill pack (test-driven-development, systematic-debugging,
  verification-before-completion, using-git-worktrees, requesting/receiving-code-review,
  brainstorming, writing-plans), dual-installed to `.claude/skills/` and `.agents/skills/`
- `tests/` — shell test suites (`*.test.sh`)
- `docs/`
