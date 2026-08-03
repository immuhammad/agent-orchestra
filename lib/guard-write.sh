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
# pwd (not pwd -P): harness_canonical_dir resolves CANON_DIR via a plain
# pwd too (see lib/harness-root.sh) -- matching that convention keeps
# ROOT and an incoming FILE_PATH comparable as plain strings. Symlink-
# resolving ROOT alone (pwd -P) while FILE_PATH stays unresolved is a
# real mismatch, not just a test artifact: on macOS, mktemp -d returns a
# /var/folders/... path that's itself a symlink to /private/var/folders/...
# -- confirmed live, this exact drift silently made every enforcement-
# layer case below false (never blocked, never exempted) until fixed.
ROOT=""
if CANON_DIR="$(qsg_resolve_canon_dir 2>/dev/null)"; then
  ROOT="$(cd "$(dirname "$CANON_DIR")" 2>/dev/null && pwd)" || ROOT=""
fi
if [ -n "$ROOT" ] && orc_is_enforcement_layer_path "$FILE_PATH" "$ROOT"; then
  echo "guard-write.sh: blocked write into '$FILE_PATH' -- hooks/, lib/, and bin/ are the harness's own live wired enforcement scripts, protected by default at the room root (a worktree's own copies under .worktrees/<issue>/ stay editable -- that's where a Builder legitimately edits them). Work in a worktree via lib/orc-worktree.sh and land the change through review, same as any other code change." >&2
  exit 2
fi

while IFS= read -r protected; do
  [ -z "$protected" ] && continue
  case "$FILE_PATH" in
    "$protected"*|*"/$protected"*)
      echo "guard-write.sh: blocked write into protected path '$protected' (see AGENTS.md / orchestrator.yaml): $FILE_PATH" >&2
      exit 2
      ;;
  esac
done <<< "$(orc_protected_paths)"

exit 0
