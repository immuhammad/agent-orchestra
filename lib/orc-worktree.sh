#!/bin/bash
# .harness/orc-worktree.sh {start|pause|resume|finish} <issue> [base-commit]
#
# Worktree-per-issue layer. Serial use for now -- one worktree
# active at a time is a convention, not an enforced lock; parallel Builders
# is a later flag-flip, not this script's job.
#
# The BRANCH is the durable unit; the worktree is disposable. git itself is
# the source of truth for both (no separate state file to drift out of
# sync): `git worktree list` for whether a worktree is currently checked
# out, `git show-ref` / `git ls-remote` for whether the branch exists.
#
#   start <issue> [base-commit]
#     Create worktree .worktrees/issue-<N> on a NEW branch
#     feature/issue-<N>, branched from an explicit commit (default: the
#     current tip of origin/uat, resolved to a SHA and pinned -- not a
#     moving ref -- so the base is reproducible even if uat advances while
#     you work). Refuses if the branch already exists (local or remote) --
#     use `resume` for that, since `start` must never re-point or delete an
#     existing branch.
#
#   pause <issue>
#     Commit any uncommitted work in the worktree as a WIP commit (no-op if
#     the tree is already clean), then remove the worktree. The branch is
#     untouched -- worktree removal never deletes it.
#
#   resume <issue>
#     Re-create the worktree from the existing branch feature/issue-<N>
#     (local if present, else fetched from origin). Refuses if a worktree
#     for this issue is already checked out somewhere.
#
#   finish <issue> [extra-issue ...]
#     Push feature/issue-<N> to origin and open a PR to uat (draft, per the
#     current review-gated flow -- see AGENTS.md Dispatch Protocol). Body
#     always includes "Closes #<issue>." (standardized so
#     merge-watch can always find it); any extra issue numbers (bundled
#     tickets sharing one branch/PR) each get their own "Closes #N." line
#     too. Does NOT remove the worktree: a review may come back
#     REQUEST-CHANGES, and fixing that means pushing more commits from the
#     same worktree. Run `pause` explicitly once the PR is truly done with.
#
#   teardown <issue>
#     Post-merge cleanup (issue #85, Task 4): removes the worktree at
#     .worktrees/issue-<N> ONLY if it is clean (`git status --porcelain`
#     empty) -- a dirty worktree is NOT force-removed, it is FLAGged to
#     orchestra via the inbox instead, since uncommitted work surviving a
#     merge is exactly the kind of thing a human should look at, not
#     something this script should silently discard. Then deletes the local
#     branch with `git branch -d` (never `-D`, matching the "this script
#     never deletes a branch" rule below in spirit -- an unmerged branch
#     must survive and get flagged too, since a merged PR
#     doesn't necessarily absorb every commit that was ever pushed to its
#     branch), and finally deletes the REMOTE branch too (#47 -- this never
#     existed before; "GitHub's delete_branch_on_merge didn't fire" was
#     never GitHub's fault, the code simply never ran it).
#
#     #47: NOT idempotent on a missing worktree or missing LOCAL branch --
#     a real merged PR always has both (start/resume always create them
#     together), so either being absent is treated as a FAILURE, not a
#     silent no-op. The previous version treated "I looked and found
#     nothing" the same as "I cleaned up", which combined with a wrong
#     REPO_ROOT (self-dogfood rooms run this from a DIFFERENT repo than the
#     one holding the worktree) to silently lose three consecutive merges'
#     worth of cleanup while logging success the whole time. A missing
#     REMOTE branch is still a harmless no-op (a branch that was `start`ed
#     but never pushed via `finish` legitimately has no remote counterpart).
#     Every removal (worktree, local branch, remote branch) is VERIFIED
#     gone before being logged as done -- `return 0` means the resources
#     are actually gone, not merely that a removal command was attempted.
#     Only ever touches the worktree/branch for the given issue number
#     (feature/issue-<N>) -- never anything else.
#
# Hard rule carried over from AGENTS.md: this script never merges. It never
# force-deletes a branch (`-D`) or force-removes a dirty worktree either --
# `teardown` only ever removes what's already clean/merged, and flags
# anything else to a human instead of discarding it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# issue #116: REPO_ROOT is the CONSUMER project's git repo (worktrees are
# created inside it), not the directory above this script (this script
# now lives in agent-orchestra's own lib/, a separate repo entirely).
REPO_ROOT="${ORC_WORKTREE_REPO_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$REPO_ROOT" ]; then
  echo "orc-worktree.sh: not inside a git repo (run from the consumer project, or set ORC_WORKTREE_REPO_ROOT)" >&2
  exit 1
