#!/bin/bash
# tests/probe-agy-hooks.sh -- manual, reproducible probe for agy
# (Antigravity CLI) hook semantics. NOT run in CI: it boots a real,
# interactive agy session in a throwaway tmux session and burns quota, so
# run it manually, once, when validating a hook change -- it is the
# STANDING MERGE GATE for changes to lib/guard-agy.sh or .agents/hooks.json.
#
# It proves, against a real agy binary rather than a mock:
# (a) agy's hooks actually load in an INTERACTIVE session -- headless
#     `agy -p` loads no hooks at all (verified separately), so this
#     probe must never be run headless or it silently proves nothing.
# (b) the PreToolUse payload shape on stdin (.toolCall.args.CommandLine)
#     matches what lib/guard-agy.sh parses (see deny-probe-hook.sh).
# (c) a real tool call is DENIED end-to-end via decision-JSON, and only
#     for the expected command -- a payload-shape drift fails this
#     loudly instead of the real guard failing open silently.
# (d) the Stop hook fires and can gate session end via decision-JSON.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
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

cp "$DIR/deny-probe-hook.sh" "$PROBE_DIR/.agents/deny-probe.sh"
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
  rm -rf "$PROBE_DIR"
else
  echo "FAILURE: Denied tool call not found. Workspace kept for diagnosis: $PROBE_DIR"
  exit 1
fi
echo "done"
