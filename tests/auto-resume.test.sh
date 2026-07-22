#!/bin/bash
# .harness/auto-resume.test.sh — tests for budgeted 5h-window
# rate-limit auto-resume. Run: bash .harness/auto-resume.test.sh
#
# Exercises auto-resume.sh directly against an isolated tmux test session
# (never the real "harness" session) with its state file pointed at a
# throwaway temp file, so nothing here touches real runtime state or a real
# agent pane.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
TEST_SESSION="harness-auto-resume-test"

export AUTO_RESUME_STATE_FILE
export AUTO_RESUME_LOG
export AUTO_RESUME_MAX_PER_DAY
export AUTO_RESUME_NOW_EPOCH
export AUTO_RESUME_QUOTA_STOP_FLAG
AUTO_RESUME_STATE_FILE="$(mktemp)"
AUTO_RESUME_LOG="$(mktemp)"
AUTO_RESUME_MAX_PER_DAY=2
AUTO_RESUME_QUOTA_STOP_FLAG="$(mktemp -u)"
rm -f "$AUTO_RESUME_STATE_FILE" # ar_ensure_state_file should recreate it
# issue #125: park detection/ownership read the hook-written pane state
# file -- point it at a throwaway dir, and skip the post-resume
# state-flip verification wait (no real hooks fire in a plain-sh pane).
PANE_STATE_DIR="$(mktemp -d)"
AUTO_RESUME_VERIFY_S=0
export PANE_STATE_DIR AUTO_RESUME_VERIFY_S

source "$LIB/auto-resume.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true
  rm -f "$AUTO_RESUME_STATE_FILE" "$AUTO_RESUME_LOG" "$AUTO_RESUME_QUOTA_STOP_FLAG"
  rm -rf "$PANE_STATE_DIR"
}
trap cleanup EXIT

# #11: every scenario below pins "now" via AUTO_RESUME_NOW_EPOCH instead of
# racing the real wall clock against fixed resets_at fixtures -- the whole
# point of this fix is that a resume decision is a real TIME comparison
# now, so the tests drive that clock explicitly rather than relying on
# opaque string equality the way the pre-fix tests could.
NOW0="$(ar_epoch_from_iso8601 "2026-07-11T12:00:00Z")"
if [ -z "$NOW0" ]; then
  echo "FATAL: ar_epoch_from_iso8601 could not parse a fixture date on this platform" >&2
  exit 1
fi
AUTO_RESUME_NOW_EPOCH="$NOW0"

tmux new-session -d -s "$TEST_SESSION" -n setup -x 200 -y 50 >/dev/null 2>&1

# Writes text directly to a pane's underlying tty device instead of
# `tmux send-keys`. `send-keys` simulates keystrokes delivered to the
# pane's shell, which has to actually be running and reading from its pty
# to receive them -- confirmed by hand to occasionally and unpredictably
# drop input outright in this sandbox regardless of how long you wait
# beforehand. Writing straight to the tty sidesteps the shell entirely
# (no keystrokes "typed", no command to parse/execute) and was 100%
# reliable across repeated trials where send-keys was not.
write_to_pane() { # $1 = pane, $2 = text
  local tty
  tty="$(tmux display-message -p -t "$1" '#{pane_tty}')"
  echo "$2" > "$tty"
}

new_test_pane() {
  # $RANDOM, not an incrementing counter: this function is always invoked
  # as `$(new_test_pane)`, which runs it in a SUBSHELL -- any variable it
  # assigns is thrown away when the subshell exits, so a shared counter
  # silently never advances and every call collides on the same name.
  local name="w${RANDOM}${RANDOM}"
  # Explicit `sh` rather than the default shell: the user's real shell
  # (zsh, with whatever prompt plugins are configured) can redraw its
  # prompt asynchronously -- a live clock or git-status segment, say --
  # which would change the pane's tail content between two polls with
  # nothing having actually "touched" the pane, corrupting the
  # fingerprint-based unchanged-since-parking check below. A plain `sh`
  # only redraws when something is actually written to it.
  tmux new-window -d -t "$TEST_SESSION" -n "$name" sh >/dev/null 2>&1
  echo "$TEST_SESSION:$name"
}

