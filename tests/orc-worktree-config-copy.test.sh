#!/bin/bash
# tests/orc-worktree-config-copy.test.sh -- issue #171 item 5b (riskiest
# edge, tested explicitly per the plan): once orchestrator.yaml and
# souls/*.md are untracked (git rm --cached, see tests/repo-gitignore.
# test.sh), `git worktree add` -- used by lib/orc-worktree.sh's
# start/resume -- only checks out TRACKED files, so a brand-new worktree
# no longer gets either physically present at its own top level.
#
# lib/harness-root.sh's harness_canonical_dir tolerates this fine: it
# walks UP from cwd looking for orchestrator.yaml as a plain filesystem
# check, and every worktree this script creates nests under
# $REPO_ROOT/.worktrees/ -- INSIDE the main checkout's own directory
# tree -- so the walk-up falls through to the main checkout's own
# (still physically present, just untracked) orchestrator.yaml. See
# tests/harness-root.test.sh for that axis; not re-tested here.
#
# orc-config.sh's readers (orc_get_scalar/orc_protected_paths/
# orc_github_repo) are a SEPARATE axis: orc_config_file() only ever
# resolves "orchestrator.yaml" relative to $PWD (or $ORC_CONFIG_FILE) --
# no walk-up at all. With cwd = the worktree (any hook/guard firing
# inside a Builder pane whose cwd IS the worktree), that resolves to
# nothing once orchestrator.yaml is untracked and no longer physically
# copied in -- protected_paths silently comes back EMPTY, a guard
# fail-open, not a loud failure. This test proves (real `git worktree
# add`, real orc-config.sh, no mocks) that start/resume copy
# orchestrator.yaml + souls/*.md into the new worktree so these readers
# keep working with cwd = the worktree.
#
# Uses a throwaway SCRATCH "main repo" + a local BARE repo standing in
# for `origin` (no live GitHub calls) -- ORC_WORKTREE_REPO_ROOT points
# lib/orc-worktree.sh at the scratch repo instead of this real checkout,
# so nothing here touches this checkout's own .worktrees/ or origin.
# Run: bash tests/orc-worktree-config-copy.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
SCRATCH="$(cd "$SCRATCH" && pwd -P)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

BARE="$SCRATCH/origin.git"
git init -q --bare "$BARE"

MAIN="$SCRATCH/main-repo"
mkdir -p "$MAIN"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email "test@test.local"
git -C "$MAIN" config user.name "test"
git -C "$MAIN" remote add origin "$BARE"

cat > "$MAIN/orchestrator.yaml" <<'EOF'
project: scratch-worktree-project
integration_branch: main
github_repo: some-owner/some-repo

protected_paths:
  - secrets/
EOF
mkdir -p "$MAIN/souls"
echo "# orchestra soul" > "$MAIN/souls/orchestra.md"
echo "# builder soul" > "$MAIN/souls/builder.md"
echo "# reviewer soul" > "$MAIN/souls/reviewer.md"
echo "# scribe soul" > "$MAIN/souls/scribe.md"
echo "x" > "$MAIN/file.txt"
# A tracked .gitignore matching this repo's own post-#171 rules --
# without this, `git add -A` (cmd_pause's WIP-commit path) would see the
# COPIED orchestrator.yaml/souls/*.md as plain untracked files (nothing
# in an empty tree ignores them) and vacuum them into a WIP commit,
# silently re-tracking exactly what item 5b untracks. The real repo
# always has this covered (.gitignore is itself a tracked file, present
# in every branch/worktree) -- mirrored here so the fixture matches
# production instead of masking this failure mode.
printf '/orchestrator.yaml\n/souls/*.md\n' > "$MAIN/.gitignore"
git -C "$MAIN" add file.txt .gitignore
git -C "$MAIN" commit -q -m "init (orchestrator.yaml/souls intentionally NOT added -- untracked from the start, matching the post-#171 state)"
git -C "$MAIN" branch -M main
git -C "$MAIN" push -u origin main -q

