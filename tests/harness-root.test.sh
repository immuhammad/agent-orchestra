#!/bin/bash
# tests/harness-root.test.sh — tests for harness_canonical_dir.
# Run: ./tests/harness-root.test.sh
#
# Rewritten for issue #116's root-resolution generalization: the function
# no longer resolves off a script's own directory (there is no longer a
# script directory inside the consumer project to resolve off of --
# lib/harness-root.sh now lives in agent-orchestra's own repo). It instead
# discovers the project root by walking up from a given start dir looking
# for orchestrator.yaml, honors ORC_PROJECT_ROOT as an explicit override,
# and FAILS LOUD (stderr + exit 1, no stdout) if neither resolves --
# there is no more silent fallback to the given dir.
#
# Uses a throwaway SCRATCH git repo + worktree (never this actual repo) so
# nothing here touches any real inbox/state.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
source "$LIB/harness-root.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
# Resolve symlinks up front (macOS: /tmp -> /private/tmp) so comparisons
# below match what `git rev-parse --path-format=absolute` itself returns.
SCRATCH="$(cd "$SCRATCH" && pwd -P)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

MAIN="$SCRATCH/main-repo"
mkdir -p "$MAIN"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email "test@test.local"
git -C "$MAIN" config user.name "test"
# orchestrator.yaml is the project-root marker the walk-up discovery
# looks for -- committed so a `git worktree add` copies it into the
# worktree too (exercising the worktree-redirect case below).
echo "project: scratch" > "$MAIN/orchestrator.yaml"
echo "x" > "$MAIN/file.txt"
git -C "$MAIN" add file.txt orchestrator.yaml
git -C "$MAIN" commit -q -m "init"

echo "== harness_canonical_dir: from the main checkout, resolves to its own .harness =="
GOT="$(harness_canonical_dir "$MAIN")"
if [ "$GOT" = "$MAIN/.harness" ]; then
  pass "main checkout resolves to its own .harness"
else
  fail "expected $MAIN/.harness, got $GOT"
fi

echo "== harness_canonical_dir: from a nested subdir with no orchestrator.yaml of its own, still walks UP to find it =="
NESTED="$MAIN/a/b/c"
mkdir -p "$NESTED"
GOT_NESTED="$(harness_canonical_dir "$NESTED")"
if [ "$GOT_NESTED" = "$MAIN/.harness" ]; then
  pass "nested subdir walks up and resolves to the project root's .harness"
else
  fail "expected $MAIN/.harness, got $GOT_NESTED"
fi

echo "== harness_canonical_dir: from a WORKTREE, still resolves to the MAIN checkout's .harness (issue #99) =="
WT="$SCRATCH/wt-issue-1"
git -C "$MAIN" worktree add -q -b feature/scratch "$WT" >/dev/null 2>&1
# The worktree gets its OWN tracked copy of orchestrator.yaml (git
# worktree checks out the full tree) -- a naive walk-up alone would find
# THAT copy and stop at the worktree root. The git-common-dir redirect is
# what's actually being tested here.
if [ ! -f "$WT/orchestrator.yaml" ]; then
  fail "test setup: worktree should have its own tracked orchestrator.yaml copy"
fi
GOT_WT="$(harness_canonical_dir "$WT")"
if [ "$GOT_WT" = "$MAIN/.harness" ]; then
  pass "worktree checkout still resolves to the MAIN checkout's .harness, not its own"
else
  fail "expected worktree to resolve to $MAIN/.harness (the canonical repo root), got $GOT_WT"
fi
if [ "$GOT_WT" != "$WT/.harness" ]; then
  pass "worktree's OWN .harness (the split-mailbox bug, #99) is NOT what got returned"
else
  fail "worktree_canonical_dir must never return the worktree's own .harness"
fi

