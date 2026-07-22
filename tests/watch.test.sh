#!/bin/bash
# .harness/watch.test.sh — TDD tests for watch.sh (T24, issue #34):
# merge-watch, deferred-nudge retry, pane-liveness. Run: bash watch.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
TEST_SESSION="harness-watch-test"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() {
  tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Source watch.sh (pulls in dispatch.sh too) under test-isolated state
# files so nothing here touches the real merge-watch/deferred-nudge/
# liveness state or the real "harness" session's inboxes.
MERGE_WATCH_STATE="$TMP/merge-watch-state"
WATCH_FLAGGED_DEAD_FILE="$TMP/flagged-dead"
DISPATCH_DEFERRED_FILE="$TMP/deferred-nudges"
WATCH_EVENTS_LOG="$TMP/events.log"
REVIEW_WATCH_STATE="$TMP/review-watch-state"
export MERGE_WATCH_STATE WATCH_FLAGGED_DEAD_FILE DISPATCH_DEFERRED_FILE WATCH_EVENTS_LOG REVIEW_WATCH_STATE
source "$LIB/watch.sh"

# Captured immediately after the real source, before any test below
# redefines these -- lets later tests restore JUST these two functions
# surgically (via `eval`) without resetting anything ELSE a still-running
# earlier test's mock (e.g. mw_teardown_branch) depends on staying mocked.
REAL_RW_FETCH_PR_COMMENTS="$(declare -f rw_fetch_pr_comments)"
REAL_RW_FETCH_OPEN_DRAFT_PRS="$(declare -f rw_fetch_open_draft_prs)"

echo "== mw_extract_issue: parses linked issue from title+body text =="
[ "$(mw_extract_issue 'Closes #34.')" = "34" ] && pass "Closes #N" || fail "Closes #N"
[ "$(mw_extract_issue 'fixes #40 also')" = "40" ] && pass "fixes #N (lowercase)" || fail "fixes #N (lowercase)"
[ "$(mw_extract_issue 'Resolved #7')" = "7" ] && pass "Resolved #N" || fail "Resolved #N"
[ -z "$(mw_extract_issue 'no issue reference here')" ] && pass "no match returns empty" || fail "no match should return empty"

echo "== mw_extract_all_issues: T31 (#68 item B) returns EVERY distinct Closes/Fixes/Resolves ref =="
MULTI="$(mw_extract_all_issues 'Closes #55.
Closes #56.')"
if [ "$(echo "$MULTI" | tr '\n' ' ' | sed 's/ $//')" = "55 56" ]; then
  pass "two Closes refs both extracted, in order"
else
  fail "expected '55 56', got: $(echo "$MULTI" | tr '\n' ' ')"
fi
[ "$(mw_extract_all_issues 'Closes #34.' | tr '\n' ' ' | sed 's/ $//')" = "34" ] && pass "single ref still works" || fail "single ref should still work"
[ -z "$(mw_extract_all_issues 'no issue reference here')" ] && pass "no match returns empty" || fail "no match should return empty"
DEDUPE="$(mw_extract_all_issues 'Closes #34. Also closes #34 again, and fixes #40.' | tr '\n' ' ' | sed 's/ $//')"
[ "$DEDUPE" = "34 40" ] && pass "duplicate ref is deduped, order preserved" || fail "expected '34 40' deduped, got: $DEDUPE"

echo "== mw_extract_issue_from_branch: T30 (#56) fallback when title/body have no ref =="
[ "$(mw_extract_issue_from_branch 'feature/issue-55')" = "55" ] && pass "feature/issue-N branch" || fail "feature/issue-N branch"
[ -z "$(mw_extract_issue_from_branch 'main')" ] && pass "non-matching branch returns empty" || fail "non-matching branch should return empty"

echo "== issue #18 item 5 (C1): a SEEDED state file locks the seam -- mw_already_processed is true, no replay =="
: > "$MERGE_WATCH_STATE"
mw_mark_processed "555"
if mw_already_processed "555"; then
  pass "a pre-seeded PR number reads as already-processed (no replay on a fresh room)"
else
  fail "a seeded PR number should read as already-processed"
fi
if ! mw_already_processed "556"; then
  pass "an UNSEEDED PR number still replays (current/expected behavior, not a regression)"
else
  fail "an unseeded PR number should NOT read as already-processed"
fi
: > "$MERGE_WATCH_STATE"

echo "== #47: mw_dev_target_root -- ORC_WORKTREE_REPO_ROOT wins outright, falls back to an optional dev_target_root config key =="
# The actual bug this closes: watch.sh runs from the HARNESS ROOT (per
# orc.sh's pane launch, no cd of its own), but in a self-dogfood room the
# real dev target (with the worktree/branch to tear down) is a SEPARATE
# nested clone -- orc-worktree.sh's own $PWD-based REPO_ROOT inference
# silently resolved to the wrong repo. This is unit-level: it only proves
# mw_dev_target_root resolves correctly, not orc-worktree.sh's own teardown
# plumbing (that has its own dedicated, live-repo coverage in
# tests/orc-worktree.test.sh, including a full wrong-repo reproduction).
FAKE_PROJECT="$TMP/fake-project-root"
mkdir -p "$FAKE_PROJECT"
unset ORC_WORKTREE_REPO_ROOT 2>/dev/null || true
NEITHER_SET="$(cd "$FAKE_PROJECT" && mw_dev_target_root)"
if [ -z "$NEITHER_SET" ]; then
  pass "neither override nor config key set -> empty (unchanged \$PWD-based default for a normal, non-nested consumer)"
else
  fail "expected empty with neither override set, got '$NEITHER_SET'"
fi

echo "dev_target_root: project/agent-orchestra" > "$FAKE_PROJECT/orchestrator.yaml"
CONFIG_RESULT="$(cd "$FAKE_PROJECT" && mw_dev_target_root)"
if [ "$CONFIG_RESULT" = "project/agent-orchestra" ]; then
  pass "reads the optional dev_target_root orchestrator.yaml key when set"
else
  fail "expected 'project/agent-orchestra' from the config key, got '$CONFIG_RESULT'"
fi

ENV_RESULT="$(cd "$FAKE_PROJECT" && ORC_WORKTREE_REPO_ROOT=/explicit/env/override mw_dev_target_root)"
if [ "$ENV_RESULT" = "/explicit/env/override" ]; then
  pass "ORC_WORKTREE_REPO_ROOT env var wins outright over the config key"
else
  fail "expected the env var to win over the config key, got '$ENV_RESULT'"
fi

echo "dev_target_root: project/agent-orchestra" > "$FAKE_PROJECT/orchestrator.yaml"
EMPTY_ENV_RESULT="$(cd "$FAKE_PROJECT" && ORC_WORKTREE_REPO_ROOT="" mw_dev_target_root)"
if [ -z "$EMPTY_ENV_RESULT" ]; then
  pass "#47 round 2 (agy) -- an explicitly-exported EMPTY ORC_WORKTREE_REPO_ROOT is a deliberate 'don't override' signal and still wins over the config key, not falling through to it"
else
  fail "#47 round 2 REGRESSION -- an explicit empty ORC_WORKTREE_REPO_ROOT should win outright (stay empty), not fall through to the config key, got '$EMPTY_ENV_RESULT'"
fi
rm -f "$FAKE_PROJECT/orchestrator.yaml"

# mw_teardown_branch is mocked to a harmless default (success, no-op) for
# every merge-watch case below unless a specific test overrides it -- it
# has its own dedicated coverage further down, and orc-worktree.sh's actual
# teardown behavior is already covered live in orc-worktree.test.sh, so
# these merge-watch cases just need to confirm merge_watch_check CALLS it
# with the right issue number, not re-verify teardown's own git plumbing.
TEARDOWN_CALLS="$TMP/teardown-calls.log"
: > "$TEARDOWN_CALLS"
mw_teardown_branch() { echo "$*" >> "$TEARDOWN_CALLS"; }

# mw_notify_pick (issue #105 Task 5) mocked the same way -- it has its own
# dedicated coverage further down, and without this mock every merge-watch
# case below would call the REAL dispatch_main and write into the real
# orchestra inbox / nudge a real pane.
PICK_CALLS="$TMP/pick-calls.log"
: > "$PICK_CALLS"
mw_notify_pick() { echo "$*" >> "$PICK_CALLS"; }

echo "== merge_watch_check: closes linked issue directly for new merges, skips already-processed =="
GH_CALLS="$TMP/gh-calls.log"
: > "$GH_CALLS"
gh() { echo "$*" >> "$GH_CALLS"; }
mw_fetch_merged_prs() {
  printf '101\tIssue #34 followups\tCloses #34, thanks all\tfeature/issue-34\n102\tsome PR\tno linked issue here\tsome-branch\n'
}
merge_watch_check
if grep -q 'issue comment 34' "$GH_CALLS" && grep -q 'issue close 34' "$GH_CALLS"; then
  pass "merge_watch_check commented+closed issue #34 for PR #101"
else
  fail "merge_watch_check should have commented+closed issue #34: $(cat "$GH_CALLS")"
fi
if grep -q '^102$' "$MERGE_WATCH_STATE" 2>/dev/null || grep -qxF '102' "$MERGE_WATCH_STATE" 2>/dev/null; then
  pass "PR #102 (no linked issue) marked processed without a gh call"
else
  fail "PR #102 should be marked processed even with no linked issue"
fi
if grep -q '102' "$GH_CALLS"; then
  fail "PR #102 has no linked issue, should NOT have called gh"
else
  pass "PR #102 correctly not closed"
fi

echo "== merge_watch_check: T31 (#68 item B) closes EACH linked issue in a multi-Closes PR body =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
mw_fetch_merged_prs() {
  # Real mw_fetch_merged_prs already gsub's body newlines to spaces before
  # emitting this tsv, so a two-line "Closes #55.\nCloses #56." PR body
  # arrives here as a single space-joined line -- match that shape.
  printf '166\tIssue #55\tCloses #55. Closes #56.\tfeature/issue-55\n'
}
merge_watch_check
if grep -q 'issue close 55' "$GH_CALLS" && grep -q 'issue close 56' "$GH_CALLS"; then
  pass "merge_watch_check closed BOTH #55 and #56 from a two-Closes PR body (dry-run of the real PR #66 case)"
else
  fail "merge_watch_check should have closed both #55 and #56: $(cat "$GH_CALLS")"
fi

echo "== merge_watch_check: T30 (#56) falls back to branch name when title+body have no Closes/Fixes/Resolves =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
mw_fetch_merged_prs() {
  printf '201\tIssue #34\tbundled T24+T25 work, no Closes verb in either title or body\tfeature/issue-34\n'
}
merge_watch_check
if grep -q 'issue close 34' "$GH_CALLS"; then
  pass "merge_watch_check fell back to the branch name for PR #201 (feature/issue-34 -> #34)"
else
  fail "merge_watch_check should have fallen back to the branch name for issue #34: $(cat "$GH_CALLS")"
fi

echo "== merge_watch_check: re-running does not re-close already-processed PRs =="
: > "$GH_CALLS"
merge_watch_check
if [ -s "$GH_CALLS" ]; then
  fail "re-running merge_watch_check should not re-close: $(cat "$GH_CALLS")"
else
  pass "already-processed PRs are not re-closed"
fi

echo "== merge_watch_check: a failed gh call is logged and does not block processing =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
gh() { echo "$*" >> "$GH_CALLS"; return 1; }
mw_fetch_merged_prs() {
  printf '401\tIssue #90\tCloses #90\tfeature/issue-90\n'
}
merge_watch_check
if grep -qxF '401' "$MERGE_WATCH_STATE" 2>/dev/null; then
  pass "PR #401 marked processed even though the gh close call failed"
else
  fail "PR #401 should still be marked processed after a failed gh call"
fi
gh() { echo "$*" >> "$GH_CALLS"; }

echo "== merge_watch_check: T5 (#85) tears down the worktree/branch for the PR's own head branch =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
: > "$TEARDOWN_CALLS"
mw_fetch_merged_prs() {
  printf '501\tIssue #77 followups\tCloses #77\tfeature/issue-77\n'
}
merge_watch_check
if grep -qxF '77' "$TEARDOWN_CALLS"; then
  pass "merge_watch_check called mw_teardown_branch for issue #77 (PR #501's own head branch)"
else
  fail "merge_watch_check should have called mw_teardown_branch for issue #77: $(cat "$TEARDOWN_CALLS")"
fi
if grep -q 'PR #501 merged -> removed worktree + merged branch for issue #77' "$WATCH_EVENTS_LOG" 2>/dev/null; then
  pass "successful teardown logged honest 'removed worktree + merged branch' wording"
else
  fail "expected a 'removed worktree + merged branch' event: $(cat "$WATCH_EVENTS_LOG" 2>/dev/null)"
fi

echo "== merge_watch_check: T5 (#85) skipped teardown is logged with its reason, non-fatal =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
: > "$TEARDOWN_CALLS"
: > "$WATCH_EVENTS_LOG"
mw_teardown_branch() { echo "$*" >> "$TEARDOWN_CALLS"; echo "worktree is dirty, flagged orchestra"; return 1; }
mw_fetch_merged_prs() {
  printf '502\tIssue #78 followups\tCloses #78\tfeature/issue-78\n'
}
merge_watch_check
if grep -q 'PR #502 merged -> teardown skipped: worktree is dirty, flagged orchestra' "$WATCH_EVENTS_LOG" 2>/dev/null; then
  pass "skipped teardown logged its actual reason, not a generic failure message"
else
  fail "expected a 'teardown skipped: worktree is dirty, flagged orchestra' event: $(cat "$WATCH_EVENTS_LOG" 2>/dev/null)"
fi
if grep -qxF '502' "$MERGE_WATCH_STATE" 2>/dev/null; then
  pass "PR #502 still marked processed even though teardown was skipped (non-fatal)"
else
  fail "PR #502 should still be marked processed after a skipped teardown"
fi
mw_teardown_branch() { echo "$*" >> "$TEARDOWN_CALLS"; }

echo "== merge_watch_check: T5 (#85) no teardown call when the head branch has no feature/issue-N shape =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
: > "$TEARDOWN_CALLS"
mw_fetch_merged_prs() {
  printf '503\tIssue #79 followups\tCloses #79\tsome-other-branch-name\n'
}
merge_watch_check
if [ -s "$TEARDOWN_CALLS" ]; then
  fail "should not have called mw_teardown_branch for a non-feature/issue-N branch: $(cat "$TEARDOWN_CALLS")"
else
  pass "no teardown call for a head branch that isn't feature/issue-N"
fi

echo "== merge_watch_check: issue #105 Task 5 -- dispatches a PICK-next nudge to orchestra after each processed PR =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
: > "$TEARDOWN_CALLS"
: > "$PICK_CALLS"
mw_fetch_merged_prs() {
  printf '601\tIssue #90 followups\tCloses #90\tfeature/issue-90\n602\tsome PR\tno linked issue here\tsome-branch\n'
}
merge_watch_check
if grep -qxF "601" "$PICK_CALLS" && grep -qxF "602" "$PICK_CALLS"; then
  pass "mw_notify_pick called for EVERY processed PR (issue-linked or not), not just ones with a teardown-able branch"
else
  fail "expected mw_notify_pick called for both PR #601 and #602: $(cat "$PICK_CALLS")"
fi

echo "== mw_notify_pick: dispatches via dispatch_main assign orchestra (write + nudge-if-idle) =="
if grep -q 'dispatch_main assign orchestra "\$pr"' "$LIB/watch.sh"; then
  pass "mw_notify_pick routes through dispatch_main's assign verb (durable .msg + nudge-if-idle)"
else
  fail "mw_notify_pick should call dispatch_main assign orchestra, not a raw pane write"
fi
echo "== #49: the ghost 'PHASE-3-PLAN' wording (no such plan ever existed) is gone from the actual dispatched message =="
if grep -q 'PICK next per PHASE-3-PLAN"' "$LIB/watch.sh"; then
  fail "#49 REGRESSION -- 'PICK next per PHASE-3-PLAN' (career-ops-harness ghost vocabulary) still present as the live dispatch text in watch.sh"
else
  pass "'PICK next per PHASE-3-PLAN' no longer appears as the live dispatch text in watch.sh"
fi
if grep -q 'PICK next per handoff.md / decisions.log' "$LIB/watch.sh"; then
  pass "the PICK-next message now points at handoff.md / decisions.log, sources that actually exist"
else
  fail "expected the updated 'PICK next per handoff.md / decisions.log' wording in mw_notify_pick"
fi

echo "== review_watch_check: APPROVE on a draft PR flips it ready + delivers ONE durable msg to builder+orchestra =="
RW_GH_CALLS="$TMP/rw-gh-calls.log"
RW_NOTIFY_CALLS="$TMP/rw-notify-calls.log"
: > "$RW_GH_CALLS"
: > "$RW_NOTIFY_CALLS"
gh() { echo "$*" >> "$RW_GH_CALLS"; }
rw_notify() { echo "$*" >> "$RW_NOTIFY_CALLS"; }
rw_fetch_open_draft_prs() {
  printf '201\tIssue 70 fix\tCloses #70\tfeature/issue-70\n'
}
rw_fetch_pr_comments() {
  printf '2026-07-21T10:00:00Z\tAPPROVE: looks good\n'
}
review_watch_check
if grep -q 'pr ready 201' "$RW_GH_CALLS"; then
  pass "issue #96: review_watch_check flipped PR #201 to ready via gh pr ready"
else
  fail "expected 'gh pr ready 201', got: $(cat "$RW_GH_CALLS")"
fi
if grep -q 'builder 70' "$RW_NOTIFY_CALLS" && grep -q 'orchestra 70' "$RW_NOTIFY_CALLS"; then
  pass "issue #96: review_watch_check notified BOTH builder and orchestra on APPROVE"
else
  fail "expected notifications to both builder and orchestra: $(cat "$RW_NOTIFY_CALLS")"
fi
NOTIFY_COUNT="$(wc -l < "$RW_NOTIFY_CALLS" | tr -d ' ')"
if [ "$NOTIFY_COUNT" -eq 2 ]; then
  pass "issue #96: exactly 2 notify calls on APPROVE (builder + orchestra), not more"
else
  fail "expected exactly 2 notify calls, got $NOTIFY_COUNT: $(cat "$RW_NOTIFY_CALLS")"
fi

echo "== review_watch_check: REQUEST-CHANGES delivers a msg to builder only, does NOT flip ready =="
: > "$RW_GH_CALLS"
: > "$RW_NOTIFY_CALLS"
rw_fetch_open_draft_prs() {
  printf '202\tIssue 71 fix\tCloses #71\tfeature/issue-71\n'
}
rw_fetch_pr_comments() {
  printf '2026-07-21T10:00:00Z\tREQUEST-CHANGES: needs work\n'
}
review_watch_check
if grep -q 'pr ready 202' "$RW_GH_CALLS"; then
  fail "CORRECTNESS REGRESSION (issue #96): REQUEST-CHANGES should NOT flip the PR to ready: $(cat "$RW_GH_CALLS")"
else
  pass "issue #96: REQUEST-CHANGES does not flip the PR to ready"
fi
if grep -q 'builder 71' "$RW_NOTIFY_CALLS"; then
  pass "issue #96: REQUEST-CHANGES notifies builder"
else
  fail "expected a builder notification: $(cat "$RW_NOTIFY_CALLS")"
fi
if grep -q 'orchestra' "$RW_NOTIFY_CALLS"; then
  fail "CORRECTNESS REGRESSION (issue #96): REQUEST-CHANGES should not notify orchestra: $(cat "$RW_NOTIFY_CALLS")"
else
  pass "issue #96: REQUEST-CHANGES does not notify orchestra"
fi

echo "== review_watch_check: re-tick with the SAME already-delivered verdict does not re-deliver (idempotent) =="
: > "$RW_GH_CALLS"
: > "$RW_NOTIFY_CALLS"
# same PR #201, same APPROVE verdict as the first test above -- already
# recorded in REVIEW_WATCH_STATE from that run.
rw_fetch_open_draft_prs() {
  printf '201\tIssue 70 fix\tCloses #70\tfeature/issue-70\n'
}
rw_fetch_pr_comments() {
  printf '2026-07-21T10:00:00Z\tAPPROVE: looks good\n'
}
review_watch_check
if [ -s "$RW_GH_CALLS" ] || [ -s "$RW_NOTIFY_CALLS" ]; then
  fail "CORRECTNESS REGRESSION (issue #96): re-tick with the same already-delivered verdict should not re-deliver: gh=$(cat "$RW_GH_CALLS") notify=$(cat "$RW_NOTIFY_CALLS")"
else
  pass "issue #96: re-tick with the same verdict already delivered is a no-op"
fi

echo "== review_watch_check: a PR that moves from REQUEST-CHANGES to a LATER APPROVE delivers the new APPROVE (latest verdict wins, not first) =="
: > "$RW_GH_CALLS"
: > "$RW_NOTIFY_CALLS"
# PR #202 already had REQUEST-CHANGES delivered (second test above); the
# fix-loop's re-review now adds a LATER APPROVE comment.
rw_fetch_open_draft_prs() {
  printf '202\tIssue 71 fix\tCloses #71\tfeature/issue-71\n'
}
rw_fetch_pr_comments() {
  printf '2026-07-21T10:00:00Z\tREQUEST-CHANGES: needs work\n2026-07-21T12:00:00Z\tAPPROVE: fixed now, approved\n'
}
review_watch_check
if grep -q 'pr ready 202' "$RW_GH_CALLS"; then
  pass "issue #96: the later APPROVE is delivered even though PR #202 already had REQUEST-CHANGES delivered earlier (latest verdict wins)"
else
  fail "CORRECTNESS REGRESSION (issue #96): expected the new APPROVE to be delivered: $(cat "$RW_GH_CALLS")"
fi
if grep -q 'orchestra 71' "$RW_NOTIFY_CALLS"; then
  pass "issue #96: the new APPROVE notifies orchestra too (the REQUEST-CHANGES round never did)"
else
  fail "expected an orchestra notification for the new APPROVE: $(cat "$RW_NOTIFY_CALLS")"
fi

echo "== review_watch_check: a comment that looks verdict-ish but isn't ANCHORED is skipped, never guessed at =="
: > "$RW_GH_CALLS"
: > "$RW_NOTIFY_CALLS"
rw_fetch_open_draft_prs() {
  printf '203\tIssue 72 fix\tCloses #72\tfeature/issue-72\n'
}
rw_fetch_pr_comments() {
  printf '2026-07-21T10:00:00Z\tI think we should approve this once CI passes\n2026-07-21T10:05:00Z\tapprove: lowercase, not the protocol format\n'
}
review_watch_check
if [ -s "$RW_GH_CALLS" ] || [ -s "$RW_NOTIFY_CALLS" ]; then
  fail "CORRECTNESS REGRESSION (issue #96): an unanchored/malformed verdict-ish comment should never be delivered: gh=$(cat "$RW_GH_CALLS") notify=$(cat "$RW_NOTIFY_CALLS")"
else
  pass "issue #96: malformed/unanchored verdict-ish comments are skipped, never guessed at"
fi

echo "== review_watch_check: a PR no longer open+draft (already ready, or already merged) is a structural no-op =="
: > "$RW_GH_CALLS"
: > "$RW_NOTIFY_CALLS"
# Simulates Orchestra having already flipped this PR ready (or merged it)
# between ticks -- rw_fetch_open_draft_prs is scoped to open+draft, so a
# PR in either state simply no longer appears; review_watch_check has
# nothing to iterate and makes zero calls.
rw_fetch_open_draft_prs() {
  :
}
review_watch_check
if [ -s "$RW_GH_CALLS" ] || [ -s "$RW_NOTIFY_CALLS" ]; then
  fail "CORRECTNESS REGRESSION (issue #96): a PR no longer open+draft should produce zero calls: gh=$(cat "$RW_GH_CALLS") notify=$(cat "$RW_NOTIFY_CALLS")"
else
  pass "issue #96: a PR no longer open+draft (already ready/merged) is a structural no-op"
fi

echo "== review_watch_check: a draft PR with no resolvable issue (no Closes/Fixes/Resolves, no feature/issue-N branch) is skipped, not guessed at =="
: > "$RW_GH_CALLS"
: > "$RW_NOTIFY_CALLS"
rw_fetch_open_draft_prs() {
  printf '204\tSome PR\tno linked issue here\tsome-random-branch\n'
}
rw_fetch_pr_comments() {
  printf '2026-07-21T10:00:00Z\tAPPROVE: looks good\n'
}
review_watch_check
if [ -s "$RW_GH_CALLS" ] || [ -s "$RW_NOTIFY_CALLS" ]; then
  fail "a draft PR with no resolvable issue should never be delivered: gh=$(cat "$RW_GH_CALLS") notify=$(cat "$RW_NOTIFY_CALLS")"
else
  pass "issue #96: a draft PR with no resolvable issue is skipped"
fi

echo "== review round 2 (agy finding 1): rw_latest_verdict against the REAL (unmocked) rw_fetch_pr_comments -- every test above mocked rw_fetch_pr_comments directly and never actually exercised the real jq newline-sentinel pipeline at all =="
# Restore the REAL rw_fetch_pr_comments/rw_fetch_open_draft_prs: earlier
# tests above redefined these directly (the established mocking pattern in
# this file), and a bash function redefinition persists for the rest of
# the script until explicitly undone -- without this, these tests would
# silently call whichever earlier test's stale mock was defined last
# instead of the real implementation, which is exactly what happened
# writing this block (a stale mock made both new assertions read from the
# SAME canned data regardless of PR number, passing one and failing the
# other for the wrong reason entirely).
# `unset -f` alone would just DELETE the function rather than restore it.
# Re-sourcing the whole file would restore it but ALSO reset every OTHER
# function back to real -- including mw_teardown_branch, which a LATER
# test in this file depends on staying mocked from an EVEN EARLIER
# override (found live: re-sourcing here made that later test's
# merge_watch_check call a REAL orc-worktree.sh teardown subprocess
# instead of its intended mock). `eval`-ing the captured definitions
# restores JUST these two functions, surgically.
eval "$REAL_RW_FETCH_PR_COMMENTS"
eval "$REAL_RW_FETCH_OPEN_DRAFT_PRS"
# gh's own `--jq` flag runs jq INSIDE the gh binary -- overriding the `gh`
# shell function loses that entirely unless the mock replicates it. This
# mock forwards the REAL --jq expression rw_fetch_pr_comments actually
# passes to a REAL local jq run against a canned fixture file, so this is
# genuine coverage of the sentinel gsub/implode + tr restore logic, not a
# re-mock of the thing under test.
gh() {
  if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    local pr="$3" jqexpr="" fixture="$TMP/rw-fixture-$3.json"
    shift 3
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--jq" ]; then jqexpr="$2"; break; fi
      shift
    done
    if [ -n "$jqexpr" ] && [ -f "$fixture" ]; then
      jq -r "$jqexpr" "$fixture" 2>/dev/null
    fi
    return 0
  fi
  echo "$*" >> "$RW_GH_CALLS"
}

cat > "$TMP/rw-fixture-301.json" <<'EOF'
{"comments": [{"createdAt": "2026-01-01T00:00:00Z", "body": "APPROVE:\n\nProbe 1: verified input handling.\nProbe 2: verified the guard rule.\nLooks good."}]}
EOF
RW_VERDICT_301="$(rw_latest_verdict 301)"
if [ "$RW_VERDICT_301" = "APPROVE" ]; then
  pass "issue #96 review round 2: a genuine multi-line APPROVE comment (verdict line + probe list on later lines) restores correctly through the real jq pipeline and start-anchors as APPROVE"
else
  fail "CORRECTNESS REGRESSION (issue #96 review round 2): expected APPROVE from a multi-line verdict comment via the real jq pipeline, got '$RW_VERDICT_301'"
fi

cat > "$TMP/rw-fixture-302.json" <<'EOF'
{"comments": [{"createdAt": "2026-01-01T00:00:00Z", "body": "REQUEST-CHANGES:\n\nProbe 1: found an issue with error handling.\nA quoted example in the finding: \"> APPROVE: not yet\" -- do not treat this as a real verdict.\nPlease fix and re-request review."}]}
EOF
RW_VERDICT_302="$(rw_latest_verdict 302)"
if [ "$RW_VERDICT_302" = "REQUEST-CHANGES" ]; then
  pass "issue #96 review round 2: a comment whose LATER line contains 'APPROVE:' (quoted/prose) does NOT match -- the anchor applies to the true first line only, via the real jq pipeline"
else
  fail "CORRECTNESS REGRESSION (issue #96 review round 2): a later-line 'APPROVE:' mention should never override the comment's true first-line verdict, got '$RW_VERDICT_302' (expected REQUEST-CHANGES)"
fi
rm -f "$TMP/rw-fixture-301.json" "$TMP/rw-fixture-302.json"

# restore the real gh/rw_notify for anything below that needs them
unset -f gh rw_notify

echo "== deferred-nudge retry (live, isolated panes) =="
tmux new-session -d -s "$TEST_SESSION" -n main
tmux split-window -h -t "$TEST_SESSION:0"
# Pane 1 starts busy (simulated), pane 0 is a plain idle shell.
tmux send-keys -t "$TEST_SESSION:0.1" "printf 'Thinking...\\n'; sleep 8" Enter
sleep 1
pane_for_agent() {
  case "$1" in
    watchtest) echo "$TEST_SESSION:0.1" ;;
    *) echo "" ;;
  esac
}
: > "$DISPATCH_DEFERRED_FILE"
# Force through the real nudge_agent (not the merge-watch override above) --
# it targets a genuinely busy pane, so this should defer and queue.
tmux has-session -t harness 2>/dev/null && HAD_REAL_HARNESS=1 || HAD_REAL_HARNESS=0
# nudge_agent checks `tmux has-session -t harness` unconditionally (T17
# design predates multi-session tests); alias it via a real session named
# "harness" only if one doesn't already exist, to avoid clobbering it.
nudge_agent "watchtest" >/dev/null 2>&1 || true
if grep -qxF "watchtest" "$DISPATCH_DEFERRED_FILE" 2>/dev/null; then
  pass "busy pane's nudge was queued to the deferred-nudge file"
