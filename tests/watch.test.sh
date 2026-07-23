#!/bin/bash
# .harness/watch.test.sh — TDD tests for watch.sh:
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

# Source watch.sh (pulls in dispatch.sh + broker.sh too) under
# test-isolated state files so nothing here touches the real merge-watch/
# broker/liveness state or the real room's inboxes (issue #125:
# BROKER_INBOX_ROOT especially -- without it broker_check would iterate,
# wake, and ARCHIVE the live inboxes).
MERGE_WATCH_STATE="$TMP/merge-watch-state"
WATCH_FLAGGED_DEAD_FILE="$TMP/flagged-dead"
WATCH_EVENTS_LOG="$TMP/events.log"
REVIEW_WATCH_STATE="$TMP/review-watch-state"
BROKER_STATE_DIR="$TMP/broker"
BROKER_INBOX_ROOT="$TMP/inbox"
export MERGE_WATCH_STATE WATCH_FLAGGED_DEAD_FILE WATCH_EVENTS_LOG REVIEW_WATCH_STATE BROKER_STATE_DIR BROKER_INBOX_ROOT
source "$LIB/watch.sh"

# wait_for_pane_cmd <target> <cmd substring> -- polls until the pane's
# foreground process matches (up to 5s). A fixed `sleep 1` after sending a
# fixture command raced the shell's startup: a just-created pane whose
# fixture hasn't started yet still reports its SHELL as the foreground
# process, which reads as idle to pane_is_idle and dead to
# pw_pane_is_dead -- both live-observed flakes of the old fixed sleeps.
wait_for_pane_cmd() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null | grep -q "$2"; then
      return 0
    fi
    sleep 0.5
  done
  echo "WARN: pane $1 never reached foreground cmd '$2'" >&2
  return 1
}

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
# CI fix round: a declare-f/eval restore-dance was tried here first -- it
# broke a LATER test (merge_watch_check) in a way that only reproduced
# on the CI runner's bash (5.2), not this machine's (3.2), confirmed by
# reproducing in a matching Docker container before touching anything.
# Replaced with the sturdier pattern: each assertion below runs inside its
# OWN command-substitution subshell. A subshell's source/function-
# overrides/unset -f all die with it -- the parent script (and every test
# after this block, on any bash version) never observes them at all.
# Nothing to restore afterward, nothing to get wrong.
cat > "$TMP/rw-fixture-301.json" <<'EOF'
{"comments": [{"createdAt": "2026-01-01T00:00:00Z", "body": "APPROVE:\n\nProbe 1: verified input handling.\nProbe 2: verified the guard rule.\nLooks good."}]}
EOF
RW_VERDICT_301="$(
  source "$LIB/watch.sh"
  # gh own --jq flag runs jq inside the gh binary -- overriding the gh
  # shell function loses that entirely unless the mock replicates it.
  # This mock forwards the REAL --jq expression rw_fetch_pr_comments
  # actually passes to a REAL local jq run against a canned fixture file,
  # so this is genuine coverage of the sentinel gsub/implode + tr restore
  # logic, not a re-mock of the thing under test. Confined to THIS
  # subshell only. No backticks or apostrophes in comments inside this
  # subshell body -- confirmed live that bash can break its own syntax
  # check on that combination specifically inside a command substitution,
  # even though the identical text is fine as a top-level comment.
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      local pr="$3" jqexpr="" fixture="$TMP/rw-fixture-$3.json"
      shift 3
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--jq" ]; then jqexpr="$2"; break; fi
        shift
      done
      [ -n "$jqexpr" ] && [ -f "$fixture" ] && jq -r "$jqexpr" "$fixture" 2>/dev/null
      return 0
    fi
  }
  rw_latest_verdict 301
)"
if [ "$RW_VERDICT_301" = "APPROVE" ]; then
  pass "issue #96 review round 2: a genuine multi-line APPROVE comment (verdict line + probe list on later lines) restores correctly through the real jq pipeline and start-anchors as APPROVE"
else
  fail "CORRECTNESS REGRESSION (issue #96 review round 2): expected APPROVE from a multi-line verdict comment via the real jq pipeline, got '$RW_VERDICT_301'"
fi

