#!/bin/bash
# tests/orc-init-key-consistency.test.sh -- rider 9 (issue #171).
#
# Self-consistency check: the YAML key-set `orc init` actually RENDERS
# into a fresh orchestrator.yaml must match the key-set shown in
# templates/orchestrator.yaml (the tracked reference file a human copies
# for a manual, non-`orc init` setup). templates/orchestrator.yaml's
# VALUES are placeholders (my-project, your-org/your-repo, ...) -- only
# its KEY STRUCTURE is asserted here. A drift either direction (init
# renders a key the template doesn't document, or the template documents
# a key init never actually writes) means the two have silently fallen
# out of sync, and whichever's true source is `orc init`'s own renderer
# (orc_init_render_orchestrator_yaml in bin/orc) -- so a mismatch is
# fixed by editing templates/orchestrator.yaml to match, never the
# generator.
#
# Key extraction mirrors lib/orc-config.sh's own indent-tracking awk
# technique (`indent = length($0) - length(trimmed)`, see
# orc_get_role_model/orc_get_nested) rather than inventing an
# incompatible parser -- this file is simple enough (2-space indent, no
# lists-of-maps) that a full YAML parser isn't needed.
#
# Run: bash tests/orc-init-key-consistency.test.sh
set -uo pipefail
# issue #189: orc init now finishes with orc-protect on by default --
# opt out here so a chflags/chattr-immutable fixture doesn't break this
# file's own scratch-dir teardown.
export ORC_INIT_NO_PROTECT=1

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORC="$DIR/../bin/orc"
TEMPLATE="$DIR/../templates/orchestrator.yaml"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_answers() { # $1 = path, stdin = KEY=value lines
  cat > "$1"
}

full_answers() { # $1 = path -- a complete, valid answers file (mirrors
  # tests/orc-init.test.sh's own full_answers helper)
  write_answers "$1" <<'EOF'
PROJECT=smoke-test-project
INTEGRATION_BRANCH=main
GITHUB_REMOTE=git@github.com:example/smoke.git
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

# extract_yaml_key_paths <file> -- prints one dotted key-path per line,
# e.g. "roles.orchestra.model", sorted+deduped. List items ("- infra/")
# and blank/comment lines are not keys and are skipped; every other
# non-blank line whose trimmed text starts "key:" contributes a path built
# from its own indent level chained through its ancestors' keys, same
# indent-tracking technique lib/orc-config.sh already uses to read this
# same file's nested roles:/budgets: blocks.
extract_yaml_key_paths() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*-[[:space:]]/ { next }
    {
      trimmed = $0
      gsub(/^[[:space:]]+/, "", trimmed)
      if (trimmed !~ /^[A-Za-z0-9_]+:/) next
      indent = length($0) - length(trimmed)
      if (indent % 2 != 0) next
      level = indent / 2
      split(trimmed, parts, ":")
      key = parts[1]
      stack[level] = key
      path = stack[0]
      for (i = 1; i <= level; i++) path = path "." stack[i]
      print path
    }
  ' "$1" | sort -u
}

echo "== rider 9 (issue #171): rendered orchestrator.yaml key-set matches templates/orchestrator.yaml's key-set =="
ANSWERS="$TMP/answers.txt"
full_answers "$ANSWERS"
TARGET="$TMP/room"
OUT="$(bash "$ORC" init --answers "$ANSWERS" "$TARGET" 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -f "$TARGET/orchestrator.yaml" ]; then
  pass "orc init --answers rendered a fresh orchestrator.yaml"
else
  fail "orc init --answers should have rendered orchestrator.yaml, got status=$STATUS: $OUT"
fi

if [ -f "$TEMPLATE" ]; then
  pass "templates/orchestrator.yaml exists"
else
  fail "templates/orchestrator.yaml is missing entirely at $TEMPLATE"
fi

RENDERED_KEYS="$(extract_yaml_key_paths "$TARGET/orchestrator.yaml")"
TEMPLATE_KEYS="$(extract_yaml_key_paths "$TEMPLATE")"

EXTRA_IN_RENDERED="$(comm -23 <(echo "$RENDERED_KEYS") <(echo "$TEMPLATE_KEYS"))"
EXTRA_IN_TEMPLATE="$(comm -13 <(echo "$RENDERED_KEYS") <(echo "$TEMPLATE_KEYS"))"

if [ -z "$EXTRA_IN_RENDERED" ]; then
  pass "every key orc init actually renders is documented in templates/orchestrator.yaml"
else
  fail "orc init renders keys NOT shown in templates/orchestrator.yaml: $(echo "$EXTRA_IN_RENDERED" | tr '\n' ' ')"
fi

if [ -z "$EXTRA_IN_TEMPLATE" ]; then
  pass "templates/orchestrator.yaml documents no keys beyond what orc init actually renders"
else
  fail "templates/orchestrator.yaml documents keys orc init never renders: $(echo "$EXTRA_IN_TEMPLATE" | tr '\n' ' ')"
fi

if [ -z "$EXTRA_IN_RENDERED" ] && [ -z "$EXTRA_IN_TEMPLATE" ]; then
  pass "rendered orchestrator.yaml and templates/orchestrator.yaml have IDENTICAL key-sets"
else
  fail "key-set drift between rendered orchestrator.yaml and templates/orchestrator.yaml -- extra in rendered: [$(echo "$EXTRA_IN_RENDERED" | tr '\n' ' ')], extra in template: [$(echo "$EXTRA_IN_TEMPLATE" | tr '\n' ' ')]"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