else
  fail "busy pane's nudge should have been queued (file: $(cat "$DISPATCH_DEFERRED_FILE" 2>/dev/null))"
fi

# Wait for the simulated "Thinking..." pane to finish and go idle, then
# confirm a retry actually delivers the nudge and drains the queue.
sleep 8
retry_deferred_nudges
if [ ! -s "$DISPATCH_DEFERRED_FILE" ]; then
  pass "retry_deferred_nudges drained the queue once the pane went idle"
else
  fail "deferred-nudge queue should be empty after retry: $(cat "$DISPATCH_DEFERRED_FILE")"
fi
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== pane-liveness: dead pane (plain shell) gets flagged exactly once =="
tmux new-session -d -s "$TEST_SESSION" -n main
tmux split-window -h -t "$TEST_SESSION:0"
# Pane 0: plain shell -- "dead" per pw_pane_is_dead. Pane 1: a fake
# long-running "CLI" (sleep) -- alive.
tmux send-keys -t "$TEST_SESSION:0.1" "sleep 20" Enter
sleep 1
pane_for_agent() {
  case "$1" in
    deadtest)  echo "$TEST_SESSION:0.0" ;;
    alivetest) echo "$TEST_SESSION:0.1" ;;
    *) echo "" ;;
  esac
}
LIVENESS_AGENTS="deadtest alivetest"
: > "$WATCH_FLAGGED_DEAD_FILE"
FLAG_CALLS="$TMP/flag-calls.log"
: > "$FLAG_CALLS"
dispatch_main() { echo "$*" >> "$FLAG_CALLS"; }

