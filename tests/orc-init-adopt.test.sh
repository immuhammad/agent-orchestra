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
# issue #189: orc init --adopt now finishes with orc-protect on by
# default -- opt out here so a chflags/chattr-immutable fixture doesn't
# break this file's own scratch-dir teardown.
export ORC_INIT_NO_PROTECT=1

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

echo "== issue #187 item 2: bare --adopt CONVERGES on a cloned-harness fixture -- dogfood identity in a non-dogfood dir is treated as un-adopted =="
# Realistic scenario-(b) shape: the operator already re-pointed origin to
# THEIR OWN repo via a company SSH alias (item 3's derivation target),
# but orchestrator.yaml is still the untouched dogfood template (project=
# agent-orchestra / github_repo=immuhammad/agent-orchestra) because adopt
# hasn't run yet. Origin does NOT point at agent-orchestra here -- that
# sub-case (origin still pointing home) is covered separately below by
# the origin-recommendation tests, where the guard legitimately keeps
# refusing until the operator re-points origin too.
CLONED_HARNESS="$TMP/my-project"
mkdir -p "$CLONED_HARNESS"
git -C "$CLONED_HARNESS" init -q
git -C "$CLONED_HARNESS" remote add origin git@work-alias:acmecorp/my-project.git
cat > "$CLONED_HARNESS/orchestrator.yaml" <<'EOF'
project: agent-orchestra
integration_branch: main
github_repo: immuhammad/agent-orchestra
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
OUT_CLONED="$(bash "$ORC" init --adopt "$CLONED_HARNESS" 2>&1)"
STATUS_CLONED=$?
if [ "$STATUS_CLONED" -eq 0 ]; then
  pass "bare --adopt on a cloned-harness fixture (dogfood yaml, non-dogfood dirname) exits 0"
else
  fail "bare --adopt on a cloned-harness fixture should exit 0, got status=$STATUS_CLONED: $OUT_CLONED"
fi
if grep -q '^project: my-project$' "$CLONED_HARNESS/orchestrator.yaml" 2>/dev/null; then
  pass "PROJECT converges to the target's own basename (my-project), not left as agent-orchestra"
else
  fail "expected project: my-project (converged from the dogfood identity), got: $(cat "$CLONED_HARNESS/orchestrator.yaml" 2>/dev/null)"
fi
# GITHUB_REPO is freshly re-derived every adopt from the (now-supported,
# item 3) alias-host origin -- proves item 3's derivation feeds directly
# into item 2's convergence for the realistic combined flow.
if grep -q '^github_repo: acmecorp/my-project$' "$CLONED_HARNESS/orchestrator.yaml" 2>/dev/null; then
  pass "github_repo is freshly re-derived from the alias origin (item 3 derivation feeding item 2's convergence)"
else
  fail "expected github_repo derived as acmecorp/my-project from the alias origin, got: $(cat "$CLONED_HARNESS/orchestrator.yaml" 2>/dev/null)"
fi

CLONED_SESSION="orctest-adopt187-cloned-$$"
(
  cd "$CLONED_HARNESS"
  ORC_SESSION="$CLONED_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
  echo $? > exit.code
)
if [ "$(cat "$CLONED_HARNESS/exit.code" 2>/dev/null)" = "0" ]; then
  pass "the own-checkout guard PASSES on the post-adopt result (bare --adopt actually converges)"
else
  fail "the own-checkout guard should pass after --adopt converged PROJECT to the dirname, got: $(cat "$CLONED_HARNESS/build.err" 2>/dev/null)"
fi
tmux kill-session -t "$CLONED_SESSION" 2>/dev/null || true

echo "== issue #187 item 2: a re-adopt of the REAL dogfood room (dirname literally agent-orchestra) keeps the identity, guard exemption intact =="
REAL_DOGFOOD="$TMP/agent-orchestra"
mkdir -p "$REAL_DOGFOOD"
git -C "$REAL_DOGFOOD" init -q
git -C "$REAL_DOGFOOD" remote add origin git@github.com:immuhammad/agent-orchestra.git
cat > "$REAL_DOGFOOD/orchestrator.yaml" <<'EOF'
project: agent-orchestra
integration_branch: main
github_repo: immuhammad/agent-orchestra
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
bash "$ORC" init --adopt "$REAL_DOGFOOD" >/dev/null 2>&1
if grep -q '^project: agent-orchestra$' "$REAL_DOGFOOD/orchestrator.yaml" 2>/dev/null; then
  pass "the real dogfood room's own shape (dirname == agent-orchestra) keeps project: agent-orchestra -- never renamed"
else
  fail "the real dogfood room should keep project: agent-orchestra, got: $(cat "$REAL_DOGFOOD/orchestrator.yaml" 2>/dev/null)"
fi
REAL_SESSION="orctest-adopt187-real-$$"
(
  cd "$REAL_DOGFOOD"
  ORC_SESSION="$REAL_SESSION" ORC_SKIP_PANE_COMMANDS=1 ORC_SKIP_LIVENESS=1 ORC_SKIP_MERGE_WATCH_SEED=1 ORC_SKIP_HOOK_WIRING_CHECK=1 ORC_ALLOW_UNMERGED_HARNESS=1 \
    bash -c "source '$DIR/../bin/orc'; orc_build_session" 2> build.err
  echo $? > exit.code
)
if [ "$(cat "$REAL_DOGFOOD/exit.code" 2>/dev/null)" = "0" ]; then
  pass "the real dogfood room's guard exemption is still intact after --adopt"
