#!/bin/bash
# tests/orc-own-checkout-guard.test.sh -- issue #171 Gate-1 plan: `orc up`
# refuses to build a control room on top of a checkout that still looks
# like the harness's own un-adopted clone (agent-orchestra), UNLESS the
# exemption holds -- the real agent-orchestra dogfood room must always
# still start. Algorithm (orc_build_session, bin/orc):
#   EXEMPT (never refuse) when project == the repo-name segment of
#     github_repo AND project == basename $PWD.
#   Otherwise REFUSE when github_repo's tail (or, if github_repo is
#     unset/malformed, the actual git origin remote's tail) is literally
#     "agent-orchestra".
#   Any other project (its own unrelated github_repo) is unaffected
#     either way.
# Run: bash tests/orc-own-checkout-guard.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^orctest-ownguard-' || true); do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
}
trap cleanup EXIT

echo "== EXEMPT: a fixture shaped exactly like the real dogfood room proceeds =="
EXEMPT_DIR="$TMP/agent-orchestra"
mkdir -p "$EXEMPT_DIR"
EXEMPT_SESSION="orctest-ownguard-exempt-$$"
(
  cd "$EXEMPT_DIR"
  cat > orchestrator.yaml <<'EOF'
project: agent-orchestra
github_repo: immuhammad/agent-orchestra
EOF
  ORC_SESSION="$EXEMPT_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
  echo $? > exit.code
)
if [ "$(cat "$EXEMPT_DIR/exit.code")" = "0" ]; then
  pass "the real dogfood room's own shape (project=agent-orchestra, github_repo=immuhammad/agent-orchestra, dirname=agent-orchestra) proceeds past the guard"
else
  fail "the real dogfood room's shape should NOT be refused: $(cat "$EXEMPT_DIR/build.err")"
fi
if tmux has-session -t "$EXEMPT_SESSION" 2>/dev/null; then
  pass "exempt fixture: a tmux session WAS built"
else
  fail "exempt fixture: expected a tmux session to be built: $(cat "$EXEMPT_DIR/build.err")"
fi
if grep -qi "un-adopted clone" "$EXEMPT_DIR/build.err" 2>/dev/null; then
  fail "exempt fixture should not print the own-checkout REFUSE message: $(cat "$EXEMPT_DIR/build.err")"
else
  pass "exempt fixture: no own-checkout REFUSE message"
fi
tmux kill-session -t "$EXEMPT_SESSION" 2>/dev/null || true

echo "== REFUSE: github_repo=immuhammad/agent-orchestra but project/dirname diverge =="
REFUSE_DIR="$TMP/some-renamed-checkout"
mkdir -p "$REFUSE_DIR"
REFUSE_SESSION="orctest-ownguard-refuse-$$"
(
  cd "$REFUSE_DIR"
  cat > orchestrator.yaml <<'EOF'
project: agent-orchestra
github_repo: immuhammad/agent-orchestra
EOF
  ORC_SESSION="$REFUSE_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
  echo $? > exit.code
)
if [ "$(cat "$REFUSE_DIR/exit.code")" != "0" ]; then
  pass "diverged dirname (project=agent-orchestra, github_repo=immuhammad/agent-orchestra, dirname != agent-orchestra) is refused"
else
  fail "expected a non-zero exit for the diverged-dirname fixture: $(cat "$REFUSE_DIR/build.err")"
fi
if grep -qi "REFUSE.*un-adopted clone\|un-adopted clone.*agent-orchestra" "$REFUSE_DIR/build.err" 2>/dev/null; then
  pass "the refusal message names the un-adopted-clone reason"
else
  fail "expected a loud REFUSE naming the un-adopted clone, got: $(cat "$REFUSE_DIR/build.err")"
fi
if tmux has-session -t "$REFUSE_SESSION" 2>/dev/null; then
  fail "diverged-dirname fixture: no tmux session should have been built"
else
  pass "diverged-dirname fixture: no tmux session was built"
fi
tmux kill-session -t "$REFUSE_SESSION" 2>/dev/null || true

echo "== never refused: a normal already-adopted project with its own unrelated github_repo, regardless of project/dirname =="
NORMAL_SESSION="orctest-ownguard-normal-$$"
NORMAL_DIR="$TMP/totally-unrelated-dirname"
mkdir -p "$NORMAL_DIR"
(
  cd "$NORMAL_DIR"
  cat > orchestrator.yaml <<'EOF'
project: my-own-project
github_repo: someowner/my-own-project
EOF
  ORC_SESSION="$NORMAL_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
  echo $? > exit.code
)
if [ "$(cat "$NORMAL_DIR/exit.code")" = "0" ]; then
  pass "a normal unrelated project (own github_repo, dirname mismatched) is never refused"
else
  fail "a normal unrelated project should never be refused by the own-checkout guard: $(cat "$NORMAL_DIR/build.err")"
fi
if tmux has-session -t "$NORMAL_SESSION" 2>/dev/null; then
  pass "normal unrelated project: tmux session was built"
else
  fail "normal unrelated project: expected a tmux session to be built: $(cat "$NORMAL_DIR/build.err")"
fi
tmux kill-session -t "$NORMAL_SESSION" 2>/dev/null || true

# Same check again, but with project == dirname this time (the OTHER
# half of the exemption's AND condition) -- still must never refuse,
# since its repo tail isn't "agent-orchestra" at all.
NORMAL2_SESSION="orctest-ownguard-normal2-$$"
NORMAL2_DIR="$TMP/my-second-project"
mkdir -p "$NORMAL2_DIR"
(
  cd "$NORMAL2_DIR"
  cat > orchestrator.yaml <<'EOF'
project: my-second-project
github_repo: someowner/my-second-project
EOF
  ORC_SESSION="$NORMAL2_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
  echo $? > exit.code
)
if [ "$(cat "$NORMAL2_DIR/exit.code")" = "0" ]; then
  pass "a normal unrelated project whose project == dirname is also never refused"
else
  fail "a normal unrelated project (project==dirname) should never be refused: $(cat "$NORMAL2_DIR/build.err")"
fi
tmux kill-session -t "$NORMAL2_SESSION" 2>/dev/null || true

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
