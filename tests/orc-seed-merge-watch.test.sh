#!/bin/bash
# tests/orc-seed-merge-watch.test.sh — TDD tests for
# lib/orc-seed-merge-watch.sh: seeds
# merge-watch-state with every currently-merged PR number so a FRESH room
# starts caught-up instead of replaying comment+close on old issues and
# firing a stale "PR #N merged -- PICK next" nudge.
# Run: bash tests/orc-seed-merge-watch.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
SEED="$LIB/orc-seed-merge-watch.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Issue #174: orc_seed_merge_watch now refuses to seed at all when GH_REPO
# is unset (rather than seeding an empty-but-present state file, which
# would then read as "already seeded" forever via the idempotent guard
# above -- poisoning the room even after GH_REPO is fixed). All FOUR
# pre-existing tests below exercise the seeding behavior itself, not this
# gate, so they need a valid GH_REPO; the dedicated unset-GH_REPO test is
# appended at the end of this file.
export GH_REPO="test-owner/test-repo"

echo "== orc_seed_merge_watch: populates an ABSENT state file with every merged PR (mocked gh) =="
STATE="$TMP/merge-watch-state"
rm -f "$STATE"
(
  export MERGE_WATCH_STATE="$STATE"
  # source SEED (which sources watch.sh itself) BEFORE overriding
  # mw_fetch_merged_prs -- the opposite order re-sources watch.sh and
  # clobbers the mock back to the real gh-calling implementation.
  source "$SEED"
  mw_fetch_merged_prs() {
    printf '101\tt1\tb1\tfeature/issue-1\n102\tt2\tb2\tfeature/issue-2\n103\tt3\tb3\tfeature/issue-3\n'
  }
  orc_seed_merge_watch
)
if [ "$(sort "$STATE" 2>/dev/null | tr '\n' ' ')" = "101 102 103 " ]; then
  pass "seeded all 3 merged PR numbers into the state file"
else
  fail "expected 101 102 103, got: $(cat "$STATE" 2>/dev/null)"
fi

echo "== orc_seed_merge_watch: idempotent -- an EXISTING state file is never touched/reseeded =="
STATE2="$TMP/existing-state"
printf '999\n' > "$STATE2"
(
  export MERGE_WATCH_STATE="$STATE2"
  source "$SEED"
  mw_fetch_merged_prs() { printf '1\tt\tb\tfeature/issue-1\n'; }
  orc_seed_merge_watch
)
if [ "$(cat "$STATE2")" = "999" ]; then
  pass "existing state file left untouched, not reseeded"
else
  fail "existing state file should be untouched, got: $(cat "$STATE2")"
fi

echo "== orc_seed_merge_watch: non-fatal when gh is unavailable/erroring -- seeds an EMPTY state file instead of aborting the caller =="
STATE3="$TMP/no-gh-state"
rm -f "$STATE3"
(
  set +e
  export MERGE_WATCH_STATE="$STATE3"
  source "$SEED"
  mw_fetch_merged_prs() { return 1; }
  orc_seed_merge_watch
  exit 0
)
SUBSHELL_STATUS=$?
if [ "$SUBSHELL_STATUS" -eq 0 ]; then
  pass "a gh failure does not abort the caller (non-fatal)"
else
  fail "orc_seed_merge_watch should never abort its caller on a gh failure (subshell exit=$SUBSHELL_STATUS)"
fi
if [ -f "$STATE3" ] && [ ! -s "$STATE3" ]; then
  pass "gh failure/no PRs: seeded an EMPTY state file (recognized as already-seeded, not absent -- absent is what triggers the replay bug)"
else
  fail "expected an empty (but present) state file, got: $(ls -la "$STATE3" 2>&1)"
fi

echo "== orc_seed_merge_watch: uses a broad limit, not merge_watch_check's own 20-PR polling cap (EVERY currently-merged PR) =="
STATE4="$TMP/limit-state"
rm -f "$STATE4"
LIMIT_SEEN="$TMP/limit-seen"
(
  export MERGE_WATCH_STATE="$STATE4"
  source "$SEED"
  mw_fetch_merged_prs() { echo "$1" > "$LIMIT_SEEN"; printf '1\tt\tb\tfeature/issue-1\n'; }
  orc_seed_merge_watch
)
SEEN="$(cat "$LIMIT_SEEN" 2>/dev/null)"
if [ -n "$SEEN" ] && [ "$SEEN" -gt 20 ] 2>/dev/null; then
  pass "seed helper requests a limit greater than merge_watch_check's routine 20 (got $SEEN)"
else
  fail "expected a seed limit > 20, got: $SEEN"
fi

echo "== orc_seed_merge_watch: refuses to seed (creates NO state file) when GH_REPO is unset =="
STATE5="$TMP/unset-repo-state"
rm -f "$STATE5"
(
  unset GH_REPO
  export MERGE_WATCH_STATE="$STATE5"
  source "$SEED"
  mw_fetch_merged_prs() { echo 'SHOULD NOT BE CALLED'; printf '1\tt\tb\tfeature/issue-1\n'; }
  orc_seed_merge_watch
) 2> "$TMP/unset-repo.err"
if [ ! -e "$STATE5" ]; then
  pass "GH_REPO unset: no state file created at all (not even empty -- a later correctly-configured orc up can still seed for real)"
else
  fail "GH_REPO unset: expected no state file, got: $(ls -la "$STATE5" 2>&1)"
fi
grep -qi 'GH_REPO' "$TMP/unset-repo.err" && pass "GH_REPO unset: loud message explains why nothing was seeded" || fail "expected a GH_REPO-mentioning message on stderr, got: $(cat "$TMP/unset-repo.err")"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
