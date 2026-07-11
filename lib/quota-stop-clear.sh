#!/bin/bash
# lib/quota-stop-clear.sh <reason> — explicit manual clear for the
# quota-stop PreToolUse gate (issue #10). This is the "Ahmad's a/b/c
# answer was recorded" signal the Gate-1 plan asked to be decided:
# inferring that answer from pane text or timing would be exactly the
# kind of drift-prone heuristic issue #11 exists to eliminate, so instead
# it's an explicit, auditable action -- whichever session received
# Ahmad's answer (or Orchestra, relaying it) runs this to lift the gate
# for every other session watching the same flag. The weekly and
# both-exhausted pools have NO automatic clear path at all (see
# lib/auto-resume.sh's ar_write_quota_stop_flag) -- this is the only way
# those ever get lifted.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./auto-resume.sh
source "$DIR/auto-resume.sh"

REASON="${1:?usage: quota-stop-clear.sh <reason, e.g. 'Ahmad: continue (c)'>}"

if [ -f "$AR_QUOTA_STOP_FLAG" ]; then
  rm -f "$AR_QUOTA_STOP_FLAG"
  ar_log "quota-stop flag manually cleared: $REASON"
  echo "quota-stop-clear.sh: cleared ($REASON)"
else
  echo "quota-stop-clear.sh: no active quota-stop flag" >&2
  exit 1
fi
