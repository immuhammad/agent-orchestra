# GEMINI.md — Antigravity CLI lane

> Template shipped by [agent-orchestra](https://github.com/immuhammad/agent-orchestra).
> Copy this into your project root alongside `AGENTS.md`, fill
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
- <Antigravity-CLI-only quirks go here -- sandboxing, tool access,
  invocation differences from Claude Code. Delete this line once filled
  in.>
- **Scratch directory.** Redirect any temporary review artifact (a
  `gh pr diff`/`gh pr view` capture, a working copy of the diff, anything
  you'd otherwise dump into the project root) to `.harness/scratch/agy/`
  -- create it if it doesn't exist yet. Treat it as wiped per-dispatch: do
  not rely on a file surviving into the next review, and never leave
  anything behind in the project root itself (a real incident: `gh pr
  diff`/`gh pr view` redirected straight to `pr17.diff`/`pr17_body.txt` in
  the project root, left behind after a repetition-loop hang, cleaned up
  by hand). Mirrors the discipline the Claude lanes already follow (see
  `souls/scribe.md`: "I write nowhere but my own scratch dir and my ack
  file") -- the single-writer rule still applies on top of this: the PR,
  the inbox `.ack`, and `decisions.log` remain the only OUTPUT channels,
  this directory is for your own working files only.
