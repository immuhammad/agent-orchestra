# Getting started

## Install: clone-per-project

Every project gets its **own clone** of agent-orchestra — there is no
shared install that multiple projects point at, and no trampoline/wrapper
script (`orc-exec.sh`) to route commands through. This clone's own
`bin`/`lib`/`hooks` sit at its root and get referenced directly.

1. Clone agent-orchestra for this project (name the clone however you
   like — e.g. after the project it'll drive):
   ```
   git clone git@github.com:immuhammad/agent-orchestra.git my-project-orc
   cd my-project-orc
   ```

2. Put the actual codebase you're working on in a **gitignored**
   `project/<name>/` subfolder — a completely separate git repo, never
   committed into this clone:
   ```
   mkdir -p project
   git clone git@github.com:you/my-project.git project/my-project
   printf '\nproject/\n' >> .gitignore
   ```
   (Bootstrapping a brand-new codebase instead of wrapping an existing
   one? `git init project/my-project` works the same way.)

3. Copy the templates into THIS clone's own root:
   ```
   cp templates/orchestrator.yaml .
   cp templates/AGENTS.md .
   cp templates/CLAUDE.md .
   cp templates/GEMINI.md .
   cp templates/handoff.md .harness/handoff.md
   cp templates/review-protocol.md .
   ```
   Edit `orchestrator.yaml` and `AGENTS.md` for this project (roles,
   models, protected paths, integration branch); fill in `CLAUDE.md` and
   `GEMINI.md`'s tool-specific notes. `AGENTS.md` stays the single source
   of truth — the other two only add tool-specific lanes, never
   contradict it. `orchestrator.yaml` at this clone's root is the marker
   `lib/harness-root.sh` walks up from cwd to find — every
   `orc`/`dispatch`/`gatekeeper` invocation needs it somewhere above
   wherever it's run from (or set `ORC_PROJECT_ROOT` explicitly).

   `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, and `review-protocol.md` are
   **per-project root files** — each clone customizes its own copy, so
   add all four to this clone's own `.gitignore` (they're not tracked in
   agent-orchestra's own upstream repo either — only `templates/` is).
   Automated generation of this whole layout (`orc init`) is tracked
   separately (issue #5); for now, set it up by hand as above.

4. Install the skill pack:
   ```
   bin/orc-install-skills .
   ```
   Installs into both `.claude/skills/` and `.agents/skills/`.

5. Wire up hooks (Claude Code `settings.json`) pointing **directly** at
   this clone's own `hooks/*.sh` / `lib/*.sh` — e.g.
   `bash "$CLAUDE_PROJECT_DIR"/lib/guard.sh` (see this repo's own
   `.claude/settings.json` for the exact shape to copy). No separate path
   to another install and no wrapper script — `$CLAUDE_PROJECT_DIR` is
   this clone's own root. See `templates/AGENTS.md`'s Handoff Protocol
   section for what each hook does.

6. `bin/orc up` builds the tmux control room from `orchestrator.yaml`,
   targeting `project/<name>/` as the working tree.

## Layout

- `bin/orc` — `orc up`, builds the tmux control room.
- `bin/orc-install-skills [target_dir]` — dual-installs the skill pack.
- `lib/` — everything else: dispatch, watch, gatekeeper, guards,
  worktree lifecycle, root-resolution.
- `hooks/` — Claude Code hook scripts (session-start, check-handoff,
  pre-compact-checkpoint, rate-limit-handoff).
- `templates/` — copy these into this clone's own root (step 3 above).
- `skills/` — source tree for the capped skill pack; `bin/orc-install-skills`
  installs from here.
- `tests/` — `*.test.sh`, one per `lib`/`hooks` script. `bash tests/foo.test.sh`
  to run one; see `.github/workflows/ci.yml` for the full-suite invocation
  (all except `orc-worktree.test.sh`, which does a live GitHub push+PR
  cycle and is meant to be run manually).
- `project/` — **not tracked**: this clone's own target-project codebase,
  a separate git repo (step 2 above).

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
