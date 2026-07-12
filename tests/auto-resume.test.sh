#!/bin/bash
# .harness/auto-resume.test.sh — tests for T20 (budgeted 5h-window
# rate-limit auto-resume). Run: bash .harness/auto-resume.test.sh
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

source "$LIB/auto-resume.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
  tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true
  rm -f "$AUTO_RESUME_STATE_FILE" "$AUTO_RESUME_LOG" "$AUTO_RESUME_QUOTA_STOP_FLAG"
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

# Injects the EXACT AGENTS.md Quota Failsafe wording into a pane's
# scrollback, simulating a Claude session that received gatekeeper's nudge
# and (per AGENTS.md) responded with the fixed failsafe question. Verifies
# and retries a couple of times rather than trusting a single fixed sleep.
simulate_parked_pane() { # $1 = pane
  local attempt waited
  for attempt in 1 2 3; do
    write_to_pane "$1" "Quota 5h at 82%. Options: (a) switch to agy (b) throttle models (c) continue. Pick one."
    waited=0
    while [ "$waited" -lt 5 ]; do
      if tmux capture-pane -p -t "$1" 2>/dev/null | grep -qF "Pick one."; then
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
  done
  return 1
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
# Simulate Ahmad (or anything else) touching the pane after it parked.
write_to_pane "$PANE4" "Ahmad: (c) continue"
sleep 0.5
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

echo "== #80: a benign in-place repaint (counter/timer) normalizes identically =="
# Unit-test the normalization directly (a plain `sh` test pane can't simulate
# an in-place TUI repaint -- it would execute the text as a command). This is
# the exact mechanism that stops a still-blocked parked pane from being dropped
# before it can auto-resume.
Q='Quota 5h at 82%. Options: (a) switch to agy (b) throttle models (c) continue. Pick one.'
FP_BEFORE="$(printf '%s\nctx:40%% | 120 tokens | 0:03 esc to interrupt\n' "$Q" | ar_normalize | shasum -a 256 | awk '{print $1}')"
FP_AFTER="$(printf '%s\nctx:57%% | 356 tokens | 1:12 esc to interrupt\n' "$Q" | ar_normalize | shasum -a 256 | awk '{print $1}')"
if [ "$FP_BEFORE" = "$FP_AFTER" ]; then
  pass "counter/timer repaint hashes identically -- parked pane won't be dropped (#80)"
else
  fail "benign repaint changed the normalized fingerprint (#80 regression)"
fi
FP_ANSWERED="$(printf '%s\nAhmad: (c) continue\n' "$Q" | ar_normalize | shasum -a 256 | awk '{print $1}')"
if [ "$FP_ANSWERED" != "$FP_BEFORE" ]; then
  pass "a real human answer still changes the fingerprint -- touched pane still drops"
else
  fail "human answer should change the normalized fingerprint (#80 over-corrected)"
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