pane_liveness_check
if grep -qxF "deadtest" "$WATCH_FLAGGED_DEAD_FILE" 2>/dev/null; then
  pass "dead pane (plain shell) recorded in flagged-dead file"
else
  fail "dead pane should be recorded as flagged"
fi
if grep -q "assign orchestra liveness" "$FLAG_CALLS"; then
  pass "pane-liveness dispatched a FLAG to orchestra for the dead pane"
else
  fail "pane-liveness should dispatch assign orchestra liveness: $(cat "$FLAG_CALLS")"
fi
if grep -qxF "alivetest" "$WATCH_FLAGGED_DEAD_FILE" 2>/dev/null; then
  fail "alive pane should NOT be flagged as dead"
else
  pass "alive pane (running command) correctly not flagged"
fi

echo "== pane-liveness: does not re-flag (and re-dispatch) an already-flagged dead pane =="
: > "$FLAG_CALLS"
pane_liveness_check
if [ -s "$FLAG_CALLS" ]; then
  fail "already-flagged dead pane should not be re-dispatched: $(cat "$FLAG_CALLS")"
else
  pass "already-flagged dead pane is not re-dispatched on the next check"
fi

echo "== pane-liveness: clears the flag once the pane recovers =="
tmux send-keys -t "$TEST_SESSION:0.0" "sleep 20" Enter
sleep 1
pane_liveness_check
if grep -qxF "deadtest" "$WATCH_FLAGGED_DEAD_FILE" 2>/dev/null; then
  fail "recovered pane's flag should have been cleared"
