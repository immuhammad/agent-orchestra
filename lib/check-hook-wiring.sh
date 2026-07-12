#!/bin/bash
# lib/check-hook-wiring.sh — issue #10/#31: verifies the RUNNING (gitignored,
# per-room) .claude/settings.json actually wires hooks/quota-stop-gate.sh as
# a PreToolUse hook. templates/settings.json is the tracked source of truth,
# but the live config is a per-room copy nobody diffs against by default --
# a hand-assembled or drifted config can silently omit a hook and nothing
# catches it. This is exactly what happened in #10: the gate shipped in
# PR #17, but #18 removed the trampoline that had wired it, the direct
# rewire dropped it, and the omission went unnoticed for the whole room's
# life until Ahmad hit it live.
#
# Usage: bash lib/check-hook-wiring.sh [settings.json path]
# Default path: .claude/settings.json relative to cwd (matches where
# `orc up`/Claude Code itself look for it).
# Exit 0: the gate is wired. Exit 2 (LOUD -- stderr + explicit message,
# never silent): file missing, malformed, or the gate hook absent.
set -uo pipefail

SETTINGS_FILE="${1:-.claude/settings.json}"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "check-hook-wiring.sh: $SETTINGS_FILE does not exist -- this room has NO Claude Code hook config at all (none of guard.sh/guard-write.sh/quota-stop-gate.sh/check-handoff.sh are wired). Copy templates/settings.json to $SETTINGS_FILE to fix." >&2
  exit 2
fi

if ! jq empty "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "check-hook-wiring.sh: $SETTINGS_FILE is not valid JSON (malformed) -- cannot verify hook wiring. Fix it or re-copy from templates/settings.json." >&2
  exit 2
fi

if jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$SETTINGS_FILE" 2>/dev/null | grep -q "quota-stop-gate.sh"; then
  exit 0
fi

echo "check-hook-wiring.sh: WARNING -- $SETTINGS_FILE does NOT wire hooks/quota-stop-gate.sh as a PreToolUse hook (issue #10). The quota-stop failsafe is silently INACTIVE in this room: an active quota-stop flag will NOT block tool use. Re-sync $SETTINGS_FILE from templates/settings.json (the tracked source of truth) to fix." >&2
exit 2
