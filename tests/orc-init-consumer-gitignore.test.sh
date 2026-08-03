#!/bin/bash
# tests/orc-init-consumer-gitignore.test.sh -- issue #171 item 5a: an
# optional CONSUMER_DIR answer writes a WHOLESALE .gitignore entry
# ("<dir>/", NOT "<dir>/*" -- that narrower form would still track the
# directory entry itself and only ignore its contents) for that
# directory into the TARGET project, via `orc init --answers FILE`
# (CONSUMER_DIR as an answers-file key) or `orc init --adopt
# --consumer-dir <path>` (CLI flag, since --adopt doesn't require an
# answers file at all). No CONSUMER_DIR given -> no .gitignore write at
# all -- orc init must never invent a file nobody asked for.
# Run: bash tests/orc-init-consumer-gitignore.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORC="$DIR/../bin/orc"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

base_answers() { # $1 = path -- minimal valid answers file (same required keys tests/orc-init.test.sh uses)
  cat > "$1" <<'EOF'
PROJECT=consumer-gitignore-test
INTEGRATION_BRANCH=main
ROLE_ORCHESTRA_MODEL=opus
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_TESTER_MODEL=sonnet
ROLE_REVIEWER_MODEL=agy
ROLE_SCRIBE_MODEL=haiku
EOF
}

echo "== orc init --answers with CONSUMER_DIR writes a wholesale .gitignore entry (trailing slash, not /*) =="
ANSWERS1="$TMP/answers1.txt"
base_answers "$ANSWERS1"
echo "CONSUMER_DIR=my-app" >> "$ANSWERS1"
TARGET1="$TMP/room1"
OUT1="$(bash "$ORC" init --answers "$ANSWERS1" "$TARGET1" 2>&1)"
STATUS1=$?
if [ "$STATUS1" -ne 0 ]; then
  fail "orc init --answers with CONSUMER_DIR should exit 0, got status=$STATUS1: $OUT1"
fi
if [ -f "$TARGET1/.gitignore" ] && grep -qxF 'my-app/' "$TARGET1/.gitignore"; then
  pass "CONSUMER_DIR=my-app writes 'my-app/' to .gitignore"
else
  fail "expected .gitignore to contain 'my-app/', got: $(cat "$TARGET1/.gitignore" 2>/dev/null || echo '<no file>')"
fi
if grep -qxF 'my-app/*' "$TARGET1/.gitignore" 2>/dev/null; then
  fail ".gitignore should NOT contain the narrower 'my-app/*' form (would still track the dir entry itself)"
else
  pass ".gitignore does not contain the narrower 'my-app/*' form"
fi

echo "== re-running (via --adopt on the same target) is idempotent -- no duplicate line =="
COUNT_BEFORE="$(grep -cxF 'my-app/' "$TARGET1/.gitignore")"
# Plain \`orc init\` refuses on an already-initialized target (see
# tests/orc-init.test.sh's own refusal case) -- that refusal is
# intentional and out of scope here. --adopt is this project's existing
# "run it again" resync path (tests/orc-init-adopt.test.sh), so it's the
# right vehicle to exercise idempotency with the SAME CONSUMER_DIR answer.
bash "$ORC" init --adopt "$TARGET1" --answers "$ANSWERS1" >/dev/null 2>&1
COUNT_AFTER="$(grep -cxF 'my-app/' "$TARGET1/.gitignore")"
if [ "$COUNT_BEFORE" -eq 1 ] && [ "$COUNT_AFTER" -eq 1 ]; then
  pass "re-running with the same CONSUMER_DIR does not duplicate the .gitignore line"
else
  fail "expected exactly 1 occurrence before and after, got before=$COUNT_BEFORE after=$COUNT_AFTER"
fi

echo "== an existing hand-authored .gitignore gets the line appended, not clobbered =="
TARGET2="$TMP/room2"
mkdir -p "$TARGET2"
printf 'node_modules/\n*.log\n' > "$TARGET2/.gitignore"
ANSWERS2="$TMP/answers2.txt"
base_answers "$ANSWERS2"
echo "CONSUMER_DIR=my-app" >> "$ANSWERS2"
bash "$ORC" init --answers "$ANSWERS2" "$TARGET2" >/dev/null 2>&1
if grep -qxF 'node_modules/' "$TARGET2/.gitignore" && grep -qxF '*.log' "$TARGET2/.gitignore" && grep -qxF 'my-app/' "$TARGET2/.gitignore"; then
  pass "existing hand-authored .gitignore content preserved and the new line appended"
else
  fail "expected existing lines preserved + new line appended, got: $(cat "$TARGET2/.gitignore")"
fi

echo "== no CONSUMER_DIR answer -> no .gitignore write at all =="
TARGET3="$TMP/room3"
ANSWERS3="$TMP/answers3.txt"
base_answers "$ANSWERS3"
bash "$ORC" init --answers "$ANSWERS3" "$TARGET3" >/dev/null 2>&1
if [ -f "$TARGET3/.gitignore" ]; then
  fail "no CONSUMER_DIR was given -- .gitignore should not have been created, found: $(cat "$TARGET3/.gitignore")"
else
  pass "no CONSUMER_DIR -> no .gitignore file written"
fi

echo "== orc init --adopt --consumer-dir <path> writes the gitignore entry via the CLI flag (no answers file needed) =="
TARGET4="$TMP/room4"
mkdir -p "$TARGET4"
OUT4="$(bash "$ORC" init --adopt "$TARGET4" --consumer-dir dist-app 2>&1)"
STATUS4=$?
if [ "$STATUS4" -ne 0 ]; then
  fail "orc init --adopt --consumer-dir should exit 0, got status=$STATUS4: $OUT4"
fi
if [ -f "$TARGET4/.gitignore" ] && grep -qxF 'dist-app/' "$TARGET4/.gitignore"; then
  pass "--adopt --consumer-dir dist-app writes 'dist-app/' to .gitignore"
else
  fail "expected .gitignore to contain 'dist-app/', got: $(cat "$TARGET4/.gitignore" 2>/dev/null || echo '<no file>')"
fi

echo "== a leading './' or trailing '/' on CONSUMER_DIR is normalized to a single trailing slash =="
TARGET5="$TMP/room5"
ANSWERS5="$TMP/answers5.txt"
base_answers "$ANSWERS5"
echo "CONSUMER_DIR=./nested-dir/" >> "$ANSWERS5"
bash "$ORC" init --answers "$ANSWERS5" "$TARGET5" >/dev/null 2>&1
if [ -f "$TARGET5/.gitignore" ] && grep -qxF 'nested-dir/' "$TARGET5/.gitignore"; then
  pass "CONSUMER_DIR normalized to 'nested-dir/' regardless of leading ./ or trailing /"
else
  fail "expected .gitignore to contain 'nested-dir/', got: $(cat "$TARGET5/.gitignore" 2>/dev/null || echo '<no file>')"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
