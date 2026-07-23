#!/bin/bash
# tests/orc-protect.test.sh — TDD tests for bin/orc-protect (issue #142,
# guard-layer redesign #141 layer 1). Run: bash tests/orc-protect.test.sh
#
# Enforcement cases need the OS immutability privilege: always present on
# macOS (chflags uchg is owner-settable), absent for unprivileged Linux
# users (chattr +i needs CAP_LINUX_IMMUTABLE — e.g. plain CI runners).
# Those cases SKIP loudly there rather than fake-passing.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BIN="$(cd "$DIR/../bin" && pwd)/orc-protect"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() {
  # clear any flags the tests left on before rm can work
  bash "$BIN" off "$TMP" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- capability probe --------------------------------------------------
probe="$TMP/cap-probe"
touch "$probe"
if [ "$(uname -s)" = Darwin ]; then
  if chflags uchg "$probe" 2>/dev/null; then CAN_FLAG=1; chflags nouchg "$probe"; else CAN_FLAG=0; fi
else
  if chattr +i "$probe" 2>/dev/null; then CAN_FLAG=1; chattr -i "$probe"; else CAN_FLAG=0; fi
fi
rm -f "$probe"

# ---- fixture: a fake project dir --------------------------------------
mkdir -p "$TMP/.claude" "$TMP/.git" "$TMP/secrets"
printf '{}\n' > "$TMP/.claude/settings.json"
printf 'x\n'  > "$TMP/.git/git-writes-here"
printf 's\n'  > "$TMP/secrets/token"
cat > "$TMP/orchestrator.yaml" <<'YAML'
project: orc-protect-probe
protected_paths:
  - .git/
  - secrets/
YAML

echo "== bad usage =="
if ! bash "$BIN" sideways "$TMP" >/dev/null 2>&1; then
  pass "unknown mode exits nonzero"
else
  fail "unknown mode should exit nonzero"
fi
if ! bash "$BIN" status "$TMP/does-not-exist" >/dev/null 2>&1; then
  pass "missing target dir exits nonzero"
else
  fail "missing target dir should exit nonzero"
fi

echo "== .git/ is never a target =="
OUT="$(bash "$BIN" status "$TMP" 2>&1 || true)"
if echo "$OUT" | grep -q "skipping '.git'"; then
  pass ".git protected_paths entry skipped, loudly"
else
  fail "expected a loud .git skip in: $OUT"
fi
if echo "$OUT" | grep -q "skipping '.agents'"; then
  pass "absent .agents/ skipped, loudly, not an error"
else
  fail "expected a loud .agents skip in: $OUT"
fi

echo "== status before any 'on': open, exit 2 =="
bash "$BIN" status "$TMP" >/dev/null 2>&1
if [ $? -eq 2 ]; then
  pass "all-open status exits 2"
else
  fail "all-open status should exit 2"
fi

if [ "$CAN_FLAG" -eq 0 ]; then
  echo "SKIP: no immutability privilege here (unprivileged Linux?) -- enforcement round-trip cases skipped"
else
  echo "== on: kernel denies writes into every target =="
  bash "$BIN" on "$TMP" >/dev/null
  if ! echo x > "$TMP/.claude/settings.json" 2>/dev/null; then
    pass "overwrite inside .claude/ denied while on"
  else
    fail "overwrite inside .claude/ should be denied"
  fi
  if ! echo x > "$TMP/.claude/new-file" 2>/dev/null; then
    pass "create inside .claude/ denied while on"
  else
    fail "create inside .claude/ should be denied"
  fi
  if ! echo x >> "$TMP/orchestrator.yaml" 2>/dev/null; then
    pass "append to orchestrator.yaml denied while on"
  else
    fail "append to orchestrator.yaml should be denied"
  fi
  if ! echo x > "$TMP/secrets/token" 2>/dev/null; then
    pass "protected_paths entry (secrets/) denied while on"
  else
    fail "write into secrets/ should be denied"
  fi
  if echo x > "$TMP/.git/git-writes-here" 2>/dev/null; then
    pass ".git/ stays writable while on (git keeps working)"
  else
    fail ".git/ must stay writable"
  fi

  echo "== status while on: protected, exit 0 =="
  if bash "$BIN" status "$TMP" >/dev/null 2>&1; then
    pass "all-protected status exits 0"
  else
    fail "all-protected status should exit 0"
  fi

  echo "== on is idempotent =="
  if bash "$BIN" on "$TMP" >/dev/null 2>&1; then
    pass "second 'on' run exits 0"
  else
    fail "second 'on' run should exit 0"
  fi

  echo "== off: round-trips back to writable =="
  bash "$BIN" off "$TMP" >/dev/null
  if echo x > "$TMP/.claude/settings.json" 2>/dev/null; then
    pass "overwrite inside .claude/ allowed again after off"
  else
    fail "off should restore writability"
  fi
  bash "$BIN" status "$TMP" >/dev/null 2>&1
  if [ $? -eq 2 ]; then
    pass "post-off status exits 2 again"
  else
    fail "post-off status should exit 2"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
