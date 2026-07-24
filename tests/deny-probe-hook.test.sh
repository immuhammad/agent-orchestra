#!/bin/bash
# tests/deny-probe-hook.test.sh -- TDD tests for the PreToolUse deny hook
# (tests/deny-probe-hook.sh) that tests/probe-agy-hooks.sh copies into its
# scratch agy workspace. Piping fixture JSON straight at the hook exercises
# the payload-parsing / drift-detection logic without booting a real agy
# session (that end-to-end part stays covered by probe-agy-hooks.sh itself).
# Run: bash tests/deny-probe-hook.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
HOOK="$DIR/deny-probe-hook.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# run_hook <json-payload> -- runs the hook with cwd = a scratch ".agents"
# dir (mirrors where probe-agy-hooks.sh actually invokes it from), since
# the hook writes to "$PWD/../probe.log".
run_hook() {
  local payload="$1" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.agents"
  HOOK_OUT="$(cd "$tmp/.agents" && echo "$payload" | bash "$HOOK")"
  rm -rf "$tmp"
}

expect_deny() {
  local desc="$1" payload="$2"
  run_hook "$payload"
  local decision reason
  decision="$(echo "$HOOK_OUT" | jq -r '.decision')"
  reason="$(echo "$HOOK_OUT" | jq -r '.reason')"
  if [ "$decision" = "deny" ] && echo "$reason" | grep -q "PROBE-DENY-e2e"; then
    pass "$desc"
  else
    fail "$desc (got: $HOOK_OUT)"
  fi
}

expect_allow() {
  local desc="$1" payload="$2"
  run_hook "$payload"
  local decision
  decision="$(echo "$HOOK_OUT" | jq -r '.decision')"
  if [ "$decision" = "allow" ]; then
    pass "$desc"
  else
    fail "$desc (got: $HOOK_OUT)"
  fi
}

echo "== expected probe command: denied with the e2e marker =="
expect_deny "exact CommandLine match is denied" \
  '{"toolCall":{"args":{"CommandLine":"echo probe-ok-77"}}}'
expect_deny "lowercase commandLine fallback (same jq path as lib/guard-agy.sh)" \
  '{"toolCall":{"args":{"commandLine":"echo probe-ok-77"}}}'

echo "== payload drift: anything unexpected falls through to allow, never a false deny =="
expect_allow "a different command is allowed, not denied" \
  '{"toolCall":{"args":{"CommandLine":"echo something-else"}}}'
expect_allow "a renamed field (payload-shape drift) is allowed" \
  '{"toolCall":{"args":{"CommandLineX":"echo probe-ok-77"}}}'
expect_allow "an empty payload is allowed" \
  '{}'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
