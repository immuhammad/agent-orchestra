#!/bin/bash
# tests/orc-rehydrate.test.sh — tests for `orc rehydrate` (issue #185,
# P0 live incident 2026-08-03): the #171 untracking migration (`git rm
# --cached orchestrator.yaml souls/*.md`, merged via PR #184) is correct
# for the COMMITTER's own checkout, but a PULLER of that commit gets
# both paths outright DELETED from its working tree by `git pull` --
# orchestrator.yaml is the marker file every fail-closed gate resolves
# the project root from, so a puller with nothing rehydrating it bricks
# the room on every subsequent tool call. This is the review-class gap
# the #184 review missed: it verified the COMMITTER's checkout and new-
# worktree hydration, never the PULLER path.
#
# Run: bash tests/orc-rehydrate.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORC="$DIR/../bin/orc"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git_id() { git -C "$1" config user.email t@t.local; git -C "$1" config user.name t; }

# mk_pre_migration_repo -- an UPSTREAM repo shaped like this project
# before #171: orchestrator.yaml + souls/*.md TRACKED at the tip.
mk_pre_migration_repo() {
  local dir
  dir="$(mktemp -d -p "$TMP")"
  git init -q "$dir"
  git_id "$dir"
  printf 'project: puller-test\nintegration_branch: main\n' > "$dir/orchestrator.yaml"
  mkdir -p "$dir/souls"
  printf 'builder soul card\n' > "$dir/souls/builder.md"
  printf 'orchestra soul card\n' > "$dir/souls/orchestra.md"
  git -C "$dir" checkout -q -b main
  git -C "$dir" add orchestrator.yaml souls
  git -C "$dir" commit -q -m "pre-migration: tracked config"
  echo "$dir"
}

echo "== puller simulation: git pull of the untracking commit deletes both paths from the working tree (reproduces the live bug) =="
UPSTREAM="$(mk_pre_migration_repo)"
PULLER="$(mktemp -d -p "$TMP")"
git clone -q "$UPSTREAM" "$PULLER" 2>/dev/null
# Snapshot pre-deletion content to diff against after rehydrate.
ORIG_YAML="$PULLER/orchestrator.yaml"; cp "$ORIG_YAML" "$TMP/orig-orchestrator.yaml"
cp "$PULLER/souls/builder.md" "$TMP/orig-builder.md"
cp "$PULLER/souls/orchestra.md" "$TMP/orig-orchestra.md"

# The migration lands upstream: git rm --cached (committer's own working
# tree keeps the physical file -- this is the design #184 endorsed).
git -C "$UPSTREAM" rm -q --cached orchestrator.yaml souls/builder.md souls/orchestra.md
git -C "$UPSTREAM" commit -q -m "untrack orchestrator.yaml/souls (#171)"

# The puller pulls: for THEM (no local modifications, clean fast-forward)
# this is a plain deletion of both paths from the working tree.
git -C "$PULLER" pull -q origin main 2>/dev/null

if [ ! -f "$PULLER/orchestrator.yaml" ] && [ ! -f "$PULLER/souls/builder.md" ] && [ ! -f "$PULLER/souls/orchestra.md" ]; then
  pass "bug reproduced: git pull of the untracking commit deletes orchestrator.yaml + souls/*.md from a puller's working tree"
else
  fail "expected the puller's working tree to lose orchestrator.yaml + souls/*.md after pulling the untracking commit"
fi

OUT="$(bash "$ORC" rehydrate "$PULLER" 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] && pass "orc rehydrate exits 0 on a puller with real tracked history" || fail "orc rehydrate should exit 0, got $STATUS: $OUT"
echo "$OUT" | grep -q 'restored orchestrator.yaml' && pass "prints what was restored (orchestrator.yaml)" || fail "expected an explicit 'restored orchestrator.yaml' line, got: $OUT"
echo "$OUT" | grep -q 'restored souls/builder.md' && pass "prints what was restored (souls/builder.md)" || fail "expected an explicit 'restored souls/builder.md' line, got: $OUT"
echo "$OUT" | grep -Eq 'from [0-9a-f]{40} \(last tracked revision\)' && pass "names the exact commit it restored from" || fail "expected the restore message to name the source revision, got: $OUT"

if diff -q "$TMP/orig-orchestrator.yaml" "$PULLER/orchestrator.yaml" >/dev/null \
  && diff -q "$TMP/orig-builder.md" "$PULLER/souls/builder.md" >/dev/null \
  && diff -q "$TMP/orig-orchestra.md" "$PULLER/souls/orchestra.md" >/dev/null; then
  pass "restored files are byte-identical to the pre-deletion originals"
else
  fail "restored files should be byte-identical to the pre-deletion originals"
fi

