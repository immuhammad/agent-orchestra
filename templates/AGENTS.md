# AGENTS.md — Harness Rules (single source of truth)

> Template shipped by [agent-orchestra](https://github.com/immuhammad/agent-orchestra)
> (epic #91a, issue #116). Copy this into your project root, fill in the
> `<PROJECT>` placeholders, and delete this blockquote. Keep this file as
> your single source of truth — tool-specific files (CLAUDE.md, GEMINI.md,
> .github/copilot-instructions.md) should only add tool-specific lanes and
> must never contradict it.

All agents (Claude Code, Antigravity CLI, Copilot CLI, or whichever mix
your project runs) follow this file.

## Roles & Model Lanes
| Role        | Primary            | Effort  | Fallback |
|-------------|---------------------|---------|----------|
| Orchestra   | <model>             | High    | <fallback> |
| Implementer | <model>             | Default | <fallback> |
| Tester      | <model>             | Default | <fallback> |
| Reviewer    | <cross-family tool> | High    | <fallback> |
| Scribe      | <model>             | Low     | <fallback> |

Fill these from `orchestrator.yaml`'s `roles:` block — keep the two in
sync (orchestrator.yaml is what `orc up` and the guards actually read;
this table is the human-facing summary).

## Skills — auto-use by role
Skills listed here must be AUTO-USED for their stage — invoked as a
matter of course, not only when explicitly asked for. Dispatch messages
should name these explicitly so they trigger every time, not just when
someone remembers to ask. `agent-orchestra`'s capped skill pack (see
`skills/`) ships:

| Role      | Stage                                | Auto-use skills |
|-----------|---------------------------------------|------------------|
| Builder   | BUILD/TEST                            | test-driven-development, systematic-debugging, verification-before-completion, using-git-worktrees |
| Builder   | before dispatching to reviewer        | requesting-code-review |
| Builder   | after reviewer's verdict (fix-loop)   | receiving-code-review |
| Reviewer  | REVIEW                                | code-review (applies `review-protocol.md`) |
| Orchestra | PICK/PLAN                             | brainstorming, writing-plans |

Add project-specific skills here as your project adopts them — keep the
pack CAPPED and evaluated on adoption, not bulk-imported (see
agent-orchestra's own #107 decision log for the reasoning).

## The Loop (per task)
1. PICK: Orchestra picks the next issue from the current milestone.
2. PLAN: Orchestra posts an implementation plan as an issue comment.
   -- HUMAN GATE 1: you approve --
3. BUILD: Implementer branches `feature/issue-<n>`, codes, commits.
4. TEST: Tester writes + runs tests locally.
5. CI: push → CI (lint + tests) must pass.
6. REVIEW: Reviewer (cross-family, so it isn't grading its own work)
   reviews the PR; Implementer fixes.
7. SCRIBE: PR summary, update the issue, update your harness state files.
   -- HUMAN GATE 2: you merge --
8. Next issue. Repeat until the milestone is done.

## Dispatch Protocol
- All agent↔agent messaging uses the file inbox and
  `lib/dispatch.sh <verb> <agent> <issue> "<msg>" [timeout_s]`. A message
  is always a durable file (`.harness/inbox/<agent>/<ts>-<issue>.msg`); a
  receiver acknowledges by writing the matching `.ack` next to it. **An
  `.ack` MUST be a one-line receipt of what actually happened** — never a
  bare `touch`/`echo "" >` (an empty file tells the sender nothing).
  Three verbs:
  - `handoff` — write `.msg`, nudge if idle, then POLL for the `.ack`,
    bounded by `timeout_s` (default 120s). Use when you must block on the
    result. On timeout: do NOT retry blindly; check the pane, then
    re-dispatch or escalate.
  - `assign` — write `.msg`, nudge if idle, return immediately. Use for
    fire-and-forget work.
  - `message` — write `.msg` only. No nudge, no ack expected. Use for FYI
    notes the receiver picks up on its own schedule.
- Nudge = one-line `tmux send-keys "check inbox"` into the receiver's
  pane, sent ONLY when that pane is idle (see `lib/dispatch.sh`'s
  `pane_is_idle`, the single source of truth — don't reimplement it
  elsewhere). On doubt this errs toward "busy" (skip the nudge): a missed
  nudge just delays pickup, while a nudge into a genuinely busy pane
  injects stray keystrokes into whatever it's mid-generating.
- Pane map (window index 0, tiled) matches `bin/orc`'s layout:
  0=orchestra 1=builder 2=reviewer 3=gatekeeper 4=watch. Always target
  panes by index (`<session>:0.N`), never by window name (renamed to
  `control-room` at launch). An out-of-range pane index does not error —
  it resolves to the invoking client's current pane — so double-check
  pane count before targeting by index.
- Review-gated draft-PR flow: Builder opens PRs as **DRAFT**, then
  `dispatch.sh assign <reviewer> <issue> "..."` (fire-and-forget — a real
  review can run long, and a bounded `handoff` poll that outruns its
  timeout strands an already-completed verdict; this live-happened on PR
  #30's security review, issue #38). Builder does NOT block on this
  dispatch: it polls the PR itself (`gh pr view`) for the review comment.
  On completion the reviewer PUSHES its own verdict back —
  `dispatch.sh assign <requester> <issue> "APPROVE: ..."` or
  `"REQUEST-CHANGES: ..."` — as a durable inbox message plus a nudge, in
  addition to posting the PR review comment; completion flows as a
  pushed message, not something the requester polls a bounded wait for.
  On APPROVE: `gh pr ready` + comment the issue. On REQUEST-CHANGES: fix
  in the same worktree and re-`assign`. You (Gate 2) only ever see ready,
  CI-green, reviewer-passed PRs.
- PR-body closing-keyword hygiene: GitHub (and merge-watch, same regex)
  treats "closes/fixes/resolves #N" ANYWHERE in a PR's title or body as a
  real closing reference, not just in the intended `Closes #N.` line.
  Closing-keyword phrasing belongs ONLY in the actual `Closes #N.`
  line(s); reword it elsewhere ("completed #N", "handled #N") so a
  description of past/unrelated work can't be misread as a new closing
  reference.
- Review-dispatch `.msg` template: every
  `dispatch.sh assign <reviewer> <issue> "..."` message MUST state the
  single-writer rule inline (below) — a reviewer's own hook config is a
  best-effort deny-list, not a substitute for the instruction actually
  reaching it. Minimum wording: "Review PR #<n> for issue #<n>. Run your
  /code-review skill (applies `review-protocol.md`). Post your verdict as
  a PR review comment (APPROVE/REQUEST-CHANGES), then push it back to me
  with `dispatch.sh assign <requester> <issue> "<verdict>"` — do not wait
  to be polled. Do NOT edit handoff.md or run git write ops
  (restore/checkout/commit/reset) in this checkout — see the
  single-writer rule below." If the diff touches auth, a `guard*.sh`
  script, or any push/merge path, it's a **risky diff** — also explicitly
  ask for the dedicated security pass `review-protocol.md` describes for
  that diff class, not just the general rubric.
- Merge-watch: the watch pane runs `lib/watch.sh`, not a bare `watch`
  command. Each loop iteration it also: (1) polls for newly-merged PRs
  and comment+closes the linked issue directly (mechanical, no agent
  dispatch), parsed from a "Closes/Fixes/Resolves #N" in the PR's title
  or body, falling back to the issue number embedded in a
  `feature/issue-<N>` head branch name; a merge with none of the three is
  skipped, not retried forever; (2) drains `dispatch.sh`'s deferred-nudge
  queue so a nudge skipped because the target pane was busy actually gets
  retried once that pane goes idle; (3) pane-liveness — detects an agent
  pane that dropped back to a plain shell and FLAGs orchestra via the
  inbox. Guard rule: `watch.sh` never merges anything itself.
- Escalation path: when Builder hits a decision point or finds a defect
  outside its ticket's scope, it does NOT just note it in the PR — it
  dispatches it to Orchestra: `dispatch.sh assign orchestra <issue>
  "FLAG: <summary + options>"`. Orchestra triages: acts directly if it's
  within existing policy, or surfaces it to you with options + a lean if
  it's a real design/priority decision. Builder never self-decides a
  scope change; Orchestra never silently absorbs a decision that belongs
  to you.

## Handoff Protocol (MANDATORY)
- Before starting ANY work: read `.harness/handoff.md` (current task
  state), `.harness/decisions.log` (durable cross-session context — past
  decisions and why), your project's memory, and your project's
  epic/task tracker.
- Before ending ANY stage or session: update `.harness/handoff.md` with:
  current task/issue #, branch, what's done, what's next, gotchas.
- **Replace, don't append — history lives in git**: `handoff.md` is a
  ≤80-line CURRENT-STATE file, not an append log. Every session REPLACES
  the "Task in flight" / "Recently done" / "Next" / "Gotchas" content
  with the current picture. `git log -p .harness/handoff.md` IS the
  archive. `check-handoff.sh` (Stop hook) additionally WARNS (does not
  block) when the file exceeds ~100 lines, as a drift signal.
- **`handoff.md` is ephemeral, `decisions.log` is durable**: `handoff.md`
  only ever describes the CURRENT session's state and gets replaced
  wholesale next session — it is not where you look for why a past
  decision was made. `decisions.log` (append-only, every agent may add to
  it) plus your project's memory are the durable record; point future
  readers there, not at `handoff.md`.
- Hooks enforce this. Do not fight the hooks.
- **Single-writer rule for shared state**: only the agent that OWNS the
  current stage writes `handoff.md` in the shared repo checkout — that's
  Builder during BUILD/TEST, Orchestra during PICK/PLAN, Scribe during
  its own SCRIBE stage. Reviewer and any other non-stage-owning agent
  NEVER `Edit`/write `handoff.md`, and NEVER run a git write op
  (`restore`, `checkout`, `commit`, `reset` — enforce this for
  non-Claude reviewers via `guard-agy.sh` + `banned-patterns.txt` or an
  equivalent deny-list) in the shared checkout. Reviewer/Scribe output
  goes ONLY to: the PR (review comment / `gh pr` calls), the inbox
  `.ack`, and `decisions.log` (via `lib/log-decision.sh`, safe to call
  concurrently — see below).
- `decisions.log` is the one exception: every agent may append to it
  (via `log-decision.sh`, never by hand) since it's append-only and
  lock-protected (`mkdir`-based) so concurrent appends never collide.
- PreCompact checkpoint: `hooks/pre-compact-checkpoint.sh` runs on the
  PreCompact hook and writes a dated "COMPACT CHECKPOINT" block to
  `handoff.md` (session id, trigger, branch/issue, dirty-tree flag)
  before compaction distills/drops raw context — REPLACING its own
  previous block (via `lib/handoff-lib.sh`'s `handoff_replace_section`)
  rather than piling up a new one every firing. It's a floor, not a
  replacement for the session's own handoff update — a hook script can
  pin WHEN compaction happened, not synthesize what's actually done/next.
  `hooks/rate-limit-handoff.sh` (StopFailure/rate_limit hook) uses the
  same shared replace helper for its own "RATE-LIMITED" section.

## Quota Failsafe (80% rule)
- If told usage crossed 80% (5h or weekly window), or you hit a rate
  limit: STOP current work, update `.harness/handoff.md` fully, then ask
  exactly this, verbatim and nothing else:
  "Quota [pool] at X%. Options: (a) switch to [fallback] (b) throttle
  models (c) continue. Pick one."
- Do NOT proceed until answered. Do NOT drift into conservation tips,
  recaps, or any other action — the question is the ONLY output.
- Fill `[pool]` (5h / weekly), `X` (the reported %), and `[fallback]`
  (the agreed fallback tool/model). Keep the (a)/(b)/(c) structure
  exactly.
- Never silently continue past a quota warning.
- On resume in another tool: first message is always
  "Read `.harness/handoff.md` and `AGENTS.md`, continue current task."

## Hard Rules
- Never merge to your integration branch or main yourself. Ever.
- Never force-push.
- Log every substantial model decision in `.harness/decisions.log` (one
  line: date, role, model, decision) via
  `lib/log-decision.sh "role|model|decision"` rather than editing the
  file by hand.