fi
# shellcheck source=./dispatch.sh
source "$DIR/dispatch.sh"
# shellcheck source=./orc-config.sh
source "$DIR/orc-config.sh"
# issue #116: "uat" was career-ops-harness's own integration branch name,
# hardcoded here -- generalized to read orchestrator.yaml's
# integration_branch (same key orc.sh's control-room build already
# reads), falling back to "uat" only for existing consumers whose config
# predates this or omits the key.
INTEGRATION_BRANCH="$(cd "$REPO_ROOT" && orc_get_scalar integration_branch)"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-uat}"

usage() {
  echo "usage: orc-worktree.sh {start|pause|resume|finish|teardown} <issue> [base-commit|extra-issue ...]" >&2
}

branch_name() { echo "feature/issue-$1"; }
# #47: worktrees are created at .worktrees/ (repo-root-relative, gitignored
# -- see .gitignore), NOT .claude/worktrees/. The old path here never
# matched where `start`/`resume` (or a Builder dispatch's own "work in a
# worktree" convention) actually put anything, so a caller resolving the
# WRONG REPO_ROOT (see REPO_ROOT above) landed on a path that would have
# been wrong even in the RIGHT repo -- two independent mismatches stacked.
# Single source of the convention so it can't drift internally again.
worktree_path() { echo "$REPO_ROOT/.worktrees/issue-$1"; }

branch_exists_local() {
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$1"
}

branch_exists_remote() {
  git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1
}

# _teardown_remote_branch_state <branch> -- echoes "exists", "absent", or
# "unknown" for the branch on origin, always returns 0. #47 round 2 (agy's
# dedicated security pass on PR #65): branch_exists_remote above is a plain
# boolean built on `git ls-remote --exit-code`'s raw exit status, which is
# 2 when origin explicitly confirms no matching ref exists, but some OTHER
# non-zero (128, typically) on a network blip, auth failure, or
# unreachable remote -- a plain boolean collapses both into "false",
# indistinguishable from "confirmed absent". cmd_teardown's remote section
# used exactly that boolean and, on a network error, fell into "already
# gone, nothing to delete" -- skipping the delete silently while still
# logging overall success, the same false-success class #47 itself is
# about. This distinguishes the three cases explicitly; cmd_teardown is the
# one caller that needs it. cmd_start's existing branch_exists_remote
# usage (a simple "does it exist, for refusing to re-point a branch"
# check) is left untouched -- out of scope for this finding.
_teardown_remote_branch_state() {
  local status
  git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1
  status=$?
  case "$status" in
    0) echo "exists" ;;
    2) echo "absent" ;;
    *) echo "unknown" ;;
  esac
}

worktree_is_checked_out() {
  local path="$1"
  git -C "$REPO_ROOT" worktree list --porcelain | grep -q "^worktree $path\$"
}

cmd_start() {
  local issue="$1" base="${2:-}"
  local branch wt
  branch="$(branch_name "$issue")"
  wt="$(worktree_path "$issue")"

  if branch_exists_local "$branch" || branch_exists_remote "$branch"; then
    echo "orc-worktree.sh: branch '$branch' already exists (local or remote) -- use 'resume', 'start' never re-points an existing branch" >&2
    return 1
  fi
  if worktree_is_checked_out "$wt"; then
    echo "orc-worktree.sh: worktree already checked out at $wt" >&2
    return 1
  fi

  git -C "$REPO_ROOT" fetch origin "$INTEGRATION_BRANCH" >/dev/null 2>&1
  if [ -z "$base" ]; then
    base="$(git -C "$REPO_ROOT" rev-parse "origin/$INTEGRATION_BRANCH")"
  fi
  local base_sha
  base_sha="$(git -C "$REPO_ROOT" rev-parse "$base" 2>/dev/null)" || {
    echo "orc-worktree.sh: base commit '$base' does not resolve" >&2
    return 1
  }

  mkdir -p "$REPO_ROOT/.worktrees"
  git -C "$REPO_ROOT" worktree add -b "$branch" "$wt" "$base_sha"
  echo "orc-worktree.sh: started $branch at $wt (base $base_sha)"
}

