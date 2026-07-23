#!/bin/bash
# tests/session-lifecycle.test.sh -- issue #6: lib/session-lifecycle.sh's
# per-role session registry (sl_read/write_role_session) and the pure
# launch-command builder (sl_build_launch_cmd) that decides
# fresh/resumed/rebuilt at pane-launch time. Run: bash tests/session-lifecycle.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$DIR/../lib/session-lifecycle.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

export ROLE_SESSION_DIR="$SCRATCH/state/role-session"
source "$LIB"

echo "== sl_role_session_file: path shape =="
if [ "$(sl_role_session_file builder)" = "$ROLE_SESSION_DIR/builder" ]; then
  pass "sl_role_session_file builds ROLE_SESSION_DIR/<role>"
else
  fail "expected $ROLE_SESSION_DIR/builder, got $(sl_role_session_file builder)"
fi

echo "== sl_read_role_session: no file recorded -> empty, exit 0 =="
GOT="$(sl_read_role_session orchestra)"
STATUS=$?
if [ -z "$GOT" ] && [ "$STATUS" -eq 0 ]; then
  pass "no prior session -> empty read, not an error"
else
  fail "expected empty/0, got '$GOT'/$STATUS"
fi

echo "== sl_write_role_session / sl_read_role_session: round-trip =="
sl_write_role_session builder "sess-abc-123"
GOT="$(sl_read_role_session builder)"
if [ "$GOT" = "sess-abc-123" ]; then
  pass "write then read round-trips the session_id"
else
  fail "expected 'sess-abc-123', got '$GOT'"
fi

echo "== sl_write_role_session: a later write overwrites the earlier one =="
sl_write_role_session builder "sess-def-456"
GOT="$(sl_read_role_session builder)"
if [ "$GOT" = "sess-def-456" ]; then
  pass "second write overwrites the first (latest sid wins)"
else
  fail "expected 'sess-def-456', got '$GOT'"
fi

echo "== sl_write_role_session: creates ROLE_SESSION_DIR if missing =="
rm -rf "$SCRATCH/state"
sl_write_role_session orchestra "sess-fresh-dir"
if [ "$(sl_read_role_session orchestra)" = "sess-fresh-dir" ]; then
  pass "sl_write_role_session mkdir -p's its own parent directory"
else
  fail "expected write to succeed after removing ROLE_SESSION_DIR"
fi

echo "== sl_read_role_session: a whitespace-only file reads as 'no sid' (never rebuilt off garbage) =="
mkdir -p "$ROLE_SESSION_DIR"
printf '   \n' > "$ROLE_SESSION_DIR/agy"
GOT="$(sl_read_role_session agy)"
if [ -z "$GOT" ]; then
  pass "whitespace-only session file reads as empty"
else
  fail "expected empty for a whitespace-only file, got '$GOT'"
fi

echo "== sl_write_role_session: empty session_id is a no-op =="
rm -f "$ROLE_SESSION_DIR/nosid"
sl_write_role_session nosid ""
if [ ! -e "$ROLE_SESSION_DIR/nosid" ]; then
  pass "an empty session_id never creates a role-session file"
else
  fail "expected no file to be written for an empty session_id"
fi

echo "== sl_build_launch_cmd: no prior session -> FRESH launch, no --resume =="
rm -rf "$ROLE_SESSION_DIR"
CMD="$(sl_build_launch_cmd builder sonnet --dangerously-skip-permissions)"
case "$CMD" in
  *'ORC_SESSION_CLASS=fresh'*) pass "fresh command exports ORC_SESSION_CLASS=fresh" ;;
  *) fail "expected ORC_SESSION_CLASS=fresh in: $CMD" ;;
esac
case "$CMD" in
  *'SESSION FRESH'*) pass "fresh command echoes a SESSION FRESH banner" ;;
  *) fail "expected a SESSION FRESH banner in: $CMD" ;;
esac
case "$CMD" in
  *'--resume'*) fail "fresh command should never mention --resume: $CMD" ;;
  *) pass "fresh command has no --resume attempt" ;;
esac
case "$CMD" in
  *'ORC_ROLE=builder'*'--model sonnet'*'--dangerously-skip-permissions'*) pass "fresh command carries role/model/flags through" ;;
  *) fail "expected role/model/flags in: $CMD" ;;
esac

