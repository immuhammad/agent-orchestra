#!/bin/bash
# tests/quota-stop-gate.test.sh — tests for issue #10's quota-stop
# PreToolUse gate: hooks/quota-stop-gate.sh (Claude Code dialect) and
# lib/guard-quota-stop-agy.sh (agy dialect), both built on the shared
# lib/quota-stop-lib.sh allow-list, plus lib/quota-stop-clear.sh's manual
# clear. Run: bash tests/quota-stop-gate.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$(cd "$DIR/../lib" && pwd)"
HOOKS="$(cd "$DIR/../hooks" && pwd)"
CLAUDE_GATE="$HOOKS/quota-stop-gate.sh"
AGY_GATE="$LIB/guard-quota-stop-agy.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
echo "project: test" > "$TMP/orchestrator.yaml"
FLAG="$TMP/.harness/state/quota-stop"

write_flag() { # $1=pool $2=pct $3=fallback
  mkdir -p "$(dirname "$FLAG")"
  jq -n --arg pool "$1" --arg pct "$2" --arg fallback "$3" \
    '{pool: $pool, pct: ($pct|tonumber), fallback: $fallback, resets_at_epoch: null, at: "2026-07-11T12:00:00Z"}' \
    > "$FLAG"
}

# run_claude_gate <tool_name> <json extra fields...>
run_claude_gate() { # $1 = full JSON payload
  local payload="$1"
  local out status
  out="$(cd "$TMP" && echo "$payload" | bash "$CLAUDE_GATE" 2>&1)"
  status=$?
  GATE_OUT="$out"
  GATE_STATUS="$status"
}

run_agy_gate() { # $1 = full JSON payload
  local payload="$1"
  local out status
  out="$(cd "$TMP" && echo "$payload" | bash "$AGY_GATE" 2>&1)"
  status=$?
  GATE_OUT="$out"
  GATE_STATUS="$status"
}

echo "== Claude Code dialect: no flag -> always allowed =="
rm -f "$FLAG"
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/whatever"}}'
if [ "$GATE_STATUS" -eq 0 ]; then
  pass "no flag: Bash tool call allowed through untouched"
else
  fail "no flag should always allow (got exit $GATE_STATUS): $GATE_OUT"
fi

echo "== Claude Code dialect: flag present blocks an ordinary Bash command =="
write_flag "5h" "85" "agy"
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
if [ "$GATE_STATUS" -eq 2 ]; then
  pass "flag present: ordinary Bash command blocked (exit 2)"
else
  fail "expected exit 2 with flag present, got $GATE_STATUS: $GATE_OUT"
fi
if echo "$GATE_OUT" | grep -qF "Quota 5h at 85%. Options: (a) switch to agy (b) throttle models (c) continue. Pick one."; then
  pass "blocked message contains the VERBATIM AGENTS.md failsafe question"
else
  fail "expected the verbatim failsafe question in stderr, got: $GATE_OUT"
fi

echo "== Claude Code dialect: allow-listed Write targets pass even while gated =="
run_claude_gate '{"tool_name":"Write","tool_input":{"file_path":".harness/handoff.md"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "Write to handoff.md allowed while gated" || fail "handoff.md write should be allowed while gated, got $GATE_STATUS"

run_claude_gate '{"tool_name":"Write","tool_input":{"file_path":".harness/decisions.log"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "Write to decisions.log allowed while gated" || fail "decisions.log write should be allowed while gated, got $GATE_STATUS"

run_claude_gate '{"tool_name":"Write","tool_input":{"file_path":".harness/inbox/orchestra/20260711-99.msg"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "Write to inbox .msg allowed while gated" || fail "inbox .msg write should be allowed while gated, got $GATE_STATUS"

run_claude_gate '{"tool_name":"Edit","tool_input":{"file_path":".harness/inbox/builder/20260711-99.ack"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "Edit of inbox .ack allowed while gated" || fail "inbox .ack edit should be allowed while gated, got $GATE_STATUS"

echo "== Claude Code dialect: a NON-allow-listed Write is still blocked while gated =="
run_claude_gate '{"tool_name":"Write","tool_input":{"file_path":"src/app.py"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "Write to an unrelated file blocked while gated" || fail "unrelated file write should be blocked while gated, got $GATE_STATUS"

echo "== Claude Code dialect: allow-listed Bash invocations pass even while gated =="
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/log-decision.sh \"role|model|decision\""}}'
[ "$GATE_STATUS" -eq 0 ] && pass "log-decision.sh invocation allowed while gated" || fail "log-decision.sh should be allowed while gated, got $GATE_STATUS"

run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash .harness/orc-exec.sh lib/dispatch.sh assign orchestra 11-10 DONE"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "dispatch.sh invocation (report-back) allowed while gated" || fail "dispatch.sh should be allowed while gated, got $GATE_STATUS"

run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/quota-stop-clear.sh \"Ahmad: continue\""}}'
[ "$GATE_STATUS" -eq 0 ] && pass "quota-stop-clear.sh invocation allowed while gated" || fail "quota-stop-clear.sh should be allowed while gated, got $GATE_STATUS"

echo "== Claude Code dialect: any other tool (e.g. Read) is blocked while gated =="
run_claude_gate '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "Read tool blocked while gated (deny-by-default, allow only the fixed list)" || fail "Read should be blocked while gated, got $GATE_STATUS"

