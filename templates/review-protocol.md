# Review Protocol

The single source of truth for how a PR review in this project is
conducted, regardless of which agent (any reviewer, current or future) is
doing it. Dispatch messages and skill wrappers reference this file rather
than re-stating it, so there is exactly one place to update the method.

## Stance: adversarial, not confirmatory

Start from the assumption that the diff contains a defect and your job is
to find it, not to confirm it looks fine. **Approving a PR without having
run a concrete probe list against it is not a review** — it's a rubber
stamp with extra steps. If nothing survives a genuine attempt to break the
change, say so explicitly (see Evidence bar below); don't skip the attempt
because the diff looks small or the author seems careful.

## Rubric

Work through each lens deliberately — don't stop at the first thing that
looks fine:

1. **Edge-case correctness.** Empty input, zero/negative/boundary values,
   concurrent access, first-run vs. Nth-run state, what happens when a
   dependency the code assumes is present isn't.
2. **Failure modes.** What does this do when the thing it calls fails —
   network error, missing file, malformed data, a process that's killed
   mid-operation? Silent failure and misleading success are both defects.
3. **Test honesty.** Do the tests actually exercise the claimed behavior,
   or do they pass regardless of whether the fix works (a mocked-away
   assertion, a test that would pass on the OLD code too)? A test suite
   that's green for the wrong reason is worse than no test.
4. **Security — first-class, not a footnote.** Every review gets this
   lens, not just diffs that look security-flavored: injection (shell,
   SQL, path traversal), secrets in logs/commits, privilege/permission
   changes, trust boundaries crossed (does this diff let one agent write
   somewhere it previously couldn't?). See "Risky diffs" below for the
   cases that need a *dedicated* pass, not just this checklist item.
5. **Deletion candidates.** Code, comments, or abstractions this diff
   makes redundant but doesn't remove. Leftover debug scaffolding.
   Duplicated logic that should have called something that already
   exists.
6. **Guard / single-writer compliance.** Does the diff respect this
   project's protected-path rules (`orchestrator.yaml`'s
   `protected_paths` via `lib/orc-config.sh`), the single-writer rule for
   `decisions.log`, and the never-force-push / never-merge-directly hard
   rules in `AGENTS.md`? A change that works but routes around a guard
   instead of through it is a defect even if it "passes."

## Risky diffs get a dedicated security pass

A diff touching **auth, guard scripts (`guard*.sh`), or any push/merge
path** (`orc-worktree.sh`, dispatch's pane-targeting, anything that writes
to a protected path or a shared branch) needs an explicit, separate pass
asking only: *what could this let someone (or some agent) do that they
couldn't before, and is that intended?* Don't fold this into the general
rubric pass for these diffs — call it out as its own step, since it's
exactly the class of defect a general "does this look right" read is most
likely to skim past.

## Evidence bar

- **REQUEST-CHANGES** items must cite `file:line` and describe a
  *concrete* failure scenario — specific input/state that produces a
  specific wrong output or crash. "This seems risky" or "consider edge
  cases" without a scenario is not an actionable finding; keep digging
  until you have one, or drop it.
- **APPROVE** must come with the explicit probe list you actually ran —
  what you tried to break and why it held. An approval with no probe list
  attached doesn't meet the bar, regardless of how the diff looks.

## Verdict

Post the verdict as an ordinary PR comment (see `AGENTS.md`'s
Reviewer-identity policy — a reviewer with no formal platform-native
reviewer seat makes the comment itself the official record): `APPROVE`
with the probe list, or `REQUEST-CHANGES` with the findings (each
`file:line` + failure scenario). Ack the dispatch message with a one-line
summary of the verdict once posted.
