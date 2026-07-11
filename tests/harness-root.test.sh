#!/bin/bash
# .harness/harness-root.test.sh — tests for harness_canonical_dir (issue
# #99: dispatch.sh/watch.sh/log-decision.sh must resolve inbox/state/log
# paths to the MAIN checkout even when running from inside a worktree).
# Run: bash .harness/harness-root.test.sh
#
# Uses a throwaway SCRATCH git repo + worktree (never this actual repo) so
# nothing here touches the real .harness/inbox, decisions.log, or any real
# worktree.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$DIR/harness-root.sh"

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
echo "x" > "$MAIN/file.txt"
git -C "$MAIN" add file.txt
git -C "$MAIN" commit -q -m "init"

echo "== harness_canonical_dir: from the main checkout, resolves to its own .harness =="
GOT="$(harness_canonical_dir "$MAIN")"
if [ "$GOT" = "$MAIN/.harness" ]; then
  pass "main checkout resolves to its own .harness"
else
  fail "expected $MAIN/.harness, got $GOT"
fi

echo "== harness_canonical_dir: from a WORKTREE, still resolves to the MAIN checkout's .harness (issue #99) =="
WT="$SCRATCH/wt-issue-1"
git -C "$MAIN" worktree add -q -b feature/scratch "$WT" >/dev/null 2>&1
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

echo "== harness_canonical_dir: outside a git repo, falls back to the given dir unchanged =="
NOGIT="$SCRATCH/not-a-repo"
mkdir -p "$NOGIT"
GOT_NOGIT="$(harness_canonical_dir "$NOGIT")"
if [ "$GOT_NOGIT" = "$NOGIT" ]; then
  pass "non-repo dir falls back to itself unchanged"
else
  fail "expected fallback to $NOGIT, got $GOT_NOGIT"
fi

echo "== end-to-end: dispatch.sh invoked from inside the worktree still writes to the MAIN checkout's inbox =="
# Copy the REAL dispatch.sh/send-lib.sh into the scratch main checkout so
# this exercises the actual production code path, not a reimplementation.
mkdir -p "$MAIN/.harness/inbox/testagent"
cp "$DIR/dispatch.sh" "$DIR/send-lib.sh" "$DIR/harness-root.sh" "$MAIN/.harness/"
git -C "$WT" fetch -q "$MAIN" >/dev/null 2>&1 || true
mkdir -p "$WT/.harness/inbox/testagent" # the worktree's OWN (should stay empty) copy
cp "$DIR/dispatch.sh" "$DIR/send-lib.sh" "$DIR/harness-root.sh" "$WT/.harness/"
OUT="$(cd "$WT" && bash .harness/dispatch.sh message testagent 999 "canonical-path test" 2>&1)"
if ls "$MAIN"/.harness/inbox/testagent/*-999.msg >/dev/null 2>&1; then
  pass "dispatch.sh run from inside the worktree wrote its .msg into the MAIN checkout's inbox"
else
  fail "expected the .msg in the MAIN checkout's inbox, dispatch.sh said: $OUT"
fi
if ! ls "$WT"/.harness/inbox/testagent/*-999.msg >/dev/null 2>&1; then
  pass "the worktree's OWN inbox copy stayed empty (mailbox no longer splits)"
else
  fail "the worktree's own inbox copy should NOT have received the message (#99 regression)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