# issue #125: "parked" is a STATE-FILE fact now, not a screen fact. These
# helpers write the pane's hook-state file exactly the way
# hooks/pane-state.sh would (state + session_id) -- simulating the parked
# session's own hooks firing, which IS the park signal. write_to_pane
# (above) is kept for the passive-output test: proving the SCREEN is
# ignored requires actually dirtying the screen.
simulate_state() { # $1 = pane, $2 = state, $3 = session_id (default sid-park)
  local pid
  pid="$(tmux display-message -p -t "$1" '#{pane_id}')"
  pane_state_write "$pid" "$2" "${3:-sid-park}"
}
simulate_parked_pane() { # $1 = pane, $2 = session_id (default sid-park)
  simulate_state "$1" failsafe "${2:-sid-park}"
}
clear_pane_state() { # $1 = pane
  local pid
  pid="$(tmux display-message -p -t "$1" '#{pane_id}')"
  pane_state_clear "$pid"
}

echo "== simulated reset resumes once (park -> reset -> resume) =="
AUTO_RESUME_NOW_EPOCH="$NOW0"
PANE="$(new_test_pane)"
simulate_parked_pane "$PANE"
ar_mark_pending "$PANE"
if [ "$(ar_read --arg p "$PANE" '.panes[$p].state')" = "pending" ]; then
  pass "pane marked pending"
else
  fail "pane should be pending after ar_mark_pending"
fi

# Parks with resets_at 2h in the future of "now" (NOW0).
ar_poll_pane "$PANE" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE" '.panes[$p].state')" = "parked" ]; then
  pass "pane transitioned pending -> parked once the failsafe question was visible"
else
  fail "pane should be parked after seeing the failsafe question"
fi

# Same resets_at again, "now" unchanged -- no reset yet, should stay parked.
ar_poll_pane "$PANE" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE" '.panes[$p].state')" = "parked" ] && [ "$(ar_read '.budget.count')" = "0" ]; then
  pass "no reset yet -- stays parked, budget untouched"
else
  fail "should stay parked with budget untouched before now reaches the stored resets_at"
fi

# #11 regression case: the freshest poll's resets_at DRIFTS (a few minutes
# later than what was stored at parking) but real wall-clock time has NOT
# actually reached the STORED deadline yet. Pre-fix, this string difference
# alone would have been read as a rollover and resumed the pane mid-window
# -- the exact overnight incident this ticket exists to fix. Post-fix nothing
# happens: the stored resets_at (recorded at parking) is what's compared to
# "now", never the freshest poll's value.
ar_poll_pane "$PANE" "2026-07-11T14:05:00Z" "85"
if [ "$(ar_read --arg p "$PANE" '.panes[$p].state')" = "parked" ] && [ "$(ar_read '.budget.count')" = "0" ]; then
  pass "#11: a drifted (but not yet reached) resets_at does NOT trigger a resume"
else
  fail "#11 regression: drift alone triggered a resume before real time reached the stored deadline"
fi

# Time genuinely reaches the stored deadline, but usage is STILL high
# (belt-and-braces, #11). Must not resume, and must NOT drop tracking --
# next iteration should get another chance once usage actually drops.
AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T14:00:00Z")"
ar_poll_pane "$PANE" "2026-07-11T19:00:00Z" "72"
if [ "$(ar_read --arg p "$PANE" '.panes[$p].state')" = "parked" ] && [ "$(ar_read '.budget.count')" = "0" ]; then
  pass "#11 belt-and-braces: window time-reset but usage still >=50% -- no resume, tracking kept"
else
  fail "should stay parked (tracking kept) when usage is still high at the moment of a real time-reset"
fi
if grep -q "still 72% (>= 50% ceiling)" "$AUTO_RESUME_LOG"; then
  pass "belt-and-braces skip was logged with the observed usage%"
else
  fail "expected a 'still 72%' belt-and-braces log line, log was: $(cat "$AUTO_RESUME_LOG")"
fi

# Usage has now dropped -- same (already-reached) deadline, resumes.
ar_poll_pane "$PANE" "2026-07-11T19:00:00Z" "10"
if [ "$(ar_read --arg p "$PANE" '.panes[$p] // empty')" = "" ]; then
  pass "tracking cleared after the reset was handled"
else
  fail "pane tracking should be cleared once the reset cycle completes"
fi
if [ "$(ar_read '.budget.count')" = "1" ]; then
  pass "budget count incremented to 1 after the auto-resume"
else
  fail "budget count should be 1 after one auto-resume, got $(ar_read '.budget.count')"
