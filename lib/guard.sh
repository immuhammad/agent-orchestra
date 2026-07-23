#!/bin/bash
# lib/guard.sh — PreToolUse guard for Bash tool calls. THIN since the
# guard-layer redesign (#141, layer 3).
#
# The old 500-line version tried to catch protected-path writes by
# re-parsing arbitrary shell -- cd-tracking, a variable table, tokenized
# write-target extraction -- and lost that game repeatedly: #98
# (fd-redirect destination pollution), #84 (interpreter inline-code
# flags), #139 (quote-state desync false positives), #140 (a set -e
# crash that failed OPEN). Hard enforcement now lives where no
# command-string parse can be sidestepped:
#   layer 1: bin/orc-protect -- kernel immutability (EPERM) on .claude/
#            .agents/ orchestrator.yaml + protected_paths entries
#   layer 2: GitHub branch protection -- PR-only, CI-required,
#            force-push/deletion blocked on the integration branch
# Write/Edit tool calls stay covered by guard-write.sh (structured
# file_path, no shell parsing involved).
#
# This file keeps ONLY the anchored deny for outright destructive
# commands -- the one class with no lower-layer backstop (rm -rf and
# history rewrites can hit paths no flag protects). Best-effort by
# design: an obfuscated destructive command (bash -c "...") can slip
# past exactly as it could the old version (#84's pre-existing class);
# Hard Rules and review own that residue. What this layer must never
# produce is a FALSE POSITIVE -- every check anchors at a segment's
# leading tokens, never greps the whole string.
set -euo pipefail

GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only orc_split_top_level_segments is consumed -- the same quote-aware
# splitter the quota-stop gate depends on. The tokenizer / write-target
# half of cmd-inspect-lib.sh has no consumer here anymore.
# shellcheck source=./cmd-inspect-lib.sh
source "$GUARD_SCRIPT_DIR/cmd-inspect-lib.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

deny() {
  echo "guard.sh: BLOCKED -- $1 (AGENTS.md Hard Rules). Protected-path writes are enforced by the kernel (bin/orc-protect, #141 layer 1) and integration-branch history by GitHub branch protection (layer 2); this thin guard denies only the destructive class nothing else backstops." >&2
  exit 2
}

while IFS= read -r seg; do
  # ltrim, then anchor every check at the segment's leading tokens so
  # text inside a quoted argument can never trip a deny (#139's class).
  seg="${seg#"${seg%%[![:space:]]*}"}"
  case "$seg" in
    'rm -rf'|'rm -rf '*|'rm -fr'|'rm -fr '*)
      deny "recursive force delete ('rm -rf')" ;;
    'git reset --hard'*|'reset --hard'*)
      deny "history/worktree reset ('reset --hard')" ;;
    'git clean'*)
      deny "untracked-file purge ('git clean')" ;;
    'git push'*)
      # any --force variant (--force, --force-with-lease) or -f, wherever
      # it sits in the segment; plain pushes and --delete branch cleanup
      # stay allowed (integration-branch deletion is blocked server-side)
      case " $seg " in
        *' --force'*|*' -f '*)
          deny "force push" ;;
      esac ;;
  esac
done < <(orc_split_top_level_segments "$COMMAND")

exit 0
