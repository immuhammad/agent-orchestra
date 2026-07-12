#!/bin/bash
# .harness/guard-write.sh — PreToolUse guard for Write/Edit tool calls.
# Blocks writes into protected paths (upstream clone is read-only, see
# AGENTS.md). guard.sh only inspects the Bash tool's command string, so
# under --dangerously-skip-permissions a Write/Edit tool call could still
# land in a protected path unguarded (G4) — this hook covers that gap.
#
# T21: protected paths come ONLY from orchestrator.yaml (protected_paths)
# via orc-config.sh -- EMPTY if the config is missing/malformed (issue #18
# B-i: no hardcoded project-specific default; the harness core itself is
# separately protected by G-series guard rules, not this list).
set -euo pipefail

GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./orc-config.sh
source "$GUARD_SCRIPT_DIR/orc-config.sh"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
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
