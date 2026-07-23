#!/bin/bash
# .harness/orc.test.sh — TDD tests for orc-config.sh + orc.sh.
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
cleanup() {
  rm -rf "$TMP"
  # A set -e mid-block failure (or INT/TERM routed through exit below)
  # never reaches a block's inline kill-session -- reap every session
  # THIS run created on the way out. Names end in our PID (plus the one
  # derived -liveness suffix), so parallel runs and the live control-room
  # are untouched. SIGKILL is NOT covered here (no trap can catch it);
  # reap_dead_orctest_sessions below converges those on the NEXT run.
  for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null \
               | grep -E "^orctest-(.*-)?$$(-liveness)?\$" || true); do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
}
trap cleanup EXIT
# An untrapped INT/TERM would skip the EXIT trap entirely -- route them
# through exit so an interrupted run still reaps its sessions.
trap 'exit 130' INT TERM

# Self-heal on the way IN (agy PR #145 round 1): no trap catches SIGKILL,
# so a kill -9'd run strands its sessions until someone cleans up by
# hand. Reap any orctest-* session whose embedded owner PID is dead;
# anything with a live PID (parallel runs, this run) always survives.
reap_dead_orctest_sessions() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^orctest-' \
  | while IFS= read -r s; do
    pid="${s%-liveness}"   # derived suffix off first
    pid="${pid##*-}"       # trailing field = the owning PID
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    tmux kill-session -t "$s" 2>/dev/null || true
  done
  return 0
}
reap_dead_orctest_sessions

echo "== PR #145 round 1: dead-PID orphan reaper =="
# A max-PID orphan stands in for a SIGKILL-stranded run (same stand-in
# gatekeeper.test.sh used for #37); a live decoy proves PID-scoping.
REAP_DEAD="orctest-reapme-2147483647"
REAP_LIVE="orctest-decoy-$$"
tmux new-session -d -s "$REAP_DEAD" >/dev/null 2>&1
tmux new-session -d -s "${REAP_DEAD}-liveness" >/dev/null 2>&1
tmux new-session -d -s "$REAP_LIVE" >/dev/null 2>&1
reap_dead_orctest_sessions
if ! tmux has-session -t "$REAP_DEAD" 2>/dev/null \
   && ! tmux has-session -t "${REAP_DEAD}-liveness" 2>/dev/null; then
  pass "dead-PID orphans reaped (plain + -liveness shapes)"
else
  fail "dead-PID orphan sessions should have been reaped"
fi
if tmux has-session -t "$REAP_LIVE" 2>/dev/null; then
  pass "live-PID session survives the reaper"
else
  fail "live-PID session must survive the reaper"
fi
tmux kill-session -t "$REAP_LIVE" 2>/dev/null || true

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

(
  cd "$TMP"
  cat > orchestrator.yaml <<'EOF'
project: my cool'project
EOF
  source "$DIR/../lib/orc-config.sh"
  orc_session_name fallback
) > "$TMP/session-hostile.out"
assert_eq "session name sanitizes EVERY char outside [A-Za-z0-9_-] (agy PR #133: spaces word-split and quotes shell-inject the /bin/sh string inside the attach-snap hook)" "my-cool-project" "$(cat "$TMP/session-hostile.out")"
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
  ORC_SESSION="$SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
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

echo "== issue #87: agent panes get real headroom on a normal terminal, not an even 5-way tile =="
# The naive `tiled` layout gives all 5 panes an equal share -- on a real
# terminal (measured: 238x60) that squeezed the 3 INTERACTIVE agent panes
# (orchestra/builder/agy) down to ~18 rows, not enough for Claude Code's
# own status line + input box + scrollback ("no space to type", live-
# reported repeatedly). gatekeeper/watch are read-only dashboards that
# tolerate a short strip; the agent panes get the rest. ORC_TERM_COLS/
# LINES override `tput` for deterministic sizing in tests -- a real
# terminal isn't guaranteed (or needed) here.
LAYOUT_SESSION="orctest-layout-$$"
LAYOUT_TMP="$(mktemp -d)"
(
  cd "$TMP"
  ORC_SESSION="$LAYOUT_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    ORC_TERM_COLS=238 ORC_TERM_LINES=60 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$LAYOUT_TMP/build.err"
)

LAYOUT_PANE_COUNT="$(tmux list-panes -t "$LAYOUT_SESSION" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "issue #87: weighted layout still has 5 panes" "5" "$LAYOUT_PANE_COUNT"

