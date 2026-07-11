# Getting started

## Install

Clone this repo as a sibling of your project (not nested inside it):

```
git clone git@github.com:immuhammad/agent-orchestra.git ~/wherever/agent-orchestra
```

In your project:

1. Copy the templates into your project root:
   ```
   cp path/to/agent-orchestra/templates/orchestrator.yaml .
   cp path/to/agent-orchestra/templates/AGENTS.md .
   cp path/to/agent-orchestra/templates/handoff.md .harness/handoff.md
   cp path/to/agent-orchestra/templates/review-protocol.md .
   ```
   Edit `orchestrator.yaml` and `AGENTS.md` for your project (roles,
   models, protected paths, integration branch). `orchestrator.yaml` at
   your project root is the marker `lib/harness-root.sh` walks up from
   cwd to find — every `orc`/`dispatch`/`gatekeeper` invocation needs it
   somewhere above wherever it's run from (or set `ORC_PROJECT_ROOT`
   explicitly).

2. Install the skill pack:
   ```
   path/to/agent-orchestra/bin/orc-install-skills .
   ```
   Installs into both `.claude/skills/` and `.agents/skills/`.

3. Wire up hooks (Claude Code `settings.json`) pointing at
   `path/to/agent-orchestra/hooks/*.sh` — see `templates/AGENTS.md`'s
   Handoff Protocol section for what each hook does.

4. `path/to/agent-orchestra/bin/orc up` builds the tmux control room from
   your `orchestrator.yaml`.

## Layout

- `bin/orc` — `orc up`, builds the tmux control room.
- `bin/orc-install-skills [target_dir]` — dual-installs the skill pack.
- `lib/` — everything else: dispatch, watch, gatekeeper, guards,
  worktree lifecycle, root-resolution.
- `hooks/` — Claude Code hook scripts (session-start, check-handoff,
  pre-compact-checkpoint, rate-limit-handoff).
- `templates/` — copy these into a new consumer project.
- `skills/` — source tree for the capped skill pack; `bin/orc-install-skills`
  installs from here.
- `tests/` — `*.test.sh`, one per `lib`/`hooks` script. `bash tests/foo.test.sh`
  to run one; see `.github/workflows/ci.yml` for the full-suite invocation
  (all except `orc-worktree.test.sh`, which does a live GitHub push+PR
  cycle and is meant to be run manually).

## Root resolution

Every script that touches project state (inbox, decisions.log, gatekeeper
heartbeat/alert-state, auto-resume state) resolves the project root the
same way (`lib/harness-root.sh`):

1. `ORC_PROJECT_ROOT` env var, if set, wins outright.
2. Otherwise walk up from cwd looking for `orchestrator.yaml`.
3. If the discovered root sits inside a git worktree, redirect to the
   worktree's MAIN checkout instead (every worktree gets its own tracked
   copy of `orchestrator.yaml`, so a naive walk-up alone would split
   state per-worktree).
4. Fails loud (stderr message, non-zero exit, no stdout) if neither
   resolves — never silently falls back to a script's own directory.

Most scripts also accept a narrower override for testing/advanced setups
(e.g. `GATEKEEPER_HEARTBEAT_FILE`, `DISPATCH_CANON_DIR`) — when every
relevant override is pinned explicitly, root resolution is skipped
entirely (lazy), so a fully-pinned test run needs no `orchestrator.yaml`
at all.
