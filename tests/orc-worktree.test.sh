#!/bin/bash
# .harness/orc-worktree.test.sh — tests for orc-worktree.sh.
# Run: bash .harness/orc-worktree.test.sh
#
# Uses a scratch, non-numeric issue id ("t18-scratch") so the branch
# (feature/issue-t18-scratch) and worktree (.worktrees/issue-t18-scratch)
# can never collide with a real issue, and are unambiguous to clean up. The
# `finish` case does a REAL push + `gh pr create` against the actual repo
# (that's what "VERIFY with a live cycle" means) -- cleanup below closes
# that scratch PR (never merges) and deletes the scratch branch both
# locally and on origin, since it's disposable test debris, not real work.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$DIR/.." >/dev/null 2>&1 && pwd)"
ORC="$DIR/../lib/orc-worktree.sh"
# issue #116: "uat" was career-ops-harness's own integration branch name --
# this repo's is "main" (read the same way orc-worktree.sh itself does).
INTEGRATION_BRANCH="$(cd "$REPO_ROOT" && source "$DIR/../lib/orc-config.sh" && orc_get_scalar integration_branch)"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-uat}"
ISSUE="t18-scratch"
BRANCH="feature/issue-$ISSUE"
WT="$REPO_ROOT/.worktrees/issue-$ISSUE"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

PR_NUMBER=""

cleanup() {
  if [ -n "$PR_NUMBER" ]; then
    gh pr close "$PR_NUMBER" >/dev/null 2>&1
  fi
  git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPO_ROOT" push origin --delete "$BRANCH" >/dev/null 2>&1
  git -C "$REPO_ROOT" branch -D "$BRANCH" >/dev/null 2>&1
  # ${TD_WT:-}/${TD_BRANCH:-}: teardown's own scratch issue, only defined
  # once the script reaches that section -- unset-safe here since this trap
  # can also fire if an earlier section fails first.
  if [ -n "${TD_WT:-}" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$TD_WT" >/dev/null 2>&1
    git -C "$REPO_ROOT" branch -D "$TD_BRANCH" >/dev/null 2>&1
  fi
  [ -n "${TD_TMP:-}" ] && rm -rf "$TD_TMP"
  true
}
trap cleanup EXIT

# Defensive: if a prior failed run left debris, clear it before starting.
cleanup

echo "== start =="
OUT="$(bash "$ORC" start "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -d "$WT" ]; then
  pass "start created the worktree dir"
else
  fail "start did not create the worktree dir (status=$STATUS): $OUT"
fi
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  pass "start created the local branch"
else
  fail "start did not create the local branch"
fi
INTEGRATION_TIP="$(git -C "$REPO_ROOT" rev-parse "origin/$INTEGRATION_BRANCH")"
WT_HEAD="$(git -C "$WT" rev-parse HEAD)"
if [ "$INTEGRATION_TIP" = "$WT_HEAD" ]; then
  pass "start branched from origin/$INTEGRATION_BRANCH's current tip"
else
  fail "start's base commit ($WT_HEAD) does not match origin/$INTEGRATION_BRANCH ($INTEGRATION_TIP)"
fi

echo "== start refuses when branch already exists =="
OUT="$(bash "$ORC" start "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "already exists"; then
  pass "start correctly refused a second time (branch already exists)"
else
  fail "start should refuse when the branch already exists (status=$STATUS): $OUT"
fi

echo "== pause: WIP commit + worktree removal, branch survives =="
echo "scratch content" > "$WT/T18-SCRATCH-FILE.txt"
OUT="$(bash "$ORC" pause "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ ! -d "$WT" ]; then
  pass "pause removed the worktree dir"
else
  fail "pause did not remove the worktree dir (status=$STATUS): $OUT"
fi
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  pass "pause left the branch intact"
else
  fail "pause must never delete the branch"
fi
if git -C "$REPO_ROOT" log "$BRANCH" --oneline -1 | grep -q "wip: pause issue $ISSUE"; then
  pass "pause created the expected WIP commit"
else
  fail "pause did not create the expected WIP commit"
fi

echo "== pause is a no-op error when nothing is checked out =="
OUT="$(bash "$ORC" pause "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "nothing to pause"; then
  pass "pause correctly refused with no active worktree"
else
  fail "pause should refuse cleanly when nothing is checked out (status=$STATUS): $OUT"
fi

echo "== resume: re-creates the worktree from the branch =="
OUT="$(bash "$ORC" resume "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -d "$WT" ]; then
  pass "resume re-created the worktree dir"
else
  fail "resume did not re-create the worktree dir (status=$STATUS): $OUT"