echo "== sl_build_launch_cmd: prior session recorded -> attempts RESUME, with a REBUILT fallback wired in =="
sl_write_role_session builder "sid-777"
CMD="$(sl_build_launch_cmd builder sonnet --dangerously-skip-permissions)"
case "$CMD" in
  *'--resume sid-777'*) pass "resume-attempt command targets the recorded session_id" ;;
  *) fail "expected '--resume sid-777' in: $CMD" ;;
esac
case "$CMD" in
  *'ORC_SESSION_CLASS=resumed'*) pass "the attempt itself is optimistically tagged resumed" ;;
  *) fail "expected ORC_SESSION_CLASS=resumed in: $CMD" ;;
esac
case "$CMD" in
  *'ORC_SESSION_CLASS=rebuilt'*) pass "a fallback path tagged rebuilt is present" ;;
  *) fail "expected ORC_SESSION_CLASS=rebuilt fallback in: $CMD" ;;
esac
case "$CMD" in
  *'REBUILT'*) pass "a loud REBUILT banner is present" ;;
  *) fail "expected a REBUILT banner in: $CMD" ;;
esac
case "$CMD" in
  *'NOT auto-relaunching'*) pass "a late/normal exit path that refuses to auto-relaunch is present" ;;
  *) fail "expected the normal-exit non-relaunch path in: $CMD" ;;
esac

echo "== agy PR #135 round 1: a tampered/malformed role-session file must NOT reach the generated shell command unvalidated (injection) =="
sl_write_role_session builder "sid-ok"
# Overwrite the file directly with an injection payload, bypassing
# sl_write_role_session entirely -- exactly the "file tampered with"
# threat agy's finding describes.
printf '%s' 'sid-1; touch /tmp/PWNED-session-lifecycle-test' > "$(sl_role_session_file builder)"
GOT="$(sl_read_role_session builder)"
if [ -z "$GOT" ]; then
  pass "sl_read_role_session rejects a sid containing shell metacharacters, returns empty"
else
  fail "SECURITY: sl_read_role_session should reject an unsafe sid, got: '$GOT'"
fi
CMD="$(sl_build_launch_cmd builder sonnet --dangerously-skip-permissions)"
case "$CMD" in
  *'touch /tmp/PWNED'*) fail "SECURITY: the injection payload reached the generated launch command: $CMD" ;;
  *) pass "an unsafe sid never reaches the generated launch command" ;;
esac
case "$CMD" in
  *'ORC_SESSION_CLASS=fresh'*) pass "an unsafe/rejected sid falls back to a FRESH launch, not a broken --resume" ;;
  *) fail "expected a fresh fallback when the recorded sid is rejected, got: $CMD" ;;
esac
rm -f /tmp/PWNED-session-lifecycle-test

echo "== sl_read_role_session: accepts a genuine UUID-shaped session_id =="
sl_write_role_session builder "a1b2c3d4-e5f6-4789-a012-b3c4d5e6f789"
if [ "$(sl_read_role_session builder)" = "a1b2c3d4-e5f6-4789-a012-b3c4d5e6f789" ]; then
  pass "a genuine UUID session_id round-trips unchanged"
else
  fail "expected a valid UUID sid to round-trip, got: $(sl_read_role_session builder)"
fi

echo "== sl_read_role_session: rejects other shell-meaningful characters individually (backtick, \$, |, &, quotes) =="
for payload in 'sid`x`' 'sid$x' 'sid|x' 'sid&x' 'sid"x' "sid'x"; do
  printf '%s' "$payload" > "$(sl_role_session_file builder)"
  if [ -n "$(sl_read_role_session builder)" ]; then
    fail "SECURITY: expected '$payload' to be rejected as an unsafe sid"
  else
    pass "rejected unsafe sid payload: $payload"
  fi
done

echo "== sl_build_launch_cmd: syntactically valid shell (bash -n on the generated command) =="
if bash -n <<< "$CMD" 2>/tmp/sl-synerr; then
  pass "generated resume-attempt command is syntactically valid shell"
else
  fail "generated command has a syntax error: $(cat /tmp/sl-synerr)"
fi
FRESH_CMD="$(rm -rf "$ROLE_SESSION_DIR"; sl_build_launch_cmd orchestra opus --dangerously-skip-permissions)"
if bash -n <<< "$FRESH_CMD" 2>/tmp/sl-synerr; then
  pass "generated fresh command is syntactically valid shell"
else
  fail "generated fresh command has a syntax error: $(cat /tmp/sl-synerr)"
fi
rm -f /tmp/sl-synerr

