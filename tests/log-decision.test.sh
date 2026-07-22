#!/bin/bash
# .harness/log-decision.test.sh — TDD tests for log-decision.sh's
# mkdir-based append locking. Run:
# bash .harness/log-decision.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
SCRIPT="$LIB/log-decision.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "== log-decision.sh: basic append =="
LOG_FILE="$TMP/decisions.log"
LOCK_DIR="$TMP/basic.lock"
LOG_DECISION_FILE="$LOG_FILE" LOG_DECISION_LOCK_DIR="$LOCK_DIR" \
  bash "$SCRIPT" "Builder|Sonnet|test decision one"
if grep -q 'Builder | Sonnet | test decision one' "$LOG_FILE" 2>/dev/null; then
  pass "single call appends a well-formed line"
else
  fail "expected a formatted line in $LOG_FILE, got: $(cat "$LOG_FILE" 2>/dev/null)"
fi

echo "== log-decision.sh: releases its lock dir after a normal run =="
if [ ! -d "$LOCK_DIR" ]; then
  pass "lock dir is removed after the call completes"
else
  fail "lock dir '$LOCK_DIR' should have been removed"
fi

echo "== log-decision.sh: two concurrent calls both land (no lost append) =="
CONC_LOG="$TMP/concurrent.log"
CONC_LOCK="$TMP/concurrent.lock"
: > "$CONC_LOG"
(
  LOG_DECISION_FILE="$CONC_LOG" LOG_DECISION_LOCK_DIR="$CONC_LOCK" \
    bash "$SCRIPT" "Builder|Sonnet|concurrent decision A"
) &
PID_A=$!
(
  LOG_DECISION_FILE="$CONC_LOG" LOG_DECISION_LOCK_DIR="$CONC_LOCK" \
    bash "$SCRIPT" "Reviewer|agy|concurrent decision B"
) &
PID_B=$!
wait "$PID_A" "$PID_B"

if grep -q 'concurrent decision A' "$CONC_LOG" && grep -q 'concurrent decision B' "$CONC_LOG"; then
  pass "both concurrent appends landed"
else
  fail "expected both concurrent decisions in the log, got: $(cat "$CONC_LOG")"
fi
if [ "$(wc -l < "$CONC_LOG" | tr -d ' ')" -eq 2 ]; then
  pass "exactly two lines -- no interleaving/corruption"
else
  fail "expected exactly 2 lines, got $(wc -l < "$CONC_LOG")"
fi

echo "== log-decision.sh: a held lock does not lose the append (bounded wait, proceeds unlocked) =="
HELD_LOG="$TMP/held.log"
HELD_LOCK="$TMP/held.lock"
mkdir "$HELD_LOCK"
START=$SECONDS
OUT="$(LOG_DECISION_FILE="$HELD_LOG" LOG_DECISION_LOCK_DIR="$HELD_LOCK" bash "$SCRIPT" "Builder|Sonnet|should still land" 2>&1)"
ELAPSED=$((SECONDS - START))
rmdir "$HELD_LOCK" 2>/dev/null || true
if grep -q 'should still land' "$HELD_LOG" 2>/dev/null; then
  pass "append still lands even when the lock was already held (proceeds unlocked after bounded wait)"
else
  fail "expected the decision to land even with a pre-held lock: $OUT"
fi
if [ "$ELAPSED" -ge 4 ]; then
  pass "waited close to the ~5s bound before proceeding unlocked"
else
  fail "expected to wait close to 5s for the held lock, only waited ${ELAPSED}s"
fi

echo "== issue #99: log-decision.sh resolves to the MAIN checkout's decisions.log, even run from a worktree =="
SCRATCH_ROOT="$(mktemp -d)"
SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd -P)"
MAIN_REPO="$SCRATCH_ROOT/main-repo"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config user.email "test@test.local"
git -C "$MAIN_REPO" config user.name "test"
# orchestrator.yaml is the project-root marker (issue #116); committed so
# `git worktree add` gives the worktree its own tracked copy too, which is
# what exercises the git-common-dir redirect below (a naive walk-up alone
# would stop at the worktree's own copy).
echo "project: scratch" > "$MAIN_REPO/orchestrator.yaml"
echo "x" > "$MAIN_REPO/file.txt"
git -C "$MAIN_REPO" add file.txt orchestrator.yaml
git -C "$MAIN_REPO" commit -q -m "init"
WT_REPO="$SCRATCH_ROOT/wt-issue-1"
git -C "$MAIN_REPO" worktree add -q -b feature/scratch "$WT_REPO" >/dev/null 2>&1
# No LOG_DECISION_FILE override here -- exercising the real default
# resolution (orchestrator.yaml discovery + worktree redirect), running
# the REAL production script from inside the WORKTREE.
(cd "$WT_REPO" && bash "$SCRIPT" "Builder|Sonnet|worktree-canonical test") >/dev/null 2>&1
if grep -q 'worktree-canonical test' "$MAIN_REPO/.harness/decisions.log" 2>/dev/null; then
  pass "decision logged from inside a worktree landed in the MAIN checkout's decisions.log"
else
  fail "expected the decision in the main checkout's decisions.log (#99 regression)"
fi
if [ ! -f "$WT_REPO/.harness/decisions.log" ]; then
  pass "the worktree's own decisions.log was never created (no split log)"
else
  fail "the worktree should NOT have its own decisions.log (#99 regression): $(cat "$WT_REPO/.harness/decisions.log")"
fi
rm -rf "$SCRATCH_ROOT"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
