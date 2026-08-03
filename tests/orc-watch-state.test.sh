#!/bin/bash
# tests/orc-watch-state.test.sh -- issue #171 Gate-1 item 7: watcher-state
# reset + identity tracking. `orc init` (every mode -- core/--force/
# --adopt) records the room's current identity (github_repo, falling back
# to project) at .harness/state/watch-repo, seeded on first init with no
# reset (nothing to reset from), and clears the four watcher-state paths
# (merge-watch-state, review-watch-state, events.log, state/last-issue/)
# ONLY when a PRIOR recorded identity exists and genuinely differs from
# the current one -- a routine resync of an otherwise-unchanged room must
# never blow away live watcher state. `orc up` (orc_build_session) does
# NOT reset anything itself -- it only WARNS (non-fatal) when the
# recorded identity mismatches, since resetting live state from a room
# that might already have panes running would be actively dangerous.
# Run: bash tests/orc-watch-state.test.sh
set -uo pipefail
# issue #189: orc init now finishes with orc-protect on by default --
# opt out here so a chflags/chattr-immutable fixture doesn't break this
# file's own scratch-dir teardown.
export ORC_INIT_NO_PROTECT=1

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORC="$DIR/../bin/orc"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; for s in $(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^orctest-watchstate-" || true); do tmux kill-session -t "$s" 2>/dev/null || true; done' EXIT

write_answers() { # $1 = path, stdin = KEY=value lines
  cat > "$1"
}

full_answers() { # $1 = path $2 = project $3 = github_repo (optional)
  write_answers "$1" <<EOF
PROJECT=$2
INTEGRATION_BRANCH=main
GITHUB_REPO=${3:-}
TICKET_TRACKER=gh-issues
ROLE_ORCHESTRA_MODEL=opus
ROLE_ORCHESTRA_EFFORT=high
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_IMPLEMENTER_EFFORT=default
ROLE_TESTER_MODEL=sonnet
ROLE_TESTER_EFFORT=default
ROLE_REVIEWER_MODEL=agy
ROLE_REVIEWER_EFFORT=high
ROLE_SCRIBE_MODEL=haiku
ROLE_SCRIBE_EFFORT=low
BUDGET_CLAUDE_PCT=80
BUDGET_AGY_PCT=80
EOF
}

seed_watcher_state() { # $1 = room dir -- populates all 4 watcher-state paths with sentinel content
  mkdir -p "$1/.harness/state/last-issue"
  echo "sentinel-merge" > "$1/.harness/merge-watch-state"
  echo "sentinel-review" > "$1/.harness/review-watch-state"
  echo "sentinel-events" > "$1/.harness/events.log"
  echo "sentinel-issue" > "$1/.harness/state/last-issue/42"
}

watcher_state_all_present() { # $1 = room dir
  [ -f "$1/.harness/merge-watch-state" ] && [ -f "$1/.harness/review-watch-state" ] \
    && [ -f "$1/.harness/events.log" ] && [ -f "$1/.harness/state/last-issue/42" ]
}

watcher_state_all_gone() { # $1 = room dir
  [ ! -e "$1/.harness/merge-watch-state" ] && [ ! -e "$1/.harness/review-watch-state" ] \
    && [ ! -e "$1/.harness/events.log" ] && [ ! -e "$1/.harness/state/last-issue" ]
}

echo "== first-ever init writes state/watch-repo, nothing existed to reset =="
ANSWERS1="$TMP/answers1.txt"
full_answers "$ANSWERS1" "watch-project-1" "owner1/repo1"
ROOM1="$TMP/room1"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM1" >/dev/null 2>&1
if [ -f "$ROOM1/.harness/state/watch-repo" ]; then
  pass "fresh init writes .harness/state/watch-repo"
else
  fail "fresh init should have written .harness/state/watch-repo"
fi
WATCH1="$(cat "$ROOM1/.harness/state/watch-repo" 2>/dev/null)"
if [ "$WATCH1" = "owner1/repo1" ]; then
  pass "state/watch-repo records github_repo (preferred over project)"
else
  fail "expected state/watch-repo=owner1/repo1, got: $WATCH1"
fi

echo "== a second run with the SAME identity (bare --force) leaves watcher-state files untouched =="
seed_watcher_state "$ROOM1"
BEFORE_MTIME="$(cat "$ROOM1/.harness/merge-watch-state")"
bash "$ORC" init --force "$ROOM1" >/dev/null 2>&1
if watcher_state_all_present "$ROOM1"; then
  pass "bare --force with unchanged identity leaves all 4 watcher-state paths present"
else
  fail "bare --force with unchanged identity should NOT have touched watcher-state paths"
fi
AFTER_CONTENT="$(cat "$ROOM1/.harness/merge-watch-state" 2>/dev/null)"
if [ "$AFTER_CONTENT" = "sentinel-merge" ]; then
  pass "merge-watch-state content is byte-identical after an unchanged-identity resync"
else
  fail "merge-watch-state content changed after an unchanged-identity resync: $AFTER_CONTENT"
fi

echo "== a second run where the recorded identity genuinely CHANGED clears all 4 watcher-state paths =="
ROOM2="$TMP/room2"
ANSWERS2="$TMP/answers2.txt"
full_answers "$ANSWERS2" "watch-project-2" "owner2/repo2"
bash "$ORC" init --answers "$ANSWERS2" "$ROOM2" >/dev/null 2>&1
seed_watcher_state "$ROOM2"
# Simulate a stale recorded identity from a DIFFERENT project -- as if
# this same directory had previously been adopted for something else.
echo "owner2/repo2-STALE" > "$ROOM2/.harness/state/watch-repo"
OUT2="$(bash "$ORC" init --force "$ROOM2" 2>&1)"
if watcher_state_all_gone "$ROOM2"; then
  pass "identity change clears all 4 watcher-state paths (merge-watch-state, review-watch-state, events.log, state/last-issue/)"
else
  fail "identity change should have cleared all 4 watcher-state paths: $(ls -la "$ROOM2/.harness" 2>&1)"
fi
if [ "$(cat "$ROOM2/.harness/state/watch-repo" 2>/dev/null)" = "owner2/repo2" ]; then
  pass "state/watch-repo is updated to the new current identity"
else
  fail "state/watch-repo should now read owner2/repo2, got: $(cat "$ROOM2/.harness/state/watch-repo" 2>/dev/null)"
fi
echo "$OUT2" | grep -qi "resetting watcher state" && pass "identity-change reset is announced loudly" || fail "expected a loud announcement of the watcher-state reset, got: $OUT2"

echo "== orc_build_session: WARNING fires when state/watch-repo mismatches current identity =="
WARN_SESSION="orctest-watchstate-warn-$$"
WARN_TMP="$TMP/warnroom"
mkdir -p "$WARN_TMP/.harness/state"
(
  cd "$WARN_TMP"
  cat > orchestrator.yaml <<'EOF'
project: warn-project
github_repo: warnowner/warnrepo
EOF
  echo "stale-identity/from-elsewhere" > .harness/state/watch-repo
  ORC_SESSION="$WARN_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
)
if grep -qi "WARNING.*watcher-state identity\|WARNING.*watch-repo\|WARNING -- recorded watcher-state" "$WARN_TMP/build.err" 2>/dev/null; then
  pass "orc_build_session warns loudly when state/watch-repo mismatches current identity"
else
  fail "expected a WARNING about mismatched watcher-state identity: $(cat "$WARN_TMP/build.err" 2>/dev/null)"
fi
tmux kill-session -t "$WARN_SESSION" 2>/dev/null || true

echo "== orc_build_session: no WARNING when state/watch-repo matches current identity =="
MATCH_SESSION="orctest-watchstate-match-$$"
MATCH_TMP="$TMP/matchroom"
mkdir -p "$MATCH_TMP/.harness/state"
(
  cd "$MATCH_TMP"
  cat > orchestrator.yaml <<'EOF'
project: match-project
github_repo: matchowner/matchrepo
EOF
  echo "matchowner/matchrepo" > .harness/state/watch-repo
  ORC_SESSION="$MATCH_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
)
if grep -qi "watcher-state identity\|watch-repo" "$MATCH_TMP/build.err" 2>/dev/null; then
  fail "no watcher-state warning expected when identity matches: $(cat "$MATCH_TMP/build.err" 2>/dev/null)"
else
  pass "no watcher-state warning when state/watch-repo matches current identity"
fi
tmux kill-session -t "$MATCH_SESSION" 2>/dev/null || true

echo "== orc_build_session: no WARNING when state/watch-repo does not exist yet (pre-#171 room, or never inited) =="
NOFILE_SESSION="orctest-watchstate-nofile-$$"
NOFILE_TMP="$TMP/nofileroom"
mkdir -p "$NOFILE_TMP"
(
  cd "$NOFILE_TMP"
  cat > orchestrator.yaml <<'EOF'
project: nofile-project
github_repo: nofileowner/nofilerepo
EOF
  ORC_SESSION="$NOFILE_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
)
if grep -qi "watcher-state identity\|watch-repo" "$NOFILE_TMP/build.err" 2>/dev/null; then
  fail "no watcher-state warning expected when state/watch-repo doesn't exist: $(cat "$NOFILE_TMP/build.err" 2>/dev/null)"
else
  pass "no watcher-state warning when state/watch-repo does not exist yet"
fi
tmux kill-session -t "$NOFILE_SESSION" 2>/dev/null || true

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