fi
if tmux capture-pane -p -t "$PANE" 2>&1 | grep -q "auto-resuming"; then
  pass "resume message was actually sent into the pane"
else
  fail "expected an auto-resume message in the pane's scrollback"
fi

echo "== #80/#81/#86 (was T31/#68-E): resume path submits via the shared send_submit =="
# Claude Code's TUI drops an Enter that arrives in the same send-keys burst
# as the pasted text. The resume path submits through the shared
# send_submit helper (moved to send-lib.sh in issue #86 -- see
# send-lib.test.sh for send_submit's own retry-shape/wrap-confirm checks).
# Note: gatekeeper's alerts no longer call send_submit/notify() directly at
# all -- issue #105 replaced that with a durable dispatch.sh message to
# Orchestra (see gatekeeper.test.sh's Task 1/2 cases and
# gk_alert_orchestra in gatekeeper.sh).
if grep -q 'send_submit "\$pane" "Quota window reset' "$LIB/auto-resume.sh"; then
  pass "resume path submits via send_submit"
else
  fail "resume path should submit via send_submit, not a raw send-keys burst"
fi
if grep -q 'gk_alert_orchestra' "$LIB/gatekeeper.sh" && grep -q 'dispatch_main assign orchestra' "$LIB/gatekeeper.sh"; then
  pass "gatekeeper alerts route through dispatch_main assign orchestra (issue #105), not a direct pane keystroke"
else
  fail "gatekeeper should route alerts through gk_alert_orchestra/dispatch_main, not send_submit directly"
fi
if grep -q "resumed $PANE (1/2 today)" "$AUTO_RESUME_LOG"; then
  pass "resume was logged with the correct budget count"
else
  fail "expected a '1/2 today' log line, log was: $(cat "$AUTO_RESUME_LOG")"
fi

echo "== respects the daily budget (2/day cap) =="
AUTO_RESUME_NOW_EPOCH="$NOW0"
PANE2="$(new_test_pane)"
simulate_parked_pane "$PANE2"
ar_mark_pending "$PANE2"
ar_poll_pane "$PANE2" "2026-07-11T14:00:00Z" "85"
AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T18:00:00Z")"
ar_poll_pane "$PANE2" "2026-07-11T18:00:00Z" "10" # reset + low usage -> should be resume #2
if [ "$(ar_read '.budget.count')" = "2" ]; then
  pass "second auto-resume brought the count to 2 (at budget)"
else
  fail "expected budget count 2 after second resume, got $(ar_read '.budget.count')"
fi

AUTO_RESUME_NOW_EPOCH="$NOW0"
PANE3="$(new_test_pane)"
simulate_parked_pane "$PANE3"
ar_mark_pending "$PANE3"
ar_poll_pane "$PANE3" "2026-07-11T14:00:00Z" "85"
AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T19:00:00Z")"
ar_poll_pane "$PANE3" "2026-07-11T19:00:00Z" "10" # reset + low usage -> budget exhausted, should NOT resume
if tmux capture-pane -p -t "$PANE3" 2>&1 | grep -q "auto-resuming"; then
  fail "third pane should NOT have been auto-resumed -- budget was exhausted"
else
  pass "third pane correctly skipped -- daily budget (2) exhausted"
fi
if [ "$(ar_read '.budget.count')" = "2" ]; then
  pass "budget count stayed at 2, did not go over"
else
  fail "budget count should stay capped at 2, got $(ar_read '.budget.count')"
fi
if grep -q "budget (2) is exhausted -- not resuming" "$AUTO_RESUME_LOG"; then
  pass "budget-exhausted skip was logged"
else
  fail "expected a budget-exhausted log line"
fi

echo "== skips a manually-touched pane (amux: only unblock what you parked) =="
AUTO_RESUME_NOW_EPOCH="$NOW0"
PANE4="$(new_test_pane)"
simulate_parked_pane "$PANE4"
ar_mark_pending "$PANE4"
ar_poll_pane "$PANE4" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE4" '.panes[$p].state')" != "parked" ]; then
  fail "setup failed: pane4 should be parked before the touch test"
