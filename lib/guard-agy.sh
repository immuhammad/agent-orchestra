#!/bin/bash
set -euo pipefail

# Antigravity CLI passes the payload via the ANTIGRAVITY_SOURCE_METADATA environment variable,
# not stdin (reading stdin hangs the agent).
INPUT="${ANTIGRAVITY_SOURCE_METADATA:-}"

# Parse the JSON payload for the command line
COMMAND=$(echo "$INPUT" | jq -r '.tool.toolCall.argumentsJson | fromjson? | .CommandLine // empty')

if [ -z "$COMMAND" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BANNED_FILE="$DIR/banned-patterns.txt"

if echo "$COMMAND" | grep -Eq -f "$BANNED_FILE"; then
  echo '{"decision":"deny", "reason":"guard-agy.sh: Command blocked by banned patterns"}'
  exit 0
fi

echo '{"decision":"allow"}'
exit 0