# Index->role mapping is a hard contract (AGENTS.md: 0=orchestra 1=builder
# 2=agy 3=gatekeeper 4=watch; dispatch.sh's pane_for_agent and gatekeeper-
# liveness's watch target hardcode these positions) -- asserted by INDEX
# ORDER, not just as an unordered set of titles (the pre-existing test
# above already covers the unordered-set case).
LAYOUT_TITLES_BY_INDEX="$(tmux list-panes -t "$LAYOUT_SESSION" -F '#{pane_index}:#{pane_title}' 2>/dev/null | sort -t: -k1,1n | cut -d: -f2 | tr '\n' ',')"
assert_eq "issue #87: index->role order preserved (0=orchestra 1=builder 2=agy 3=gatekeeper 4=watch)" "orchestra,builder,agy,gatekeeper,pr/budget watch," "$LAYOUT_TITLES_BY_INDEX"

AGENT_MIN_HEIGHT="$(tmux list-panes -t "$LAYOUT_SESSION" -F '#{pane_index} #{pane_height}' 2>/dev/null | awk '$1<=2 {print $2}' | sort -n | head -1)"
if [ -n "$AGENT_MIN_HEIGHT" ] && [ "$AGENT_MIN_HEIGHT" -ge 25 ]; then
  pass "issue #87: all 3 agent panes (orchestra/builder/agy) have >= 25 rows on a 238x60 terminal (smallest: ${AGENT_MIN_HEIGHT})"
else
  fail "CORRECTNESS REGRESSION (issue #87): an agent pane has fewer than 25 rows on a 238x60 terminal (smallest measured: ${AGENT_MIN_HEIGHT:-none})"
fi

MONITOR_MIN_HEIGHT="$(tmux list-panes -t "$LAYOUT_SESSION" -F '#{pane_index} #{pane_height}' 2>/dev/null | awk '$1>=3 {print $2}' | sort -n | head -1)"
if [ -n "$MONITOR_MIN_HEIGHT" ] && [ "$MONITOR_MIN_HEIGHT" -gt 0 ]; then
  pass "issue #87: monitor panes (gatekeeper/watch) still have a positive row count (${MONITOR_MIN_HEIGHT}) -- short is fine, zero is not"
else
  fail "CORRECTNESS REGRESSION (issue #87): a monitor pane has zero/negative height"
fi
if tmux show-hooks -t "$LAYOUT_SESSION" 2>/dev/null | grep -q 'client-attached'; then
  fail "weighted branch must NOT arm the attach-snap hook (it already sized from the real terminal; the hook is the FALLBACK's self-heal)"
else
  pass "weighted branch arms no client-attached snap hook"
fi
tmux kill-session -t "$LAYOUT_SESSION" 2>/dev/null || true

echo "== issue #87: a terminal too small for the weighted layout falls back to the original tiled layout, loudly =="
SMALL_SESSION="orctest-small-$$"
SMALL_TMP="$(mktemp -d)"
(
  cd "$TMP"
  ORC_SESSION="$SMALL_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    ORC_TERM_COLS=80 ORC_TERM_LINES=24 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$SMALL_TMP/build.err"
)
SMALL_PANE_COUNT="$(tmux list-panes -t "$SMALL_SESSION" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "issue #87: too-small terminal still builds all 5 panes (graceful fallback, not a hard failure)" "5" "$SMALL_PANE_COUNT"
if grep -qi 'WARNING.*too small' "$SMALL_TMP/build.err" 2>/dev/null; then
  pass "issue #87: a too-small terminal warns loudly about falling back to the tiled layout"
else
  fail "expected a loud WARNING about falling back to tiled on a too-small terminal, got: $(cat "$SMALL_TMP/build.err" 2>/dev/null)"
fi
SMALL_ZERO_HEIGHT="$(tmux list-panes -t "$SMALL_SESSION" -F '#{pane_height}' 2>/dev/null | awk '$1<=0' | wc -l | tr -d ' ')"
assert_eq "issue #87: fallback layout never produces a zero-height pane" "0" "$SMALL_ZERO_HEIGHT"
tmux kill-session -t "$SMALL_SESSION" 2>/dev/null || true

