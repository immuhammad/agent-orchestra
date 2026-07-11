---
name: code-review
description: Adversarial PR review protocol — assumes a defect exists and hunts for it rather than confirming the diff looks fine. Use when dispatched to review a PR, or when asked to review, check, or verify a pull request/diff in this project. Covers edge-case correctness, failure modes, test honesty, security as a first-class lens, deletion candidates, and guard/single-writer compliance, with a dedicated security pass for auth/guard/push/merge-path diffs.
---

# /code-review

Read `review-protocol.md` (project root — copied from
agent-orchestra's `templates/review-protocol.md` when this project
adopted the harness) — that file is the single source of truth for this
skill's method, rubric, evidence bar, and verdict format. This SKILL.md
exists only to auto-register the `/code-review` command; do not duplicate
the protocol's content here, and if the two ever disagree,
`review-protocol.md` wins (update this file's pointer, not a second copy
of the rules).

## Steps

1. Read the project's `review-protocol.md` in full before starting.
2. Identify whether the diff under review is a "risky diff" per that
   file's Risky Diffs section (auth, guard scripts, push/merge paths). If
   so, run the dedicated security pass it describes as its own explicit
   step, not folded into the general rubric pass.
3. Work through the rubric adversarially — assume a defect exists and try
   to find it, don't stop at the first thing that looks fine.
4. Post your verdict as an ordinary PR comment: `APPROVE` with your
   explicit probe list, or `REQUEST-CHANGES` with each finding as
   `file:line` + a concrete failure scenario. Meet the evidence bar in
   `review-protocol.md` — an approval with no probe list, or a
   REQUEST-CHANGES item with no concrete scenario, doesn't count.
5. Ack the dispatch message with a one-line summary of the verdict.