echo "== gate resolves after rehydrate: bricked before, unblocked after =="
GATE="$DIR/../hooks/room-branch-gate.sh"
BEFORE_STATUS_DIR="$(mktemp -d -p "$TMP")"
PULLER2="$(mktemp -d -p "$TMP")"
git clone -q "$UPSTREAM" "$PULLER2" 2>/dev/null
git -C "$PULLER2" pull -q origin main 2>/dev/null
OUT="$(cd "$PULLER2" && env -u CLAUDE_PROJECT_DIR bash -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}" | bash "'"$GATE"'"' 2>&1)"
STATUS=$?
[ "$STATUS" -eq 2 ] && pass "before rehydrate: gate is bricked (fails closed) on the puller checkout, matching the live incident" || fail "expected the gate to fail closed pre-rehydrate, got $STATUS: $OUT"

bash "$ORC" rehydrate "$PULLER2" >/dev/null 2>&1
OUT="$(cd "$PULLER2" && env -u CLAUDE_PROJECT_DIR bash -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}" | bash "'"$GATE"'"' 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] && pass "after rehydrate: gate resolves the project root and allows an ordinary command again" || fail "expected the gate to resolve and allow post-rehydrate, got $STATUS: $OUT"

echo "== refuse-if-exists: never overwrites a file that's already present =="
OVER="$(mk_pre_migration_repo)"
printf 'project: HAND-EDITED, DO NOT CLOBBER\n' > "$OVER/orchestrator.yaml"
OUT="$(bash "$ORC" rehydrate "$OVER" 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] && pass "refuse-overwrite case exits 0 (idempotent no-op, not an error)" || fail "refuse-overwrite case should exit 0, got $STATUS: $OUT"
if grep -q 'HAND-EDITED, DO NOT CLOBBER' "$OVER/orchestrator.yaml"; then
  pass "an already-present orchestrator.yaml is left byte-for-byte untouched"
else
  fail "SECURITY REGRESSION: orc rehydrate overwrote an existing orchestrator.yaml -- refuse-if-exists is the whole security property"
fi
echo "$OUT" | grep -q 'already present' && pass "prints an explicit 'already present' notice rather than silently no-op'ing" || fail "expected an 'already present' message, got: $OUT"

echo "== idempotent: a second rehydrate run after a real restore is a clean no-op =="
IDEMP="$(mk_pre_migration_repo)"
rm -f "$IDEMP/orchestrator.yaml"
bash "$ORC" rehydrate "$IDEMP" >/dev/null 2>&1
OUT="$(bash "$ORC" rehydrate "$IDEMP" 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] && pass "second run exits 0" || fail "idempotent second run should exit 0, got $STATUS: $OUT"
echo "$OUT" | grep -q 'already present' && pass "second run reports 'already present', does not re-restore" || fail "expected 'already present' on the second run, got: $OUT"

echo "== no-history case: a path that was NEVER tracked fails cleanly, not a crash =="
NOHIST="$(mktemp -d -p "$TMP")"
git init -q "$NOHIST"
git_id "$NOHIST"
printf 'placeholder\n' > "$NOHIST/README.md"
git -C "$NOHIST" add README.md
git -C "$NOHIST" commit -q -m init
OUT="$(bash "$ORC" rehydrate "$NOHIST" 2>&1)"
STATUS=$?
[ "$STATUS" -eq 1 ] && pass "no tracked history anywhere -> clean exit 1, not a crash" || fail "expected a clean exit 1 for the no-history case, got $STATUS: $OUT"
echo "$OUT" | grep -qi 'no tracked history' && pass "no-history case explains itself instead of a bare bash error" || fail "expected a diagnosable 'no tracked history' message, got: $OUT"
if echo "$OUT" | grep -qiE 'unbound variable|command not found|line [0-9]+:.*syntax error'; then
  fail "CRASH: the no-history case leaked a raw bash error instead of a clean message: $OUT"
else
  pass "no-history case produces no raw bash/set -e crash output"
fi
[ -f "$NOHIST/orchestrator.yaml" ] && fail "no-history case should not have fabricated an orchestrator.yaml" || pass "no-history case leaves no orchestrator.yaml behind (nothing to restore from)"

echo "== works from a detached HEAD =="
DETACHED="$(mk_pre_migration_repo)"
DETACH_SHA="$(git -C "$DETACHED" rev-parse HEAD)"
rm -f "$DETACHED/orchestrator.yaml"
git -C "$DETACHED" checkout -q --detach "$DETACH_SHA"
OUT="$(bash "$ORC" rehydrate "$DETACHED" 2>&1)"
STATUS=$?
[ "$STATUS" -eq 0 ] && [ -f "$DETACHED/orchestrator.yaml" ] && pass "rehydrate restores correctly from a detached HEAD" || fail "expected a successful restore from a detached HEAD, got $STATUS: $OUT"

echo "== not a git repository at all: clean error, not a crash =="
NOTGIT="$(mktemp -d -p "$TMP")"
OUT="$(bash "$ORC" rehydrate "$NOTGIT" 2>&1)"
STATUS=$?
[ "$STATUS" -eq 1 ] && pass "non-git target directory -> clean exit 1" || fail "expected a clean exit 1 for a non-git target, got $STATUS: $OUT"
echo "$OUT" | grep -qi 'not inside a git repository' && pass "non-git case explains itself" || fail "expected a 'not inside a git repository' message, got: $OUT"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