cat > "$TMP/rw-fixture-302.json" <<'EOF'
{"comments": [{"createdAt": "2026-01-01T00:00:00Z", "body": "REQUEST-CHANGES:\n\nProbe 1: found an issue with error handling.\nA quoted example in the finding: \"> APPROVE: not yet\" -- do not treat this as a real verdict.\nPlease fix and re-request review."}]}
EOF
RW_VERDICT_302="$(
  source "$LIB/watch.sh"
  gh() {
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      local pr="$3" jqexpr="" fixture="$TMP/rw-fixture-$3.json"
      shift 3
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--jq" ]; then jqexpr="$2"; break; fi
        shift
      done
      [ -n "$jqexpr" ] && [ -f "$fixture" ] && jq -r "$jqexpr" "$fixture" 2>/dev/null
      return 0
    fi
  }
  rw_latest_verdict 302
)"
if [ "$RW_VERDICT_302" = "REQUEST-CHANGES" ]; then
  pass "issue #96 review round 2: a comment whose LATER line contains 'APPROVE:' (quoted/prose) does NOT match -- the anchor applies to the true first line only, via the real jq pipeline"
else
  fail "CORRECTNESS REGRESSION (issue #96 review round 2): a later-line 'APPROVE:' mention should never override the comment's true first-line verdict, got '$RW_VERDICT_302' (expected REQUEST-CHANGES)"
fi
rm -f "$TMP/rw-fixture-301.json" "$TMP/rw-fixture-302.json"

echo "== issue #125: broker_check -- state-gated wake, ack verification, archive, retention, escalation (isolated) =="
tmux new-session -d -s "$TEST_SESSION" -n main
tmux split-window -h -t "$TEST_SESSION:0"
# Pane 1 starts busy (simulated heuristic-busy, no hook state).
tmux send-keys -t "$TEST_SESSION:0.1" "printf 'Thinking...\\n'; sleep 30" Enter
wait_for_pane_cmd "$TEST_SESSION:0.1" sleep
pane_for_agent() {
  case "$1" in
    watchtest) echo "$TEST_SESSION:0.1" ;;
    *) echo "" ;;
  esac
}
BROKER_AGENTS="watchtest"
BROKER_WAKE_GRACE_S=0
BROKER_ACK_DEADLINE_S=60
BROKER_ARCHIVE_MIN_AGE_S=0
mkdir -p "$BROKER_INBOX_ROOT/watchtest" "$BROKER_STATE_DIR"
SUBMIT_CALLS="$TMP/submit-calls.log"
: > "$SUBMIT_CALLS"
send_submit() { echo "$1 <- $2" >> "$SUBMIT_CALLS"; }
echo "payload" > "$BROKER_INBOX_ROOT/watchtest/20260101000000-1.msg"

broker_check
if [ ! -s "$SUBMIT_CALLS" ]; then
  pass "issue #125: heuristically-busy pane -> broker holds, no wake typed"
else
  fail "broker should not wake a busy pane: $(cat "$SUBMIT_CALLS")"
fi
if grep -q "watchtest 20260101000000-1" "$BROKER_PENDING_LIST" 2>/dev/null; then
  pass "issue #125: undelivered message is listed in the pending file"
else
  fail "expected the pending list to name the undelivered msg: $(cat "$BROKER_PENDING_LIST" 2>/dev/null)"
fi

# Pane goes idle -> the next pass wakes, exactly once per ack deadline.
tmux send-keys -t "$TEST_SESSION:0.1" C-c
sleep 1
broker_check
if [ "$(grep -c 'check inbox' "$SUBMIT_CALLS")" = "1" ]; then
  pass "issue #125: idle pane -> exactly one verified wake"
else
  fail "expected exactly one wake, got: $(cat "$SUBMIT_CALLS")"
fi
broker_check
if [ "$(grep -c 'check inbox' "$SUBMIT_CALLS")" = "1" ]; then
  pass "issue #125: within ack_deadline_s no second wake fires (in-flight wake owns the window)"
else
  fail "a second wake fired inside the ack deadline: $(cat "$SUBMIT_CALLS")"
fi

