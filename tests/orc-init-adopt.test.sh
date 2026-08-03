#!/bin/bash
# tests/orc-init-adopt.test.sh -- `orc init --adopt [target]`, issue #171.
# Adopts the harness into an EXISTING directory: (a) a plain project dir
# that never ran `orc init`, or (b) a raw clone of agent-orchestra itself
# meant as someone else's new project starting point (still carrying the
# dogfood room's own orchestrator.yaml/AGENTS.md/souls/* etc). Identity
# (PROJECT/GITHUB_REPO) is derived automatically instead of requiring a
# hand-written answers file; an optional --answers FILE overrides any
# derived value. Unlike plain `orc init`, --adopt does NOT refuse when
# orchestrator.yaml already exists -- it resyncs via the same drift-safe
# orc_init_apply_file path --force uses.
# Run: bash tests/orc-init-adopt.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORC="$DIR/../bin/orc"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

file_mtime() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%Y' "$1" 2>/dev/null
  else
    stat -f '%m' "$1" 2>/dev/null
  fi
}

echo "== --adopt on a fresh dir with no orchestrator.yaml derives PROJECT from dirname and GITHUB_REPO from git origin (SSH form) =="
ADOPT_SSH="$TMP/my-ssh-project"
mkdir -p "$ADOPT_SSH"
git -C "$ADOPT_SSH" init -q
git -C "$ADOPT_SSH" remote add origin git@github.com:some-owner/some-repo.git
OUT_SSH="$(bash "$ORC" init --adopt "$ADOPT_SSH" 2>&1)"
STATUS_SSH=$?
if [ "$STATUS_SSH" -eq 0 ]; then
  pass "--adopt on a fresh git-repo dir exits 0"
else
  fail "--adopt on a fresh git-repo dir should exit 0, got status=$STATUS_SSH: $OUT_SSH"
fi
if grep -q '^project: my-ssh-project$' "$ADOPT_SSH/orchestrator.yaml" 2>/dev/null; then
  pass "PROJECT derived from the target's own dirname"
else
  fail "expected project: my-ssh-project, got: $(cat "$ADOPT_SSH/orchestrator.yaml" 2>/dev/null)"
fi
if grep -q '^github_repo: some-owner/some-repo$' "$ADOPT_SSH/orchestrator.yaml" 2>/dev/null; then
  pass "GITHUB_REPO derived from git origin (SSH form)"
else
  fail "expected github_repo: some-owner/some-repo, got: $(cat "$ADOPT_SSH/orchestrator.yaml" 2>/dev/null)"
fi
for f in AGENTS.md CLAUDE.md GEMINI.md review-protocol.md souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md .claude/settings.json .agents/hooks.json; do
  [ -f "$ADOPT_SSH/$f" ] || fail "--adopt should have written $f"
done
pass "--adopt writes every templates-derived file (fresh target)"

echo "== --adopt derives GITHUB_REPO from an HTTPS-form git origin too =="
ADOPT_HTTPS="$TMP/my-https-project"
mkdir -p "$ADOPT_HTTPS"
git -C "$ADOPT_HTTPS" init -q
git -C "$ADOPT_HTTPS" remote add origin https://github.com/https-owner/https-repo.git
bash "$ORC" init --adopt "$ADOPT_HTTPS" >/dev/null 2>&1
if grep -q '^github_repo: https-owner/https-repo$' "$ADOPT_HTTPS/orchestrator.yaml" 2>/dev/null; then
  pass "GITHUB_REPO derived from git origin (HTTPS form)"
else
  fail "expected github_repo: https-owner/https-repo, got: $(cat "$ADOPT_HTTPS/orchestrator.yaml" 2>/dev/null)"
fi

echo "== --adopt with no git origin at all still succeeds, github_repo empty =="
ADOPT_NOREPO="$TMP/my-norepo-project"
mkdir -p "$ADOPT_NOREPO"
OUT_NOREPO="$(bash "$ORC" init --adopt "$ADOPT_NOREPO" 2>&1)"
STATUS_NOREPO=$?
if [ "$STATUS_NOREPO" -eq 0 ] && grep -q '^github_repo: *$' "$ADOPT_NOREPO/orchestrator.yaml" 2>/dev/null; then
  pass "--adopt on a dir with no git origin succeeds with an empty github_repo"
else
  fail "expected a clean exit and empty github_repo, got status=$STATUS_NOREPO: $(cat "$ADOPT_NOREPO/orchestrator.yaml" 2>/dev/null)"
fi

echo "== --adopt on a dir that ALREADY has orchestrator.yaml preserves the existing project value (not the dirname) =="
ADOPT_EXISTING="$TMP/some-random-dirname"
mkdir -p "$ADOPT_EXISTING"
cat > "$ADOPT_EXISTING/orchestrator.yaml" <<'EOF'
project: already-named-project
integration_branch: main
github_repo: existing-owner/existing-repo
ticket_tracker: gh-issues

