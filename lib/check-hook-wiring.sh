#!/bin/bash
# lib/check-hook-wiring.sh -- issue #10/#31/#48: verifies the RUNNING
# (gitignored, per-room) .claude/settings.json actually wires every hook
# templates/settings.json (the tracked source of truth) says it should.
#
# issue #48: this used to check against a HARDCODED list of hooks the
# script's author knew about at the time it was written (quota-stop-gate,
# guard, guard-write, room-branch-gate) -- any hook added to the template
# AFTER that was invisible to it forever. Confirmed live: PR #45 (#33)
# wired three pane-state.sh hooks into the template; this doctor kept
# passing a room missing all three, silently, because it never learned to
# look for them. Two lists meant to stay in sync will drift -- this is the
# project's own recurring lesson (see #10 itself: the same doctor pattern,
# rotted unseen one ticket later). Fixed by deriving the expected hook set
# from the template AT CHECK TIME instead of a list: every (event,
# matcher, script) triple present in the template must also be present in
# the live config with the SAME command; a hook added to the template is
# automatically covered the day it lands, no doctor update required.
#
# Usage: bash lib/check-hook-wiring.sh [settings.json path]
# Default path: .claude/settings.json relative to cwd (matches where
# `orc up`/Claude Code itself look for it). Template path is resolved
# relative to THIS script's own location (never the caller's cwd), so it
# works regardless of where the live settings.json lives; overridable via
# CHECK_HOOK_WIRING_TEMPLATE for tests.
#
# Exit 0: every template hook is wired live, unaltered (an extra live-only
# hook is fine -- a room may legitimately layer extras, see .claude vs
# templates precedent, issue #31 protection -- reported as a NOTE, not a
# failure). Exit 2 (LOUD -- stderr + explicit message per finding, never
# silent): the live or template file is missing/malformed, OR any template
# hook is missing or altered in the live config.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SETTINGS_FILE="${1:-.claude/settings.json}"
TEMPLATE_FILE="${CHECK_HOOK_WIRING_TEMPLATE:-$DIR/../templates/settings.json}"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "check-hook-wiring.sh: $SETTINGS_FILE does not exist -- this room has NO Claude Code hook config at all (none of guard.sh/guard-write.sh/quota-stop-gate.sh/check-handoff.sh are wired). Copy $TEMPLATE_FILE to $SETTINGS_FILE to fix." >&2
  exit 2
fi

if ! jq empty "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "check-hook-wiring.sh: $SETTINGS_FILE is not valid JSON (malformed) -- cannot verify hook wiring. Fix it or re-copy from $TEMPLATE_FILE." >&2
  exit 2
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "check-hook-wiring.sh: template $TEMPLATE_FILE does not exist -- cannot verify hook wiring without the tracked source of truth to diff against." >&2
  exit 2
fi

if ! jq empty "$TEMPLATE_FILE" >/dev/null 2>&1; then
  echo "check-hook-wiring.sh: template $TEMPLATE_FILE is not valid JSON (malformed) -- cannot verify hook wiring." >&2
  exit 2
fi

# chw_extract <file> -- prints one TAB-separated "event\tmatcher\tcommand"
# line per hook command in the file, for EVERY event the file happens to
# have (no hardcoded event list either -- a future event type needs no
# doctor update). matcher is empty string when the block has none
# (SessionStart/UserPromptSubmit/PreCompact/Stop/StopFailure don't use one).
chw_extract() {
  jq -r '
    (.hooks // {}) | to_entries[] | .key as $event |
    (.value // [])[] | (.matcher // "") as $matcher |
    (.hooks // [])[] | .command as $cmd |
    "\($event)\t\($matcher)\t\($cmd)"
  ' "$1" 2>/dev/null
}

# chw_basename <command> -- the hook script's own filename (e.g.
# "quota-stop-gate.sh"), the stable identity of a hook independent of its
# exact invocation (interpreter prefix, project-root variable, arguments).
# `tail -1`: a command could in principle mention more than one .sh path;
# the LAST one is the one actually being run.
chw_basename() {
  echo "$1" | grep -oE '[A-Za-z0-9_.-]+\.sh' | tail -1
}

TEMPLATE_HOOKS="$(chw_extract "$TEMPLATE_FILE")"
LIVE_HOOKS="$(chw_extract "$SETTINGS_FILE")"

DRIFT=0
while IFS=$'\t' read -r t_event t_matcher t_cmd; do
  [ -z "$t_event" ] && continue
  t_base="$(chw_basename "$t_cmd")"
  found=0
  exact=0
  live_cmd=""
  while IFS=$'\t' read -r l_event l_matcher l_cmd; do
    [ -z "$l_event" ] && continue
    [ "$l_event" = "$t_event" ] || continue
    [ "$l_matcher" = "$t_matcher" ] || continue
    l_base="$(chw_basename "$l_cmd")"
    [ "$l_base" = "$t_base" ] || continue
    found=1
    live_cmd="$l_cmd"
    if [ "$l_cmd" = "$t_cmd" ]; then
      exact=1
      break
    fi
  done <<< "$LIVE_HOOKS"

  if [ "$found" -eq 0 ]; then
    echo "check-hook-wiring.sh: WARNING -- $SETTINGS_FILE is MISSING the '$t_base' hook wired in $TEMPLATE_FILE for event=$t_event matcher='${t_matcher:-<none>}' (expected command: $t_cmd). Re-sync $SETTINGS_FILE from $TEMPLATE_FILE to fix." >&2
    DRIFT=1
  elif [ "$exact" -eq 0 ]; then
    echo "check-hook-wiring.sh: WARNING -- $SETTINGS_FILE's '$t_base' hook for event=$t_event matcher='${t_matcher:-<none>}' is ALTERED -- expected: $t_cmd -- got: $live_cmd. Re-sync $SETTINGS_FILE from $TEMPLATE_FILE to fix." >&2
    DRIFT=1
  fi
done <<< "$TEMPLATE_HOOKS"

# Extra live-only hooks are informational, never a failure (issue #31
# precedent: a room may legitimately layer hooks the template doesn't
# ship).
while IFS=$'\t' read -r l_event l_matcher l_cmd; do
  [ -z "$l_event" ] && continue
  l_base="$(chw_basename "$l_cmd")"
  in_template=0
  while IFS=$'\t' read -r t_event t_matcher t_cmd; do
    [ -z "$t_event" ] && continue
    [ "$t_event" = "$l_event" ] || continue
    [ "$t_matcher" = "$l_matcher" ] || continue
    t_base="$(chw_basename "$t_cmd")"
    [ "$t_base" = "$l_base" ] && { in_template=1; break; }
  done <<< "$TEMPLATE_HOOKS"
  if [ "$in_template" -eq 0 ]; then
    echo "check-hook-wiring.sh: NOTE -- $SETTINGS_FILE wires an extra hook not present in $TEMPLATE_FILE: event=$l_event matcher='${l_matcher:-<none>}' command=$l_cmd (allowed)." >&2
  fi
done <<< "$LIVE_HOOKS"

[ "$DRIFT" -eq 1 ] && exit 2
exit 0
