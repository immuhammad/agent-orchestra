# GEMINI.md — Antigravity CLI lane

> Template shipped by [agent-orchestra](https://github.com/immuhammad/agent-orchestra)
> (issue #18). Copy this into your project root alongside `AGENTS.md`, fill
> in the `<PROJECT>` placeholders, and delete this blockquote. `AGENTS.md`
> is this project's single source of truth for harness rules — this file
> adds Antigravity-CLI-specific notes only and must never contradict it.

Read `AGENTS.md` at this project's root, in full, before any work — it
defines the roles, model lanes, skills, loop, dispatch protocol, handoff
protocol, and hard rules every agent (regardless of tool) follows.

## Reviewer
Antigravity CLI (`agy`) runs the Reviewer role in `<PROJECT>` (cross-family
from Claude, so it isn't grading its own work — see `AGENTS.md`'s Roles &
Model Lanes table). As Reviewer it applies `review-protocol.md` (project
root) — the same protocol every reviewer uses regardless of tool — via the
`/code-review` skill installed at `.agents/skills/code-review/SKILL.md`,
which points at the same file.

## Session bootup
See `AGENTS.md`'s Handoff Protocol for the full read-order and what's
ephemeral (`handoff.md`) vs. durable (`decisions.log` + memory).

## Tool-specific notes
- <Antigravity-CLI-only quirks go here — sandboxing, tool access,
  invocation differences from Claude Code. Delete this line once filled
  in.>