protected_paths:

roles:
  orchestra:
    model: opus
    effort: high
  implementer:
    model: sonnet
    effort: default
  tester:
    model: sonnet
    effort: default
  reviewer:
    model: agy
    effort: high
  scribe:
    model: haiku
    effort: low

budgets:
  claude:
    failsafe_pct: 80
  agy:
    failsafe_pct: 80
EOF
OUT_EXISTING="$(bash "$ORC" init --adopt "$ADOPT_EXISTING" 2>&1)"
STATUS_EXISTING=$?
if [ "$STATUS_EXISTING" -eq 0 ]; then
  pass "--adopt on a dir with an existing orchestrator.yaml exits 0 (no refuse, unlike plain init)"
else
  fail "--adopt should not refuse on an existing room, got status=$STATUS_EXISTING: $OUT_EXISTING"
fi
if grep -q '^project: already-named-project$' "$ADOPT_EXISTING/orchestrator.yaml" 2>/dev/null; then
  pass "existing project: value is PRESERVED, not overwritten from dirname (some-random-dirname)"
else
  fail "expected project: already-named-project to be preserved, got: $(cat "$ADOPT_EXISTING/orchestrator.yaml" 2>/dev/null)"
fi
for f in AGENTS.md CLAUDE.md GEMINI.md review-protocol.md souls/orchestra.md souls/builder.md souls/reviewer.md souls/scribe.md .claude/settings.json .agents/hooks.json; do
  [ -f "$ADOPT_EXISTING/$f" ] || fail "--adopt should have rendered $f for an existing room"
done
pass "--adopt renders every templates-derived file for an existing room too"

echo "== --adopt on an existing room with a hand-edited AGENTS.md backs it up, does not clobber =="
echo "MY HAND-EDITED CONTENT, DO NOT LOSE ME" >> "$ADOPT_EXISTING/AGENTS.md"
BACKUP_BEFORE="$(find "$ADOPT_EXISTING/.harness/state/init-backups" -type d -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
OUT_DRIFT="$(bash "$ORC" init --adopt "$ADOPT_EXISTING" 2>&1)"
if echo "$OUT_DRIFT" | grep -qi "DRIFT BACKUP.*AGENTS.md"; then
  pass "a hand-edited AGENTS.md triggers a loud DRIFT BACKUP message on --adopt"
else
  fail "expected a DRIFT BACKUP message for the hand-edited AGENTS.md, got: $OUT_DRIFT"
fi
BACKUP_AFTER_DIR="$(find "$ADOPT_EXISTING/.harness/state/init-backups" -type d -mindepth 1 2>/dev/null | sort | tail -1)"
if [ -n "$BACKUP_AFTER_DIR" ] && grep -q "MY HAND-EDITED CONTENT, DO NOT LOSE ME" "$BACKUP_AFTER_DIR/AGENTS.md" 2>/dev/null; then
  pass "the hand-edited AGENTS.md content was preserved in the backup, not silently discarded"
else
  fail "expected the hand-edited content preserved under $ADOPT_EXISTING/.harness/state/init-backups/*/AGENTS.md"
fi
if ! grep -q "MY HAND-EDITED CONTENT" "$ADOPT_EXISTING/AGENTS.md" 2>/dev/null; then
  pass "the live AGENTS.md was overwritten with the current template render (not left hand-edited)"
else
  fail "live AGENTS.md should have been overwritten by --adopt's resync"
fi

echo "== --adopt is idempotent: a second run with no changes touches nothing =="
ADOPT_IDEM="$TMP/idempotent-project"
mkdir -p "$ADOPT_IDEM"
git -C "$ADOPT_IDEM" init -q
git -C "$ADOPT_IDEM" remote add origin git@github.com:idem-owner/idem-repo.git
bash "$ORC" init --adopt "$ADOPT_IDEM" >/dev/null 2>&1
sleep 1
AGENTS_MTIME_BEFORE="$(file_mtime "$ADOPT_IDEM/AGENTS.md")"
SETTINGS_MTIME_BEFORE="$(file_mtime "$ADOPT_IDEM/.claude/settings.json")"
YAML_MTIME_BEFORE="$(file_mtime "$ADOPT_IDEM/orchestrator.yaml")"
OUT_IDEM2="$(bash "$ORC" init --adopt "$ADOPT_IDEM" 2>&1)"
AGENTS_MTIME_AFTER="$(file_mtime "$ADOPT_IDEM/AGENTS.md")"
SETTINGS_MTIME_AFTER="$(file_mtime "$ADOPT_IDEM/.claude/settings.json")"
YAML_MTIME_AFTER="$(file_mtime "$ADOPT_IDEM/orchestrator.yaml")"
if [ "$AGENTS_MTIME_BEFORE" = "$AGENTS_MTIME_AFTER" ] && [ "$SETTINGS_MTIME_BEFORE" = "$SETTINGS_MTIME_AFTER" ] && [ "$YAML_MTIME_BEFORE" = "$YAML_MTIME_AFTER" ]; then
  pass "a second --adopt run with no changes touches no manifest-tracked file (mtimes unchanged)"