fi
# Simulate Ahmad (or anything else) taking the session over: its own
# hooks fire and the state moves off failsafe (issue #125: a "touch" is a
# state transition now, not a screen change).
simulate_state "$PANE4" busy
ar_poll_pane "$PANE4" "2026-07-11T14:00:00Z" "85" # no reset yet, but the pane changed
if [ "$(ar_read --arg p "$PANE4" '.panes[$p] // empty')" = "" ]; then
  pass "touched pane's tracking was dropped"
else
  fail "touched pane should have its tracking dropped immediately"
fi
if grep -q "not ours to resume anymore" "$AUTO_RESUME_LOG"; then
  pass "touched-pane skip was logged with the amux rationale"
else
  fail "expected a 'not ours to resume anymore' log line"
fi
if [ "$(ar_read '.budget.count')" = "2" ]; then
  pass "touched-pane skip did not consume any budget"
else
  fail "touched-pane skip must not spend budget, got count=$(ar_read '.budget.count')"
fi

echo "== #125 (supersedes #73/#80): parked pane + ARBITRARY passive screen output + window reset -> auto-continues =="
# The whole #73/#80 fingerprint saga existed because ownership was a
# screen property: passive output (gatekeeper alerts, watch nudges,
# counter repaints) landing in a parked pane changed the screen and
# dropped tracking. With state-file ownership the screen is simply not an
# input: dirty it as hard as you like -- as long as the pane's hooks
# still say failsafe with the same session_id, it is still ours.
AUTO_RESUME_NOW_EPOCH="$NOW0"
ar_write '.budget.count = 0' # isolate this section's budget assertions
PANE5="$(new_test_pane)"
simulate_parked_pane "$PANE5" "sid-5"
ar_mark_pending "$PANE5" "driver"
ar_poll_pane "$PANE5" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE5" '.panes[$p].state')" = "parked" ] && [ "$(ar_read --arg p "$PANE5" '.panes[$p].session_id')" = "sid-5" ]; then
  pass "#125: pane parks with the parking session_id recorded"
else
  fail "#125: pane should park with session_id in the tracking entry"
fi

# Dirty the screen aggressively -- alerts, nudges, even the literal old
# failsafe question text. None of it may matter.
write_to_pane "$PANE5" "# gatekeeper: FYI -- PR #200 opened, auto-merge armed"
sleep 0.3
write_to_pane "$PANE5" "# Quota 5h at 82%. Options: (a) switch to agy (b) throttle models (c) continue. Pick one."
sleep 0.3

ar_poll_pane "$PANE5" "2026-07-11T14:00:00Z" "85" # no reset yet
if [ "$(ar_read --arg p "$PANE5" '.panes[$p].state')" = "parked" ]; then
  pass "#125: pane stays parked through arbitrary passive screen output (state unchanged, screen ignored)"
else
  fail "#125 REGRESSION: passive screen output alone dropped tracking -- ownership is reading the screen again"
fi

AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T19:00:00Z")"
ar_poll_pane "$PANE5" "2026-07-11T19:00:00Z" "10" # window reset + low usage
if [ "$(ar_read --arg p "$PANE5" '.panes[$p] // empty')" = "" ]; then
  pass "#125: tracking cleared after the reset was handled"
else
  fail "#125 REGRESSION: pane never auto-continued -- tracking still present after a genuine reset"
fi
if tmux capture-pane -p -t "$PANE5" 2>&1 | grep -q "auto-resuming"; then
  pass "#125: pane received the auto-resume message despite the dirtied screen (the #73 live incident stays fixed)"
else
  fail "#125 REGRESSION (the #73 live incident): pane never got auto-continued after the window reset"
fi
if [ "$(ar_read '.budget.count')" = "1" ]; then
  pass "#125: auto-resume consumed budget normally"
else
  fail "#125: expected budget count 1 after the auto-resume, got $(ar_read '.budget.count')"
fi

echo "== #125: question ANSWERED (session's hooks flip failsafe -> busy) -> no injection, tracking dropped =="
AUTO_RESUME_NOW_EPOCH="$NOW0"
PANE6="$(new_test_pane)"
simulate_parked_pane "$PANE6" "sid-6"
ar_mark_pending "$PANE6" "driver"
ar_poll_pane "$PANE6" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE6" '.panes[$p].state')" != "parked" ]; then
  fail "#125 setup failed: pane6 should be parked before the answered-question test"