else
  pass "recovered pane's flag is cleared"
fi
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== pane-liveness: orchestra's own death uses 'message' (no nudge attempt into a dead pane) =="
tmux new-session -d -s "$TEST_SESSION" -n main
pane_for_agent() {
  case "$1" in
    orchestra) echo "$TEST_SESSION:0.0" ;;
    *) echo "" ;;
  esac
}
LIVENESS_AGENTS="orchestra"
: > "$WATCH_FLAGGED_DEAD_FILE"
: > "$FLAG_CALLS"
dispatch_main() { echo "$*" >> "$FLAG_CALLS"; }
pane_liveness_check
if grep -q "^message orchestra liveness" "$FLAG_CALLS"; then
  pass "orchestra's own death is recorded via 'message' (durable, no nudge)"
else
  fail "orchestra self-death should use 'message': $(cat "$FLAG_CALLS")"
fi
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== T33 (issue #77): merge_watch_check logs PR events to EVENTS_LOG for the dashboard's PRs section =="
: > "$GH_CALLS"
: > "$MERGE_WATCH_STATE"
: > "$WATCH_EVENTS_LOG"
mw_fetch_merged_prs() {
  printf '301\tIssue #34 followups\tCloses #34, thanks all\tfeature/issue-34\n302\tsome PR\tno linked issue here\tsome-branch\n'
}
merge_watch_check
if grep -q 'PR #301 merged -> commented+closed issue #34' "$WATCH_EVENTS_LOG" 2>/dev/null; then
  pass "merge_watch_check logged the closed PR to EVENTS_LOG"
else
  fail "expected a 'PR #301 merged -> commented+closed issue #34' event: $(cat "$WATCH_EVENTS_LOG" 2>/dev/null)"
fi
if grep -q 'PR #302 merged, no linked issue found' "$WATCH_EVENTS_LOG" 2>/dev/null; then
  pass "merge_watch_check logged the skipped (no-issue) PR to EVENTS_LOG too"
else
  fail "expected a 'PR #302 merged, no linked issue found' event: $(cat "$WATCH_EVENTS_LOG" 2>/dev/null)"
fi

echo "== T33: pane-liveness FLAG/recovery events are logged to EVENTS_LOG =="
tmux new-session -d -s "$TEST_SESSION" -n main
tmux split-window -h -t "$TEST_SESSION:0"
tmux send-keys -t "$TEST_SESSION:0.1" "sleep 20" Enter
sleep 1
pane_for_agent() {
  case "$1" in
    deadtest) echo "$TEST_SESSION:0.0" ;;
    *) echo "" ;;
  esac
}
LIVENESS_AGENTS="deadtest"
: > "$WATCH_FLAGGED_DEAD_FILE"
: > "$WATCH_EVENTS_LOG"
dispatch_main() { echo "$*" >> "$TMP/flag-calls.log"; }
pane_liveness_check
if grep -q "FLAGGED deadtest" "$WATCH_EVENTS_LOG" 2>/dev/null; then
  pass "pane-liveness logged the FLAGGED event"