# Ack lands -> the pair is archived (min-age 0 here) and bookkeeping cleaned.
echo "ACK: done" > "$BROKER_INBOX_ROOT/watchtest/20260101000000-1.ack"
broker_check
if [ ! -e "$BROKER_INBOX_ROOT/watchtest/20260101000000-1.msg" ] \
  && [ -e "$BROKER_INBOX_ROOT/watchtest/archive/20260101000000-1.msg" ] \
  && [ -e "$BROKER_INBOX_ROOT/watchtest/archive/20260101000000-1.ack" ]; then
  pass "issue #125: acked pair archived out of the live inbox"
else
  fail "expected msg+ack archived: live=$(ls "$BROKER_INBOX_ROOT/watchtest" 2>/dev/null) archive=$(ls "$BROKER_INBOX_ROOT/watchtest/archive" 2>/dev/null)"
fi

# Retention: an archived file older than the window is pruned.
touch -t 202001010000 "$BROKER_INBOX_ROOT/watchtest/archive/20260101000000-1.msg"
touch -t 202001010000 "$BROKER_INBOX_ROOT/watchtest/archive/20260101000000-1.ack"
broker_check
if [ ! -e "$BROKER_INBOX_ROOT/watchtest/archive/20260101000000-1.msg" ]; then
  pass "issue #125: archive pruned past archive_retention_days"
else
  fail "expected the ancient archived pair to be pruned"
fi

# issue #127: wake dedupe -- multiple pending messages, ONE shared wake,
# every message's attempt file stamped.
: > "$SUBMIT_CALLS"
echo "m3" > "$BROKER_INBOX_ROOT/watchtest/20260101000000-3.msg"
echo "m4" > "$BROKER_INBOX_ROOT/watchtest/20260101000000-4.msg"
broker_check
if [ "$(grep -c 'check inbox' "$SUBMIT_CALLS")" = "1" ]; then
  pass "issue #127: two pending msgs -> exactly ONE typed wake (per agent, not per message)"
else
  fail "issue #127: expected one shared wake for two msgs, got: $(cat "$SUBMIT_CALLS")"
fi
if [ -f "$BROKER_STATE_DIR/watchtest__20260101000000-3" ] && [ -f "$BROKER_STATE_DIR/watchtest__20260101000000-4" ]; then
  pass "issue #127: the shared wake is stamped against BOTH messages' attempt files"
else
  fail "issue #127: both attempt files should exist, got: $(ls "$BROKER_STATE_DIR" 2>/dev/null)"
fi
rm -f "$BROKER_INBOX_ROOT/watchtest/20260101000000-3.msg" "$BROKER_INBOX_ROOT/watchtest/20260101000000-4.msg"
rm -f "$BROKER_STATE_DIR"/watchtest__20260101000000-3 "$BROKER_STATE_DIR"/watchtest__20260101000000-4

# Escalation: attempts exhausted + deadline passed -> durable FLAG --
# deduped to ONE per agent per pass even with several stuck msgs (#127).
FLAG_CALLS="$TMP/broker-flag-calls.log"
: > "$FLAG_CALLS"
dispatch_main() { echo "$*" >> "$FLAG_CALLS"; }
echo "payload2" > "$BROKER_INBOX_ROOT/watchtest/20260101000000-2.msg"
echo "payload5" > "$BROKER_INBOX_ROOT/watchtest/20260101000000-5.msg"
echo "2 1" > "$BROKER_STATE_DIR/watchtest__20260101000000-2"
echo "2 1" > "$BROKER_STATE_DIR/watchtest__20260101000000-5"
broker_check
if [ "$(grep -c "FLAG: undelivered inbox message for 'watchtest'" "$FLAG_CALLS")" = "1" ]; then
  pass "issue #125/#127: exhausted wakes escalate as ONE durable FLAG per agent per pass"
else
  fail "expected exactly one escalation FLAG, got: $(cat "$FLAG_CALLS")"
fi
read -r ESC_ATTEMPTS _ < "$BROKER_STATE_DIR/watchtest__20260101000000-2"
read -r ESC_ATTEMPTS5 _ < "$BROKER_STATE_DIR/watchtest__20260101000000-5"
if [ "$ESC_ATTEMPTS" = "99" ] && [ "$ESC_ATTEMPTS5" = "99" ]; then
  pass "issue #125/#127: BOTH stuck messages are marked escalated (attempts=99) so neither re-fires"