fi
# Ahmad answers: the session's own UserPromptSubmit hook fires and writes
# busy -- THAT is the moved-on signal, not any screen content.
simulate_state "$PANE6" busy "sid-6"
AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T19:00:00Z")"
ar_poll_pane "$PANE6" "2026-07-11T19:00:00Z" "10" # window reset + low usage, but the pane moved on
if [ "$(ar_read --arg p "$PANE6" '.panes[$p] // empty')" = "" ]; then
  pass "#125: answered pane's tracking was dropped"
else
  fail "#125: answered pane should have its tracking dropped, not left parked"
fi
if tmux capture-pane -p -t "$PANE6" 2>&1 | grep -q "auto-resuming"; then
  fail "#125 REGRESSION: auto-resume injected into a pane whose state had already moved past failsafe"
else
  pass "#125: no auto-resume injected once the pane's state moved past failsafe"
fi
if grep -q "not ours to resume anymore" "$AUTO_RESUME_LOG"; then
  pass "#125: answered-pane skip was logged with the amux rationale"
else
  fail "#125: expected a 'not ours to resume anymore' log line for the answered pane"
fi

echo "== #125: session RESTART while parked (same state, NEW session_id) -> ownership dropped, no injection =="
# A fresh session in the pane writes its own session_id (SessionStart
# hook; still failsafe if the quota flag is up). Same state, different
# identity -- the resume text would land in a session that never asked
# the question. Must drop, not inject.
AUTO_RESUME_NOW_EPOCH="$NOW0"
PANE7="$(new_test_pane)"
simulate_parked_pane "$PANE7" "sid-old"
ar_mark_pending "$PANE7" "worker"
ar_poll_pane "$PANE7" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE7" '.panes[$p].state')" = "parked" ] && [ "$(ar_read --arg p "$PANE7" '.panes[$p].role')" = "worker" ]; then
  pass "#125: pane parks (role field still recorded for logging/back-compat)"
else
  fail "#125: pane should park with role=worker recorded"
fi
simulate_parked_pane "$PANE7" "sid-new" # restarted session claims the pane
ar_poll_pane "$PANE7" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE7" '.panes[$p] // empty')" = "" ]; then
  pass "#125: a new session_id in the same pane drops ownership immediately"
else
  fail "#125 REGRESSION: ownership survived a session restart -- the resume would inject into a stranger session"
fi
if tmux capture-pane -p -t "$PANE7" 2>&1 | grep -q "auto-resuming"; then
  fail "#125 REGRESSION: auto-resume injected into a restarted (different) session"
else
  pass "#125: no injection into the restarted session"
fi

echo "== #73: window NOT reset -> no action regardless (driver) =="
AUTO_RESUME_NOW_EPOCH="$NOW0"
PANE8="$(new_test_pane)"
simulate_parked_pane "$PANE8"
ar_mark_pending "$PANE8" "driver"
ar_poll_pane "$PANE8" "2026-07-11T14:00:00Z" "85"
ar_poll_pane "$PANE8" "2026-07-11T14:00:00Z" "85" # unchanged resets_at, now still before it
if [ "$(ar_read --arg p "$PANE8" '.panes[$p].state')" = "parked" ]; then
  pass "#73: driver pane with no window reset yet stays parked, no action taken"
else
  fail "#73: driver pane should stay parked when the window has not actually reset"
fi
if tmux capture-pane -p -t "$PANE8" 2>&1 | grep -q "auto-resuming"; then
  fail "#73 REGRESSION: driver pane was auto-resumed despite no window reset"
else
  pass "#73: no premature auto-resume for the driver without a real window reset"
fi

echo "== #125: state file CLEARED while parked (pane died, liveness cleaned it) -> tracking dropped, no injection =="
# The crash path: the parked session's process dies, watch.sh's
# pane-liveness detects the dead pane and calls pane_state_clear. No
# state file = no ownership = drop -- never type into whatever is in
# that pane now.
AUTO_RESUME_NOW_EPOCH="$NOW0"
ar_write '.budget.count = 0' # isolate from budget exhaustion in earlier sections
PANE9="$(new_test_pane)"
simulate_parked_pane "$PANE9" "sid-9"
ar_mark_pending "$PANE9" "driver"
ar_poll_pane "$PANE9" "2026-07-11T14:00:00Z" "85"
if [ "$(ar_read --arg p "$PANE9" '.panes[$p].state')" != "parked" ]; then
  fail "#125 setup failed: pane9 should be parked before the cleared-state test"