echo "== issue #87 review round 2: no ORC_TERM_COLS/LINES override AND no real controlling tty -- falls back loudly, never trusts a non-tty tput default as if it were the real client size =="
# CI-reproduced: `tput cols`/`tput lines` do NOT reliably fail when stdout
# isn't a real terminal -- with TERM set (even TERM=dumb) but no tty, tput
# happily returns a plausible-looking "80"/"24" fallback default instead of
# erroring. Trusting that as "the actual client size" is exactly the
# "garbage math" this test guards against. stdout is redirected to a
# regular FILE (not inherited) so `[ -t 1 ]` is reliably false here
# regardless of how this test suite itself happens to be invoked.
NOTTY_SESSION="orctest-notty-$$"
NOTTY_TMP="$(mktemp -d)"
(
  cd "$TMP"
  # -u TMUX (issue #119, review round 2 -- reproduced live running this
  # suite from inside a real tmux pane): this test's whole POINT is
  # "nothing about the real client size is knowable" -- but the #119 fix
  # added a SECOND way to learn it (the attached tmux client), which is
  # unconditionally available whenever $TMUX happens to be inherited from
  # whatever shell is running this test. Stripped explicitly so the
  # scenario stays genuinely size-unknown regardless of the invoking
  # shell's own tmux context, instead of accidentally exercising #119's
  # new code path (that path has its own dedicated tests below).
  env -u ORC_TERM_COLS -u ORC_TERM_LINES -u TMUX TERM=dumb \
    ORC_SESSION="$NOTTY_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" > "$NOTTY_TMP/build.out" 2> "$NOTTY_TMP/build.err" < /dev/null
)
NOTTY_PANE_COUNT="$(tmux list-panes -t "$NOTTY_SESSION" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "issue #87: no override + no tty still builds all 5 panes (graceful fallback)" "5" "$NOTTY_PANE_COUNT"
if grep -qi 'WARNING.*too small' "$NOTTY_TMP/build.err" 2>/dev/null; then
  pass "issue #87: no override + no tty falls back to tiled with a loud warning, not a silent guess at the real size"
else
  fail "CORRECTNESS REGRESSION (issue #87): no override + no tty should fall back loudly, not trust a non-tty tput default -- got: $(cat "$NOTTY_TMP/build.err" 2>/dev/null)"
fi
NOTTY_ZERO_HEIGHT="$(tmux list-panes -t "$NOTTY_SESSION" -F '#{pane_height}' 2>/dev/null | awk '$1<=0' | wc -l | tr -d ' ')"
assert_eq "issue #87: no-tty fallback never produces a zero-height pane" "0" "$NOTTY_ZERO_HEIGHT"
tmux kill-session -t "$NOTTY_SESSION" 2>/dev/null || true

# issue #119: `orc up` run from INSIDE an already-attached tmux client (a
# human's outer terminal is itself a tmux pane) measures the CALLING
# PANE's own geometry via tput, not the actual physical terminal window --
# live-hit rebuilding this room's own #87 layout, where the calling pane
# was narrower than the real attached client, tripping the loud tiled
# fallback for no real reason. Fixed by sizing from the attached client
# (`tmux display-message -p '#{client_width} #{client_height}'`) whenever
# $TMUX is set, before falling through to tput/none.
#
# A `tmux` STUB on PATH (not a real second attached client, which would
# need a real pty) intercepts ONLY the exact display-message call this
# fix makes and execs through to the REAL tmux binary (captured as
# REAL_TMUX before PATH is touched) for every other invocation --
# session/window management in this test still goes through real tmux.
REAL_TMUX="$(command -v tmux)"

echo "== issue #119: \$TMUX set -> sizes from the attached tmux CLIENT, not tput, and echoes the chosen size + source =="
T119_STUB_DIR="$(mktemp -d)"
cat > "$T119_STUB_DIR/tmux" <<STUB
#!/bin/bash
if [ "\$1" = "display-message" ] && [ "\$2" = "-p" ] && [ "\$3" = "#{client_width} #{client_height}" ]; then
  echo "199 55"
  exit 0
