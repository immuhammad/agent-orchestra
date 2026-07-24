<div align="center">

# 🎼 agent-orchestra

**Run an AI engineering team in a tmux room on your laptop —
real tickets, adversarial cross-model review, human gates, and receipts for everything.**

[![CI](https://github.com/immuhammad/agent-orchestra/actions/workflows/ci.yml/badge.svg)](https://github.com/immuhammad/agent-orchestra/actions/workflows/ci.yml)
![shell](https://img.shields.io/badge/built%20with-bash%20%2B%20tmux%20%2B%20git-4EAA25)
![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)

</div>

---

`orc` turns a tmux session into a small engineering org: a Claude **Orchestra**
pane that plans, dispatches, and merges; a Claude **Builder** that implements
test-first; a Gemini **Reviewer** (Antigravity CLI) that adversarially probes
every PR; and shell **watchdogs** that keep quota, liveness, and merge hygiene
honest. Agents coordinate through a file-based inbox with acknowledgment
receipts — no daemon, no framework, no cloud service. Just bash, tmux, git,
and the agent CLIs you already have.

Extracted from [career-ops-harness](https://github.com/immuhammad/career-ops-harness),
where it started life as the `.harness/` folder that ran the project it lived in.

<!-- demo: docs/demo.gif — see docs/recording.md -->

## The room

```
┌──────────────────────── tmux: <your-project> ───────────────────────┐
│                                                                    │
│  0 · ORCHESTRA (Claude)          1 · BUILDER (Claude)             │
│  plans tickets, writes Gate-1    implements red-first TDD in git   │
│  plans, dispatches, verifies     worktrees, requests review,       │
│  artifacts, holds Gate-2 merge   never flips its own PR to ready   │
│                                                                    │
│  2 · REVIEWER (Gemini / agy)     3 · GATEKEEPER (bash)             │
│  adversarial cross-family        quota failsafe + liveness         │
│  review: APPROVE needs a probe   heartbeat — suspend-aware, so a   │
│  list, findings need scenarios   closed laptop lid isn't an alarm  │
│                                                                    │
│  4 · WATCH (bash)                                                  │
│  merge-watch: closes issues, tears down worktrees, nudges the      │
│  next pick — plus a live room-status header                        │
└──────────────────────────────────────────────────────────────────┘
```

## What makes it different

- **Cross-family review.** The builder is Claude; the reviewer is Gemini.
  Different model families means review isn't self-confirmation — and it has
  caught real bugs here, including a fail-open security flaw in this repo's
  own `orc init --force` before it merged.
- **Evidence over assertions.** An APPROVE without a probe list doesn't count.
  A REQUEST-CHANGES without a concrete failure scenario doesn't count.
  "Tested end-to-end" is verified against artifacts — CI logs, transcripts,
  files on disk — because we learned the hard way that agents will claim it
  anyway (see `review-protocol.md`).
- **Human gates.** Gate-1: no build starts without a plan of record on the
  ticket. Gate-2: only the Orchestra (or you) flips a PR to ready and merges —
  on green CI plus reviewer APPROVE. Builders never merge their own work.
- **Receipts on disk.** Dispatch is a file-based inbox: `.msg` in, one-line
  `.ack` receipt back, atomically written, collision-safe. Room state lives in
  `handoff.md` (ephemeral) and `decisions.log` (durable). Everything is
  greppable after the fact.
- **Ground truth, not screen-scraping.** Agent busy/idle state is written by
  the agents' own lifecycle hooks, keyed by tmux pane — dispatch and wake
  decisions gate on that, not on guessing from rendered output.
- **Context hygiene, mechanical.** `dispatch.sh --fresh` clears the receiving
  pane between unrelated tickets — verified idle first, `/clear` typed with a
  race-proof ordering guarantee, message delivered only after the fresh
  session is confirmed. Issue N+1 never pays for issue N's residue.
- **Guardrails with teeth.** PreToolUse guards block the banned-command class
  (`rm -rf`, force-push, …) inside agent panes; `orc-protect` makes kernel
  files OS-immutable (`chflags`/`chattr`) so no agent can edit its own guards;
  branch protection backstops the merge path; a soft-policy `rules.md` layer
  carries the norms that don't need enforcement.
- **A watchdog that knows about laptops.** The gatekeeper's staleness check is
  gap-aware: a suspend/resume or room rebuild grants a grace window instead of
  firing a false alarm at 2am.

## Quickstart

Every project gets its **own clone** of this repo; your actual codebase lives
gitignored inside it. No shared install, no wrapper layer.

```bash
# 1. one clone per project
git clone git@github.com:immuhammad/agent-orchestra.git my-project-orc
cd my-project-orc

# 2. nest the codebase you're working on (a separate git repo, never committed here)
git clone git@github.com:you/my-project.git project/my-project

# 3. onboard — interactive wizard writes orchestrator.yaml, AGENTS.md,
#    role identity cards, and installs the skill pack
bin/orc init .

# 4. build the control room
bin/orc up
```

Re-running init later is safe: `orc init --force` resyncs template-derived
files from your `orchestrator.yaml`, detects hand-edits via a sha256 manifest,
backs them up loudly before overwriting, and never touches live room state.
See [docs/getting-started.md](docs/getting-started.md) for the full walkthrough.

**You'll need:** `tmux`, `git`, `gh` (authenticated), `jq`, and the agent CLIs
you want in the room (Claude Code; optionally Antigravity for the
cross-family reviewer lane).

## How work flows

```
ticket → Gate-1 plan (on the issue) → dispatch .msg → builder: red-first TDD
      → draft PR → cross-family review (2-round cap, then escalate) → CI green
      → BUILD-DONE .msg → Orchestra verifies artifacts → Gate-2 ready + merge
      → merge-watch closes the issue, tears down the worktree, nudges next pick
```

The protocol lives in `AGENTS.md` (single source of truth for every agent,
regardless of vendor), `review-protocol.md` (the evidence bar), and
`orchestrator.yaml` (roles, models, budgets, protected paths).

## The skill pack

Eleven task-discipline skills, dual-installed to `.claude/skills/` and
`.agents/skills/` by `bin/orc-install-skills` so every agent family shares one
playbook: `test-driven-development`, `systematic-debugging`,
`verification-before-completion`, `using-git-worktrees`,
`requesting-code-review`, `receiving-code-review`, `code-review`,
`brainstorming`, `writing-plans`, `subagent-driven-development`,
`dispatching-parallel-agents`.

## Built by itself

This repo is developed inside the room it describes — every feature above
landed through the loop above, with the `.msg`/`.ack` receipts to show for it.
One recent day's run, fully hands-off between human gates: a hardened
hook-probe merge gate (#158), the suspend-aware watchdog (#155),
`orc init --force` (#116), and mechanical context hygiene (#159) — four
tickets from Gate-1 plan to merged PR, including one real security finding
caught in cross-family review along the way.

## Status

Young and moving fast; macOS-first, Linux-tested in CI (35 shell test suites,
red-first culture). Issues and war stories welcome.
