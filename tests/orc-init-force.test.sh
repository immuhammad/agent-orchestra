#!/bin/bash
# tests/orc-init-force.test.sh -- issue #116: `orc init --force`, the
# re-init/resync story. Plan of record: Orchestra's Gate-1 comment on
# https://github.com/immuhammad/agent-orchestra/issues/116 (semantics of
# --force, drift reconciliation via a sha256 manifest, idempotence).
# Every scratch target is a mktemp dir; nothing here touches this
# checkout's own .claude/ (guard-protected) or orchestrator.yaml.
# Run: bash tests/orc-init-force.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORC="$DIR/../bin/orc"
ORC_BIN_DIR="$(cd "$DIR/../bin" && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
file_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

write_answers() { # $1 = path, stdin = KEY=value lines
  cat > "$1"
}

full_answers() { # $1 = path -- a complete, valid answers file
  write_answers "$1" <<'EOF'
PROJECT=force-test-project
INTEGRATION_BRANCH=main
GITHUB_REMOTE=git@github.com:example/force.git
TICKET_TRACKER=gh-issues
PROTECTED_PATHS=infra/,secrets/
GATE_APPROVER=Ahmad
ROLE_ORCHESTRA_MODEL=opus
ROLE_ORCHESTRA_EFFORT=high
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_IMPLEMENTER_EFFORT=default
ROLE_TESTER_MODEL=sonnet
ROLE_TESTER_EFFORT=default
ROLE_REVIEWER_MODEL=agy
ROLE_REVIEWER_EFFORT=high
ROLE_SCRIBE_MODEL=haiku
ROLE_SCRIBE_EFFORT=low
BUDGET_CLAUDE_PCT=80
BUDGET_AGY_PCT=75
EOF
}

# the manifest-tracked set (bin/orc's orc_init_manifest_targets, mirrored
# here as a plain list so the test doesn't need to source bin/orc)
TRACKED_FILES=(AGENTS.md CLAUDE.md GEMINI.md review-protocol.md \
  souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md \
  .claude/settings.json .agents/hooks.json)

hash_tree() { # $1 = dir -- fingerprint of every tracked file's content+path.
  # cksum (not md5/shasum) is POSIX and ships identically on BSD (macOS) and
  # GNU (Linux CI) -- same portability call lib/watch.sh already made for
  # this kind of non-security change detection.
  local f
  for f in "${TRACKED_FILES[@]}" orchestrator.yaml; do
    [ -f "$1/$f" ] && cksum "$1/$f"
  done | cksum
}