fi
exec "$REAL_TMUX" "\$@"
STUB
chmod +x "$T119_STUB_DIR/tmux"
T119_SESSION="orctest-119-$$"
T119_TMP="$(mktemp -d)"
(
  cd "$TMP"
  env -u ORC_TERM_COLS -u ORC_TERM_LINES PATH="$T119_STUB_DIR:$PATH" TMUX="/tmp/faketmux,12345,0" \
    ORC_SESSION="$T119_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" > "$T119_TMP/build.out" 2> "$T119_TMP/build.err" < /dev/null
)
# issue #119 review: $TMUX's socket segment IS load-bearing for plain tmux
# CLI invocations with no -L/-S (confirmed live on tmux 3.7b -- a
# different TMUX value really does route to a different server/socket,
# not just a nesting marker). The builder subshell above ran with
# TMUX="/tmp/faketmux,12345,0", so every query against the session it
# built must use that SAME value or it's asking the wrong server.
T119_WINSIZE="$(TMUX="/tmp/faketmux,12345,0" tmux list-windows -t "$T119_SESSION" -F '#{window_width}x#{window_height}' 2>/dev/null)"
assert_eq "issue #119: room is sized from the stubbed attached-client dimensions (199x55), not this test's own tput/pane size" "199x55" "$T119_WINSIZE"
if grep -q 'sizing room at 199x55 (source: attached tmux client)' "$T119_TMP/build.out" 2>/dev/null; then
  pass "issue #119: happy path echoes the chosen size + source"
else
  fail "issue #119: expected an echoed 'sizing room at 199x55 (source: attached tmux client)' line, got: $(cat "$T119_TMP/build.out" 2>/dev/null)"
fi
TMUX="/tmp/faketmux,12345,0" tmux kill-session -t "$T119_SESSION" 2>/dev/null || true

echo "== issue #119: ORC_TERM_COLS/LINES override still wins even when \$TMUX is set (override stays top-priority) =="
T119OV_SESSION="orctest-119ov-$$"
T119OV_TMP="$(mktemp -d)"
(
  cd "$TMP"
  PATH="$T119_STUB_DIR:$PATH" TMUX="/tmp/faketmux,12345,0" \
    ORC_TERM_COLS=90 ORC_TERM_LINES=30 \
    ORC_SESSION="$T119OV_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" > "$T119OV_TMP/build.out" 2> "$T119OV_TMP/build.err" < /dev/null
)
T119OV_WINSIZE="$(TMUX="/tmp/faketmux,12345,0" tmux list-windows -t "$T119OV_SESSION" -F '#{window_width}x#{window_height}' 2>/dev/null)"
assert_eq "issue #119: ORC_TERM_COLS/LINES (90x30) wins over the attached-client stub (199x55)" "90x30" "$T119OV_WINSIZE"
TMUX="/tmp/faketmux,12345,0" tmux kill-session -t "$T119OV_SESSION" 2>/dev/null || true

echo "== issue #119: \$TMUX set but no attached client (empty display-message) falls through to the loud tiled fallback, not a crash =="
T119EMPTY_STUB_DIR="$(mktemp -d)"
# agy review round 1 (PR #123): a real client-less tmux server does NOT
# print nothing for #{client_width}/#{client_height} -- confirmed live, it
# prints a single space + newline. Echoing genuinely nothing here was a
# dishonest mock that masked the bin/orc bug this fix addresses (a bare
# `[ -n "$client_size" ]` treated " " as valid, then parsed empty
# term_cols/term_lines out of it).
cat > "$T119EMPTY_STUB_DIR/tmux" <<STUB
#!/bin/bash
if [ "\$1" = "display-message" ] && [ "\$2" = "-p" ] && [ "\$3" = "#{client_width} #{client_height}" ]; then
  echo " "
  exit 0
fi
exec "$REAL_TMUX" "\$@"
STUB
chmod +x "$T119EMPTY_STUB_DIR/tmux"
T119EMPTY_SESSION="orctest-119empty-$$"
T119EMPTY_TMP="$(mktemp -d)"
(
  cd "$TMP"
  env -u ORC_TERM_COLS -u ORC_TERM_LINES PATH="$T119EMPTY_STUB_DIR:$PATH" TMUX="/tmp/faketmux,12345,0" \
    ORC_SESSION="$T119EMPTY_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" > "$T119EMPTY_TMP/build.out" 2> "$T119EMPTY_TMP/build.err" < /dev/null
)
T119EMPTY_PANE_COUNT="$(TMUX="/tmp/faketmux,12345,0" tmux list-panes -t "$T119EMPTY_SESSION" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "issue #119: empty client-size reading still builds all 5 panes via the loud fallback" "5" "$T119EMPTY_PANE_COUNT"
if grep -qi 'WARNING.*too small' "$T119EMPTY_TMP/build.err" 2>/dev/null; then
  pass "issue #119: no attached-client size + no tty falls back loudly, same as the no-override/no-tty case"
