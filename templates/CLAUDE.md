# CLAUDE.md — Claude Code lane

> Template shipped by [agent-orchestra](https://github.com/immuhammad/agent-orchestra)
> (issue #18). Copy this into your project root alongside `AGENTS.md`, fill
> in the `<PROJECT>` placeholders, and delete this blockquote. `AGENTS.md`
> is this project's single source of truth for harness rules — this file
> adds Claude-Code-specific notes only and must never contradict it.

Read `AGENTS.md` at this project's root, in full, before any work — it
defines the roles, model lanes, skills, loop, dispatch protocol, handoff
protocol, and hard rules every agent (regardless of tool) follows.

## Roles this file's agent may run
Claude Code sessions in `<PROJECT>` run as Orchestra, Builder (Implementer/
Tester), or Scribe per `orchestrator.yaml`'s `roles:` block — see
`AGENTS.md`'s Roles & Model Lanes table for the effort/fallback assigned to
each.

## Session bootup
`hooks/session-start.sh` fires on every Claude Code `SessionStart` and
surfaces the harness reminder as `additionalContext` — see `AGENTS.md`'s
Handoff Protocol for the full read-order and what's ephemeral
(`handoff.md`) vs. durable (`decisions.log` + memory).

## Tool-specific notes
- <Claude-Code-only quirks go here — hook wiring (`.claude/settings.json`),
  skill pack location (`.claude/skills/`), permission config. Delete this
  line once filled in.>
- Protected paths are OS-immutable while `bin/orc-protect on` is set
  (guard-layer redesign #141): writes into `.claude/`, `.agents/`,
  `orchestrator.yaml` fail with EPERM at the kernel, whatever tool or
  shell shape attempts them. For a LEGITIMATE config edit or template
  re-sync: `bin/orc-protect off`, edit, `bin/orc-protect on` — and say
  so in your handoff/decisions entry so the toggle is auditable.