fi
clear_pane_state "$PANE9"
AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T19:00:00Z")"
ar_poll_pane "$PANE9" "2026-07-11T19:00:00Z" "10" # window reset + low usage, but the state is gone
if [ "$(ar_read --arg p "$PANE9" '.panes[$p] // empty')" = "" ]; then
  pass "#125: cleared-state pane's tracking was dropped"
else
  fail "#125 REGRESSION: tracking survived a cleared state file (dead pane) -- the resume would fire blind"
fi
if tmux capture-pane -p -t "$PANE9" 2>&1 | grep -q "auto-resuming"; then
  fail "#125 REGRESSION: auto-resume injected into a pane with no state at all (post-crash)"
else
  pass "#125: no injection into a pane whose state was cleared (post-crash safety)"
fi

echo "== weekly (seven_day) never wires into auto-resume =="
GATEKEEPER="$LIB/gatekeeper.sh"
WEEKLY_BLOCK="$(sed -n '/Claude weekly (seven_day) over/,/^  fi/p' "$GATEKEEPER")"
if echo "$WEEKLY_BLOCK" | grep -q "ar_mark_pending"; then
  fail "the weekly (seven_day) alert block must NEVER call ar_mark_pending"
else
  pass "weekly alert block does not call ar_mark_pending"
fi
FIVE_HOUR_BLOCKS="$(sed -n '/Claude 5h over: fallback = agy/,/^    fi/p;/both exhausted/,/^  else/p' "$GATEKEEPER")"
if echo "$FIVE_HOUR_BLOCKS" | grep -q "ar_mark_pending"; then
  pass "the 5h alert paths do call ar_mark_pending (sanity check the wiring exists at all)"
else
  fail "expected ar_mark_pending to be wired into the 5h alert paths"
fi

echo "== #11: ar_epoch_from_iso8601 cross-platform parse =="
EPOCH_A="$(ar_epoch_from_iso8601 "2026-07-11T12:00:00Z")"
EPOCH_B="$(ar_epoch_from_iso8601 "2026-07-11T13:00:00Z")"
if [ -n "$EPOCH_A" ] && [ -n "$EPOCH_B" ] && [ "$((EPOCH_B - EPOCH_A))" = "3600" ]; then
  pass "ar_epoch_from_iso8601 parses ISO-8601 and one hour apart is exactly 3600s"
else
  fail "expected a clean 3600s delta between two ISO timestamps 1h apart, got A=$EPOCH_A B=$EPOCH_B"
fi
if [ -z "$(ar_epoch_from_iso8601 "not a date" 2>/dev/null)" ]; then
  pass "ar_epoch_from_iso8601 returns nothing (not a guess) for unparseable input"
else
  fail "ar_epoch_from_iso8601 should return empty for unparseable input, not guess"
fi

echo "== #32: ar_epoch_from_iso8601 parses the REAL usage-API shape (fractional seconds + numeric offset) =="
# The exact literal from the 4.5h dead-room outage (.harness/budget.log,
# 2026-07-12 19:53:53): BSD `date` on macOS can take neither GNU-style
# `date -d` NOR its own `-j -f "%Y-%m-%dT%H:%M:%SZ"` fallback here -- the
# fixture format string demands a literal "Z" and no fraction, but the
# real Claude usage API sends fractional seconds AND a numeric +00:00
# offset. Both call sites (ar_write_quota_stop_flag and ar_poll_pane's
# resume comparison) go through this ONE function -- there was never a
# second, working parse path; the parking-path log line that looked like
# a successful parse was just an unparsed echo of the raw string.
REAL_TS="2026-07-12T20:39:59.719039+00:00"
GOT_EPOCH="$(ar_epoch_from_iso8601 "$REAL_TS" 2>/dev/null)"
WANT_EPOCH="$(ar_epoch_from_iso8601 "2026-07-12T20:39:59Z")" # same instant, fraction/offset-free oracle
if [ -n "$GOT_EPOCH" ] && [ "$GOT_EPOCH" = "$WANT_EPOCH" ]; then
  pass "ar_epoch_from_iso8601 parses fractional-seconds + numeric-offset timestamps (the real outage literal)"
else
  fail "expected ar_epoch_from_iso8601('$REAL_TS') = $WANT_EPOCH, got '$GOT_EPOCH'"
