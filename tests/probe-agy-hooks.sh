#!/bin/bash
set -euo pipefail

PROBE_DIR="/tmp/agy-probe-workspace-$$"
mkdir -p "$PROBE_DIR/.agents"

echo "project: orc-probe" > "$PROBE_DIR/orchestrator.yaml"

cat << 'JSON' > "$PROBE_DIR/.agents/hooks.json"
{
  "orc-probe": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash deny-probe.sh" }
        ]
      }
    ],
    "Stop": [
      { "type": "command", "command": "bash stop-probe.sh" }
    ]
  }
}
JSON

cat << 'SH' > "$PROBE_DIR/.agents/deny-probe.sh"
#!/bin/bash
echo "=== DENY-PROBE fired ===" >> "$PWD/../probe.log"
echo '{"decision":"deny", "reason":"PROBE-DENY-e2e: this command is blocked by the probe gate"}'
exit 0
SH
chmod +x "$PROBE_DIR/.agents/deny-probe.sh"

cat << 'SH' > "$PROBE_DIR/.agents/stop-probe.sh"
#!/bin/bash
echo "=== EVENT: Stop ===" >> "$PWD/../probe.log"
echo '{"decision":"allow"}'
exit 0
SH
chmod +x "$PROBE_DIR/.agents/stop-probe.sh"

SESSION_NAME="agy-probe-$$"
PROMPT='Use your run_command tool to execute exactly: echo probe-ok-77. Report verbatim what happened including any denial message. Then stop.'

tmux new-session -d -s "$SESSION_NAME" -c "$PROBE_DIR" -x 200 -y 50 "agy --project orc-probe --add-dir $PROBE_DIR --dangerously-skip-permissions"

sleep 30

tmux set-buffer "$PROMPT"
tmux paste-buffer -t "$SESSION_NAME"
sleep 2
tmux send-keys -t "$SESSION_NAME" Enter

for i in $(seq 1 24); do
  sleep 5
  if grep -q 'EVENT: Stop' "$PROBE_DIR/probe.log" 2>/dev/null; then break; fi
done
sleep 3

tmux capture-pane -t "$SESSION_NAME" -p > "$PROBE_DIR/tmux-screen.txt"
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

echo "=== PROBE RESULTS ==="
cat "$PROBE_DIR/tmux-screen.txt"

if grep -q "PROBE-DENY-e2e" "$PROBE_DIR/tmux-screen.txt"; then
  echo "SUCCESS: Denied tool call found in output."
else
  echo "FAILURE: Denied tool call not found."
  exit 1
fi
echo "done"
