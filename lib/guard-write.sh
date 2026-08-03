#!/bin/bash
# .harness/guard-write.sh — PreToolUse guard for Write/Edit tool calls.
# Blocks writes into protected paths (upstream clone is read-only, see
# AGENTS.md). guard.sh only inspects the Bash tool's command string, so
# under --dangerously-skip-permissions a Write/Edit tool call could still
# land in a protected path unguarded (G4) — this hook covers that gap.
#
# Protected paths come ONLY from orchestrator.yaml (protected_paths)
# via orc-config.sh -- EMPTY if the config is missing/malformed (no
# hardcoded project-specific default). This does NOT unprotect
# .claude/ or .agents/: those are checked separately below via
# orc_is_harness_config_path, regardless of orchestrator.yaml.
set -euo pipefail

GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./orc-config.sh
source "$GUARD_SCRIPT_DIR/orc-config.sh"
# shellcheck source=./quota-stop-lib.sh
source "$GUARD_SCRIPT_DIR/quota-stop-lib.sh"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# .claude/ and .agents/ wire the harness's own enforcement
# (guard.sh, guard-write.sh, quota-stop-gate.sh, the Stop hook) -- protected
# BY DEFAULT, independent of orchestrator.yaml's protected_paths, so no
# missing config entry can leave the guard editable/deletable by the agent
# it constrains (agy's dedicated security review found: an unprotected
# settings.json let an agent inject ORC_ONESHOT=1 into the Stop hook's
# own command). This is
# instructive, not a flat wall -- Ahmad legitimately changes settings, so
# the message names the sanctioned edit path instead of just forbidding.
if orc_is_harness_config_path "$FILE_PATH"; then
  echo "guard-write.sh: blocked write into '$FILE_PATH' -- .claude/ and .agents/ are protected by default (they wire guard.sh/guard-write.sh/quota-stop-gate.sh/the Stop hook; leaving them editable would let an agent delete or spoof its own guard). To change hook wiring: edit templates/settings.json or templates/agents-hooks.json (the tracked source of truth) and re-sync into this room. To change a project's OTHER write-protected paths, edit protected_paths in orchestrator.yaml instead." >&2
  exit 2
fi

# issue #189: <root>/hooks, <root>/lib, <root>/bin -- the harness's own
# live wired enforcement scripts -- are protected by default at the room
# ROOT only; a Builder's own worktree copies (.worktrees/issue-N/hooks/...)
# stay editable, since that's the live daily workflow this must not break
# (see lib/orc-config.sh's orc_is_enforcement_layer_path). Best-effort
# root resolution: if it can't be resolved (no orchestrator.yaml
# findable -- this isn't a harness room at all), this ADDITIVE check is
# simply skipped, same posture as before this fix existed; the
# .claude/.agents/protected_paths checks above/below are unaffected
# either way.
# No cd/pwd resolution needed here -- orc_is_enforcement_layer_path
# (lib/orc-config.sh) physically resolves both FILE_PATH and ROOT
# internally via orc_physical_normalize, so a plain string dirname is
# enough (CANON_DIR is already absolute -- harness_canonical_dir always
# returns one). An earlier version of this line used `pwd -P` here,
# which double-resolved against that same internal resolution and (on
# macOS, where mktemp -d's /var/folders/... is itself a symlink to
# /private/var/folders/...) went stale the moment orc_physical_normalize
# was added -- confirmed live via this file's own test suite.
ROOT=""
if CANON_DIR="$(qsg_resolve_canon_dir 2>/dev/null)"; then
  ROOT="$(dirname "$CANON_DIR")"
fi
if [ -n "$ROOT" ] && orc_is_enforcement_layer_path "$FILE_PATH" "$ROOT"; then
  echo "guard-write.sh: blocked write into '$FILE_PATH' -- hooks/, lib/, and bin/ are the harness's own live wired enforcement scripts, protected by default at the room root (a worktree's own copies under .worktrees/<issue>/ stay editable -- that's where a Builder legitimately edits them). Work in a worktree via lib/orc-worktree.sh and land the change through review, same as any other code change." >&2
  exit 2
fi

# orc_is_protected_path -- root-anchored, .worktrees-exempt (see its own
# header): replaces a raw substring match that used to block a worktree's
# own copy of any protected_paths entry too (agy's dedicated security
# review, round 2 -- the same false-positive class hooks/lib/bin above
# was already fixed against).
if [ -n "$ROOT" ] && orc_is_protected_path "$FILE_PATH" "$ROOT"; then
  echo "guard-write.sh: blocked write into a protected path (see AGENTS.md / orchestrator.yaml): $FILE_PATH" >&2
  exit 2
fi

exit 0