else
  fail "a second identical --adopt run should be a true no-op, mtimes changed: AGENTS $AGENTS_MTIME_BEFORE->$AGENTS_MTIME_AFTER settings $SETTINGS_MTIME_BEFORE->$SETTINGS_MTIME_AFTER yaml $YAML_MTIME_BEFORE->$YAML_MTIME_AFTER: $OUT_IDEM2"
fi
if echo "$OUT_IDEM2" | grep -qi "DRIFT BACKUP"; then
  fail "a no-op second --adopt run should not report any DRIFT BACKUP: $OUT_IDEM2"
else
  pass "a no-op second --adopt run reports no drift backups"
fi

echo "== --adopt seeds the .harness/inbox/{orchestra,builder,agy,scribe} dirs =="
for agent in orchestra builder agy scribe; do
  if [ -d "$ADOPT_IDEM/.harness/inbox/$agent" ]; then
    pass "--adopt seeded inbox/$agent"
  else
    fail "--adopt should have seeded inbox/$agent"
  fi
done

echo "== --adopt: origin-recommendation prints ONLY when origin resolves to immuhammad/agent-orchestra =="
ADOPT_DOGFOOD_CLONE="$TMP/cloned-harness"
mkdir -p "$ADOPT_DOGFOOD_CLONE"
git -C "$ADOPT_DOGFOOD_CLONE" init -q
git -C "$ADOPT_DOGFOOD_CLONE" remote add origin git@github.com:immuhammad/agent-orchestra.git
OUT_DOGFOOD="$(bash "$ORC" init --adopt "$ADOPT_DOGFOOD_CLONE" 2>&1)"
if echo "$OUT_DOGFOOD" | grep -q "origin still points at immuhammad/agent-orchestra"; then
  pass "origin-recommendation message prints for a raw clone of agent-orchestra itself"
else
  fail "expected the origin-recommendation message, got: $OUT_DOGFOOD"
fi
if echo "$OUT_DOGFOOD" | grep -qi "git remote set-url origin"; then
  pass "origin-recommendation message tells the operator how to re-point or clear origin"
else
  fail "expected re-point/clear instructions in the recommendation message"
fi

ADOPT_UNRELATED="$TMP/unrelated-project-repo"
mkdir -p "$ADOPT_UNRELATED"
git -C "$ADOPT_UNRELATED" init -q
git -C "$ADOPT_UNRELATED" remote add origin git@github.com:some-owner/unrelated-project.git
OUT_UNRELATED="$(bash "$ORC" init --adopt "$ADOPT_UNRELATED" 2>&1)"
if echo "$OUT_UNRELATED" | grep -q "origin still points at immuhammad/agent-orchestra"; then
  fail "the origin-recommendation message should NOT print for an unrelated repo: $OUT_UNRELATED"
else
  pass "origin-recommendation message does NOT print for an unrelated origin"
fi

echo "== --adopt: an explicit --answers FILE overrides any derived value =="
ADOPT_OVERRIDE="$TMP/override-project"
mkdir -p "$ADOPT_OVERRIDE"
git -C "$ADOPT_OVERRIDE" init -q
git -C "$ADOPT_OVERRIDE" remote add origin git@github.com:derived-owner/derived-repo.git
ANSWERS_OVERRIDE="$TMP/answers-override.txt"
cat > "$ANSWERS_OVERRIDE" <<'EOF'
PROJECT=explicit-override-project
EOF
bash "$ORC" init --adopt "$ADOPT_OVERRIDE" --answers "$ANSWERS_OVERRIDE" >/dev/null 2>&1
if grep -q '^project: explicit-override-project$' "$ADOPT_OVERRIDE/orchestrator.yaml" 2>/dev/null; then
  pass "an explicit --answers PROJECT value overrides the derived dirname"
else
  fail "expected the explicit PROJECT answer to win, got: $(cat "$ADOPT_OVERRIDE/orchestrator.yaml" 2>/dev/null)"
fi
if grep -q '^github_repo: derived-owner/derived-repo$' "$ADOPT_OVERRIDE/orchestrator.yaml" 2>/dev/null; then
  pass "github_repo still auto-derives from git origin when not explicitly overridden"
else
  fail "expected github_repo derived from git origin (not overridden), got: $(cat "$ADOPT_OVERRIDE/orchestrator.yaml" 2>/dev/null)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