cmd_pause() {
  local issue="$1"
  local branch wt
  branch="$(branch_name "$issue")"
  wt="$(worktree_path "$issue")"

  if ! worktree_is_checked_out "$wt"; then
    echo "orc-worktree.sh: no worktree checked out at $wt -- nothing to pause" >&2
    return 1
  fi

  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    git -C "$wt" add -A
    git -C "$wt" commit -q -m "wip: pause issue $issue"
    echo "orc-worktree.sh: committed WIP on $branch"
  else
    echo "orc-worktree.sh: working tree already clean, no WIP commit needed"
  fi

  git -C "$REPO_ROOT" worktree remove "$wt"
  echo "orc-worktree.sh: paused $branch, worktree removed (branch is durable, untouched)"
}

cmd_resume() {
  local issue="$1"
  local branch wt
  branch="$(branch_name "$issue")"
  wt="$(worktree_path "$issue")"

  if worktree_is_checked_out "$wt"; then
    echo "orc-worktree.sh: worktree already checked out at $wt -- nothing to resume" >&2
    return 1
  fi

  if ! branch_exists_local "$branch"; then
    if branch_exists_remote "$branch"; then
      git -C "$REPO_ROOT" fetch origin "$branch:$branch" >/dev/null 2>&1
    else
      echo "orc-worktree.sh: branch '$branch' does not exist locally or on origin -- use 'start' first" >&2
      return 1
    fi
  fi

  mkdir -p "$REPO_ROOT/.worktrees"
  git -C "$REPO_ROOT" worktree add "$wt" "$branch"
  echo "orc-worktree.sh: resumed $branch at $wt"
}

# build_pr_body <issue> [extra-issue ...] -- one "Closes #N." line per issue
# number given. Split out so tests can check the bundled-issue shape
# directly instead of only through a real (network) gh pr create call.
build_pr_body() {
  local issue="$1"
  shift
  local body="Closes #$issue."
  local extra
  for extra in "$@"; do
    body="$body
Closes #$extra."
  done
  echo "$body"
}

cmd_finish() {
  local issue="$1"
  shift
  # A ticket bundling more than one GitHub issue onto the
  # same branch/PR used to get a PR body written
  # by hand that sometimes dropped the "Closes #N" line entirely -- merge-
  # watch then silently skipped it. Any EXTRA issue numbers passed here get
  # their own "Closes #N" line too, so the standard template covers bundles
  # without anyone having to remember to edit the body afterward.
  local extra_issues=("$@")
  local branch wt
  branch="$(branch_name "$issue")"
  wt="$(worktree_path "$issue")"

  if ! worktree_is_checked_out "$wt"; then
    echo "orc-worktree.sh: no worktree checked out at $wt -- 'resume' it first" >&2
    return 1
  fi

  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    git -C "$wt" add -A
    git -C "$wt" commit -q -m "wip: finish issue $issue"
    echo "orc-worktree.sh: committed outstanding WIP on $branch before pushing"
  fi

  git -C "$wt" push -u origin "$branch"

  local body
  # "${extra_issues[@]+"${extra_issues[@]}"}" (not the bare "${extra_issues[@]}")
  # -- macOS ships bash 3.2, where `set -u` throws "unbound variable" on an
  # EMPTY array's [@] expansion (fixed upstream in bash 4.4+, but this repo
  # runs on whatever /bin/bash the box has). Bit real: with `set -uo
  # pipefail` and no `-e`, that error inside this command substitution
  # silently produced an EMPTY $body for the single-issue (non-bundled)
  # case, which `gh pr create --body ""` then accepted without complaint.
  body="$(build_pr_body "$issue" "${extra_issues[@]+"${extra_issues[@]}"}")"

  local pr_url
  pr_url="$(cd "$wt" && gh pr create \
    --base "$INTEGRATION_BRANCH" --head "$branch" --draft \
    --title "Issue #$issue" \
    --body "$body" 2>&1)" || {
    echo "orc-worktree.sh: push succeeded but gh pr create failed:" >&2
    echo "$pr_url" >&2
    return 1
  }
  echo "orc-worktree.sh: pushed $branch and opened draft PR: $pr_url"
}