else
  fail "issue #119: expected the loud too-small WARNING when the client-size reading is empty, got: $(cat "$T119EMPTY_TMP/build.err" 2>/dev/null)"
fi
TMUX="/tmp/faketmux,12345,0" tmux kill-session -t "$T119EMPTY_SESSION" 2>/dev/null || true

echo "== fallback sizing self-heals at first attach: one-shot client-attached hook snaps the monitor strip to the weighted branch's absolute monitor_rows =="
# The percent-proportioned fallback rescales unpredictably when the first
# real client attaches (live-hit twice on 2026-07-23: the 25% strip landed
# at 23 of 59 rows and had to be resize-pane'd by hand). The fallback now
# arms a ONE-SHOT client-attached hook -- run-shell -b, because the hook
# fires before tmux rescales the window to the new client, so an inline
# resize would be mangled; a backgrounded shell re-enters the server after
# the attach completes -- that snaps the strip to monitor_rows and unsets
# itself. The attach is driven from a pane of a second throwaway session:
# tmux itself provides the pty this suite doesn't have.
SNAP_SESSION="orctest-snap-$$"
SNAP_OUTER="orctest-snapouter-$$"
SNAP_TMP="$(mktemp -d)"
(
  cd "$TMP"
  env -u ORC_TERM_COLS -u ORC_TERM_LINES -u TMUX TERM=dumb \
    ORC_SESSION="$SNAP_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" > "$SNAP_TMP/build.out" 2> "$SNAP_TMP/build.err" < /dev/null
)
if tmux show-hooks -t "$SNAP_SESSION" 2>/dev/null | grep -q 'client-attached'; then
  pass "fallback build arms the one-shot client-attached snap hook"
else
  fail "fallback build should arm a client-attached hook, show-hooks says: $(tmux show-hooks -t "$SNAP_SESSION" 2>/dev/null)"
fi
tmux new-session -d -s "$SNAP_OUTER" -x 240 -y 60
tmux send-keys -t "$SNAP_OUTER" "TMUX= tmux attach -t $SNAP_SESSION" C-m
SNAP_STRIP=""
SNAP_I=0
while [ "$SNAP_I" -lt 40 ]; do
  SNAP_STRIP="$(tmux display-message -p -t "$SNAP_SESSION:0.3" '#{pane_height}' 2>/dev/null)"
  [ "$SNAP_STRIP" = "14" ] && break
  sleep 0.25
  SNAP_I=$((SNAP_I+1))
done
assert_eq "first real attach snaps the monitor strip to monitor_rows (14)" "14" "$SNAP_STRIP"
SNAP_AGENT="$(tmux display-message -p -t "$SNAP_SESSION:0.0" '#{pane_height}' 2>/dev/null)"
if [ -n "$SNAP_AGENT" ] && [ "$SNAP_AGENT" -ge 15 ]; then
  pass "post-snap agent panes get the rest of the client height (${SNAP_AGENT} rows >= the 15-row min_agent_rows floor)"
else
  fail "post-snap agent panes should be >= 15 rows, got: ${SNAP_AGENT}"
fi
if tmux show-hooks -t "$SNAP_SESSION" 2>/dev/null | grep -q 'client-attached'; then
  fail "the snap hook must unset itself after the first attach (one sizing decision -- never fights later manual tuning)"
else
  pass "the snap hook unset itself after the first attach"
fi
tmux kill-session -t "$SNAP_OUTER" 2>/dev/null || true
tmux kill-session -t "$SNAP_SESSION" 2>/dev/null || true

echo "== agy PR #133 round 1: a hand-set ORC_SESSION outside [A-Za-z0-9_-] is REFUSED before any tmux call (it reaches /bin/sh via the attach-snap hook) =="
# orc_session_name sanitizes every DERIVED name, so only a verbatim
# ORC_SESSION override can carry a space or quote into orc_build_session.
# The hostile value below carries both failure modes agy demonstrated:
# word-splitting (space) and sh-string breakout (single quote).
HOSTILE_NAME="bad name'; echo pwned"
HOSTILE_TMP="$(mktemp -d)"
HOSTILE_RC=0
(
  cd "$TMP"
  ORC_SESSION="$HOSTILE_NAME" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    ORC_TERM_COLS=238 ORC_TERM_LINES=60 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" > "$HOSTILE_TMP/build.out" 2> "$HOSTILE_TMP/build.err"
) || HOSTILE_RC=$?
if [ "$HOSTILE_RC" -ne 0 ]; then
  pass "hostile session name: orc_build_session exits nonzero"