echo "== refuse-without-force is unchanged on an already-initialized target =="
ANSWERS1="$TMP/answers1.txt"
full_answers "$ANSWERS1"
ROOM1="$TMP/room1"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM1" >/dev/null 2>&1
BEFORE_HASH="$(hash_tree "$ROOM1")"
OUT="$(bash "$ORC" init --answers "$ANSWERS1" "$ROOM1" 2>&1)"
STATUS=$?
AFTER_HASH="$(hash_tree "$ROOM1")"
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi "REFUSE" && [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
  pass "bare re-init (no --force) on an initialized target still refuses loudly, unchanged"
else
  fail "expected an unchanged loud REFUSE without --force, got status=$STATUS: $OUT"
fi

echo "== bare --force: clean resync is a true no-op, and running it twice stays a no-op =="
ROOM2="$TMP/room2"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM2" >/dev/null 2>&1
# bash 3.2 (macOS default) has no associative arrays -- parallel indexed
# arrays, aligned by position with TRACKED_FILES, stand in for a map.
BEFORE_HASHES=()
BEFORE_MTIMES=()
i=0
for f in "${TRACKED_FILES[@]}"; do
  BEFORE_HASHES[$i]="$(file_sha256 "$ROOM2/$f")"
  BEFORE_MTIMES[$i]="$(file_mtime "$ROOM2/$f")"
  i=$((i + 1))
done
YAML_BEFORE_HASH="$(file_sha256 "$ROOM2/orchestrator.yaml")"
YAML_BEFORE_MTIME="$(file_mtime "$ROOM2/orchestrator.yaml")"

OUT1="$(bash "$ORC" init --force "$ROOM2" 2>&1)"
STATUS1=$?
OUT2="$(bash "$ORC" init --force "$ROOM2" 2>&1)"
STATUS2=$?

NOOP_OK=1
i=0
for f in "${TRACKED_FILES[@]}"; do
  [ "$(file_sha256 "$ROOM2/$f")" = "${BEFORE_HASHES[$i]}" ] || { NOOP_OK=0; echo "  content changed: $f"; }
  [ "$(file_mtime "$ROOM2/$f")" = "${BEFORE_MTIMES[$i]}" ] || { NOOP_OK=0; echo "  mtime changed: $f"; }
  i=$((i + 1))
done
if [ "$STATUS1" -eq 0 ] && [ "$STATUS2" -eq 0 ] && [ "$NOOP_OK" -eq 1 ]; then
  pass "bare --force run twice with nothing changed touches no file's content or mtime"
else
  fail "expected a byte-identical, mtime-preserving no-op across two --force runs (status1=$STATUS1 status2=$STATUS2): $OUT1 / $OUT2"
fi
if [ ! -d "$ROOM2/.harness/state/init-backups" ]; then
  pass "no backup directory was created when nothing was drifted"
else
  fail "a backup directory appeared even though nothing was hand-edited: $(ls "$ROOM2/.harness/state/init-backups")"
fi
if [ "$(file_sha256 "$ROOM2/orchestrator.yaml")" = "$YAML_BEFORE_HASH" ] && [ "$(file_mtime "$ROOM2/orchestrator.yaml")" = "$YAML_BEFORE_MTIME" ]; then
  pass "orchestrator.yaml is untouched (content+mtime) across bare --force runs"
else
  fail "orchestrator.yaml should be completely out of scope for bare --force"
fi

echo "== hand-edited AGENTS.md: --force backs it up (loud), then overwrites with the current template =="
ROOM3="$TMP/room3"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM3" >/dev/null 2>&1
ORIGINAL_AGENTS="$(cat "$ROOM3/AGENTS.md")"
printf '\n\nHAND-EDITED LINE, NOT FROM ANY TEMPLATE\n' >> "$ROOM3/AGENTS.md"
HANDEDITED_AGENTS="$(cat "$ROOM3/AGENTS.md")"
OUT="$(bash "$ORC" init --force "$ROOM3" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -qi "DRIFT BACKUP" && echo "$OUT" | grep -q "AGENTS.md"; then
  pass "--force prints a loud drift-backup notice naming AGENTS.md"
else
  fail "expected a loud DRIFT BACKUP notice for AGENTS.md, got status=$STATUS: $OUT"
fi
BACKUP_FILE="$(find "$ROOM3/.harness/state/init-backups" -name AGENTS.md 2>/dev/null | head -1)"
if [ -n "$BACKUP_FILE" ] && [ "$(cat "$BACKUP_FILE")" = "$HANDEDITED_AGENTS" ]; then
  pass "the hand-edited AGENTS.md content was preserved verbatim in the backup"
else
  fail "expected a backup of the hand-edited AGENTS.md under .harness/state/init-backups/"
fi
if [ "$(cat "$ROOM3/AGENTS.md")" = "$ORIGINAL_AGENTS" ]; then
  pass "the live AGENTS.md was overwritten back to the current template's rendering"
else
  fail "the live AGENTS.md should match the fresh template render after --force"
fi

echo "== .harness/ is provably untouched (content+mtime) across a --force =="
ROOM4="$TMP/room4"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM4" >/dev/null 2>&1
echo "custom handoff content, not a template" > "$ROOM4/.harness/handoff.md"
echo "2026-07-24|builder|sonnet|a decision that must survive --force" >> "$ROOM4/.harness/decisions.log"
echo "- a soft rule that must survive --force" > "$ROOM4/.harness/rules.md"
mkdir -p "$ROOM4/.harness/inbox/builder"
echo "BUILD: something in flight, must survive --force" > "$ROOM4/.harness/inbox/builder/20260101000000-1.msg"
HARNESS_FILES=(handoff.md decisions.log rules.md inbox/builder/20260101000000-1.msg)
H_BEFORE=()
M_BEFORE=()
i=0
for f in "${HARNESS_FILES[@]}"; do
  H_BEFORE[$i]="$(file_sha256 "$ROOM4/.harness/$f")"
  M_BEFORE[$i]="$(file_mtime "$ROOM4/.harness/$f")"
  i=$((i + 1))
done
# hand-edit a tracked file too, so this --force run actually does work
# (not just a no-op that trivially never opens .harness/ either way)
printf '\nanother hand edit\n' >> "$ROOM4/CLAUDE.md"
bash "$ORC" init --force "$ROOM4" >/dev/null 2>&1
HARNESS_OK=1
i=0
for f in "${HARNESS_FILES[@]}"; do
  [ "$(file_sha256 "$ROOM4/.harness/$f")" = "${H_BEFORE[$i]}" ] || { HARNESS_OK=0; echo "  content changed: .harness/$f"; }
  [ "$(file_mtime "$ROOM4/.harness/$f")" = "${M_BEFORE[$i]}" ] || { HARNESS_OK=0; echo "  mtime changed: .harness/$f"; }
  i=$((i + 1))
done
if [ "$HARNESS_OK" -eq 1 ]; then
  pass "handoff.md, decisions.log, rules.md, and a live inbox .msg are byte- and mtime-identical across --force"
else
  fail "--force must never touch pre-existing .harness/ content"
fi

echo "== orchestrator.yaml: preserved on bare --force, rewritten with an explicit --answers file =="
ROOM5="$TMP/room5"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM5" >/dev/null 2>&1
BARE_YAML_BEFORE="$(cat "$ROOM5/orchestrator.yaml")"
bash "$ORC" init --force "$ROOM5" >/dev/null 2>&1
if [ "$(cat "$ROOM5/orchestrator.yaml")" = "$BARE_YAML_BEFORE" ]; then
  pass "bare --force leaves orchestrator.yaml exactly as it was"
else
  fail "bare --force must never rewrite orchestrator.yaml"
fi
ANSWERS2="$TMP/answers2.txt"
write_answers "$ANSWERS2" <<'EOF'
PROJECT=force-test-project-RENAMED
INTEGRATION_BRANCH=main
TICKET_TRACKER=gh-issues
GATE_APPROVER=Ahmad
ROLE_ORCHESTRA_MODEL=opus
ROLE_ORCHESTRA_EFFORT=high
ROLE_IMPLEMENTER_MODEL=sonnet
ROLE_IMPLEMENTER_EFFORT=default
ROLE_TESTER_MODEL=sonnet
ROLE_TESTER_EFFORT=default
ROLE_REVIEWER_MODEL=agy
ROLE_REVIEWER_EFFORT=high
ROLE_SCRIBE_MODEL=haiku
ROLE_SCRIBE_EFFORT=low
BUDGET_CLAUDE_PCT=90
BUDGET_AGY_PCT=90
EOF
bash "$ORC" init --force --answers "$ANSWERS2" "$ROOM5" >/dev/null 2>&1
if grep -q 'project: force-test-project-RENAMED' "$ROOM5/orchestrator.yaml" \
  && grep -q 'failsafe_pct: 90' "$ROOM5/orchestrator.yaml"; then
  pass "--force --answers FILE fully rewrites orchestrator.yaml from the new answers"
else
  fail "--force --answers should rewrite orchestrator.yaml, got: $(cat "$ROOM5/orchestrator.yaml")"
fi

echo "== missing manifest (pre-#116 project): every tracked file is conservatively treated as drifted =="
ROOM6="$TMP/room6"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM6" >/dev/null 2>&1
BEFORE_AGENTS="$(cat "$ROOM6/AGENTS.md")"
rm -f "$ROOM6/.harness/state/init-manifest"
OUT="$(bash "$ORC" init --force "$ROOM6" 2>&1)"
STATUS=$?
MISSING_MANIFEST_OK=1
for f in "${TRACKED_FILES[@]}"; do
  echo "$OUT" | grep -q "$f" || { MISSING_MANIFEST_OK=0; echo "  no backup notice for: $f"; }
done
if [ "$STATUS" -eq 0 ] && [ "$MISSING_MANIFEST_OK" -eq 1 ]; then
  pass "a missing manifest backs up every tracked file conservatively, none skipped"
else
  fail "expected every tracked file backed up on a missing manifest, got status=$STATUS: $OUT"
fi
if [ "$(cat "$ROOM6/AGENTS.md")" = "$BEFORE_AGENTS" ]; then
  pass "content is unchanged even when conservatively treated as drifted (nothing was actually hand-edited)"
else
  fail "AGENTS.md content should still match the template even on the conservative path"
fi
if [ -f "$ROOM6/.harness/state/init-manifest" ]; then
  pass "a fresh manifest is written after the conservative --force run, for next time"
else
  fail "expected --force to (re)write the manifest even after a missing-manifest run"
fi

echo "== orc-protect'd room: --force lifts and restores immutability around the resync =="
ROOM7="$TMP/room7"
bash "$ORC" init --answers "$ANSWERS1" "$ROOM7" >/dev/null 2>&1
bash "$ORC_BIN_DIR/orc-protect" on "$ROOM7" >/dev/null 2>&1
OUT="$(bash "$ORC" init --force "$ROOM7" 2>&1)"
STATUS=$?
bash "$ORC_BIN_DIR/orc-protect" status "$ROOM7" >/dev/null 2>&1
STILL_PROTECTED=$?
if [ "$STATUS" -eq 0 ] && [ "$STILL_PROTECTED" -eq 0 ]; then
  pass "--force resyncs an orc-protect'd room without error and re-protects it afterward"
else
  fail "expected --force to lift+restore orc-protect cleanly, got status=$STATUS still-protected-exit=$STILL_PROTECTED: $OUT"
fi
bash "$ORC_BIN_DIR/orc-protect" off "$ROOM7" >/dev/null 2>&1 || true

echo "== --force on a target with no orchestrator.yaml at all refuses (it resyncs, it doesn't create) =="
OUT="$(bash "$ORC" init --force "$TMP/never-initialized" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && echo "$OUT" | grep -qi "REFUSE"; then
  pass "--force on a never-initialized target refuses loudly instead of creating one"
else
  fail "expected a loud REFUSE for --force on an uninitialized target, got status=$STATUS: $OUT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
