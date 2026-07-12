#!/bin/bash
# .harness/guard-write.test.sh — TDD tests for guard-write.sh, including T21's
# config-driven protected_paths (issue #26). No prior test file existed for
# this hook; added alongside the T21 config-loading change.
# Run: bash .harness/guard-write.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GUARD="$DIR/../lib/guard-write.sh"

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

echo "== issue #18 B-i: EMPTY default, no hardcoded project name (no config) =="
expect_allowed "write into career-ops/ is allowed (no config, old default is gone)"        "career-ops/x.txt"
expect_allowed "write into nested career-ops/ is allowed (no config, old default is gone)" "src/career-ops/x.txt"
expect_allowed "write outside career-ops/ is allowed (no config)"                          "extension/x.txt"

echo "== T21: protected paths from orchestrator.yaml =="
CUSTOM_YAML=$'protected_paths:\n  - vendor/legacy/'
MALFORMED_YAML='this is not yaml at all {{{ :::'

expect_allowed "malformed config: no protected paths (issue #18 B-i)" \
  "career-ops/x.txt" "$MALFORMED_YAML"
expect_blocked "custom protected_paths blocks its own path" \
  "vendor/legacy/x.txt" "$CUSTOM_YAML"
expect_allowed "custom protected_paths does not widen to anything not listed" \
  "career-ops/x.txt" "$CUSTOM_YAML"

echo "== issue #31: .claude/ and .agents/ are protected BY DEFAULT, independent of orchestrator.yaml =="
expect_blocked "write into .claude/settings.json is blocked with NO orchestrator.yaml at all" \
  ".claude/settings.json"
expect_blocked "write into .agents/hooks.json is blocked with NO orchestrator.yaml at all" \
  ".agents/hooks.json"
expect_blocked "write into a nested .claude/ path is blocked" \
  "some/nested/.claude/settings.local.json"
expect_blocked ".claude/ default protection is NOT overridden by an orchestrator.yaml that doesn't mention it" \
  ".claude/settings.json" "$CUSTOM_YAML"

run_guard_write ".claude/settings.json"
if echo "$GUARD_OUT" | grep -q "templates/settings.json"; then
  echo "PASS: blocked-write message names the sanctioned edit path (templates/settings.json)"
  PASS=$((PASS + 1))
else
  echo "FAIL: expected the blocked-write message to name templates/settings.json as the sanctioned edit path, got: $GUARD_OUT"
  FAIL=$((FAIL + 1))
fi

expect_allowed "a normal project write (unrelated to .claude//.agents/) is still allowed" \
  "src/some-feature.js"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