else
  fail "hostile session name: orc_build_session should refuse (exit nonzero), got exit 0"
fi
if grep -qi 'REFUSE' "$HOSTILE_TMP/build.err" 2>/dev/null; then
  pass "hostile session name: REFUSE reported loudly on stderr"
else
  fail "hostile session name: expected a loud REFUSE on stderr, got: $(cat "$HOSTILE_TMP/build.err" 2>/dev/null)"
fi
HOSTILE_SESSIONS="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'bad name' || true)"
assert_eq "hostile session name: no tmux session was created" "0" "$HOSTILE_SESSIONS"

echo "== issue #59: liveness watchdog restart no longer uses nohup (guard.sh correctly fails closed on nohup, which blocked bin/orc's OWN restart drill mid-drill) =="
if grep -v '^[[:space:]]*#' "$DIR/../bin/orc" | grep -q 'nohup'; then
  fail "bin/orc should no longer launch gatekeeper-liveness.sh via nohup (a comment MAY still mention nohup to explain why -- only a live invocation fails this) -- the harness's own restart drill needs an inspectable path, same as the other three loops"
else
  pass "bin/orc no longer uses nohup"
fi

echo "== issue #6: orchestra/builder pane launches go through sl_build_launch_cmd (session lifecycle classification), not a bare hardcoded claude invocation =="
if grep -q 'source "\$ORC_LIB_DIR/session-lifecycle.sh"' "$DIR/../bin/orc"; then
  pass "bin/orc sources lib/session-lifecycle.sh"
else
  fail "expected bin/orc to source lib/session-lifecycle.sh"
fi
if grep -q 'sl_build_launch_cmd orchestra ' "$DIR/../bin/orc" && grep -q 'sl_build_launch_cmd builder ' "$DIR/../bin/orc"; then
  pass "bin/orc builds the orchestra and builder pane launch commands via sl_build_launch_cmd"
else
  fail "expected orc_build_session to call sl_build_launch_cmd for both orchestra and builder"
fi
if grep -qE "send-keys -t \"\\\$session:0\\.0\" \"ORC_ROLE=orchestra claude" "$DIR/../bin/orc"; then
  fail "bin/orc should no longer hardcode a bare ORC_ROLE=orchestra claude launch (issue #6: every launch is classified)"
else
  pass "bin/orc no longer hardcodes a bare unclassified orchestra launch"
fi

echo "== issue #6: orc_build_session, no prior role-session recorded -> pane 0/1 launch commands are classified FRESH =="
CLASS_SESSION="orctest-lifecycle-$$"
CLASS_TMP="$(mktemp -d)"
CLASS_STUB_DIR="$(mktemp -d)"
# A real fake `claude` on PATH so a genuinely-executed launch line (should
# this test ever stop skipping pane commands) never hits a real binary --
# not exercised here (ORC_SKIP_PANE_COMMANDS=1 below), but keeps this test
# self-contained if that ever changes.
cat > "$CLASS_STUB_DIR/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$CLASS_STUB_DIR/claude"
(
  cd "$CLASS_TMP"
  cat > orchestrator.yaml <<'EOF'
project: lifecycle-test-project
roles:
  orchestra:
    model: opus
  implementer:
    model: sonnet
EOF
  PATH="$CLASS_STUB_DIR:$PATH" ORC_SESSION="$CLASS_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; echo \"ORCH_CMD=\$(sl_build_launch_cmd orchestra opus --dangerously-skip-permissions)\"; echo \"BUILD_CMD=\$(sl_build_launch_cmd builder sonnet --dangerously-skip-permissions)\"" > lifecycle.out 2> lifecycle.err
)
ORCH_LINE="$(grep '^ORCH_CMD=' "$CLASS_TMP/lifecycle.out" | sed 's/^ORCH_CMD=//')"
BUILD_LINE="$(grep '^BUILD_CMD=' "$CLASS_TMP/lifecycle.out" | sed 's/^BUILD_CMD=//')"
if echo "$ORCH_LINE" | grep -q 'ORC_SESSION_CLASS=fresh' && echo "$ORCH_LINE" | grep -q -- '--model opus'; then
  pass "a fresh room's orchestra pane launch command is classified FRESH with the right model"