else
  fail "expected attempts=99 on both after escalation, got: $ESC_ATTEMPTS / $ESC_ATTEMPTS5"
fi
rm -f "$BROKER_INBOX_ROOT/watchtest/20260101000000-2.msg" "$BROKER_INBOX_ROOT/watchtest/20260101000000-5.msg"
rm -f "$BROKER_STATE_DIR"/watchtest__20260101000000-2 "$BROKER_STATE_DIR"/watchtest__20260101000000-5
unset -f dispatch_main
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== issue #130: agy statusline -> pane-state translation (agy's own #129 finding) =="
# Sandbox the pane-state dir: dispatch.sh pinned PANE_STATE_DIR to the
# REAL room's canon dir at source time, and these tests write agy
# states -- re-point it for this section, restore after.
PANE_STATE_DIR_SAVED="$PANE_STATE_DIR"
PANE_STATE_DIR="$TMP/pane-state"
mkdir -p "$PANE_STATE_DIR"
tmux new-session -d -s "$TEST_SESSION" -n main
AGY_TEST_PANE_ID="$(tmux display-message -p -t "$TEST_SESSION:0.0" '#{pane_id}')"
pane_for_agent() {
  case "$1" in
    agy) echo "$TEST_SESSION:0.0" ;;
    *) echo "" ;;
  esac
}
AGY_STATUSLINE_FILE="$TMP/agy-statusline.json"
AGY_STATUSLINE_MAX_AGE_S=300
printf '{"agent_state":"idle","session_id":"agy-sess-1"}' > "$AGY_STATUSLINE_FILE"
broker_translate_agy_state
if [ "$(pane_state_read "$AGY_TEST_PANE_ID" 2>/dev/null)" = "idle" ] && [ "$(pane_state_session "$AGY_TEST_PANE_ID" 2>/dev/null)" = "agy-sess-1" ]; then
  pass "issue #130: idle agent_state + session_id translated into pane-state"
else
  fail "issue #130: expected idle/agy-sess-1 in the pane-state file"
fi
printf '{"agent_state":"running_tool","session_id":"agy-sess-1"}' > "$AGY_STATUSLINE_FILE"
broker_translate_agy_state
if [ "$(pane_state_read "$AGY_TEST_PANE_ID" 2>/dev/null)" = "busy" ]; then
  pass "issue #130: any non-idle agent_state maps to busy (fail toward do-not-type)"
else
  fail "issue #130: expected busy for agent_state=running_tool"
fi
touch -t 202001010000 "$AGY_STATUSLINE_FILE"
broker_translate_agy_state
if pane_state_read "$AGY_TEST_PANE_ID" >/dev/null 2>&1; then
  fail "issue #130: a STALE statusline must clear the translated state (polled source, unknown truth)"
else
  pass "issue #130: stale statusline clears the state -- heuristic fallback back in charge"
fi
printf '{"agent_state":"idle","session_id":"agy-sess-1"}' > "$AGY_STATUSLINE_FILE"
broker_translate_agy_state
rm -f "$AGY_STATUSLINE_FILE"
broker_translate_agy_state
if pane_state_read "$AGY_TEST_PANE_ID" >/dev/null 2>&1; then
  fail "issue #130: a MISSING statusline must clear the translated state"
else
  pass "issue #130: missing statusline clears the state"
fi
PANE_STATE_DIR="$PANE_STATE_DIR_SAVED"
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== issue #6: broker_states_summary appends a (classification) suffix when one is on file =="
PANE_STATE_DIR_SAVED="$PANE_STATE_DIR"
PANE_STATE_DIR="$TMP/pane-state-lifecycle"
mkdir -p "$PANE_STATE_DIR"
tmux new-session -d -s "$TEST_SESSION" -n main
tmux split-window -h -t "$TEST_SESSION:0"
LC_PANE0_ID="$(tmux display-message -p -t "$TEST_SESSION:0.0" '#{pane_id}')"
LC_PANE1_ID="$(tmux display-message -p -t "$TEST_SESSION:0.1" '#{pane_id}')"
pane_for_agent() {
  case "$1" in
    lcorchestra) echo "$TEST_SESSION:0.0" ;;
    lcbuilder)   echo "$TEST_SESSION:0.1" ;;
    *) echo "" ;;
  esac
}
BROKER_AGENTS="lcorchestra lcbuilder"
pane_state_write "$LC_PANE0_ID" idle "sid-x" "resumed"
pane_state_write "$LC_PANE1_ID" busy "sid-y"
SUMMARY="$(broker_states_summary)"
if echo "$SUMMARY" | grep -q "lcorchestra:idle(resumed)"; then
  pass "issue #6: a pane with a recorded classification shows it in the summary"