cmd_teardown() {
  local issue="$1"
  local branch wt failed=0
  branch="$(branch_name "$issue")"
  wt="$(worktree_path "$issue")"

  # -- worktree ------------------------------------------------------------
  if worktree_is_checked_out "$wt"; then
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
      dispatch_main assign orchestra "$issue" \
        "FLAG: worktree for issue #$issue ($wt) has uncommitted changes after merge -- teardown skipped, do NOT force-remove, investigate." >/dev/null
      echo "orc-worktree.sh: teardown skipped: worktree at $wt is dirty (flagged orchestra)" >&2
      return 1
    fi
    git -C "$REPO_ROOT" worktree remove "$wt"
    if worktree_is_checked_out "$wt"; then
      echo "orc-worktree.sh: teardown FAILED: 'git worktree remove' ran but $wt is still checked out -- refusing to report success" >&2
      failed=1
    else
      echo "orc-worktree.sh: removed worktree at $wt"
    fi
  else
    # #47: a real merged PR always has a worktree here (start/resume always
    # create one) -- "not found" is either a legitimate double-run (harmless
    # in practice: watch.sh's mw_already_processed state file guarantees
    # teardown only ever runs ONCE per merged PR) or exactly the wrong-
    # REPO_ROOT/wrong-path-convention bug that silently ate three merges'
    # worth of cleanup while this line used to read "nothing to remove" and
    # return success. Cannot tell those apart from here, so fail loud
    # rather than guess innocent.
    echo "orc-worktree.sh: teardown FAILED: no worktree checked out at $wt, but a just-merged issue is expected to have one -- REPO_ROOT ($REPO_ROOT) or the worktree path convention may be wrong. Refusing to report success; if this really is a legitimate re-run, verify the branch is also already gone before ignoring this." >&2
    failed=1
  fi

  # -- local branch ----------------------------------------------------------
  if branch_exists_local "$branch"; then
    local err
    if err="$(git -C "$REPO_ROOT" branch -d "$branch" 2>&1)"; then
      if branch_exists_local "$branch"; then
        echo "orc-worktree.sh: teardown FAILED: 'git branch -d' ran but $branch still exists locally -- refusing to report success" >&2
        failed=1
      else
        echo "orc-worktree.sh: deleted local branch $branch"
      fi
    else
      echo "orc-worktree.sh: teardown skipped: local branch $branch not fully merged (git branch -d refused): $err" >&2
      failed=1
    fi
  else
    echo "orc-worktree.sh: teardown FAILED: no local branch $branch found, but a just-merged issue is expected to have one -- REPO_ROOT ($REPO_ROOT) may be wrong. Refusing to report success." >&2
    failed=1
  fi

  # -- remote branch (#47: never existed before) ----------------------------
  # Confirmed absence is NOT treated as suspicious the way worktree/local-
  # branch absence is: a branch that was `start`ed but never pushed via
  # `finish` legitimately has no remote counterpart, and that's a normal
  # state, not a sign anything is wrong. An UNKNOWN state (network/auth
  # error, unreachable remote) is different -- #47 round 2: conflating
  # "confirmed absent" with "couldn't check" let a network blip skip the
  # delete silently while still reporting overall success.
  local remote_state
  remote_state="$(_teardown_remote_branch_state "$branch")"
  case "$remote_state" in
    exists)
      if git -C "$REPO_ROOT" push origin --delete "$branch" >/dev/null 2>&1 \
        && [ "$(_teardown_remote_branch_state "$branch")" = "absent" ]; then
        echo "orc-worktree.sh: deleted remote branch $branch"
      else
        echo "orc-worktree.sh: teardown FAILED: could not verify remote branch $branch was deleted -- refusing to report success" >&2
        failed=1
      fi
      ;;
    absent)
      echo "orc-worktree.sh: remote branch $branch already gone (or never pushed), nothing to delete"
      ;;
    unknown)
      echo "orc-worktree.sh: teardown FAILED: could not verify whether remote branch $branch exists on origin (network or auth error?) -- refusing to report success" >&2
      failed=1
      ;;
  esac

  [ "$failed" -eq 0 ]
}

main() {
  local sub="${1:-}" issue="${2:-}"
  if [ -z "$sub" ] || [ -z "$issue" ]; then
    usage
    return 1
  fi
  shift 2 || true

  case "$sub" in
    start)    cmd_start "$issue" "$@" ;;
    pause)    cmd_pause "$issue" ;;
    resume)   cmd_resume "$issue" ;;
    finish)   cmd_finish "$issue" "$@" ;;
    teardown) cmd_teardown "$issue" ;;
    *)
      usage
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