fi
if [ -f "$WT/T18-SCRATCH-FILE.txt" ]; then
  pass "resume's worktree has the WIP-committed file from before pause"
else
  fail "resumed worktree is missing the file committed before pause"
fi

echo "== resume refuses when a worktree is already checked out =="
OUT="$(bash "$ORC" resume "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "nothing to resume"; then
  pass "resume correctly refused a second time (already checked out)"
else
  fail "resume should refuse when already checked out (status=$STATUS): $OUT"
fi

echo "== finish: push + draft PR (live gh call) =="
echo "second change" >> "$WT/T18-SCRATCH-FILE.txt"
OUT="$(bash "$ORC" finish "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -q "opened draft PR"; then
  pass "finish pushed and opened a draft PR"
  PR_URL="$(echo "$OUT" | grep -Eo 'https://[^ ]+')"
  PR_NUMBER="$(echo "$PR_URL" | grep -Eo '[0-9]+$')"
else
  fail "finish did not report success (status=$STATUS): $OUT"
fi
if [ -n "$PR_NUMBER" ] && gh pr view "$PR_NUMBER" --json isDraft -q .isDraft 2>/dev/null | grep -q true; then
  pass "the opened PR is a draft"
else
  fail "the opened PR should be a draft (PR_NUMBER=$PR_NUMBER)"
fi
if git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  pass "finish pushed the branch to origin"
else
  fail "finish should have pushed the branch to origin"
fi
if [ -d "$WT" ]; then
  pass "finish left the worktree in place (for a possible fix-and-repush loop)"
else
  fail "finish should NOT remove the worktree"
fi
# gh's read-after-write can lag right after `gh pr create`, so retry a
# couple of times before failing (observed as a one-off flake, not a real
# body-content mismatch -- verified separately with a direct debug run).
BODY_OK=0
for _ in 1 2 3; do
  if [ -n "$PR_NUMBER" ] && gh pr view "$PR_NUMBER" --json body -q .body 2>/dev/null | grep -qF "Closes #$ISSUE."; then
    BODY_OK=1
    break
  fi
  sleep 2
done
if [ "$BODY_OK" -eq 1 ]; then
  pass "T30 (#56): PR body includes the standardized 'Closes #N.' line"
else
  fail "T30 (#56): PR body should include 'Closes #$ISSUE.' (PR_NUMBER=$PR_NUMBER)"
fi

echo "== build_pr_body: extra issue numbers each get their own Closes line (T30, bundled tickets) =="
BUNDLE_BODY_OUT="$(bash -c "source '$ORC' >/dev/null 2>&1; build_pr_body 99 100 101")"
if echo "$BUNDLE_BODY_OUT" | grep -qF "Closes #99." && echo "$BUNDLE_BODY_OUT" | grep -qF "Closes #100." && echo "$BUNDLE_BODY_OUT" | grep -qF "Closes #101."; then
  pass "bundled finish body includes a Closes line per issue"
else
  fail "bundled finish body should include a Closes line per issue: $BUNDLE_BODY_OUT"
fi
if bash -c "source '$ORC' >/dev/null 2>&1; build_pr_body 42" | grep -qxF "Closes #42."; then
  pass "single-issue body is unchanged (just 'Closes #N.')"
else
  fail "single-issue body should still be exactly 'Closes #42.'"
fi

echo "== finish refuses when no worktree is checked out =="
bash "$ORC" pause "$ISSUE" >/dev/null 2>&1
OUT="$(bash "$ORC" finish "$ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "resume"; then
  pass "finish correctly refused with no active worktree"
else
  fail "finish should refuse cleanly when nothing is checked out (status=$STATUS): $OUT"
fi

# -- teardown (issue #85, Task 4) --------------------------------------------
# A fresh, second scratch issue -- freshly `start`ed with no commits beyond
# origin/uat's tip is trivially "merged" (its tip IS an ancestor of the
# current HEAD), so the success path needs no real merge to set up, just a
# clean worktree. Kept separate from $ISSUE/$BRANCH above so the two scratch
# lifecycles never interact.
TD_ISSUE="t18-teardown-scratch"
TD_BRANCH="feature/issue-$TD_ISSUE"
TD_WT="$REPO_ROOT/.worktrees/issue-$TD_ISSUE"
TD_TMP="$(mktemp -d)"

# Only clears worktree/branch debris -- never touches TD_TMP, which must
# survive across the whole teardown section (an earlier version of this
# helper rm -rf'd TD_TMP too and was invoked mid-section, deleting the very
# scratch-log directory the dirty-worktree case below depends on).
teardown_cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$TD_WT" >/dev/null 2>&1
  git -C "$REPO_ROOT" branch -D "$TD_BRANCH" >/dev/null 2>&1
  true
}
teardown_cleanup

