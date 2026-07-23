#!/bin/bash
# tests/orc-rule.test.sh — TDD tests for bin/orc-rule + the session-start
# rules surfacing (issue #144, #141 layer 4). Run: bash tests/orc-rule.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BIN="$(cd "$DIR/../bin" && pwd)/orc-rule"
HOOK="$(cd "$DIR/../hooks" && pwd)/session-start.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

RULES="$TMP/rules.md"

echo "== append: creates file with header + first rule =="
ORC_RULES_FILE="$RULES" bash "$BIN" "never re-ask permission on a dispatched .msg" >/dev/null
if head -1 "$RULES" | grep -q '^# RULES'; then
  pass "header written on first append"
else
  fail "expected a # RULES header, got: $(head -1 "$RULES" 2>/dev/null)"
fi
if grep -q '^- [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}: never re-ask permission on a dispatched .msg$' "$RULES"; then
  pass "rule line date-stamped and appended"
else
  fail "rule line malformed: $(grep '^- ' "$RULES")"
fi

echo "== append: second call appends, header not duplicated =="
ORC_RULES_FILE="$RULES" bash "$BIN" "use absolute paths in dispatch calls" >/dev/null
if [ "$(grep -c '^# RULES' "$RULES")" -eq 1 ] && [ "$(grep -c '^- ' "$RULES")" -eq 2 ]; then
  pass "2 rules, 1 header"
else
  fail "expected 2 rules 1 header, got $(grep -c '^- ' "$RULES") rules $(grep -c '^# RULES' "$RULES") headers"
fi

echo "== refuse: empty and multi-line rules =="
if ! ORC_RULES_FILE="$RULES" bash "$BIN" >/dev/null 2>&1; then
  pass "empty rule refused"
else
  fail "empty rule should exit nonzero"
fi
if ! ORC_RULES_FILE="$RULES" bash "$BIN" $'line one\nline two' >/dev/null 2>&1; then
  pass "multi-line rule refused"
else
  fail "multi-line rule should exit nonzero"
fi
if [ "$(grep -c '^- ' "$RULES")" -eq 2 ]; then
  pass "refused calls appended nothing"
else
  fail "file grew on refused input"
fi

echo "== lock: released after a normal run; concurrent appends both land =="
if [ ! -d "$RULES.lock" ]; then
  pass "lock dir released"
else
  fail "lock dir left behind"
fi
(ORC_RULES_FILE="$RULES" bash "$BIN" "concurrent A" >/dev/null) &
A=$!
(ORC_RULES_FILE="$RULES" bash "$BIN" "concurrent B" >/dev/null) &
B=$!
wait "$A" "$B"
if grep -q 'concurrent A' "$RULES" && grep -q 'concurrent B' "$RULES"; then
  pass "both concurrent appends landed"
else
  fail "lost a concurrent append: $(grep '^- ' "$RULES")"
fi

echo "== session-start: surfaces rules in additionalContext =="
# Run the hook from a scratch project dir holding a .harness/rules.md.
PROJ="$TMP/proj"
mkdir -p "$PROJ/.harness"
ORC_RULES_FILE="$PROJ/.harness/rules.md" bash "$BIN" "surfaced rule alpha" >/dev/null
CTX="$(cd "$PROJ" && printf '{}' | ORC_ONESHOT=0 bash "$HOOK" | jq -r '.additionalContext')"
if echo "$CTX" | grep -q 'surfaced rule alpha'; then
  pass "rule text present in additionalContext"
else
  fail "rule text missing from: ${CTX:0:200}"
fi
if echo "$CTX" | grep -q 'guidance not enforcement'; then
  pass "surfacing labels rules as guidance, not enforcement"
else
  fail "guidance label missing"
fi

echo "== session-start: no rules file, no RULES section =="
PROJ2="$TMP/proj2"
mkdir -p "$PROJ2/.harness"
CTX2="$(cd "$PROJ2" && printf '{}' | bash "$HOOK" | jq -r '.additionalContext')"
if ! echo "$CTX2" | grep -q 'RULES (append-only'; then
  pass "absent rules file stays silent"
else
  fail "RULES section should not appear without a rules file"
fi

echo "== session-start: cap surfaces newest 40 with a loud note =="
PROJ3="$TMP/proj3"
mkdir -p "$PROJ3/.harness"
for i in $(seq 1 45); do
  ORC_RULES_FILE="$PROJ3/.harness/rules.md" bash "$BIN" "rule number $i" >/dev/null
done
CTX3="$(cd "$PROJ3" && printf '{}' | bash "$HOOK" | jq -r '.additionalContext')"
if echo "$CTX3" | grep -q 'rule number 45' && ! echo "$CTX3" | grep -q 'rule number 1$' && echo "$CTX3" | grep -q 'newest 40 of 45'; then
  pass "cap keeps newest, drops oldest, says so"
else
  fail "cap behavior wrong (has45=$(echo "$CTX3" | grep -c 'rule number 45') has1=$(echo "$CTX3" | grep -c 'rule number 1$') note=$(echo "$CTX3" | grep -c 'newest 40 of 45'))"
fi

echo "== session-start: ORC_ONESHOT stays minimal (no rules briefing) =="
CTX4="$(cd "$PROJ3" && printf '{}' | ORC_ONESHOT=1 bash "$HOOK")"
if [ "$CTX4" = '{}' ]; then
  pass "one-shot spawn gets no rules context"
else
  fail "one-shot output should be bare {}: $CTX4"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