else
  fail "expected a FLAGGED event in EVENTS_LOG: $(cat "$WATCH_EVENTS_LOG" 2>/dev/null)"
fi
tmux send-keys -t "$TEST_SESSION:0.0" "sleep 20" Enter
sleep 1
pane_liveness_check
if grep -q "deadtest pane alive again" "$WATCH_EVENTS_LOG" 2>/dev/null; then
  pass "pane-liveness logged the recovery event"
else
  fail "expected a recovery event in EVENTS_LOG: $(cat "$WATCH_EVENTS_LOG" 2>/dev/null)"
fi
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== T33: watch_render draws all four dashboard sections and nothing is lost from their backing files =="
: > "$WATCH_EVENTS_LOG"
echo "2026-07-05 00:00:00 - PR #999 merged -> closed issue #1" >> "$WATCH_EVENTS_LOG"
echo "testagent" > "$DEFERRED_FILE"
echo "deadagent" > "$FLAGGED_DEAD_FILE"
OUT="$(watch_render)"
MISSING=""
for section in PRs "DEFERRED NUDGES" "PANE LIVENESS" EVENTS; do
  echo "$OUT" | grep -q "== $section ==" || MISSING="$MISSING [$section]"
done
if [ -z "$MISSING" ]; then
  pass "watch_render draws all four dashboard sections"
else
  fail "missing dashboard section(s):$MISSING -- got: $OUT"
fi
if echo "$OUT" | grep -q "PR #999" && echo "$OUT" | grep -q "testagent" && echo "$OUT" | grep -q "DEAD: deadagent"; then
  pass "watch_render surfaces the backing files' current contents (nothing silently dropped)"
else
  fail "watch_render should surface PR #999 / testagent / DEAD: deadagent, got: $OUT"
fi
: > "$DEFERRED_FILE"
: > "$FLAGGED_DEAD_FILE"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