echo "== teardown: clean worktree + trivially-merged branch are both removed =="
bash "$ORC" start "$TD_ISSUE" >/dev/null 2>&1
OUT="$(bash "$ORC" teardown "$TD_ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ ! -d "$TD_WT" ]; then
  pass "teardown removed the clean worktree"
else
  fail "teardown should have removed the clean worktree (status=$STATUS): $OUT"
fi
if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$TD_BRANCH"; then
  pass "teardown deleted the (trivially merged) branch"
else
  fail "teardown should have deleted the merged branch: $OUT"
fi

echo "== #47: teardown on an ALREADY-gone worktree/branch now fails LOUDLY, not a silent no-op =="
# #47: this used to be documented/tested as an idempotent no-op -- that was
# exactly the bug. A merged PR always has a worktree+branch pair to clean
# (start/resume always create them together); "found nothing" is either a
# legitimate double-run (harmless in practice, since watch.sh's own
# mw_already_processed state file guarantees teardown is only ever invoked
# ONCE per merged PR in the real flow) or the wrong-repo-root/wrong-path bug
# that cost this room three merges' worth of debris tonight -- and
# cmd_teardown has no way to tell those apart from the inside. Per the
# ticket: "return 0 MUST mean the worktree and branches are gone, not I
# didn't find them" -- so it no longer guesses innocent-until-proven and
# instead fails loud every time, on the theory that a human/agy noticing an
# unnecessary complaint is far cheaper than a silent lie about cleanup that
# already cost real debris three merges running.
OUT="$(bash "$ORC" teardown "$TD_ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi "FAILED"; then
  pass "re-running teardown on an already-gone worktree/branch now fails loudly instead of lying"
else
  fail "re-running teardown should fail loudly, not silently succeed (status=$STATUS): $OUT"
fi

echo "== teardown: dirty worktree is FLAGged to orchestra, never force-removed =="
bash "$ORC" start "$TD_ISSUE" >/dev/null 2>&1
echo "uncommitted scratch content" > "$TD_WT/DIRTY.txt"
TD_FLAG_LOG="$TD_TMP/flag-calls.log"
: > "$TD_FLAG_LOG"
OUT="$(
  source "$ORC"
  dispatch_main() { echo "$*" >> "$TD_FLAG_LOG"; }
  cmd_teardown "$TD_ISSUE"
)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && [ -d "$TD_WT" ]; then
  pass "dirty worktree was left in place, not force-removed"
else
  fail "teardown must never force-remove a dirty worktree (status=$STATUS): $OUT"
fi
if grep -q "assign orchestra $TD_ISSUE" "$TD_FLAG_LOG" && grep -qi "FLAG" "$TD_FLAG_LOG"; then
  pass "dirty worktree was FLAGged to orchestra via dispatch_main"
else
  fail "dirty worktree should have FLAGged orchestra: $(cat "$TD_FLAG_LOG")"
fi
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$TD_BRANCH"; then
  pass "branch left intact when worktree teardown was skipped (dirty)"
else
  fail "branch should survive when teardown skips a dirty worktree"
fi
rm -f "$TD_WT/DIRTY.txt"
teardown_cleanup

echo "== teardown: unmerged branch is FLAGged (git branch -d refuses), never -D'd =="
# NOTE: can't reuse $ISSUE/$BRANCH here -- `finish` above ran `push -u origin
# $BRANCH`, which sets an upstream tracking ref; once a branch's upstream has
# every local commit (true here, finish just pushed them all), `git branch
# -d` considers it "fully merged into its upstream" and deletes it happily,
# regardless of whether it's merged into HEAD. A genuinely unmerged branch
# for this test needs an unpushed commit and no upstream configured, so a
# fresh TD_ISSUE cycle (never pushed) is used instead.
bash "$ORC" start "$TD_ISSUE" >/dev/null 2>&1
echo "unpushed commit content" > "$TD_WT/UNMERGED.txt"
git -C "$TD_WT" add -A
git -C "$TD_WT" commit -q -m "unpushed scratch commit, never merged"
git -C "$REPO_ROOT" worktree remove --force "$TD_WT" >/dev/null 2>&1
OUT="$(bash "$ORC" teardown "$TD_ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -q "not fully merged"; then
  pass "unmerged branch was flagged (git branch -d refused), not force-deleted"
else
  fail "teardown should refuse to delete an unmerged branch (status=$STATUS): $OUT"
