#!/bin/bash
# .harness/orc.test.sh — TDD tests for orc-config.sh + orc.sh (T21, issue #26).
# Run: bash .harness/orc.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" == "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== orc-config.sh: scalars =="
(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: test-project
integration_branch: uat
roles:
  orchestra:
    model: opus
    effort: high
  implementer:
    model: sonnet
    effort: default
protected_paths:
  - career-ops/
EOF
  source "$DIR/../lib/orc-config.sh"
  echo "PROJECT=$(orc_get_scalar project)"
  echo "BRANCH=$(orc_get_scalar integration_branch)"
  echo "ORCH_MODEL=$(orc_get_role_model orchestra)"
  echo "IMPL_MODEL=$(orc_get_role_model implementer)"
) > "$TMP/scalars.out"

assert_eq "project scalar"          "test-project" "$(grep '^PROJECT=' "$TMP/scalars.out" | cut -d= -f2)"
assert_eq "integration_branch scalar" "uat"         "$(grep '^BRANCH=' "$TMP/scalars.out" | cut -d= -f2)"
assert_eq "roles.orchestra.model"   "opus"          "$(grep '^ORCH_MODEL=' "$TMP/scalars.out" | cut -d= -f2)"
assert_eq "roles.implementer.model" "sonnet"        "$(grep '^IMPL_MODEL=' "$TMP/scalars.out" | cut -d= -f2)"

echo "== orc-config.sh: protected_paths (block list) =="
(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: test-project
protected_paths:
  - career-ops/
  - vendor/legacy/
EOF
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/block.out"
assert_eq "block-list count" "2" "$(wc -l < "$TMP/block.out" | tr -d ' ')"
grep -q '^career-ops/$' "$TMP/block.out" && pass "block-list contains career-ops/" || fail "block-list contains career-ops/"
grep -q '^vendor/legacy/$' "$TMP/block.out" && pass "block-list contains vendor/legacy/" || fail "block-list contains vendor/legacy/"

echo "== orc-config.sh: protected_paths (inline list) =="
(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: test-project
protected_paths: [career-ops/, docs/frozen/]
EOF
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/inline.out"
assert_eq "inline-list count" "2" "$(wc -l < "$TMP/inline.out" | tr -d ' ')"
grep -q '^career-ops/$' "$TMP/inline.out" && pass "inline-list contains career-ops/" || fail "inline-list contains career-ops/"
grep -q '^docs/frozen/$' "$TMP/inline.out" && pass "inline-list contains docs/frozen/" || fail "inline-list contains docs/frozen/"

echo "== orc-config.sh: fail-closed fallback =="
(
  cd "$TMP"
  rm -f orchestrator.yaml
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/missing.out"
assert_eq "missing config falls back to career-ops/" "career-ops/" "$(cat "$TMP/missing.out")"

(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: test-project
protected_paths:
EOF
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/empty-key.out"
assert_eq "empty protected_paths key falls back to career-ops/" "career-ops/" "$(cat "$TMP/empty-key.out")"

(
  cd "$TMP"
  printf 'this is not yaml at all {{{ :::' > orchestrator.yaml
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/garbage.out"
assert_eq "malformed config falls back to career-ops/" "career-ops/" "$(cat "$TMP/garbage.out")"

echo "== orc.sh: orc_build_session builds the control room from config =="
SESSION="orctest-$$"
(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: test-project
integration_branch: uat
roles:
  orchestra:
    model: opus
  implementer:
    model: sonnet
protected_paths:
  - career-ops/
EOF
  ORC_SESSION="$SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$TMP/build.err"
)

PANE_COUNT="$(tmux list-panes -t "$SESSION" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "control room has 5 panes (issue #89: pane 3/copilot retired)" "5" "$PANE_COUNT"

TITLES="$(tmux list-panes -t "$SESSION" -F '#{pane_title}' 2>/dev/null | sort | tr '\n' ',')"
EXPECTED_TITLES="agy,builder,gatekeeper,orchestra,pr/budget watch,"
assert_eq "pane titles match role map (no standing copilot/scribe pane)" "$EXPECTED_TITLES" "$TITLES"

grep -q 'project=test-project' "$TMP/build.err" && pass "build log reports project from yaml" || fail "build log reports project from yaml"
grep -q 'orchestra_model=opus' "$TMP/build.err" && pass "build log reports orchestra model from yaml" || fail "build log reports orchestra model from yaml"
grep -q 'protected_paths=career-ops/' "$TMP/build.err" && pass "build log reports protected_paths from yaml" || fail "build log reports protected_paths from yaml"

tmux kill-session -t "$SESSION" 2>/dev/null || true

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
