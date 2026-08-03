#!/bin/bash
# lib/guard-write-agy.sh — PreToolUse guard for agy (Antigravity CLI)
# write-shaped tool calls, wired via .agents/hooks.json. agy's full
# write-protection counterpart to lib/guard-write.sh: the SAME three
# checks (.claude/.agents default protection, issue #189's
# <root>/hooks|lib|bin enforcement-layer protection, orchestrator.yaml's
# protected_paths), same order, same shared helpers (lib/orc-config.sh) --
# kept in lock-step deliberately so the two dialects can't drift.
#
# This did NOT originally port the .claude/.agents/protected_paths checks
# -- issue #189's first cut scoped this file to ONLY the hooks/lib/bin
# check, reasoning that bin/orc-protect's kernel immutability already
# covered .claude/.agents/protected_paths for every agent equally. That
# reasoning was WRONG for protected_paths specifically (agy's dedicated
# security review of this diff, finding 2): bin/orc-protect explicitly
# SKIPS any '.git/'-rooted protected_paths entry (git itself must keep
# writing there), and separately skips any entry that doesn't exist yet
# at the moment 'orc-protect on' runs -- for either case the SOFTWARE
# guard is the only actual backstop, and agy had none. Full parity port
# now, closing that gap for .claude/.agents too rather than leaving a
# second, same-shape hole for a future finding to rediscover.
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

deny() {
  echo "{\"decision\":\"deny\", \"reason\":$(jq -Rn --arg m "$1" '$m')}"
  exit 0
}

# .claude/ and .agents/ wire the harness's own enforcement -- protected BY
# DEFAULT, independent of orchestrator.yaml's protected_paths. Mirrors
# lib/guard-write.sh's identical check verbatim (same message, same
# helper) so the two dialects can't drift on this either.
if orc_is_harness_config_path "$FILE_PATH"; then
  deny "guard-write: blocked write into '$FILE_PATH' -- .claude/ and .agents/ are protected by default (they wire guard.sh/guard-write.sh/quota-stop-gate.sh/the Stop hook; leaving them editable would let an agent delete or spoof its own guard). To change hook wiring: edit templates/settings.json or templates/agents-hooks.json (the tracked source of truth) and re-sync into this room. To change a project's OTHER write-protected paths, edit protected_paths in orchestrator.yaml instead."
fi

# issue #189: <root>/hooks, <root>/lib, <root>/bin -- the harness's own
# live wired enforcement scripts -- are protected by default at the room
# ROOT only; a Builder's own worktree copies (.worktrees/issue-N/hooks/...)
# stay editable. Best-effort root resolution: if it can't be resolved (no
# orchestrator.yaml findable -- this isn't a harness room at all), this
# ADDITIVE check is simply skipped; the .claude/.agents/protected_paths
# checks above/below are unaffected either way. orc_is_enforcement_layer_path
# physically resolves both sides itself (symlink-safe) -- no cd/pwd needed
# here, see lib/guard-write.sh's matching comment.
ROOT=""
if CANON_DIR="$(qsg_resolve_canon_dir 2>/dev/null)"; then
  ROOT="$(dirname "$CANON_DIR")"
fi

if [ -n "$ROOT" ] && orc_is_enforcement_layer_path "$FILE_PATH" "$ROOT"; then
  deny "guard-write: blocked write into '$FILE_PATH' -- hooks/, lib/, and bin/ are the harness's own live wired enforcement scripts, protected by default at the room root (a worktree's own copies under .worktrees/<issue>/ stay editable -- that's where a Builder legitimately edits them). Work in a worktree via lib/orc-worktree.sh and land the change through review, same as any other code change."
fi

while IFS= read -r protected; do
  [ -z "$protected" ] && continue
  case "$FILE_PATH" in
    "$protected"*|*"/$protected"*)
      deny "guard-write: blocked write into protected path '$protected' (see AGENTS.md / orchestrator.yaml): $FILE_PATH"
      ;;
  esac
done <<< "$(orc_protected_paths)"

echo '{"decision":"allow"}'
exit 0