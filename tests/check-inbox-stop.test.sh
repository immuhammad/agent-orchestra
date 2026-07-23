#!/bin/bash
# tests/check-inbox-stop.test.sh — issue #125: the Stop-hook inbox pickup
# that makes delivery to a BUSY agent deterministic at turn end (blocks
# going idle while unacked .msg files exist). Run: bash tests/check-inbox-stop.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
HOOK="$DIR/../hooks/check-inbox-stop.sh"
TMP="$(mktemp -d)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CANON="$TMP/harness"
mkdir -p "$CANON/inbox/builder" "$CANON/state"

# env-scrubbed runner: this suite may run inside a room pane whose own
# ORC_ROLE/ORC_ONESHOT would otherwise leak into the hook.
run_hook() { # $1 = role ('' = no ORC_ROLE at all), $2 = stdin json (default {})
  local role="${1-builder}" json="${2:-}"
  [ -z "$json" ] && json='{}'
  if [ -z "$role" ]; then
    echo "$json" | env -u ORC_ROLE -u ORC_ONESHOT CHECK_INBOX_CANON_DIR="$CANON" bash "$HOOK" 2>&1
  else
    echo "$json" | env -u ORC_ONESHOT ORC_ROLE="$role" CHECK_INBOX_CANON_DIR="$CANON" bash "$HOOK" 2>&1
  fi
}

echo "== empty inbox: stop allowed =="
OUT="$(run_hook builder)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "empty inbox -> exit 0, silent"
else
  fail "expected exit 0 silent for an empty inbox, got status=$STATUS: $OUT"
fi

echo "== unacked .msg: stop BLOCKED with a reason naming the file and the #121 rule =="
echo "do the thing" > "$CANON/inbox/builder/20260101000000-7.msg"
OUT="$(run_hook builder)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "20260101000000-7.msg" && echo "$OUT" | grep -q "assign IS the authorization"; then
  pass "unacked msg -> exit 2, reason lists the file and restates assign-is-authorization"
else
  fail "expected exit 2 naming the msg + the #121 rule, got status=$STATUS: $OUT"
fi

echo "== acked .msg: stop allowed again =="
echo "ACK: done" > "$CANON/inbox/builder/20260101000000-7.ack"
OUT="$(run_hook builder)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
  pass "acked msg -> exit 0, silent"
else
  fail "expected exit 0 once the msg is acked, got status=$STATUS: $OUT"
fi
rm -f "$CANON/inbox/builder/20260101000000-7.ack"

echo "== stop_hook_active=true: reminds once, never blocks forever =="
OUT="$(run_hook builder '{"stop_hook_active": "true"}')"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "stop_hook_active -> exit 0 (one reminder per stop cycle, no infinite block)"
else
  fail "expected exit 0 under stop_hook_active, got status=$STATUS: $OUT"
fi

echo "== ORC_ONESHOT=1: headless one-shots are exempt =="
OUT="$(echo '{}' | env ORC_ONESHOT=1 ORC_ROLE=builder CHECK_INBOX_CANON_DIR="$CANON" bash "$HOOK" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "ORC_ONESHOT=1 -> exit 0 despite the unacked msg"
else
  fail "expected exit 0 for a one-shot session, got status=$STATUS: $OUT"
fi

echo "== no ORC_ROLE: unknown sessions are never blocked =="
OUT="$(run_hook "")"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "no ORC_ROLE -> exit 0 (fail toward silence, like check-handoff's #50 rule)"
else
  fail "expected exit 0 with no ORC_ROLE, got status=$STATUS: $OUT"
fi

echo "== unrecognized role (scribe): never blocked =="
OUT="$(run_hook scribe)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "non-inbox role -> exit 0"
else
  fail "expected exit 0 for role=scribe, got status=$STATUS: $OUT"
fi

echo "== agy and reviewer roles: stop BLOCKED if inbox has unacked msg =="
mkdir -p "$CANON/inbox/agy" "$CANON/inbox/reviewer"
echo "do the thing" > "$CANON/inbox/agy/20260101000000-7.msg"
echo "do the thing" > "$CANON/inbox/reviewer/20260101000000-7.msg"
for test_role in agy reviewer; do
  OUT="$(run_hook "$test_role")"
  STATUS=$?
  if [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q "20260101000000-7.msg"; then
    pass "unacked msg for $test_role -> exit 2"
  else
    fail "expected exit 2 for $test_role, got status=$STATUS: $OUT"
  fi
done

echo "== quota-stop flag up: parked sessions are never forced through their inbox =="
echo '{"pool":"5h"}' > "$CANON/state/quota-stop"
OUT="$(run_hook builder)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "failsafe flag -> exit 0 (broker holds delivery until the park lifts)"
else
  fail "expected exit 0 while the quota-stop flag exists, got status=$STATUS: $OUT"
fi
rm -f "$CANON/state/quota-stop"

echo "== missing inbox dir for the role: no error, no block =="
OUT="$(run_hook orchestra)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "missing inbox dir -> exit 0"
else
  fail "expected exit 0 for a role with no inbox dir, got status=$STATUS: $OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
