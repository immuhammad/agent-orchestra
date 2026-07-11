#!/bin/bash
# .harness/orc-worktree.sh {start|pause|resume|finish} <issue> [base-commit]
#
# Worktree-per-issue layer (T18, Q5c). Serial use for now -- one worktree
# active at a time is a convention, not an enforced lock; parallel Builders
# is a later flag-flip (T18's plan note), not this script's job.
#
# The BRANCH is the durable unit; the worktree is disposable. git itself is
# the source of truth for both (no separate state file to drift out of
# sync): `git worktree list` for whether a worktree is currently checked
# out, `git show-ref` / `git ls-remote` for whether the branch exists.
#
#   start <issue> [base-commit]
#     Create worktree .claude/worktrees/issue-<N> on a NEW branch
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
#     always includes "Closes #<issue>." (T30, issue #56 -- standardized so
#     merge-watch can always find it); any extra issue numbers (bundled
#     tickets sharing one branch/PR) each get their own "Closes #N." line
#     too. Does NOT remove the worktree: a review may come back
#     REQUEST-CHANGES, and fixing that means pushing more commits from the
#     same worktree. Run `pause` explicitly once the PR is truly done with.
#
#   teardown <issue>
#     Post-merge cleanup (issue #85, Task 4): removes the worktree at
#     .claude/worktrees/issue-<N> ONLY if it is clean (`git status
#     --porcelain` empty) -- a dirty worktree is NOT force-removed, it is
#     FLAGged to orchestra via the inbox instead, since uncommitted work
#     surviving a merge is exactly the kind of thing a human should look at,
#     not something this script should silently discard. Then deletes the
#     branch with `git branch -d` (never `-D`, matching the "this script
#     never deletes a branch" rule below in spirit -- an unmerged branch
#     must survive and get flagged too, per the T31 lesson that a merged PR
#     doesn't necessarily absorb every commit that was ever pushed to its
#     branch). Idempotent: an already-gone worktree or already-gone branch
#     is a clean no-op, not an error. Only ever touches the worktree/branch
#     for the given issue number (feature/issue-<N>) -- never anything else.
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
worktree_path() { echo "$REPO_ROOT/.claude/worktrees/issue-$1"; }

branch_exists_local() {
  git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$1"
}

branch_exists_remote() {
  git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1
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

  mkdir -p "$REPO_ROOT/.claude/worktrees"
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

  mkdir -p "$REPO_ROOT/.claude/worktrees"
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
  # T30 (issue #56): a ticket bundling more than one GitHub issue onto the
  # same branch/PR (e.g. T24+T25 on #34+#40) used to get a PR body written
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
  local branch wt
  branch="$(branch_name "$issue")"
  wt="$(worktree_path "$issue")"

  if worktree_is_checked_out "$wt"; then
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
      dispatch_main assign orchestra "$issue" \
        "FLAG: worktree for issue #$issue ($wt) has uncommitted changes after merge -- teardown skipped, do NOT force-remove, investigate." >/dev/null
      echo "orc-worktree.sh: teardown skipped: worktree at $wt is dirty (flagged orchestra)" >&2
      return 1
    fi
    git -C "$REPO_ROOT" worktree remove "$wt"
    echo "orc-worktree.sh: removed worktree at $wt"
  else
    echo "orc-worktree.sh: no worktree checked out at $wt, nothing to remove"
  fi

  if branch_exists_local "$branch"; then
    local err
    if err="$(git -C "$REPO_ROOT" branch -d "$branch" 2>&1)"; then
      echo "orc-worktree.sh: deleted merged branch $branch"
    else
      echo "orc-worktree.sh: teardown skipped: branch $branch not fully merged (git branch -d refused): $err" >&2
      return 1
    fi
  else
    echo "orc-worktree.sh: branch $branch already gone, nothing to delete"
  fi
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
