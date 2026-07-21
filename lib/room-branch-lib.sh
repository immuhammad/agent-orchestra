#!/bin/bash
# lib/room-branch-lib.sh — shared room-branch-state helper (issue #60 task B).
#
# room_branch_state <root> tells callers whether the git checkout at <root>
# currently sits on the project's integration branch (same resolution
# orc-worktree.sh already uses: orchestrator.yaml's integration_branch,
# falling back to "uat"). Three states:
#   ok            -- HEAD is the integration branch
#   mismatch <br> -- HEAD is a different, resolvable branch <br>
#   unknown       -- anything indeterminate (root doesn't exist, isn't a git
#                    repo, or HEAD is detached) -- callers MUST fail closed
#                    on unknown, never treat it as ok.
#
# Override checking (room_branch_override_reason / room_branch_override_active)
# is intentionally separate from room_branch_state: mismatch detection stays
# pure and side-effect-free so it's cheap to call on every tool invocation
# (task E's per-call guard). Callers decide what an override means
# (refuse/warn/proceed) and are responsible for surfacing/logging it
# themselves, since only they know the right audience (a hook's stderr
# denial vs. decisions.log on a session build).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./orc-config.sh
source "$DIR/orc-config.sh"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"

# room_branch_integration_branch <root> -- prints the configured
# integration branch name (orchestrator.yaml's integration_branch,
# falling back to "uat"), same resolution orc-worktree.sh uses. Split out
# from room_branch_state so callers that only need the branch NAME (e.g.
# the restore-command allow-list below) don't duplicate this resolution.
room_branch_integration_branch() {
  local root="${1:?usage: room_branch_integration_branch <root>}"
  local integration
  integration="$(cd "$root" 2>/dev/null && orc_get_scalar integration_branch 2>/dev/null)"
  echo "${integration:-uat}"
}

# room_branch_state <root> -> prints "ok", "mismatch <branch>", or "unknown"
room_branch_state() {
  local root="${1:?usage: room_branch_state <root>}"
  local current integration

  current="$(cd "$root" 2>/dev/null && git symbolic-ref --short -q HEAD 2>/dev/null)"
  if [ -z "$current" ]; then
    echo "unknown"
    return 0
  fi

  integration="$(room_branch_integration_branch "$root")"

  if [ "$current" = "$integration" ]; then
    echo "ok"
  else
    echo "mismatch $current"
  fi
}

# room_branch_override_reason <root> -> prints the room-branch-override
# file's content (the reason, whitespace-collapsed to one line) if
# <root>'s canonical .harness/state/room-branch-override exists; prints
# nothing otherwise. Does not consider ORC_ALLOW_UNMERGED_HARNESS -- that
# override is env-visible on its own and has no reason text to surface.
room_branch_override_reason() {
  local root="${1:?usage: room_branch_override_reason <root>}"
  local canon_dir override_file
  canon_dir="$(harness_canonical_dir "$root" 2>/dev/null)" || return 0
  override_file="$canon_dir/state/room-branch-override"
  [ -f "$override_file" ] || return 0
  awk 'NF{ if (out) out = out " " $0; else out = $0 } END{ print out }' "$override_file"
}

# room_branch_override_active <root> -> exit 0 (true) if either override
# mechanism is in effect: the file (any content, even empty -- presence is
# the signal) or ORC_ALLOW_UNMERGED_HARNESS=1. Exit 1 otherwise.
room_branch_override_active() {
  local root="${1:?usage: room_branch_override_active <root>}"
  [ "${ORC_ALLOW_UNMERGED_HARNESS:-}" = "1" ] && return 0
  local canon_dir
  canon_dir="$(harness_canonical_dir "$root" 2>/dev/null)" || return 1
  [ -f "$canon_dir/state/room-branch-override" ]
}

# room_branch_restore_command_allowed <command> <root> -- issue #60 task E:
# the ONE Bash escape hatch the room-branch gate allows beyond the shared
# qsg park-honestly set (lib/quota-stop-lib.sh) -- a gated session must be
# able to restore itself onto the integration branch, or the gate has no
# way out short of an operator override. Deliberately as strict as
# lib/quota-stop-lib.sh's own allow-list: any chaining/redirection/
# substitution metacharacter hard-rejects outright, and the trimmed
# command must be EXACTLY "git checkout <integration>" or "git switch
# <integration>" -- no extra flags, no trailing arguments.
room_branch_restore_command_allowed() {
  local cmd="$1" root="$2" integration trimmed
  [ -z "$cmd" ] && return 1
  case "$cmd" in
    *';'*|*'&&'*|*'||'*|*'|'*|*'<'*|*'>'*|*'$('*|*'`'*|*'&'*) return 1 ;;
  esac
  trimmed="$(echo "$cmd" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  integration="$(room_branch_integration_branch "$root")"
  case "$trimmed" in
    "git checkout $integration"|"git switch $integration") return 0 ;;
    *) return 1 ;;
  esac
}