else
  fail "expected orchestra's launch command to be ORC_SESSION_CLASS=fresh --model opus, got: $ORCH_LINE"
fi
if echo "$BUILD_LINE" | grep -q 'ORC_SESSION_CLASS=fresh' && echo "$BUILD_LINE" | grep -q -- '--model sonnet'; then
  pass "a fresh room's builder pane launch command is classified FRESH with the right model"
else
  fail "expected builder's launch command to be ORC_SESSION_CLASS=fresh --model sonnet, got: $BUILD_LINE"
fi
rm -rf "$CLASS_TMP" "$CLASS_STUB_DIR"

echo "== issue #59: liveness watchdog launches via a tmux session, same mechanism as the other three loops =="
LIVE_SESSION="orctest-liveness-$$"
LIVE_TMP="$(mktemp -d)"
(
  cd "$LIVE_TMP"
  cat > orchestrator.yaml <<'EOF'
project: liveness-test-project
EOF
  ORC_SESSION="$LIVE_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
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
  ORC_SESSION="$SKIP_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
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
  ORC_SESSION="$HOOKWIRE_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
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
  PATH="$FAKE_GH_BIN:$PATH" ORC_SESSION="$SEED_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
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
  ORC_SESSION="orctest-seedskip-$$" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$SEED_TMP2/build.err"
)
if [ ! -f "$SEED_TMP2/.harness/merge-watch-state" ]; then
  pass "ORC_SKIP_MERGE_WATCH_SEED=1 skips seeding entirely"
else
  fail "ORC_SKIP_MERGE_WATCH_SEED=1 should have skipped seeding"
fi
tmux kill-session -t "orctest-seedskip-$$" 2>/dev/null || true
rm -rf "$SEED_TMP" "$SEED_TMP2"

echo "== issue #60 task C: orc_build_session refuses/warns on room-branch mismatch =="
rb_mk_repo() {
  local dir
  dir="$(mktemp -d)"
  dir="$(cd "$dir" && pwd -P)"
  git init -q "$dir"
  git -C "$dir" config user.email "test@test.local"
  git -C "$dir" config user.name "test"
  echo "$dir"
}

RB_REFUSE_TMP="$(rb_mk_repo)"
(
  cd "$RB_REFUSE_TMP"
  cat > orchestrator.yaml <<'EOF'
project: rbcheck-mismatch-noover
integration_branch: uat
EOF
  git checkout -q -b uat
  git commit -q --allow-empty -m init
  git checkout -q -b feature/rb-refuse
  ORC_SESSION="orctest-rbrefuse-$$" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$RB_REFUSE_TMP/build.err"
  echo $? > "$RB_REFUSE_TMP/exit.code"
)
assert_eq "mismatch + no override: orc_build_session exits 1" "1" "$(cat "$RB_REFUSE_TMP/exit.code")"
grep -qi "refuse" "$RB_REFUSE_TMP/build.err" && pass "mismatch + no override: REFUSE reported on stderr" || fail "mismatch + no override: expected REFUSE on stderr: $(cat "$RB_REFUSE_TMP/build.err")"
if tmux has-session -t "orctest-rbrefuse-$$" 2>/dev/null; then
  fail "mismatch + no override: no tmux session should have been built"
else
  pass "mismatch + no override: no tmux session was built"
fi
tmux kill-session -t "orctest-rbrefuse-$$" 2>/dev/null || true
rm -rf "$RB_REFUSE_TMP"

RB_ENVOVERRIDE_TMP="$(rb_mk_repo)"
(
  cd "$RB_ENVOVERRIDE_TMP"
  cat > orchestrator.yaml <<'EOF'
project: rb-env-override-test
integration_branch: uat
EOF
  git checkout -q -b uat
  git commit -q --allow-empty -m init
  git checkout -q -b feature/rb-env-override
  ORC_SESSION="orctest-rbenv-$$" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$RB_ENVOVERRIDE_TMP/build.err"
  echo $? > "$RB_ENVOVERRIDE_TMP/exit.code"
)
assert_eq "mismatch + ORC_ALLOW_UNMERGED_HARNESS=1: orc_build_session exits 0" "0" "$(cat "$RB_ENVOVERRIDE_TMP/exit.code")"
grep -qi "warn" "$RB_ENVOVERRIDE_TMP/build.err" && pass "mismatch + env override: loud warning on stderr" || fail "mismatch + env override: expected a warning: $(cat "$RB_ENVOVERRIDE_TMP/build.err")"
if tmux has-session -t "orctest-rbenv-$$" 2>/dev/null; then
  pass "mismatch + env override: tmux session was built (proceeded)"
