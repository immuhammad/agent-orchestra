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

3. Onboard the room — one command:
   ```
   bin/orc init .
   ```
   The interactive wizard asks for the project name,
   integration branch, role→model assignments, budget failsafe
   percentages, gate approver, and protected paths, then writes
   everything: `orchestrator.yaml`, `AGENTS.md`, `CLAUDE.md`,
   `GEMINI.md`, per-role `souls/` identity cards,
   `.claude/settings.json` + `.agents/hooks.json` (hook wiring for both
   agent families, pointing directly at this clone's own `hooks/`/`lib/`
   — no wrapper layer), installs the skill pack into `.claude/skills/` +
   `.agents/skills/`, records a sha256 manifest of every generated file
   (`.harness/state/init-manifest`), and finishes by running the two
   static verifiers (`lib/check-hook-wiring.sh`,
   `bin/orc-install-skills --check`). Nothing is written unless
   validation passes in full. Non-interactive:
   `bin/orc init --answers answers.env .` — a flat KEY=value file (see
   `orc_init_validate` in `bin/orc` for the accepted keys).

   `AGENTS.md` stays the single source of truth — `CLAUDE.md` and
   `GEMINI.md` only add tool-specific lanes, never contradict it.
   `orchestrator.yaml` at this clone's root is also the marker
   `lib/harness-root.sh` walks up from cwd to find — every
   `orc`/`dispatch`/`gatekeeper` invocation needs it somewhere above
   wherever it's run from (or set `ORC_PROJECT_ROOT` explicitly). The
   generated root files are **per-room** — customize your clone's copies
   freely; only `templates/` is tracked upstream.

   Re-running later is safe: plain `orc init` refuses
   loudly on an already-initialized room; `bin/orc init --force .`
   resyncs the templates-derived files against the current templates —
   hand-edited files are detected via the manifest and backed up loudly
   under `.harness/state/init-backups/` before being overwritten, and
   live room state (`.harness/` inbox, decisions.log, handoff.md) is
   never touched. `--force --answers FILE` does a full re-init including
   `orchestrator.yaml`.

4. `bin/orc up` builds the tmux control room from `orchestrator.yaml`,
   targeting `project/<name>/` as the working tree. On a fresh room (no
   `.harness/merge-watch-state` yet) this also seeds that file with every
   currently-merged PR number (`lib/orc-seed-merge-watch.sh`), so
   `watch.sh`'s merge-watch doesn't replay comment+close on old PRs and
   fire a stale "PICK next" nudge the first time it runs. Idempotent
   (only seeds once, safe to call `orc up` again) and non-fatal (a `gh`
   hiccup never blocks `orc up`); set `ORC_SKIP_MERGE_WATCH_SEED=1` to
   skip it outright.

## Layout

- `bin/orc` — `orc init` (onboarding wizard; `--force` re-init/resync)
  and `orc up` (builds the tmux control room).
- `bin/orc-install-skills [target_dir]` — dual-installs the skill pack
  (also run for you by `orc init`; `--check` verifies an install).
- `lib/` — everything else: dispatch, watch, gatekeeper, guards,
  worktree lifecycle, root-resolution, merge-watch seeding.
- `hooks/` — Claude Code hook scripts (session-start, check-handoff,
  pre-compact-checkpoint, rate-limit-handoff).
- `templates/` — the source `orc init` renders the room's root files
  from (step 3 above).
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