fi
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$TD_BRANCH"; then
  pass "unmerged branch still exists after teardown (never -D'd)"
else
  fail "teardown must never -D an unmerged branch"
fi

# -- #47: the two-repo mismatch that cost this room 3 merges' worth of -----
# debris tonight, PLUS the never-implemented remote branch delete ----------
#
# Fully local/offline (a bare repo stands in for "origin") -- this
# reproduces watch.sh's real bug (it runs from the HARNESS ROOT, a
# different repo than the dev target whose worktree/branch it's tearing
# down) without touching the real network or the real project repo, unlike
# the live-network sections above.
echo "== #47: teardown run from a DIFFERENT repo than the one holding the worktree/branch must fail loudly, not silently 'succeed' =="

ORIGIN_BARE="$(mktemp -d)"
git init -q --bare "$ORIGIN_BARE"

# pwd -P (not plain mktemp's output): on macOS, /tmp/var is a symlink to
# /private/var, so an unresolved mktemp path textually differs from the
# canonicalized path `git worktree list --porcelain` reports, which broke
# worktree_is_checked_out()'s string comparison -- same lesson
# tests/guard.test.sh's sandbox helpers already learned.
DEVROOT="$(mktemp -d)"
DEVROOT="$(cd "$DEVROOT" && pwd -P)"
git init -q "$DEVROOT"
git -C "$DEVROOT" config user.email "test@test.local"
git -C "$DEVROOT" config user.name "test"
git -C "$DEVROOT" remote add origin "$ORIGIN_BARE"
git -C "$DEVROOT" commit -q --allow-empty -m init
git -C "$DEVROOT" push -q -u origin HEAD:main

MM_ISSUE="mismatch-scratch"
MM_BRANCH="feature/issue-$MM_ISSUE"
MM_WT="$DEVROOT/.worktrees/issue-$MM_ISSUE"
git -C "$DEVROOT" worktree add -q -b "$MM_BRANCH" "$MM_WT" main
git -C "$DEVROOT" push -q -u origin "$MM_BRANCH"

CALLERROOT="$(mktemp -d)"
CALLERROOT="$(cd "$CALLERROOT" && pwd -P)"
git init -q "$CALLERROOT"
git -C "$CALLERROOT" config user.email "test@test.local"
git -C "$CALLERROOT" config user.name "test"
git -C "$CALLERROOT" commit -q --allow-empty -m "unrelated repo, e.g. the harness root watch.sh actually runs from"
# orc-worktree.sh sources lib/dispatch.sh, which fails CLOSED at SOURCE
# TIME if it can't resolve a canonical .harness dir from $PWD -- give the
# caller repo its own orchestrator.yaml so that resolution succeeds and
# this test actually exercises REPO_ROOT mismatch handling, not an
# unrelated dispatch.sh bootstrap failure.
echo "project: mismatch-test" > "$CALLERROOT/orchestrator.yaml"

mismatch_cleanup() {
  git -C "$DEVROOT" worktree remove --force "$MM_WT" >/dev/null 2>&1
  rm -rf "$DEVROOT" "$CALLERROOT" "$ORIGIN_BARE"
  true
}

echo "-- reproduces tonight's exact conditions: caller's \$PWD is the WRONG repo, no ORC_WORKTREE_REPO_ROOT override --"
OUT="$(cd "$CALLERROOT" && bash "$ORC" teardown "$MM_ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  pass "#47 -- teardown invoked from the wrong repo (no explicit root) fails loudly instead of reporting success"
else
  fail "#47 REGRESSION -- teardown invoked from the wrong repo silently reported success: $OUT"
fi
if [ -d "$MM_WT" ] && git -C "$DEVROOT" show-ref --verify --quiet "refs/heads/$MM_BRANCH"; then
  pass "worktree and branch are untouched in the real dev repo after the wrong-repo attempt (nothing was silently 'cleaned up' in the wrong place either)"
else
  fail "worktree/branch should still exist in the real dev repo untouched after a wrong-repo teardown attempt"
fi

echo "-- with ORC_WORKTREE_REPO_ROOT explicitly pointed at the real dev repo: succeeds AND actually removes worktree + local branch + remote branch --"
OUT="$(cd "$CALLERROOT" && ORC_WORKTREE_REPO_ROOT="$DEVROOT" bash "$ORC" teardown "$MM_ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "#47 -- teardown succeeds once the real repo root is given explicitly, from a caller sitting in a totally different repo"
else
  fail "#47 -- teardown should succeed with the correct ORC_WORKTREE_REPO_ROOT (status=$STATUS): $OUT"
fi
if [ ! -d "$MM_WT" ]; then
  pass "worktree was actually removed"