else
  fail "issue #6: expected 'lcorchestra:idle(resumed)' in the summary, got: $SUMMARY"
fi
if echo "$SUMMARY" | grep -q "lcbuilder:busy \|lcbuilder:busy\$"; then
  pass "issue #6: a pane with no classification on file renders exactly as before (no suffix)"
else
  fail "issue #6: expected 'lcbuilder:busy' with no suffix, got: $SUMMARY"
fi
PANE_STATE_DIR="$PANE_STATE_DIR_SAVED"
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== pane-liveness: dead pane (plain shell) gets flagged exactly once =="
tmux new-session -d -s "$TEST_SESSION" -n main
tmux split-window -h -t "$TEST_SESSION:0"
# Pane 0: plain shell -- "dead" per pw_pane_is_dead. Pane 1: a fake
# long-running "CLI" (sleep) -- alive.
tmux send-keys -t "$TEST_SESSION:0.1" "sleep 20" Enter
wait_for_pane_cmd "$TEST_SESSION:0.1" sleep
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
wait_for_pane_cmd "$TEST_SESSION:0.0" sleep
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
wait_for_pane_cmd "$TEST_SESSION:0.1" sleep
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
wait_for_pane_cmd "$TEST_SESSION:0.0" sleep
pane_liveness_check
if grep -q "deadtest pane alive again" "$WATCH_EVENTS_LOG" 2>/dev/null; then
  pass "pane-liveness logged the recovery event"
else
  fail "expected a recovery event in EVENTS_LOG: $(cat "$WATCH_EVENTS_LOG" 2>/dev/null)"
fi
tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

echo "== T33 (issue #120/#125): watch_render -- compact header with states + pending + liveness; nothing lost from the backing files =="
: > "$WATCH_EVENTS_LOG"
echo "2026-07-05 00:00:00 - PR #999 merged -> closed issue #1" >> "$WATCH_EVENTS_LOG"
mkdir -p "$BROKER_STATE_DIR"
echo "testagent 20260101000000-9 45s ?" > "$BROKER_PENDING_LIST"
echo "deadagent" > "$FLAGGED_DEAD_FILE"
OUT="$(WATCH_PANE_LINES=20 WATCH_EVENTS_SHOWN=999 watch_render)"
if echo "$OUT" | grep -Eq '^Watch [0-9:]+  60s \| .* \| pending 1 \| 1 dead$'; then
  pass "issue #125: 1-line header folds interval + agent states + pending count + liveness summary"
else
  fail "issue #125: expected a 'Watch HH:MM:SS  60s | <states> | pending 1 | 1 dead' header, got: $OUT"
fi
if echo "$OUT" | grep -q "PR #999" && echo "$OUT" | grep -q "PENDING: testagent" && echo "$OUT" | grep -q "DEAD: deadagent"; then
  pass "issue #125: watch_render surfaces the backing files' current contents (nothing silently dropped)"
else
  fail "issue #125: watch_render should surface PR #999 / PENDING: testagent / DEAD: deadagent, got: $OUT"
fi
: > "$BROKER_PENDING_LIST"
: > "$FLAGGED_DEAD_FILE"

echo "== issue #120/#125: header collapses to 'pending 0 | all alive' and drops the PENDING:/DEAD: lines when both backing files are empty =="
OUT="$(WATCH_PANE_LINES=20 WATCH_EVENTS_SHOWN=999 watch_render)"
if echo "$OUT" | grep -Eq '\| pending 0 \| all alive$'; then
  pass "issue #125: zero-case header reads 'pending 0 | all alive'"
