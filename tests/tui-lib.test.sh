#!/bin/bash
# .harness/tui-lib.test.sh — tests for T33 (issue #77) shared TUI helpers.
# Run: bash .harness/tui-lib.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB="$DIR/tui-lib.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=./tui-lib.sh
source "$LIB"

echo "== tui_color_enabled: false when stdout is not a tty (this test's own invocation) =="
if tui_color_enabled; then
  fail "expected tui_color_enabled to be false under command substitution/redirection"
else
  pass "tui_color_enabled correctly false outside a tty"
fi

echo "== tui_color_enabled: false when NO_COLOR is set, even if forced =="
OUT="$(NO_COLOR=1 bash -c "source '$LIB'; tui_color_enabled" </dev/null 2>&1; echo "exit:$?")"
if echo "$OUT" | grep -q "exit:1"; then
  pass "NO_COLOR=1 makes tui_color_enabled false"
else
  fail "expected tui_color_enabled to fail under NO_COLOR=1, got: $OUT"
fi

echo "== tui_green/tui_red/tui_bold: plain text passthrough outside a tty (no stray escape codes) =="
OUT="$(tui_green "hello")"
if [ "$OUT" = "hello" ]; then
  pass "tui_green passes text through unmodified outside a tty"
else
  fail "expected plain 'hello', got: $(printf '%q' "$OUT")"
fi

OUT="$(tui_red "world")"
if [ "$OUT" = "world" ]; then
  pass "tui_red passes text through unmodified outside a tty"
else
  fail "expected plain 'world', got: $(printf '%q' "$OUT")"
fi

echo "== tui_traffic_light: thresholds (green <60, yellow 60-79, red >=80) pass text through plainly outside a tty =="
if [ "$(tui_traffic_light 10 "10%")" = "10%" ]; then pass "traffic light 10% (green zone) passthrough"; else fail "traffic light 10% mismatch"; fi
if [ "$(tui_traffic_light 65 "65%")" = "65%" ]; then pass "traffic light 65% (yellow zone) passthrough"; else fail "traffic light 65% mismatch"; fi
if [ "$(tui_traffic_light 80 "80%")" = "80%" ]; then pass "traffic light 80% (red zone) passthrough"; else fail "traffic light 80% mismatch"; fi
if [ "$(tui_traffic_light 99 "99%")" = "99%" ]; then pass "traffic light 99% (red zone) passthrough"; else fail "traffic light 99% mismatch"; fi

echo "== tui_clear: does not emit anything (and does not error) outside a tty =="
OUT="$(tui_clear)"
if [ -z "$OUT" ]; then
  pass "tui_clear is a no-op outside a tty"
else
  fail "expected no output from tui_clear outside a tty, got: $(printf '%q' "$OUT")"
fi

echo "== tui_section: contains the title text, plain, outside a tty =="
OUT="$(tui_section "QUOTA")"
if echo "$OUT" | grep -q "QUOTA"; then
  pass "tui_section includes the section title"
else
  fail "expected section title in output, got: $OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
