# AGENTS.md — Harness Rules (single source of truth)

> Template shipped by [agent-orchestra](https://github.com/immuhammad/agent-orchestra).
> Copy this into your project root, fill in the `<PROJECT>` placeholders,
> and delete this blockquote. Keep this file as your single source of
> truth — tool-specific files (CLAUDE.md, GEMINI.md,
> .github/copilot-instructions.md) only add tool-specific lanes and must
> never contradict it.

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

Fill from `orchestrator.yaml`'s `roles:` block (what `orc up` and the
guards actually read) — keep this table in sync as the human-facing
summary.

## Skills — auto-use by role
Skills below are AUTO-USED for their stage, not only when asked — name
them in dispatch messages so they fire every time.

| Role      | Stage                                | Auto-use skills |
|-----------|---------------------------------------|------------------|
| Builder   | BUILD/TEST                            | test-driven-development, systematic-debugging, verification-before-completion, using-git-worktrees |
| Builder   | before dispatching to reviewer        | requesting-code-review |
| Builder   | after reviewer's verdict (fix-loop)   | receiving-code-review |
| Reviewer  | REVIEW                                | code-review (applies `review-protocol.md`) |
| Orchestra | PICK/PLAN                             | brainstorming, writing-plans |

Add project-specific skills as adopted — keep the pack CAPPED and
evaluated on adoption, not bulk-imported.

## The Loop (per task)
1. PICK: Orchestra picks the next issue from the current milestone.
2. PLAN: Orchestra posts an implementation plan as an issue comment.
   -- HUMAN GATE 1: you approve --
3. BUILD: Implementer branches `feature/issue-<n>`, codes, commits.
4. TEST: Tester writes + runs tests locally.
5. CI: push → CI (lint + tests) must pass.
6. REVIEW: Builder dispatches Reviewer directly and iterates on
   REQUEST-CHANGES until APPROVE (see Dispatch Protocol) — cross-family,
   so it isn't grading its own work.
7. SCRIBE: PR summary, update the issue, update your harness state files.
   -- HUMAN GATE 2: you merge --
8. Next issue. Repeat until the milestone is done.

## Dispatch Protocol
- All agent↔agent messaging uses the file inbox and
  `lib/dispatch.sh <verb> <agent> <issue> "<msg>" [timeout_s]`. A message
  is always a durable file (`.harness/inbox/<agent>/<ts>-<issue>.msg`); a
  receiver acknowledges by writing the matching `.ack` next to it — a
  one-line receipt of what actually happened, never a bare `touch`/empty
  file (that tells the sender nothing). Three verbs:
  - `handoff` — write `.msg`, nudge if idle, then POLL for the `.ack`,
    bounded by `timeout_s` (default 120s). Use when you must block on the
    result. On timeout: don't retry blindly — check the pane, then
    re-dispatch or escalate.
  - `assign` — write `.msg`, nudge if idle, return immediately.
    Fire-and-forget work.
  - `message` — write `.msg` only. No nudge, no ack expected — FYI notes
    picked up on the receiver's own schedule.
- **Completion is symmetric, not polled.** On finishing (or blocking on)
  dispatched work, PUSH the outcome back —
  `assign <requester> <issue> "<OUTCOME>: ..."` (BUILD-DONE, FIX-PUSHED,
  APPROVE, REQUEST-CHANGES, FLAG) — rather than the requester polling or
  spawning a background task to watch acks. The `.ack` beside the
  original `.msg` is only ever a passive arrival receipt, never the
  completion signal.
