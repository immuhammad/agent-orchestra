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

echo "== orc-config.sh: orc_session_name (issue #18 item 7 / #19) =="
(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: my-cool-project
EOF
  source "$DIR/../lib/orc-config.sh"
  orc_session_name fallback
) > "$TMP/session.out"
assert_eq "session name derives from orchestrator.yaml's project" "my-cool-project" "$(cat "$TMP/session.out")"

(
  cd "$TMP"
  rm -f orchestrator.yaml
  source "$DIR/../lib/orc-config.sh"
  orc_session_name my-fallback
) > "$TMP/session-fallback.out"
assert_eq "session name falls back when no orchestrator.yaml" "my-fallback" "$(cat "$TMP/session-fallback.out")"

(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: client.acme:prod
EOF
  source "$DIR/../lib/orc-config.sh"
  orc_session_name fallback
) > "$TMP/session-sanitized.out"
assert_eq "session name sanitizes tmux's own separators (. and :)" "client-acme-prod" "$(cat "$TMP/session-sanitized.out")"
rm -f "$TMP/orchestrator.yaml"

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

echo "== orc-config.sh: EMPTY default, no hardcoded project name (issue #18 B-i) =="
(
  cd "$TMP"
  rm -f orchestrator.yaml
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/missing.out"
assert_eq "missing config: no protected paths (protected_paths comes ONLY from orchestrator.yaml)" "" "$(cat "$TMP/missing.out")"

(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: test-project
protected_paths:
EOF
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/empty-key.out"
assert_eq "empty protected_paths key: no protected paths" "" "$(cat "$TMP/empty-key.out")"

(
  cd "$TMP"
  printf 'this is not yaml at all {{{ :::' > orchestrator.yaml
  source "$DIR/../lib/orc-config.sh"
  orc_protected_paths
) > "$TMP/garbage.out"
assert_eq "malformed config: no protected paths" "" "$(cat "$TMP/garbage.out")"

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
  ORC_SESSION="$SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 \
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

echo "== issue #59: liveness watchdog restart no longer uses nohup (guard.sh correctly fails closed on nohup, which blocked bin/orc's OWN restart drill mid-drill) =="
if grep -v '^[[:space:]]*#' "$DIR/../bin/orc" | grep -q 'nohup'; then
  fail "bin/orc should no longer launch gatekeeper-liveness.sh via nohup (a comment MAY still mention nohup to explain why -- only a live invocation fails this) -- the harness's own restart drill needs an inspectable path, same as the other three loops"
else
  pass "bin/orc no longer uses nohup"
fi

echo "== issue #59: liveness watchdog launches via a tmux session, same mechanism as the other three loops =="
LIVE_SESSION="orctest-liveness-$$"
LIVE_TMP="$(mktemp -d)"
(
  cd "$LIVE_TMP"
  cat > orchestrator.yaml <<'EOF'
project: liveness-test-project
EOF
  ORC_SESSION="$LIVE_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$LIVE_TMP/build.err"
)
sleep 1
if tmux has-session -t "${LIVE_SESSION}-liveness" 2>/dev/null; then
  pass "orc_build_session started a dedicated tmux session for the liveness watchdog (${LIVE_SESSION}-liveness)"
else
  fail "expected a tmux session '${LIVE_SESSION}-liveness' for the liveness watchdog, none found: $(cat "$LIVE_TMP/build.err" 2>/dev/null)"
fi
tmux kill-session -t "$LIVE_SESSION" 2>/dev/null || true
tmux kill-session -t "${LIVE_SESSION}-liveness" 2>/dev/null || true
rm -rf "$LIVE_TMP"

echo "== issue #59: ORC_SKIP_LIVENESS=1 still skips the liveness watchdog entirely (regression) =="
SKIP_SESSION="orctest-liveness-skip-$$"
SKIP_TMP="$(mktemp -d)"
(
  cd "$SKIP_TMP"
  echo "project: liveness-skip-test" > orchestrator.yaml
  ORC_SESSION="$SKIP_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$SKIP_TMP/build.err"
)
sleep 1
if tmux has-session -t "${SKIP_SESSION}-liveness" 2>/dev/null; then
  fail "ORC_SKIP_LIVENESS=1 should skip the liveness watchdog tmux session entirely"
else
  pass "ORC_SKIP_LIVENESS=1 skips the liveness tmux session"
fi
tmux kill-session -t "$SKIP_SESSION" 2>/dev/null || true
rm -rf "$SKIP_TMP"

echo "== issue #22: orc_build_session seeds the inbox dirs dispatch.sh actually uses, not a hand-made layout =="
for agent in orchestra builder agy scribe; do
  if [ -d "$TMP/.harness/inbox/$agent" ]; then
    pass "orc_build_session seeded inbox/$agent"
  else
    fail "orc_build_session should have seeded inbox/$agent (fresh room must not rely on a hand-made layout)"
  fi
done
if [ -d "$TMP/.harness/inbox/copilot" ]; then
  fail "orc_build_session should NOT seed a legacy inbox/copilot dir in a fresh room (issue #22: scribe/ is the live physical dir now)"
else
  pass "fresh room has no legacy inbox/copilot dir"
fi

echo "== issue #10/#31: orc_build_session runs the hook-wiring doctor check, LOUD but non-fatal =="
# The room built above had NO .claude/settings.json at all -- the check
# should have WARNED in build.err (loud) without orc_build_session itself
# failing (non-fatal, already proven by the pane/inbox assertions above
# succeeding despite this).
if grep -qi "quota-stop-gate" "$TMP/build.err" 2>/dev/null; then
  pass "orc_build_session's hook-wiring check warned loudly about the missing gate (no .claude/settings.json in this fresh room)"
else
  fail "expected orc_build_session to have run the hook-wiring check and warned about the missing gate: $(cat "$TMP/build.err" 2>/dev/null)"
fi

HOOKWIRE_SESSION="orctest-hookwire-$$"
HOOKWIRE_TMP="$(mktemp -d)"
mkdir -p "$HOOKWIRE_TMP/.claude"
cp "$DIR/../templates/settings.json" "$HOOKWIRE_TMP/.claude/settings.json"
(
  cd "$HOOKWIRE_TMP"
  echo "project: hookwire-test" > orchestrator.yaml
  ORC_SESSION="$HOOKWIRE_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$HOOKWIRE_TMP/build.err"
)
if grep -qi "quota-stop-gate" "$HOOKWIRE_TMP/build.err" 2>/dev/null; then
  fail "a correctly-wired .claude/settings.json should NOT trigger the hook-wiring warning: $(cat "$HOOKWIRE_TMP/build.err")"
else
  pass "a correctly-wired .claude/settings.json (copied from templates/settings.json) triggers no warning"
fi
tmux kill-session -t "$HOOKWIRE_SESSION" 2>/dev/null || true
rm -rf "$HOOKWIRE_TMP"

echo "== orc.sh: ORC_SESSION defaults to THIS project's own session, not a shared 'harness' (issue #18 item 7 / #19) =="
DEFAULT_SESSION_OUT="$(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: second-clone-project
EOF
  unset ORC_SESSION
  bash -c "source '$DIR/../bin/orc'; echo \"\$ORC_SESSION\""
)"
assert_eq "ORC_SESSION derives from orchestrator.yaml's project, unset by default" "second-clone-project" "$DEFAULT_SESSION_OUT"

ENV_OVERRIDE_OUT="$(
  cd "$TMP"
  ORC_SESSION="explicit-override" \
    bash -c "source '$DIR/../bin/orc'; echo \"\$ORC_SESSION\""
)"
assert_eq "ORC_SESSION env override still wins over orchestrator.yaml" "explicit-override" "$ENV_OVERRIDE_OUT"
rm -f "$TMP/orchestrator.yaml"