else
  fail "mismatch + env override: expected orc_build_session to proceed and build the session: $(cat "$RB_ENVOVERRIDE_TMP/build.err")"
fi
tmux kill-session -t "orctest-rbenv-$$" 2>/dev/null || true
rm -rf "$RB_ENVOVERRIDE_TMP"

RB_FILEOVERRIDE_TMP="$(rb_mk_repo)"
(
  cd "$RB_FILEOVERRIDE_TMP"
  cat > orchestrator.yaml <<'EOF'
project: rb-file-override-test
integration_branch: uat
EOF
  git checkout -q -b uat
  git commit -q --allow-empty -m init
  git checkout -q -b feature/rb-file-override
  mkdir -p .harness/state
  echo "approved hotfix, see issue #60" > .harness/state/room-branch-override
  ORC_SESSION="orctest-rbfile-$$" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$RB_FILEOVERRIDE_TMP/build.err"
  echo $? > "$RB_FILEOVERRIDE_TMP/exit.code"
)
assert_eq "mismatch + file override: orc_build_session exits 0" "0" "$(cat "$RB_FILEOVERRIDE_TMP/exit.code")"
grep -q "approved hotfix, see issue #60" "$RB_FILEOVERRIDE_TMP/build.err" && pass "mismatch + file override: reason is surfaced on stderr" || fail "mismatch + file override: expected the override reason on stderr: $(cat "$RB_FILEOVERRIDE_TMP/build.err")"
tmux kill-session -t "orctest-rbfile-$$" 2>/dev/null || true
rm -rf "$RB_FILEOVERRIDE_TMP"

RB_DIRTY_TMP="$(rb_mk_repo)"
(
  cd "$RB_DIRTY_TMP"
  cat > orchestrator.yaml <<'EOF'
project: rbcheck-tracked-mod
integration_branch: uat
EOF
  git checkout -q -b uat
  echo "tracked" > tracked.txt
  git add tracked.txt orchestrator.yaml
  git commit -q -m init
  echo "dirty change" >> tracked.txt
  ORC_SESSION="orctest-rbdirty-$$" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$RB_DIRTY_TMP/build.err"
  echo $? > "$RB_DIRTY_TMP/exit.code"
)
assert_eq "dirty tracked tree on integration branch: orc_build_session exits 0" "0" "$(cat "$RB_DIRTY_TMP/exit.code")"
grep -qi "dirty" "$RB_DIRTY_TMP/build.err" && pass "dirty tracked tree: loud warning on stderr" || fail "dirty tracked tree: expected a warning: $(cat "$RB_DIRTY_TMP/build.err")"
if tmux has-session -t "orctest-rbdirty-$$" 2>/dev/null; then
  pass "dirty tracked tree: tmux session was still built (warn-only, not blocking)"
else
  fail "dirty tracked tree: expected orc_build_session to proceed despite the warning: $(cat "$RB_DIRTY_TMP/build.err")"
fi
tmux kill-session -t "orctest-rbdirty-$$" 2>/dev/null || true
rm -rf "$RB_DIRTY_TMP"

RB_CLEAN_TMP="$(rb_mk_repo)"
(
  cd "$RB_CLEAN_TMP"
  cat > orchestrator.yaml <<'EOF'
project: rb-clean-test
integration_branch: uat
EOF
  git checkout -q -b uat
  git add orchestrator.yaml
  git commit -q -m init
  ORC_SESSION="orctest-rbclean-$$" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> "$RB_CLEAN_TMP/build.err"
  echo $? > "$RB_CLEAN_TMP/exit.code"
)
assert_eq "clean tree on integration branch: orc_build_session exits 0" "0" "$(cat "$RB_CLEAN_TMP/exit.code")"
if grep -qi "room branch\|dirty" "$RB_CLEAN_TMP/build.err"; then
  fail "clean tree on integration branch: no room-branch warning expected: $(cat "$RB_CLEAN_TMP/build.err")"
else
  pass "clean tree on integration branch: no room-branch warning"
fi
tmux kill-session -t "orctest-rbclean-$$" 2>/dev/null || true
rm -rf "$RB_CLEAN_TMP"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
