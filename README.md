<div align="center">

# 🎼 agent-orchestra

### Your laptop. One tmux session. An AI engineering team that ships real PRs —
### with adversarial reviews, human gates, and receipts for everything.

[![CI](https://github.com/immuhammad/agent-orchestra/actions/workflows/ci.yml/badge.svg)](https://github.com/immuhammad/agent-orchestra/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![built with](https://img.shields.io/badge/built%20with-bash%20%2B%20tmux%20%2B%20git-4EAA25)
![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)
![agents](https://img.shields.io/badge/agents-Claude%20%2B%20Gemini-8A2BE2)

**No cloud platform. No framework. No magic.**
Just bash, tmux, git, and the agent CLIs you already have — organized like a real engineering org.

</div>

<!-- demo: docs/demo.gif — see docs/recording.md -->

---

Everyone can make an AI agent write code. The hard part is making agents
**accountable**: not reviewing their own work, not claiming "tested" when
nothing ran, not merging anything a human never gated. `orc` builds a tmux
control room where every agent has a role, every claim needs evidence, and
every action leaves a receipt on disk.

Extracted from [career-ops-harness](https://github.com/immuhammad/career-ops-harness),
where it started as the `.harness/` folder running the project it lived in.

## The room

| Pane | Runs | Job |
|---|---|---|
| **0 · Orchestra** | Claude Code | Plans tickets, writes Gate-1 plans, dispatches work, verifies evidence, holds the merge |
| **1 · Builder** | Claude Code | Implements red-first TDD in isolated git worktrees — never merges its own work |
| **2 · Reviewer** | Gemini (Antigravity CLI) | Adversarial cross-family review — an APPROVE without a probe list doesn't count |
| **3 · Gatekeeper** | bash | Quota failsafe + liveness heartbeat — suspend-aware, so a closed laptop lid isn't a 2am alarm |
| **4 · Watch** | bash | Merge-watch: closes issues, tears down worktrees, nudges the next pick — plus a live status header |

## How work flows

| # | Stage | Owner | What happens | The receipt |
|---|---|---|---|---|
| 1 | Plan | Orchestra | No build starts without a plan of record on the ticket (**Gate 1**) | Plan comment on the issue |
| 2 | Dispatch | Orchestra | Atomic `.msg` into the builder's file inbox — pane verified idle first, context cleared between unrelated tickets (`--fresh`) | `.msg` + one-line `.ack` on disk |
| 3 | Build | Builder | Red-first TDD in a git worktree; opens a **draft** PR | Failing→passing tests in the diff |
| 4 | Review | Reviewer | Adversarial pass from a *different model family*; findings need concrete failure scenarios; 2-round cap, then escalate | APPROVE with an explicit probe list |
| 5 | Verify | Orchestra | Claims checked against artifacts — CI logs, fixtures, diff scope — never against assertions | Verification notes before merge |
| 6 | Merge | Orchestra / you | Ready + merge only on reviewer APPROVE **and** green CI (**Gate 2**) | Merged PR |
| 7 | Teardown | Watch | Issue auto-closed, worktree removed, next pick nudged | Clean room, greppable history |

## Why it's built this way

| Design call | The failure it kills | How it works here |
|---|---|---|
| **Cross-family review** | Same-model review is self-confirmation | Claude builds, Gemini reviews — it has caught a real fail-open security bug here before merge |
| **Evidence over assertions** | Agents say "tested end-to-end" when nothing ran | Approvals require probe lists; claims are verified against logs, files, and transcripts (`review-protocol.md`) |
| **Human gates** | Autonomy without accountability | Gate-1 plan before any build; Gate-2 merge held by the Orchestra or you — builders never ship their own work |
| **Receipts on disk** | Chat-history archaeology | File-based inbox (`.msg`/`.ack`), `handoff.md` room state, durable `decisions.log` — all plain text, all greppable |
| **Ground-truth state** | Guessing busy/idle from rendered screens | Agents' own lifecycle hooks write their state, keyed by tmux pane — dispatch gates on that |
| **Context hygiene** | Ticket N+1 pays for (and is misled by) ticket N's residue | `dispatch.sh --fresh`: verify idle → `/clear` → confirm fresh session → only then deliver |
| **Guards with teeth** | An agent editing its own rules | PreToolUse guards block banned commands; `orc-protect` makes kernel files OS-immutable (`chflags`/`chattr`); branch protection backstops the merge path |
| **Laptop-aware watchdog** | False alarms after every suspend | Gap-aware staleness: a wall-clock jump in the watchdog's own tick grants grace instead of firing |

## The skill pack

Eleven task-discipline skills, dual-installed to `.claude/skills/` and
`.agents/skills/` so every agent family follows one playbook:

| Skill | What it enforces |
|---|---|
| `test-driven-development` | Red first — no implementation before a failing test |
| `verification-before-completion` | Evidence before "done" — run it, read the output, then claim it |
| `code-review` | Adversarial protocol — assume a defect exists and hunt for it |
| `systematic-debugging` | Root-cause before fixes, on any unexpected behavior |
| `requesting-code-review` / `receiving-code-review` | Reviews get requested at the right moments — and feedback gets verified, not performed |
| `using-git-worktrees` | Every ticket builds in isolation |
| `writing-plans` | Multi-step work starts from a written plan |
| `brainstorming` | Intent and design before any creative work |
| `subagent-driven-development` / `dispatching-parallel-agents` | Independent tasks fan out instead of serializing |

## Quickstart

Every project gets its **own clone**; your codebase lives gitignored inside it.

```bash
# 1. one clone per project
git clone git@github.com:immuhammad/agent-orchestra.git my-project-orc
cd my-project-orc

# 2. nest the codebase you're working on (a separate git repo, never committed here)
git clone git@github.com:you/my-project.git project/my-project

# 3. onboard — the wizard writes config, docs, hook wiring, and skills, then verifies itself
bin/orc init .

# 4. build the control room
bin/orc up
```

Re-running init is safe: `orc init --force` resyncs generated files, detects
hand-edits via a sha256 manifest, backs them up loudly, and never touches live
room state. Full walkthrough: [docs/getting-started.md](docs/getting-started.md).

**You'll need:** `tmux`, `git`, `gh` (authenticated), `jq`, and the agent CLIs
for the panes you want (Claude Code; optionally Antigravity for the
cross-family reviewer lane).

## Built by itself

This repo is developed inside the room it describes — one recent day's run,
hands-off between human gates:

| Issue | PR | What landed |
|---|---|---|
| #158 | #160 | Hardened hook-probe merge gate (boots a real reviewer session to verify hook wiring) |
| #155 | #161 | Suspend-aware watchdog — gap-aware staleness, both real incidents reproduced red-first |
| #116 | #162 | `orc init --force` — safe re-init with manifest-based drift backups |
| #159 | #164 | Mechanical context hygiene — `dispatch.sh --fresh` with a race-proof ordering guarantee |

Four tickets, plan → build → cross-family review → CI → gated merge —
including one genuine security finding caught in review along the way.

## Status & license

Young and moving fast; macOS-first, Linux-tested in CI (35 shell test suites,
red-first culture). Issues and war stories welcome. [MIT](LICENSE).
