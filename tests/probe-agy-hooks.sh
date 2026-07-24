#!/bin/bash
# tests/probe-agy-hooks.sh — Manual, reproducible probe for agy hook semantics
# This is a NOT-CI, manual-run, quota-consuming script that serves as the 
# standing merge gate for any future hook changes for Antigravity (agy).
#
# It proves:
# (a) Each wired event actually fires (in interactive context).
# (b) The payload delivery mechanism and raw dump shape.
# (c) A banned pattern actually DENIED end-to-end.
# (d) Stop-hook semantics.

set -euo pipefail

PROBE_DIR="/tmp/agy-probe-workspace-$$"
mkdir -p "$PROBE_DIR/.agents"

echo "Building scratch workspace at $PROBE_DIR..."

cat << 'EOF' > "$PROBE_DIR/.agents/hooks.json"
{
  "test-project": {
    "PreInvocation": [
      {
        "type": "command",
        "command": "bash .agents/probe-hook.sh PreInvocation"
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .agents/guard-mock.sh"
          },
          {
            "type": "command",
            "command": "bash .agents/probe-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "type": "command",
        "command": "bash .agents/probe-hook.sh PostToolUse"
      }
    ],
    "PostInvocation": [
      {
        "type": "command",
        "command": "bash .agents/probe-hook.sh PostInvocation"
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "bash .agents/probe-hook.sh Stop"
      },
      {
        "type": "command",
        "command": "bash .agents/stop-block-mock.sh"
      }
    ]
  }
}
EOF

cat << 'EOF' > "$PROBE_DIR/.agents/probe-hook.sh"
#!/bin/bash
EVENT=$1
LOG_FILE="$PWD/probe-events.log"
echo "=== EVENT: $EVENT ===" >> "$LOG_FILE"
INPUT=$(cat)
echo "$INPUT" >> "$LOG_FILE"
if [ "$EVENT" = "Stop" ]; then
  echo '{"decision":"allow"}'
fi
EOF
chmod +x "$PROBE_DIR/.agents/probe-hook.sh"

cat << 'EOF' > "$PROBE_DIR/.agents/guard-mock.sh"
#!/bin/bash
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // .toolCall.args.commandLine // empty')
if echo "$COMMAND" | grep -q "git commit"; then
  echo '{"decision":"deny", "reason":"mock: Command blocked"}'
  exit 0
fi
echo '{"decision":"allow"}'
exit 0
EOF
chmod +x "$PROBE_DIR/.agents/guard-mock.sh"

cat << 'EOF' > "$PROBE_DIR/.agents/stop-block-mock.sh"
#!/bin/bash
# Simulates check-inbox-stop-agy.sh blocking behavior exactly once
INPUT=$(cat)
if [ ! -f "$PWD/stop-blocked.marker" ]; then
  touch "$PWD/stop-blocked.marker"
  echo '{"decision":"continue","reason":"Mock inbox message pending"}'
  exit 0
fi
echo '{"decision":"allow"}'
exit 0
EOF
chmod +x "$PROBE_DIR/.agents/stop-block-mock.sh"

cd "$PROBE_DIR"

SESSION_NAME="agy-probe-$$"
echo "Booting agy in throwaway tmux session: $SESSION_NAME..."

tmux new-session -d -s "$SESSION_NAME" "cd $PROBE_DIR && agy -p \"Please use run_command to execute 'git commit -m probe' and then finish.\" --project-id test-project --add-dir $PROBE_DIR --dangerously-skip-permissions | tee session.log"

echo "Waiting for session to complete (up to 3 minutes)..."
TIMEOUT=180
while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
  sleep 2
  TIMEOUT=$((TIMEOUT - 2))
  if [ $TIMEOUT -le 0 ]; then
    echo "Timeout! Killing tmux session..."
    tmux kill-session -t "$SESSION_NAME"
    break
  fi
done

echo "=== PROBE RESULTS ==="
echo "Events Log:"
cat probe-events.log || echo "No events logged!"

echo "Session Output:"
cat session.log || echo "No session output!"

echo "Checking for denied tool call in output..."
if grep -q "Tool call denied by pre-tool hook" session.log; then
  echo "SUCCESS: Denied tool call found in output."
else
  echo "FAILURE: Denied tool call not found."
fi

echo "Cleaning up..."
rm -rf "$PROBE_DIR"
echo "Probe complete."
