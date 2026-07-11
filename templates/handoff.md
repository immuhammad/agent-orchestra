# HANDOFF — read me first, update me before you stop
Last updated: <date>
Updated by: <role/session — e.g. "Orchestra (fresh session)">

**Note: this file is REPLACED each session, not appended to.** Hard
target ≤80 lines. History lives in git (`git log -p .harness/handoff.md`).

## Task in flight
**#<issue> — <STAGE>.** One or two sentences on what's actually in
progress right now and why.

## Recently done (most recent first)
- Most recent completed item first, one or two lines each.

## Next
1. What happens after the task in flight lands.
2. Anything queued behind it.

## Gotchas
- Anything a cold session needs to know before touching this that isn't
  obvious from the code (a stuck-state workaround, a known flaky check,
  a decision still awaiting a human answer).
- On resume in another tool: first message is always
  "Read .harness/handoff.md and AGENTS.md, continue current task."