echo "== orc.sh: orc_build_session seeds merge-watch-state on a fresh room (issue #18 item 5 / C1) =="
SEED_SESSION="orctest-seed-$$"
SEED_TMP="$(mktemp -d)"
FAKE_GH_BIN="$SEED_TMP/bin"
mkdir -p "$FAKE_GH_BIN"
cat > "$FAKE_GH_BIN/gh" <<'FAKEGH'
#!/bin/bash
# Emulates `gh pr list ... --jq '.[] | ...'` against an empty result set --
# real gh+jq prints nothing for an empty array, not a literal "[]".
true
FAKEGH
chmod +x "$FAKE_GH_BIN/gh"
(
  cd "$SEED_TMP"
  cat > orchestrator.yaml <<'EOF'
project: seed-test-project
EOF
  PATH="$FAKE_GH_BIN:$PATH" ORC_SESSION="$SEED_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$SEED_TMP/build.err"
)
if [ -f "$SEED_TMP/.harness/merge-watch-state" ]; then
  pass "orc_build_session seeded merge-watch-state on a fresh room (state file now exists)"
else
  fail "expected .harness/merge-watch-state to exist after orc_build_session: $(cat "$SEED_TMP/build.err" 2>/dev/null)"
fi
tmux kill-session -t "$SEED_SESSION" 2>/dev/null || true

SEED_TMP2="$(mktemp -d)"
(
  cd "$SEED_TMP2"
  cat > orchestrator.yaml <<'EOF'
project: seed-skip-test-project
EOF
  mkdir -p .harness
  ORC_SESSION="orctest-seedskip-$$" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$SEED_TMP2/build.err"
)
if [ ! -f "$SEED_TMP2/.harness/merge-watch-state" ]; then
  pass "ORC_SKIP_MERGE_WATCH_SEED=1 skips seeding entirely"
else
  fail "ORC_SKIP_MERGE_WATCH_SEED=1 should have skipped seeding"
fi
tmux kill-session -t "orctest-seedskip-$$" 2>/dev/null || true
rm -rf "$SEED_TMP" "$SEED_TMP2"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