- Nudge = one-line `tmux send-keys "check inbox"` into the receiver's
  pane, sent only when idle (`lib/dispatch.sh`'s `pane_is_idle` is the
  single source of truth — don't reimplement it). On doubt this errs
  toward "busy": a missed nudge only delays pickup, while nudging a busy
  pane injects stray keystrokes mid-generation.
- Pane map (window index 0, tiled) matches `bin/orc`'s layout:
  0=orchestra 1=builder 2=reviewer 3=gatekeeper 4=watch — Scribe has no
  standing pane; a dispatch spawns it as a one-shot headless run instead
  of nudging an existing session. Target panes by index (`<session>:0.N`),
  never by window name (renamed to `control-room` at launch). An
  out-of-range index resolves to the invoking client's own current pane
  rather than erroring — double-check pane count before targeting by
  index.
- **Build-dispatch authority.** A BUILD dispatch that already carries
  Gate-1 approval MUST end with an explicit authority line, so the
  receiving agent acts instead of re-confirming a gate already passed:
  "This message IS your Gate-1 approval. START NOW. Do NOT reply asking
  whether to proceed. Escalate only per the escalation rule below — a
  genuine decision point, or a defect outside your ticket. Asking
  permission to begin is not escalation; it is a stall. Report back when
  finished or blocked via `dispatch.sh assign orchestra <issue>
  "<OUTCOME>: ..."` (BUILD-DONE, FIX-PUSHED, or FLAG) — do not wait to be
  polled."
- **Review flow: Builder runs it directly; Orchestra is a gate, not a
  switchboard.** Builder opens the PR as DRAFT, `assign`s the reviewer
  (fire-and-forget — reviews can run long, and a bounded `handoff` poll
  that outruns its timeout risks stranding an already-completed verdict).
  Builder does not block on this dispatch: it polls the PR itself
  (`gh pr view`) for the review comment. The reviewer posts its verdict
  BOTH as a PR comment AND a pushed message (`assign <requester> <issue>
  "APPROVE: ..."` / `"REQUEST-CHANGES: ..."`) — never something the
  requester polls a bounded wait for. Builder ↔ Reviewer iterate directly
  on REQUEST-CHANGES (fix, re-`assign`) with NO Orchestra hop. Builder
  returns to Orchestra only on: (a) APPROVE, (b) 2 rounds with no APPROVE
  (repeated REQUEST-CHANGES usually means the design is wrong — an
  Orchestra-level call), or (c) a genuine decision point / out-of-ticket
  defect (escalate below). **The 2-round review loop is Builder's;
  ready/merge authority did NOT move with it** — on APPROVE, Orchestra
  (not Builder) does `gh pr ready` + comments the issue, on to Gate 2.
  Builder never flips a PR to ready. You (Gate 2) only ever see ready,
  CI-green, reviewer-passed PRs.
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
- PR-body closing-keyword hygiene: GitHub (and merge-watch's regex) treats
  "closes/fixes/resolves #N" ANYWHERE in a PR's title/body as a real
  closing reference. Keep that phrasing ONLY in the actual `Closes #N.`
  line; reword mentions of past/unrelated work ("completed #N", "handled
  #N") so they can't be misread as a new closing reference.
- Merge-watch (`lib/watch.sh`, not a bare `watch` command) each
  iteration: (1) comments+closes the linked issue directly on a merged
  PR — mechanical, no dispatch — parsed from "Closes/Fixes/Resolves #N"
  in the title/body, falling back to a `feature/issue-<N>` head branch;
  unresolvable = skipped, not retried forever; (2) drains `dispatch.sh`'s
  deferred-nudge queue so a nudge skipped for a busy pane retries once it
  goes idle; (3) flags Orchestra via the inbox if an agent pane drops
  back to a plain shell. `watch.sh` never merges anything itself.
- **Escalation path.** Builder AND Reviewer (any non-Orchestra agent)
  route every decision point or out-of-ticket defect to Orchestra via
  FLAG — never directly to you, never self-decided:
  `dispatch.sh assign orchestra <issue> "FLAG: <summary + options>"`.
  Orchestra triages: acts directly if it's within existing policy, or
  surfaces it to you with options + a lean (a recommendation, never a
  bare list) if it's genuinely your call — and ALWAYS replies to the
  flagging agent with the disposition, closing the loop. Orchestra never
  silently absorbs a decision that belongs to you. Asking whether to
  start work a dispatch already authorized (see Build-dispatch authority)
  is not escalation — it's a stall.

## Handoff Protocol (MANDATORY)
- Before starting ANY work: read `.harness/handoff.md` (current state),
  `.harness/decisions.log` (durable cross-session context), your
  project's memory, and its issue tracker.
- Before ending ANY stage/session: update `.harness/handoff.md` with:
  current task/issue #, branch, what's done, what's next, gotchas.
- **Replace, don't append.** `handoff.md` is a ≤80-line CURRENT-STATE
  file every session REPLACES wholesale — its "Task in flight" /
  "Recently done" / "Next" / "Gotchas" sections, not a log
  (`git log -p .harness/handoff.md` is the archive); it describes only the
  CURRENT session, never why a past decision was made — `decisions.log`
  (append-only) plus your project's memory are the durable record for
  that. `check-handoff.sh` (Stop hook) WARNS, doesn't block, past ~100
  lines as a drift signal.
- Hooks enforce this. Do not fight the hooks.
- **Single-writer rule for shared state**: only the agent OWNING the
  current stage writes `handoff.md` (Builder during BUILD/TEST, Orchestra
  during PICK/PLAN, Scribe during its own stage). Every other agent NEVER
  writes `handoff.md` or runs a git write op (`restore`/`checkout`/
  `commit`/`reset` — enforce this for non-Claude reviewers via
  `guard-agy.sh` + `banned-patterns.txt` or an equivalent deny-list) in
  the shared checkout. Non-owning output goes ONLY to: the PR (review
  comment / `gh pr` calls), the inbox `.ack`, and `decisions.log`.
- `decisions.log` is the one exception: every agent may append via
  `log-decision.sh` (never by hand) — append-only and lock-protected
  (`mkdir`-based), so concurrent appends never collide.
- PreCompact checkpoint: `hooks/pre-compact-checkpoint.sh` writes a dated
  "COMPACT CHECKPOINT" block to `handoff.md` before compaction (session
  id, trigger, branch/issue, dirty-tree flag), REPLACING its own previous
  block (via `lib/handoff-lib.sh`'s `handoff_replace_section`) rather
  than piling up. A floor, not a substitute for your own
  handoff update — it pins WHEN compaction happened, not what's actually
  done/next. `hooks/rate-limit-handoff.sh` (StopFailure/rate_limit hook)
  writes its own self-replacing "RATE-LIMITED" section the same way.

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
