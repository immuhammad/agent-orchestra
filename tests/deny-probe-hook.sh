#!/bin/bash
# tests/deny-probe-hook.sh -- PreToolUse hook body for the scratch agy
# session tests/probe-agy-hooks.sh boots (copied verbatim into the probe
# workspace's .agents/deny-probe.sh). Kept as its own file, rather than
# inlined into the probe script, so tests/deny-probe-hook.test.sh can pipe
# fixture JSON directly at it without booting agy.
#
# Parses .toolCall.args.CommandLine the same way lib/guard-agy.sh does,
# and denies ONLY the exact expected probe command. Any other shape
# (renamed field, different command, empty payload) falls through to
# allow instead of denying -- so if Antigravity's hook payload shape
# ever drifts, the outer probe's "denied tool call found" check fails
# LOUDLY instead of a silently-broken parse masquerading as a pass.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // .toolCall.args.commandLine // empty')

if [ "$COMMAND" = "echo probe-ok-77" ]; then
  echo "=== DENY-PROBE fired ===" >> "$PWD/../probe.log"
  echo '{"decision":"deny", "reason":"PROBE-DENY-e2e: this command is blocked by the probe gate"}'
else
  echo "=== DENY-PROBE saw unexpected payload (CommandLine=[$COMMAND]) ===" >> "$PWD/../probe.log"
  echo '{"decision":"allow"}'
fi