fi
NEG_OFFSET_EPOCH="$(ar_epoch_from_iso8601 "2026-07-12T15:39:59.740925-05:00" 2>/dev/null)"
if [ -n "$NEG_OFFSET_EPOCH" ] && [ "$NEG_OFFSET_EPOCH" = "$WANT_EPOCH" ]; then
  pass "ar_epoch_from_iso8601 also handles a negative numeric offset (same instant, different zone)"
else
  fail "expected the -05:00 fixture to resolve to the same instant $WANT_EPOCH, got '$NEG_OFFSET_EPOCH'"
fi

echo "== #32: a genuinely null/absent resets_at still fails CLOSED to manual-clear =="
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"
: > "$AUTO_RESUME_LOG"
ar_write_quota_stop_flag "5h" "81" "agy" ""
if [ "$(jq -r '.resets_at_epoch' "$AUTO_RESUME_QUOTA_STOP_FLAG" 2>/dev/null)" = "null" ]; then
  pass "an absent resets_at still leaves resets_at_epoch null (correct fail-closed, manual clear required)"
else
  fail "an absent resets_at should leave resets_at_epoch null, got: $(cat "$AUTO_RESUME_QUOTA_STOP_FLAG")"
fi
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"

echo "== #32: ar_write_quota_stop_flag no longer logs a parse failure for the real outage literal =="
: > "$AUTO_RESUME_LOG"
ar_write_quota_stop_flag "5h" "81" "agy" "$REAL_TS"
if grep -q "could not parse resets_at" "$AUTO_RESUME_LOG"; then
  fail "ar_write_quota_stop_flag logged a parse failure for a real, valid usage-API timestamp: $(cat "$AUTO_RESUME_LOG")"
else
  pass "ar_write_quota_stop_flag did not log a parse failure for the real outage literal"
fi
if [ "$(jq -r '.resets_at_epoch' "$AUTO_RESUME_QUOTA_STOP_FLAG" 2>/dev/null)" = "$WANT_EPOCH" ]; then
  pass "flag's resets_at_epoch is correctly populated (non-null) from the real outage literal -- auto-clear is now live"
else
  fail "expected resets_at_epoch=$WANT_EPOCH in the flag, got: $(cat "$AUTO_RESUME_QUOTA_STOP_FLAG" 2>/dev/null || echo MISSING)"
fi
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"

echo "== #10: quota-stop flag write/clear (the #11<->#10 seam) =="
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"
ar_write_quota_stop_flag "5h" "85" "agy" "2026-07-11T14:00:00Z"
if [ -f "$AUTO_RESUME_QUOTA_STOP_FLAG" ]; then
  pass "ar_write_quota_stop_flag created the flag file"
else
  fail "ar_write_quota_stop_flag did not create the flag file"
fi
if [ "$(jq -r '.pool' "$AUTO_RESUME_QUOTA_STOP_FLAG")" = "5h" ] \
  && [ "$(jq -r '.pct' "$AUTO_RESUME_QUOTA_STOP_FLAG")" = "85" ] \
  && [ "$(jq -r '.fallback' "$AUTO_RESUME_QUOTA_STOP_FLAG")" = "agy" ]; then
  pass "flag content carries pool/pct/fallback"
else
  fail "flag content missing expected fields: $(cat "$AUTO_RESUME_QUOTA_STOP_FLAG")"
fi

AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T13:00:00Z")" # before the 5h flag's resets_at
ar_clear_quota_stop_flag_if_reset
if [ -f "$AUTO_RESUME_QUOTA_STOP_FLAG" ]; then
  pass "flag NOT cleared before the real window reset time is reached"
else
  fail "flag was cleared too early (before resets_at)"
fi

AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T14:00:00Z")" # exactly at the 5h flag's resets_at
ar_clear_quota_stop_flag_if_reset
if [ ! -f "$AUTO_RESUME_QUOTA_STOP_FLAG" ]; then
  pass "flag auto-cleared once now reached the stored resets_at (5h pool)"
else
  fail "flag should have auto-cleared at the real window reset"
fi
if grep -q "quota-stop flag cleared -- window reset (pool=5h)" "$AUTO_RESUME_LOG"; then
  pass "flag clear was logged"
else
  fail "expected a 'quota-stop flag cleared' log line"
fi