echo "== issue #18 (item 8): a NESTED clone-per-project dev target (its own orchestrator.yaml, inside an OUTER project's tree) resolves to its own .harness, not the outer one =="
OUTER="$SCRATCH/outer-harness"
mkdir -p "$OUTER"
echo "project: outer" > "$OUTER/orchestrator.yaml"
NESTED_PROJECT="$OUTER/project/agent-orchestra"
mkdir -p "$NESTED_PROJECT"
echo "project: agent-orchestra" > "$NESTED_PROJECT/orchestrator.yaml"
GOT_NESTED_PROJECT="$(harness_canonical_dir "$NESTED_PROJECT")"
if [ "$GOT_NESTED_PROJECT" = "$NESTED_PROJECT/.harness" ]; then
  pass "nested dev-target clone resolves to ITS OWN .harness, not walking past it to the outer project's"
else
  fail "expected $NESTED_PROJECT/.harness, got $GOT_NESTED_PROJECT"
fi

echo "== harness_canonical_dir: ORC_PROJECT_ROOT overrides discovery outright =="
NOGIT="$SCRATCH/not-a-repo"
mkdir -p "$NOGIT"
GOT_OVERRIDE="$(ORC_PROJECT_ROOT="$NOGIT" harness_canonical_dir "$NOGIT")"
if [ "$GOT_OVERRIDE" = "$NOGIT/.harness" ]; then
  pass "ORC_PROJECT_ROOT wins even with no orchestrator.yaml and no git repo at all"
else
  fail "expected $NOGIT/.harness, got $GOT_OVERRIDE"
fi

echo "== harness_canonical_dir: FAILS LOUD (no stdout, exit 1) when neither ORC_PROJECT_ROOT nor orchestrator.yaml resolve =="
GOT_FAIL="$(harness_canonical_dir "$NOGIT" 2>/tmp/harness-root-test-stderr.$$)"
STATUS_FAIL=$?
STDERR_FAIL="$(cat "/tmp/harness-root-test-stderr.$$" 2>/dev/null)"
rm -f "/tmp/harness-root-test-stderr.$$"
if [ "$STATUS_FAIL" -ne 0 ] && [ -z "$GOT_FAIL" ]; then
  pass "no orchestrator.yaml + no override: non-zero exit, empty stdout (no silent fallback)"
else
  fail "expected non-zero exit + empty stdout, got status=$STATUS_FAIL stdout=[$GOT_FAIL]"
fi
if [ -n "$STDERR_FAIL" ]; then
  pass "failure is reported on stderr, not silent"
else
  fail "expected a stderr message explaining the resolution failure"
fi

echo "== end-to-end: dispatch.sh invoked from inside the worktree still writes to the MAIN checkout's inbox =="
# Runs the REAL production lib/dispatch.sh (this repo's actual script, not
# a copy) with cwd inside the worktree, relying purely on orchestrator.yaml
# discovery -- no DISPATCH_CANON_DIR override -- to prove the production
# code path, not a reimplementation. dispatch.sh requires the target
# agent's inbox dir to already exist (it's not auto-created for unknown
# agent names), so pre-create it in the MAIN checkout, same as any real
# agent's inbox would be.
mkdir -p "$MAIN/.harness/inbox/testagent"
OUT="$(cd "$WT" && bash "$LIB/dispatch.sh" message testagent 999 "canonical-path test" 2>&1)"
if ls "$MAIN"/.harness/inbox/testagent/*-999.msg >/dev/null 2>&1; then
  pass "dispatch.sh run from inside the worktree wrote its .msg into the MAIN checkout's inbox"
else
  fail "expected the .msg in the MAIN checkout's inbox, dispatch.sh said: $OUT"
fi
if [ ! -d "$WT/.harness/inbox/testagent" ] || ! ls "$WT"/.harness/inbox/testagent/*-999.msg >/dev/null 2>&1; then
  pass "the worktree's OWN inbox copy stayed empty (mailbox no longer splits)"
else
  fail "the worktree's own inbox copy should NOT have received the message (#99 regression)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
