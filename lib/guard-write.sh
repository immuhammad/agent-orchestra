#!/bin/bash
# .harness/guard-write.sh — PreToolUse guard for Write/Edit tool calls.
# Blocks writes into protected paths (upstream clone is read-only, see
# AGENTS.md). guard.sh only inspects the Bash tool's command string, so
# under --dangerously-skip-permissions a Write/Edit tool call could still
# land in a protected path unguarded (G4) — this hook covers that gap.
#
# T21: protected paths come ONLY from orchestrator.yaml (protected_paths)
# via orc-config.sh -- EMPTY if the config is missing/malformed (issue #18
# B-i: no hardcoded project-specific default). This does NOT unprotect
# .claude/ or .agents/: those are checked separately below via
# orc_is_harness_config_path, regardless of orchestrator.yaml.
set -euo pipefail

GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./orc-config.sh
source "$GUARD_SCRIPT_DIR/orc-config.sh"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# issue #31: .claude/ and .agents/ wire the harness's own enforcement
# (guard.sh, guard-write.sh, quota-stop-gate.sh, the Stop hook) -- protected
# BY DEFAULT, independent of orchestrator.yaml's protected_paths, so no
# missing config entry can leave the guard editable/deletable by the agent
# it constrains (agy's probe-3 on PR #30: an unprotected settings.json let
# an agent inject ORC_ONESHOT=1 into the Stop hook's own command). This is
# instructive, not a flat wall -- Ahmad legitimately changes settings, so
# the message names the sanctioned edit path instead of just forbidding.
if orc_is_harness_config_path "$FILE_PATH"; then
  echo "guard-write.sh: blocked write into '$FILE_PATH' -- .claude/ and .agents/ are protected by default (they wire guard.sh/guard-write.sh/quota-stop-gate.sh/the Stop hook; leaving them editable would let an agent delete or spoof its own guard). To change hook wiring: edit templates/settings.json or templates/agents-hooks.json (the tracked source of truth) and re-sync into this room. To change a project's OTHER write-protected paths, edit protected_paths in orchestrator.yaml instead." >&2
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