echo "== regression (agy security review): a compound command cannot smuggle an unrelated command alongside an allow-listed one =="
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"rm -rf /Users/mac/important && bash lib/dispatch.sh assign orchestra x DONE"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "compound command (&&) with a smuggled rm -rf is blocked, not allowed through" || fail "SECURITY REGRESSION: compound command bypass allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/dispatch.sh assign orchestra x DONE; rm -rf /Users/mac/important"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "compound command (;) with a smuggled rm -rf is blocked, not allowed through" || fail "SECURITY REGRESSION: compound command bypass allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/dispatch.sh assign orchestra x \"$(rm -rf /Users/mac/important)\""}}'
[ "$GATE_STATUS" -eq 2 ] && pass "command substitution inside an otherwise-matching call is blocked" || fail "SECURITY REGRESSION: command substitution bypass allowed, got $GATE_STATUS: $GATE_OUT"

echo "== regression (agy security review): allow-listed script invocation with a pipe-delimited argument still works =="
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/log-decision.sh \"role|model|decision text\""}}'
[ "$GATE_STATUS" -eq 0 ] && pass "log-decision.sh's own pipe-delimited argument shape is NOT mistaken for a shell pipe" || fail "quote-aware split regressed: log-decision.sh with a pipe-delimited arg got blocked, $GATE_STATUS: $GATE_OUT"

echo "== regression (agy security review): the Write allow-list is anchored to the project's canon dir, not any matching basename =="
OUTSIDE="$(mktemp -d)"
run_claude_gate "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$OUTSIDE/handoff.md\"}}"
[ "$GATE_STATUS" -eq 2 ] && pass "a handoff.md OUTSIDE this project's canon dir is still blocked while gated" || fail "SECURITY REGRESSION: path allow-list not scoped to canon dir, got $GATE_STATUS: $GATE_OUT"
rm -f "$OUTSIDE/handoff.md" 2>/dev/null

echo "== Claude Code dialect: clearing the flag re-opens the gate =="
rm -f "$FLAG"
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "gate re-opened once the flag is cleared" || fail "gate should re-open once the flag is cleared, got $GATE_STATUS"

echo "== Claude Code dialect: unresolvable project root fails OPEN =="
NOROOT="$(mktemp -d)"
OUT="$(cd "$NOROOT" && echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | bash "$CLAUDE_GATE" 2>&1)"
STATUS=$?
rm -rf "$NOROOT"
[ "$STATUS" -eq 0 ] && pass "no orchestrator.yaml findable -> fails open (allow), not closed" || fail "expected fail-open (exit 0) with no resolvable project root, got $STATUS: $OUT"

echo "== agy dialect: no flag -> allow decision =="
rm -f "$FLAG"
run_agy_gate '{"toolCall":{"args":{"CommandLine":"rm -rf /tmp/whatever"}}}'
if [ "$GATE_STATUS" -eq 0 ] && echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: no flag -> {\"decision\":\"allow\"}"
else
  fail "agy: expected an allow decision with no flag, got: $GATE_OUT"
fi

echo "== agy dialect: flag present -> deny decision with the verbatim question =="
write_flag "weekly" "91" "none"
run_agy_gate '{"toolCall":{"args":{"CommandLine":"gh pr view 5"}}}'
DECISION="$(echo "$GATE_OUT" | jq -r '.decision // empty' 2>/dev/null)"
REASON="$(echo "$GATE_OUT" | jq -r '.reason // empty' 2>/dev/null)"
if [ "$DECISION" = "deny" ]; then
  pass "agy: flag present -> deny decision"
else
  fail "agy: expected a deny decision with flag present, got: $GATE_OUT"
fi
if echo "$REASON" | grep -qF "Quota weekly at 91%. Options: (a) switch to none (b) throttle models (c) continue. Pick one."; then
  pass "agy: deny reason contains the VERBATIM AGENTS.md failsafe question"
else
  fail "agy: expected the verbatim failsafe question in the deny reason, got: $REASON"
fi

echo "== agy dialect: allow-listed command passes even while gated =="
run_agy_gate '{"toolCall":{"args":{"CommandLine":"bash lib/dispatch.sh assign orchestra 11-10 DONE"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: dispatch.sh invocation allowed while gated"
else
  fail "agy: dispatch.sh should be allowed while gated, got: $GATE_OUT"
fi

echo "== lib/quota-stop-clear.sh: clears an active flag and logs it =="
write_flag "5h" "88" "agy"
AR_LOG_TMP="$(mktemp)"
( cd "$TMP" && AUTO_RESUME_QUOTA_STOP_FLAG="$FLAG" AUTO_RESUME_LOG="$AR_LOG_TMP" AUTO_RESUME_STATE_FILE="$(mktemp)" \
  bash "$LIB/quota-stop-clear.sh" "Ahmad: continue (c)" >/dev/null 2>&1 )
if [ ! -f "$FLAG" ]; then
  pass "quota-stop-clear.sh removed the flag file"
else
  fail "quota-stop-clear.sh should have removed the flag file"
fi
if grep -q "manually cleared: Ahmad: continue (c)" "$AR_LOG_TMP" 2>/dev/null; then
  pass "quota-stop-clear.sh logged the manual clear with its reason"
else
  fail "expected a 'manually cleared' log line, got: $(cat "$AR_LOG_TMP" 2>/dev/null)"
fi
rm -f "$AR_LOG_TMP"

echo "== lib/quota-stop-clear.sh: no-op (exit 1) when nothing is active =="
rm -f "$FLAG"
( cd "$TMP" && AUTO_RESUME_QUOTA_STOP_FLAG="$FLAG" AUTO_RESUME_STATE_FILE="$(mktemp)" \
  bash "$LIB/quota-stop-clear.sh" "no-op check" >/dev/null 2>/dev/null )
CLEAR_STATUS=$?
[ "$CLEAR_STATUS" -eq 1 ] && pass "quota-stop-clear.sh exits 1 when there's no flag to clear" || fail "expected exit 1 with no active flag, got $CLEAR_STATUS"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