else
  fail "worktree should have been removed"
fi
if ! git -C "$DEVROOT" show-ref --verify --quiet "refs/heads/$MM_BRANCH"; then
  pass "local branch was actually deleted"
else
  fail "local branch should have been deleted"
fi
if ! git -C "$DEVROOT" ls-remote --exit-code --heads origin "$MM_BRANCH" >/dev/null 2>&1; then
  pass "#47 finding 3 -- remote branch was actually deleted (this never existed in the code before #47)"
else
  fail "#47 REGRESSION -- remote branch should have been deleted, was left behind"
fi

mismatch_cleanup

echo "== #47: remote-only absence (never pushed) is still a harmless no-op -- only LOCAL worktree/branch absence is treated as suspicious =="
# A branch that was `start`ed but never `finish`ed (never pushed) has no
# remote counterpart at all -- that's a legitimate state (not every scratch
# branch reaches a real PR), so its absence on origin must not be treated
# the same as a wrong-repo-root false success. Local worktree+branch are a
# different story: start/resume always create them TOGETHER, so for a
# teardown invoked on a real merged PR, their absence really is the
# suspicious signal.
# The preceding "unmerged branch" section intentionally leaves TD_BRANCH
# behind un-deleted (that's what it's testing) -- clear it first so `start`
# below isn't a silent no-op against a stale branch from that case.
teardown_cleanup
bash "$ORC" start "$TD_ISSUE" >/dev/null 2>&1
OUT="$(bash "$ORC" teardown "$TD_ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "#47 -- a clean worktree + locally-merged branch with NO remote counterpart still tears down successfully (remote absence alone isn't suspicious)"
else
  fail "#47 -- teardown of a never-pushed branch should still succeed (status=$STATUS): $OUT"
fi
teardown_cleanup

echo "== #47 round 2 (agy's dedicated security pass on PR #65): a network/auth error checking the remote must NOT be mistaken for 'branch already gone' =="
# git ls-remote --exit-code returns exit 2 when origin explicitly confirms
# no matching ref exists, but a DIFFERENT non-zero (128, unreachable
# remote/auth failure/etc) on any other failure. The original
# branch_exists_remote collapsed both into the same "false" -- a network
# blip during teardown's remote-delete step would silently skip it while
# cmd_teardown still logged overall success, exactly the false-success
# class #47 is about, just relocated to the new code. Reproduced fully
# offline: origin points at a path that isn't a git repo at all, so
# ls-remote fails with a real fatal error (exit 128), not exit 2.
NET_ORIGIN_BARE="$(mktemp -d)"
NET_ORIGIN_BARE="$(cd "$NET_ORIGIN_BARE" && pwd -P)"
git init -q --bare "$NET_ORIGIN_BARE"

NET_DEVROOT="$(mktemp -d)"
NET_DEVROOT="$(cd "$NET_DEVROOT" && pwd -P)"
git init -q "$NET_DEVROOT"
git -C "$NET_DEVROOT" config user.email "test@test.local"
git -C "$NET_DEVROOT" config user.name "test"
git -C "$NET_DEVROOT" remote add origin "$NET_ORIGIN_BARE"
git -C "$NET_DEVROOT" commit -q --allow-empty -m init
git -C "$NET_DEVROOT" push -q -u origin HEAD:main

NET_ISSUE="net-error-scratch"
NET_BRANCH="feature/issue-$NET_ISSUE"
NET_WT="$NET_DEVROOT/.worktrees/issue-$NET_ISSUE"
git -C "$NET_DEVROOT" worktree add -q -b "$NET_BRANCH" "$NET_WT" main
git -C "$NET_DEVROOT" push -q -u origin "$NET_BRANCH"

# Break the remote AFTER pushing, so the branch genuinely exists on
# "origin" but is now unreachable -- exactly the network-blip shape.
git -C "$NET_DEVROOT" remote set-url origin "$NET_DEVROOT/definitely-not-a-git-repo"

OUT="$(ORC_WORKTREE_REPO_ROOT="$NET_DEVROOT" bash "$ORC" teardown "$NET_ISSUE" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  pass "#47 round 2 -- teardown fails loudly when the remote can't be reached, instead of silently skipping the delete and reporting success"
else
  fail "#47 round 2 REGRESSION -- a network/auth error checking the remote branch was mistaken for 'already gone', teardown reported success: $OUT"
fi

git -C "$NET_DEVROOT" worktree remove --force "$NET_WT" >/dev/null 2>&1
rm -rf "$NET_DEVROOT" "$NET_ORIGIN_BARE"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