echo "== #10: weekly/both flags do NOT auto-clear (require the manual clear path) =="
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"
ar_write_quota_stop_flag "weekly" "90" "none"
AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2099-01-01T00:00:00Z")" # far future -- would clear a 5h-style flag
ar_clear_quota_stop_flag_if_reset
if [ -f "$AUTO_RESUME_QUOTA_STOP_FLAG" ]; then
  pass "weekly-pool flag never auto-clears, even far in the future (matches 'weekly always stops for Ahmad')"
else
  fail "weekly-pool flag should require the manual clear path, not auto-clear"
fi
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"
ar_write_quota_stop_flag "both" "95" "none"
ar_clear_quota_stop_flag_if_reset
if [ -f "$AUTO_RESUME_QUOTA_STOP_FLAG" ]; then
  pass "a 'both' flag with NO resets_at at all (e.g. the usage API fetch failed) never auto-clears, stays fully manual"
else
  fail "a 'both' flag with no resets_at should require the manual clear path, not auto-clear"
fi
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"

echo "== #10-rework finding 5: 'both' flag WITH a 5h resets_at downgrades to 'weekly' on reset, not permanently stuck =="
# The original bug: gatekeeper.sh wrote the "both" flag with NO resets_at
# at all, so even once the 5h window genuinely reset and Claude quota
# came back, ar_clear_quota_stop_flag_if_reset had nothing to compare
# against and the flag (and the whole PreToolUse gate) stayed stuck
# forever -- breaking unattended recovery. gatekeeper.sh now passes the
# 5h resets_at for "both" too; this exercises the clear function directly
# (auto-resume.sh's own responsibility) with that resets_at.
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"
ar_write_quota_stop_flag "both" "95" "none" "2026-07-11T14:00:00Z"
AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T13:00:00Z")" # before the 5h reset
ar_clear_quota_stop_flag_if_reset "12"
if [ "$(jq -r '.pool' "$AUTO_RESUME_QUOTA_STOP_FLAG" 2>/dev/null)" = "both" ]; then
  pass "still 'both' before the 5h window has actually reset"
else
  fail "should still be 'both' before the 5h reset time is reached"
fi

AUTO_RESUME_NOW_EPOCH="$(ar_epoch_from_iso8601 "2026-07-11T14:00:00Z")" # exactly at the 5h reset
ar_clear_quota_stop_flag_if_reset "12"
if [ ! -f "$AUTO_RESUME_QUOTA_STOP_FLAG" ]; then
  fail "SECURITY/RECOVERY REGRESSION (finding 5): 'both' flag vanished entirely on 5h reset -- agy may still be exhausted, should downgrade to weekly, not fully clear"
elif [ "$(jq -r '.pool' "$AUTO_RESUME_QUOTA_STOP_FLAG")" = "weekly" ]; then
  pass "'both' downgraded to 'weekly' once the 5h window genuinely reset (agy's own pool still unverifiable, so it doesn't fully clear)"
else
  fail "expected pool=weekly after the downgrade, got: $(cat "$AUTO_RESUME_QUOTA_STOP_FLAG")"
fi
if [ "$(jq -r '.pct' "$AUTO_RESUME_QUOTA_STOP_FLAG" 2>/dev/null)" = "12" ]; then
  pass "downgraded flag shows the CURRENT weekly% passed in, not the stale 5h% the 'both' flag was written with"
else
  fail "expected pct=12 (current weekly%) in the downgraded flag, got: $(cat "$AUTO_RESUME_QUOTA_STOP_FLAG")"
fi
if grep -q "downgraded both -> weekly" "$AUTO_RESUME_LOG"; then
  pass "downgrade was logged"
else
  fail "expected a 'downgraded both -> weekly' log line"
fi
# The downgraded weekly flag must now behave exactly like any other
# weekly flag: no resets_at_epoch, never auto-clears on its own.
ar_clear_quota_stop_flag_if_reset "12"
if [ -f "$AUTO_RESUME_QUOTA_STOP_FLAG" ] && [ "$(jq -r '.pool' "$AUTO_RESUME_QUOTA_STOP_FLAG")" = "weekly" ]; then
  pass "the downgraded weekly flag itself does not auto-clear -- still requires the manual clear path"
else
  fail "the downgraded weekly flag should persist (manual-clear-only), got: $(cat "$AUTO_RESUME_QUOTA_STOP_FLAG" 2>/dev/null || echo MISSING)"
fi
rm -f "$AUTO_RESUME_QUOTA_STOP_FLAG"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