# Confirm the fixture actually matches the post-migration state before
# trusting any assertion built on top of it.
if git -C "$MAIN" ls-files --error-unmatch orchestrator.yaml >/dev/null 2>&1; then
  fail "test setup: orchestrator.yaml should NOT be tracked in the scratch repo"
fi

export ORC_WORKTREE_REPO_ROOT="$MAIN"

echo "== start: worktree creation succeeds against an untracked-orchestrator.yaml main repo =="
OUT="$(bash "$LIB/orc-worktree.sh" start scratch1 2>&1)"
STATUS=$?
WT="$MAIN/.worktrees/issue-scratch1"
if [ "$STATUS" -eq 0 ] && [ -d "$WT" ]; then
  pass "start created the worktree"
else
  fail "start failed (status=$STATUS): $OUT"
fi

echo "== start copies orchestrator.yaml into the new worktree (config-content reads work with cwd=worktree) =="
if [ -f "$WT/orchestrator.yaml" ]; then
  pass "orchestrator.yaml physically present in the new worktree"
else
  fail "orchestrator.yaml missing from the new worktree -- config-content readers (orc_get_scalar etc.) would silently fail closed with cwd=worktree"
fi

echo "== start copies souls/*.md into the new worktree =="
for f in souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md; do
  if [ -f "$WT/$f" ]; then
    pass "$f present in the new worktree"
  else
    fail "$f missing from the new worktree"
  fi
done

echo "== orc_get_scalar/orc_protected_paths/orc_github_repo resolve correctly from inside the new worktree (cwd-based, no walk-up) =="
GOT_PROJECT="$(cd "$WT" && source "$LIB/orc-config.sh" && orc_get_scalar project)"
if [ "$GOT_PROJECT" = "scratch-worktree-project" ]; then
  pass "orc_get_scalar project resolves correctly from inside the worktree"
else
  fail "expected 'scratch-worktree-project', got '$GOT_PROJECT'"
fi

GOT_PATHS="$(cd "$WT" && source "$LIB/orc-config.sh" && orc_protected_paths)"
if [ "$GOT_PATHS" = "secrets/" ]; then
  pass "orc_protected_paths resolves correctly from inside the worktree (guard-write.sh would actually enforce it)"
else
  fail "expected 'secrets/', got '$GOT_PATHS' -- protected_paths silently empty inside a worktree is a guard fail-open"
fi

GOT_REPO="$(cd "$WT" && source "$LIB/orc-config.sh" && orc_github_repo)"
if [ "$GOT_REPO" = "some-owner/some-repo" ]; then
  pass "orc_github_repo resolves correctly from inside the worktree"
else
  fail "expected 'some-owner/some-repo', got '$GOT_REPO'"
fi

echo "== pause's WIP-commit path (git add -A) does NOT vacuum the copied, gitignored orchestrator.yaml/souls/*.md into a commit =="
echo "real wip change" > "$WT/wip-marker.txt"
bash "$LIB/orc-worktree.sh" pause scratch1 >/dev/null 2>&1
if git -C "$MAIN" show "feature/issue-scratch1:orchestrator.yaml" >/dev/null 2>&1; then
  fail "pause's 'git add -A' WIP commit accidentally tracked orchestrator.yaml on the branch -- defeats the untracked migration"
else
  pass "pause's WIP commit did not track the copied orchestrator.yaml"
fi
bash "$LIB/orc-worktree.sh" resume scratch1 >/dev/null 2>&1
if [ -f "$WT/orchestrator.yaml" ]; then
  pass "resume also copies orchestrator.yaml into the worktree"
else
  fail "resume did not copy orchestrator.yaml into the worktree"
fi
for f in souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md; do
  if [ -f "$WT/$f" ]; then
    pass "resume also copies $f into the worktree"
  else
    fail "resume did not copy $f into the worktree"
  fi
done

echo "== the copied orchestrator.yaml stays untracked inside the worktree (plain file copy, no git add) =="
if git -C "$WT" ls-files --error-unmatch orchestrator.yaml >/dev/null 2>&1; then
  fail "orchestrator.yaml copy got git-added inside the worktree -- must stay untracked, plain filesystem copy only"
else
  pass "copied orchestrator.yaml stays untracked inside the worktree"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