else
  fail "the real dogfood room should still pass the own-checkout guard after --adopt, got: $(cat "$REAL_DOGFOOD/build.err" 2>/dev/null)"
fi
tmux kill-session -t "$REAL_SESSION" 2>/dev/null || true

echo "== issue #187 item 2: dogfood-convergence override never fires for an already-named, unrelated room (no false positive) =="
if grep -q '^project: already-named-project$' "$ADOPT_EXISTING/orchestrator.yaml" 2>/dev/null; then
  pass "an already-adopted room with its own unrelated identity is untouched by the dogfood-convergence check (regression guard)"
else
  fail "the dogfood-convergence check should never touch an already-named unrelated room: $(cat "$ADOPT_EXISTING/orchestrator.yaml" 2>/dev/null)"
fi

echo "== issue #187 item 3: the origin-recommendation triggers on host-alias origins too (parsed tail = agent-orchestra, regardless of host) =="
ADOPT_ALIAS_DOGFOOD="$TMP/cloned-harness-alias"
mkdir -p "$ADOPT_ALIAS_DOGFOOD"
git -C "$ADOPT_ALIAS_DOGFOOD" init -q
git -C "$ADOPT_ALIAS_DOGFOOD" remote add origin git@work-alias:immuhammad/agent-orchestra.git
OUT_ALIAS_DOGFOOD="$(bash "$ORC" init --adopt "$ADOPT_ALIAS_DOGFOOD" 2>&1)"
if echo "$OUT_ALIAS_DOGFOOD" | grep -q "origin still points at immuhammad/agent-orchestra"; then
  pass "the origin-recommendation message fires for a host-alias origin resolving to immuhammad/agent-orchestra"
else
  fail "expected the origin-recommendation message for the alias origin, got: $OUT_ALIAS_DOGFOOD"
fi

ADOPT_FORK="$TMP/someones-fork"
mkdir -p "$ADOPT_FORK"
git -C "$ADOPT_FORK" init -q
git -C "$ADOPT_FORK" remote add origin git@github.com:someone-else/agent-orchestra.git
OUT_FORK="$(bash "$ORC" init --adopt "$ADOPT_FORK" 2>&1)"
if echo "$OUT_FORK" | grep -q "origin still points at someone-else/agent-orchestra"; then
  pass "the origin-recommendation also fires (tail-only match) for a differently-owned fork named agent-orchestra"
else
  fail "expected the origin-recommendation for a same-name fork under a different owner, got: $OUT_FORK"
fi

echo "== issue #189: orc init --adopt finishes with orc-protect on by default =="
PROTECT_PROBE="$TMP/protect-cap-probe"
touch "$PROTECT_PROBE"
if [ "$(uname -s)" = Darwin ]; then
  if chflags uchg "$PROTECT_PROBE" 2>/dev/null; then CAN_FLAG=1; chflags nouchg "$PROTECT_PROBE"; else CAN_FLAG=0; fi
else
  if chattr +i "$PROTECT_PROBE" 2>/dev/null; then CAN_FLAG=1; chattr -i "$PROTECT_PROBE"; else CAN_FLAG=0; fi
fi
rm -f "$PROTECT_PROBE"

if [ "$CAN_FLAG" -eq 0 ]; then
  echo "SKIP: no immutability privilege here (unprivileged Linux?) -- orc-protect-on-by-default cases skipped"
else
  ADOPT_PROTECT="$TMP/adopt-protect-on"
  mkdir -p "$ADOPT_PROTECT"
  OUT_ADOPT_PROTECT="$(ORC_INIT_NO_PROTECT= bash "$ORC" init --adopt "$ADOPT_PROTECT" 2>&1)"
  if echo "$OUT_ADOPT_PROTECT" | grep -q "orc init: orc-protect applied"; then
    pass "orc init --adopt prints 'orc-protect applied'"
  else
    fail "expected 'orc-protect applied' in output: $OUT_ADOPT_PROTECT"
  fi
  if bash "$DIR/../bin/orc-protect" status "$ADOPT_PROTECT" >/dev/null 2>&1; then
    pass "orc init --adopt leaves the room orc-protect'd"
  else
    fail "expected the room to be orc-protect'd after orc init --adopt"
  fi
  bash "$DIR/../bin/orc-protect" off "$ADOPT_PROTECT" >/dev/null 2>&1 || true
fi

echo "== ORC_INIT_NO_PROTECT=1 skips orc-protect for --adopt too =="
ADOPT_NOPROTECT="$TMP/adopt-no-protect"
mkdir -p "$ADOPT_NOPROTECT"
OUT_ADOPT_NOPROTECT="$(bash "$ORC" init --adopt "$ADOPT_NOPROTECT" 2>&1)"
if echo "$OUT_ADOPT_NOPROTECT" | grep -q "orc init: orc-protect skipped (ORC_INIT_NO_PROTECT set)"; then
  pass "ORC_INIT_NO_PROTECT=1 prints the skip message for --adopt"
else
  fail "expected the skip message in output: $OUT_ADOPT_NOPROTECT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
