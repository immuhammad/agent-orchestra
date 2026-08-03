#!/bin/bash
# lib/guard-write-agy.sh — PreToolUse guard for agy (Antigravity CLI)
# Write/Edit-shaped tool calls, wired via .agents/hooks.json. agy
# counterpart to lib/guard-write.sh's issue #189 addition: <root>/hooks,
# <root>/lib, <root>/bin are the harness's own live wired enforcement
# scripts, protected by default at the room ROOT only -- a Builder's own
# worktree copies (.worktrees/issue-N/hooks/...) stay editable.
#
# Scoped ONLY to that one check -- not a full agy port of
# guard-write.sh's .claude/.agents/protected_paths logic, which is out of
# scope here: .claude/.agents is already covered for every agent equally
# by bin/orc-protect's kernel immutability (layer 1), regardless of which
# agent's software hooks run. hooks/lib/bin are deliberately NOT in that
# kernel-immutability set (see lib/orc-config.sh's
# orc_is_enforcement_layer_path header for why -- git pull/merge must
# keep writing them with no protect-off/on dance), so this software check
# is their ONLY backstop, and it has to exist for agy too, not just
# Claude Code, or an agy session bypasses it entirely.
#
# Speaks agy's own protocol (JSON in via .toolCall.args, JSON decision out
# on stdout), same shape guard-room-branch-agy.sh already established.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./orc-config.sh
source "$DIR/orc-config.sh"
# shellcheck source=./quota-stop-lib.sh
source "$DIR/quota-stop-lib.sh"

INPUT=$(cat)

# Same confirmed agy write-tool payload shape as
# guard-room-branch-agy.sh/guard-quota-stop-agy.sh (TargetFile primary,
# FilePath/file_path defensive fallbacks).
FILE_PATH=$(echo "$INPUT" | jq -r '
  .toolCall.args.TargetFile //
  .toolCall.args.FilePath // .toolCall.args.file_path // empty
')

if [ -z "$FILE_PATH" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

# Best-effort root resolution -- see lib/guard-write.sh's matching
# comment: an unresolvable root just skips this additive check rather
# than denying everything.
# pwd (not pwd -P) -- see lib/guard-write.sh's matching comment: this
# must stay comparable with an unresolved FILE_PATH as a plain string.
ROOT=""
if CANON_DIR="$(qsg_resolve_canon_dir 2>/dev/null)"; then
  ROOT="$(cd "$(dirname "$CANON_DIR")" 2>/dev/null && pwd)" || ROOT=""
fi

if [ -n "$ROOT" ] && orc_is_enforcement_layer_path "$FILE_PATH" "$ROOT"; then
  MSG="guard-write: blocked write into '$FILE_PATH' -- hooks/, lib/, and bin/ are the harness's own live wired enforcement scripts, protected by default at the room root (a worktree's own copies under .worktrees/<issue>/ stay editable -- that's where a Builder legitimately edits them). Work in a worktree via lib/orc-worktree.sh and land the change through review, same as any other code change."
  echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$MSG" '$m')}"
  exit 0
fi

echo '{"decision":"allow"}'
exit 0