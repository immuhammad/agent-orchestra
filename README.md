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
until #91b (career-ops-harness moves onto its own agent-orchestra clone)
lands.

## Deployment model: clone-per-project

Every project gets its **own clone** of this repo. The actual codebase
you're working on lives nested inside that clone as a gitignored
`project/<name>/` subfolder — a completely separate git repo, never
committed into agent-orchestra. Hooks reference this clone's own
`bin/`/`lib`/`hooks/` directly (`bash "$CLAUDE_PROJECT_DIR"/lib/guard.sh`,
see this repo's own `.claude/settings.json`) — there is no shared install
or trampoline layer to route through. See `docs/getting-started.md` for the
step-by-step.

## Layout
- `bin/orc` — entry point
- `lib/` — send-lib, tui-lib, handoff-lib, harness-root, guards
- `hooks/` — session-start, check-handoff, pre-compact-checkpoint, rate-limit-handoff
- `templates/` — AGENTS.md, CLAUDE.md, GEMINI.md, orchestrator.yaml, handoff seed, review-protocol.md, souls/ (per-role SOUL.md identity cards)
- `skills/` — capped skill pack (test-driven-development, systematic-debugging,
  verification-before-completion, using-git-worktrees, requesting/receiving-code-review,
  brainstorming, writing-plans), dual-installed to `.claude/skills/` and `.agents/skills/`
- `tests/` — shell test suites (`*.test.sh`)
- `docs/`
- `project/` — **not tracked**: this clone's own target-project codebase (a
  separate git repo), created per the clone-per-project deployment model
  above
