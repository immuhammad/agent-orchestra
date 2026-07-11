#!/bin/bash
# .harness/guard-write.test.sh — TDD tests for guard-write.sh, including T21's
# config-driven protected_paths (issue #26). No prior test file existed for
# this hook; added alongside the T21 config-loading change.
# Run: bash .harness/guard-write.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$DIR/guard-write.sh"

PASS=0
FAIL=0

# run_guard_write <file_path> [orchestrator.yaml contents]
run_guard_write() {
  local file_path="$1"
  local yaml_content="${2:-}"

  local tmp
  tmp="$(mktemp -d)"

  if [ -n "$yaml_content" ]; then
    printf '%s\n' "$yaml_content" > "$tmp/orchestrator.yaml"
  fi

  local payload
  payload="$(jq -n --arg fp "$file_path" '{tool_input: {file_path: $fp}}')"

  local out status
  out="$(cd "$tmp" && echo "$payload" | bash "$GUARD" 2>&1)"
  status=$?

  rm -rf "$tmp"
  GUARD_OUT="$out"
  GUARD_STATUS=$status
}

expect_blocked() {
  local desc="$1" file_path="$2" yaml="${3:-}"
  run_guard_write "$file_path" "$yaml"
  if [ "$GUARD_STATUS" -eq 2 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 2, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

expect_allowed() {
  local desc="$1" file_path="$2" yaml="${3:-}"
  run_guard_write "$file_path" "$yaml"
  if [ "$GUARD_STATUS" -eq 0 ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit 0, got $GUARD_STATUS) -- output: $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

echo "== regression: default career-ops/ blocking =="
expect_blocked "write into career-ops/ is blocked (no config)"       "career-ops/x.txt"
expect_blocked "write into nested career-ops/ is blocked (no config)" "src/career-ops/x.txt"
expect_allowed "write outside career-ops/ is allowed (no config)"     "extension/x.txt"

echo "== T21: protected paths from orchestrator.yaml =="
CUSTOM_YAML=$'protected_paths:\n  - vendor/legacy/'
MALFORMED_YAML='this is not yaml at all {{{ :::'

expect_blocked "malformed config still blocks career-ops/ (fail closed)" \
  "career-ops/x.txt" "$MALFORMED_YAML"
expect_blocked "custom protected_paths blocks its own path" \
  "vendor/legacy/x.txt" "$CUSTOM_YAML"
expect_allowed "custom protected_paths no longer blocks career-ops/" \
  "career-ops/x.txt" "$CUSTOM_YAML"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
