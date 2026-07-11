#!/bin/bash
# .harness/inbox-poll.test.sh — tests for inbox-poll.sh, incl. T30 (issue
# #56) suspect-empty-ack detection. Run: bash .harness/inbox-poll.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
POLL="$DIR/../lib/inbox-poll.sh"
TESTBOX="$DIR/inbox/testpollagent"
# issue #116: inbox-poll.sh resolves its inbox root via
# INBOX_POLL_CANON_DIR (or orchestrator.yaml discovery) now, not its own
# script directory -- pin it at $DIR so TESTBOX above is where it actually
# looks.
export INBOX_POLL_CANON_DIR="$DIR"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$TESTBOX"; }
trap cleanup EXIT
cleanup
mkdir -p "$TESTBOX"

echo "== no inbox for agent =="
OUT="$(bash "$POLL" nosuchagent 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 1 ] && echo "$OUT" | grep -q "no inbox"; then
  pass "unknown agent inbox reported cleanly"
else
  fail "unknown agent should fail with 'no inbox' (status=$STATUS): $OUT"
fi

echo "== all messages fully (non-empty) acked -- no pending, no suspect =="
echo "hi" > "$TESTBOX/1-1.msg"
echo "APPROVE" > "$TESTBOX/1-1.ack"
OUT="$(bash "$POLL" testpollagent 2>&1)"
if echo "$OUT" | grep -q "no pending messages"; then
  pass "fully-acked inbox reports no pending messages"
else
  fail "fully-acked inbox should report no pending messages: $OUT"
fi
rm -f "$TESTBOX"/*.msg "$TESTBOX"/*.ack

echo "== un-acked message is PENDING =="
echo "hi" > "$TESTBOX/2-2.msg"
OUT="$(bash "$POLL" testpollagent 2>&1)"
if echo "$OUT" | grep -q "^PENDING: .*2-2.msg"; then
  pass "un-acked message reported as PENDING"
else
  fail "un-acked message should be reported PENDING: $OUT"
fi
rm -f "$TESTBOX"/*.msg "$TESTBOX"/*.ack

echo "== T30 (#56): 0-byte ack is flagged SUSPECT, not treated as a real ack =="
echo "hi" > "$TESTBOX/3-3.msg"
: > "$TESTBOX/3-3.ack"
OUT="$(bash "$POLL" testpollagent 2>&1)"
if echo "$OUT" | grep -q "^SUSPECT (empty ack): .*3-3.msg"; then
  pass "0-byte ack reported as SUSPECT"
else
  fail "0-byte ack should be reported SUSPECT: $OUT"
fi
if echo "$OUT" | grep -qi "no pending messages"; then
  fail "SUSPECT-ack case should not also print the all-clear 'no pending messages' line: $OUT"
else
  pass "SUSPECT-ack case correctly skips the all-clear message"
fi
rm -f "$TESTBOX"/*.msg "$TESTBOX"/*.ack

echo "== T30 (#56): whitespace-only ack (bare newline) is also flagged SUSPECT =="
echo "hi" > "$TESTBOX/4-4.msg"
printf '\n' > "$TESTBOX/4-4.ack"
OUT="$(bash "$POLL" testpollagent 2>&1)"
if echo "$OUT" | grep -q "^SUSPECT (empty ack): .*4-4.msg"; then
  pass "whitespace-only ack reported as SUSPECT"
else
  fail "whitespace-only ack should be reported SUSPECT: $OUT"
fi
rm -f "$TESTBOX"/*.msg "$TESTBOX"/*.ack

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
