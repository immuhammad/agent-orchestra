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

run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/dispatch.sh assign orchestra 11-10 DONE"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "dispatch.sh invocation (report-back), a DIRECT local invocation, allowed while gated" || fail "dispatch.sh should be allowed while gated, got $GATE_STATUS"

echo "== issue #18 B1: the orc-exec.sh trampoline is gone -- a trampoline-prefixed invocation is no longer specially unwrapped =="
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash .harness/orc-exec.sh lib/dispatch.sh assign orchestra 11-10 DONE"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "an orc-exec.sh-prefixed invocation is blocked -- the allow-list matches DIRECT invocations only, no trampoline unwrapping" || fail "expected the dead trampoline prefix to no longer bypass the allow-list, got $GATE_STATUS: $GATE_OUT"

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

echo "== regression (agy PR#17 rework, finding 1): a redirection cannot smuggle a write to an arbitrary file =="
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/dispatch.sh assign orchestra x DONE > /tmp/quota-stop-gate-poc-redirect"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "an allow-listed call with a trailing > redirection is blocked, not allowed through" || fail "SECURITY REGRESSION (finding 1): redirection bypass allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/dispatch.sh assign orchestra x DONE 2>> /tmp/quota-stop-gate-poc-redirect2"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "an fd-prefixed redirection (2>>) is also blocked" || fail "SECURITY REGRESSION (finding 1): fd-prefixed redirection bypass allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"bash lib/dispatch.sh assign orchestra x \"message with < and > as literal text\""}}'
[ "$GATE_STATUS" -eq 0 ] && pass "a QUOTED literal < or > inside an argument is not mistaken for a redirection" || fail "over-strict: quoted </> inside an argument got blocked, $GATE_STATUS: $GATE_OUT"

echo "== regression (agy PR#17 rework, finding 2): the path allow-list survives a .. traversal attempt, not just a bare cross-project path =="
run_claude_gate '{"tool_name":"Write","tool_input":{"file_path":".harness/inbox/builder/../../../../etc/quota-stop-gate-poc-traversal.msg"}}'
[ "$GATE_STATUS" -eq 2 ] && pass "a Write with a .. traversal that string-glob-matches the inbox pattern is still blocked" || fail "SECURITY REGRESSION (finding 2): path traversal bypass allowed, got $GATE_STATUS: $GATE_OUT"

run_claude_gate '{"tool_name":"Write","tool_input":{"file_path":".harness/inbox/builder/./20260711-99.msg"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "a harmless ./ in an otherwise-legitimate inbox path is still allowed (normalization doesn't over-block)" || fail "over-strict: a harmless ./ segment got blocked, $GATE_STATUS: $GATE_OUT"

echo "== Claude Code dialect: clearing the flag re-opens the gate =="
rm -f "$FLAG"
run_claude_gate '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
[ "$GATE_STATUS" -eq 0 ] && pass "gate re-opened once the flag is cleared" || fail "gate should re-open once the flag is cleared, got $GATE_STATUS"

echo "== regression (agy PR#17 rework, finding 3): unresolvable project root fails CLOSED, not open =="
NOROOT="$(mktemp -d)"
OUT="$(cd "$NOROOT" && env -u CLAUDE_PROJECT_DIR bash -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}" | bash "'"$CLAUDE_GATE"'"' 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] && pass "no orchestrator.yaml findable and no CLAUDE_PROJECT_DIR -> fails CLOSED (blocked)" || fail "SECURITY REGRESSION (finding 3): expected fail-closed (exit 2) with no resolvable project root, got $STATUS: $OUT"
echo "$OUT" | grep -qi "failing closed" && pass "fail-closed message is diagnosable (says why), not a silent brick" || fail "expected a diagnosable 'failing closed' message, got: $OUT"

echo "== regression (agy PR#17 rework, finding 3): CLAUDE_PROJECT_DIR anchor resolves even when \$PWD has nothing discoverable =="
OUT="$(cd "$NOROOT" && env CLAUDE_PROJECT_DIR="$TMP" bash -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}" | bash "'"$CLAUDE_GATE"'"' 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] && pass "CLAUDE_PROJECT_DIR anchor lets resolution succeed from an unrelated cwd (no flag active there, so allowed)" || fail "CLAUDE_PROJECT_DIR anchor should have resolved successfully, got $STATUS: $OUT"
rm -rf "$NOROOT"

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

echo "== regression (agy PR#17 rework, finding 3): agy dialect also fails CLOSED on an unresolvable root =="
NOROOT2="$(mktemp -d)"
OUT="$(cd "$NOROOT2" && env -u CLAUDE_PROJECT_DIR bash -c 'echo "{\"toolCall\":{\"args\":{\"CommandLine\":\"ls -la\"}}}" | bash "'"$AGY_GATE"'"' 2>&1)"
rm -rf "$NOROOT2"
DECISION="$(echo "$OUT" | jq -r '.decision // empty' 2>/dev/null)"
[ "$DECISION" = "deny" ] && pass "agy: unresolvable root -> deny decision (fails closed), not allow" || fail "SECURITY REGRESSION (finding 3, agy): expected a deny decision, got: $OUT"

echo "== finding-4 (PR#17 flag 4), CONFIRMED live 2026-07-12: agy's real write-tool payload shape (name=write_to_file, args.TargetFile) is allow-listed for handoff.md =="
# The exact live-captured payload shape (redacted path/content): a genuine
# agy PreToolUse call for a native file write is
# {"toolCall":{"name":"write_to_file","args":{"CodeContent":"...",
# "Description":"...","Overwrite":true,"TargetFile":"/abs/path"}}}.
# TargetFile (CapitalCase) is now the CONFIRMED primary key, not a guess.
run_agy_gate '{"toolCall":{"name":"write_to_file","args":{"CodeContent":"trace-capture-ok","Description":"test","Overwrite":true,"TargetFile":".harness/handoff.md"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: a real write_to_file call targeting handoff.md is allowed while gated (was previously trapped -- empty CommandLine always fell through to deny)"
else
  fail "agy file-write gate: expected handoff.md write to be allowed via the confirmed TargetFile key, got: $GATE_OUT"
fi
run_agy_gate '{"toolCall":{"name":"write_to_file","args":{"CodeContent":"trace-capture-ok","Description":"test","Overwrite":true,"TargetFile":"/tmp/some-other-file-not-allowlisted.txt"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
  pass "agy: a real write_to_file call targeting a NON-allow-listed path is still blocked while gated"
else
  fail "agy file-write gate: a non-allow-listed path should still be denied, got: $GATE_OUT"
fi

echo "== finding-4: the confirmed TargetFile key works standalone, without any of the OLD 7-way speculative guess keys present =="
run_agy_gate '{"toolCall":{"name":"write_to_file","args":{"TargetFile":".harness/decisions.log"}}}'
if echo "$GATE_OUT" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
  pass "agy: TargetFile alone (no FilePath/filePath/Path/etc.) correctly resolves an allow-listed path"
else
  fail "agy: TargetFile alone should resolve an allow-listed path, got: $GATE_OUT"
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