# -- functional: actually EXECUTE the generated command against a fake
# `claude` binary on PATH, so the resume/fallback/no-relaunch behavior is
# proven at runtime, not just asserted as string shape. Each fake claude
# invocation appends one line to CALLS_LOG: "<ORC_SESSION_CLASS> <args...>".
FAKE_BIN="$SCRATCH/fakebin"
mkdir -p "$FAKE_BIN"
CALLS_LOG="$SCRATCH/calls.log"

echo "== functional: resume attempt exits FAST (0s < window) -> exactly one fallback call tagged rebuilt =="
: > "$CALLS_LOG"
cat > "$FAKE_BIN/claude" <<EOF
#!/bin/bash
echo "\${ORC_SESSION_CLASS:-unset} \$*" >> "$CALLS_LOG"
case "\$*" in
  *--resume*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_BIN/claude"
sl_write_role_session builder "sid-fail-fast"
CMD="$(SL_RESUME_FAIL_WINDOW_S=10 sl_build_launch_cmd builder sonnet --dangerously-skip-permissions)"
PATH="$FAKE_BIN:$PATH" bash -c "$CMD" >/dev/null 2>&1
CALL_COUNT="$(wc -l < "$CALLS_LOG" | tr -d ' ')"
if [ "$CALL_COUNT" -eq 2 ]; then
  pass "fast resume failure invokes claude exactly twice (resume attempt + fresh fallback)"
else
  fail "expected 2 claude invocations, got $CALL_COUNT: $(cat "$CALLS_LOG")"
fi
if grep -q '^resumed .*--resume sid-fail-fast' "$CALLS_LOG"; then
  pass "first call was the resume attempt, tagged resumed"
else
  fail "expected a resumed --resume call, got: $(cat "$CALLS_LOG")"
fi
if grep -q '^rebuilt ' "$CALLS_LOG"; then
  pass "second call is the fallback, tagged rebuilt"
else
  fail "expected a rebuilt fallback call, got: $(cat "$CALLS_LOG")"
fi
if grep -q -- '--resume' <<< "$(grep '^rebuilt ' "$CALLS_LOG")"; then
  fail "the rebuilt fallback call should NOT itself pass --resume"
else
  pass "the rebuilt fallback launches plain (no --resume)"
fi

echo "== functional: resume attempt SUCCEEDS (exit 0) -> no fallback, exactly one call tagged resumed =="
: > "$CALLS_LOG"
cat > "$FAKE_BIN/claude" <<EOF
#!/bin/bash
echo "\${ORC_SESSION_CLASS:-unset} \$*" >> "$CALLS_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/claude"
CMD="$(SL_RESUME_FAIL_WINDOW_S=10 sl_build_launch_cmd builder sonnet --dangerously-skip-permissions)"
PATH="$FAKE_BIN:$PATH" bash -c "$CMD" >/dev/null 2>&1
CALL_COUNT="$(wc -l < "$CALLS_LOG" | tr -d ' ')"
if [ "$CALL_COUNT" -eq 1 ]; then
  pass "a successful resume attempt never triggers a fallback launch"
else
  fail "expected exactly 1 claude invocation on success, got $CALL_COUNT: $(cat "$CALLS_LOG")"
fi
if grep -q '^resumed ' "$CALLS_LOG"; then
  pass "the sole call is tagged resumed"
else
  fail "expected the sole call tagged resumed, got: $(cat "$CALLS_LOG")"
fi

echo "== functional: resume runs PAST the fail window then exits non-zero -> normal end, NOT auto-relaunched =="
: > "$CALLS_LOG"
cat > "$FAKE_BIN/claude" <<EOF
#!/bin/bash
echo "\${ORC_SESSION_CLASS:-unset} \$*" >> "$CALLS_LOG"
case "\$*" in
  *--resume*) sleep 2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_BIN/claude"
CMD="$(SL_RESUME_FAIL_WINDOW_S=1 sl_build_launch_cmd builder sonnet --dangerously-skip-permissions)"
OUT="$(PATH="$FAKE_BIN:$PATH" bash -c "$CMD" 2>&1)"
CALL_COUNT="$(wc -l < "$CALLS_LOG" | tr -d ' ')"
if [ "$CALL_COUNT" -eq 1 ]; then
  pass "a resume that ran past the fail window is never auto-relaunched"
else
  fail "expected exactly 1 claude invocation (no relaunch), got $CALL_COUNT: $(cat "$CALLS_LOG")"
fi
if echo "$OUT" | grep -q "NOT auto-relaunching"; then
  pass "a late exit is explained, not silent"
else
  fail "expected the NOT auto-relaunching message, got: $OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