else
  fail "issue #125: expected 'pending 0 | all alive' in the header, got: $OUT"
fi
if echo "$OUT" | grep -q "PENDING:" || echo "$OUT" | grep -q "DEAD:"; then
  fail "issue #125: PENDING:/DEAD: lines should not appear when both backing files are empty, got: $OUT"
else
  pass "issue #125: no PENDING:/DEAD: lines printed when both backing files are empty"
fi

echo "== issue #120/#124: EVENTS tail is ADAPTIVE, off-by-one fixed, truncation explicit =="
: > "$WATCH_EVENTS_LOG"
for i in $(seq 1 20); do echo "2026-07-05 00:00:00 - event $i" >> "$WATCH_EVENTS_LOG"; done
OUT="$(WATCH_PANE_LINES=10 WATCH_EVENTS_SHOWN=999 watch_render)"
OUT_LINES="$(echo "$OUT" | wc -l | tr -d ' ')"
if [ "$OUT_LINES" = "9" ]; then
  pass "issue #124: rendered output leaves the cursor row free (9 output lines for a 10-row pane, header never scrolls off)"
else
  fail "issue #124: expected exactly 9 rendered lines for WATCH_PANE_LINES=10, got $OUT_LINES: $OUT"
fi
if echo "$OUT" | grep -qF "(last 6 of 20)"; then
  pass "issue #120: truncated EVENTS tail states '(last N of TOTAL)' explicitly"
else
  fail "issue #120: expected an explicit '(last 6 of 20)' truncation note, got: $OUT"
fi
SHOWN_EVENTS="$(echo "$OUT" | grep -c '^  2026-07-05')"
if [ "$SHOWN_EVENTS" = "6" ]; then
  pass "issue #120: exactly 6 event lines shown (budget minus the truncation note itself)"
else
  fail "issue #120: expected exactly 6 event lines shown, got $SHOWN_EVENTS: $OUT"
fi

echo "== issue #124: dynamic PENDING/DEAD lines are DEDUCTED from the events budget (the live header-scroll incident) =="
echo "a 1 1s ?" > "$BROKER_PENDING_LIST"
echo "b 2 2s ?" >> "$BROKER_PENDING_LIST"
OUT="$(WATCH_PANE_LINES=10 WATCH_EVENTS_SHOWN=999 watch_render)"
OUT_LINES="$(echo "$OUT" | wc -l | tr -d ' ')"
if [ "$OUT_LINES" = "9" ]; then
  pass "issue #124: with 2 PENDING lines the frame still fits the pane (events shrank to make room)"
else
  fail "issue #124: expected 9 output lines with 2 PENDING lines present, got $OUT_LINES: $OUT"
fi
if echo "$OUT" | grep -qF "(last 4 of 20)"; then
  pass "issue #124: events tail shrank by exactly the dynamic-line count"
else
  fail "issue #124: expected '(last 4 of 20)' with 2 dynamic lines, got: $OUT"
fi
: > "$BROKER_PENDING_LIST"

echo "== issue #120: a bigger WATCH_PANE_LINES shows every event with no truncation note once everything fits =="
OUT="$(WATCH_PANE_LINES=30 WATCH_EVENTS_SHOWN=999 watch_render)"
if echo "$OUT" | grep -q "event 1$" && echo "$OUT" | grep -q "event 20$" && ! echo "$OUT" | grep -q "(last"; then
  pass "issue #120: all 20 events shown with room to spare, no truncation note"
else
  fail "issue #120: expected all 20 events with no truncation note when the pane has room, got: $OUT"
fi

echo "== issue #125: events_shown caps the display even when the pane has room (Ahmad's 3-5 ask; orchestrator.yaml watch.events_shown) =="
OUT="$(WATCH_PANE_LINES=30 WATCH_EVENTS_SHOWN=4 watch_render)"
if echo "$OUT" | grep -qF "(last 3 of 20)"; then
  pass "issue #125: WATCH_EVENTS_SHOWN=4 caps the tail to '(last 3 of 20)' despite a 30-row pane"
else
  fail "issue #125: expected '(last 3 of 20)' under an explicit events_shown cap, got: $OUT"
fi
: > "$WATCH_EVENTS_LOG"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
