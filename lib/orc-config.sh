#!/bin/bash
# .harness/orc-config.sh — minimal orchestrator.yaml v1 reader.
#
# No yq/PyYAML dependency (neither is guaranteed present) -- this is a
# purpose-built reader for the small, fixed schema in orchestrator.yaml, not a
# general YAML parser. It supports scalars (`key: value`) and `protected_paths`
# as either an inline list (`[a, b]`) or a block list (`- a` / `- b`).
#
# protected_paths comes ONLY from orchestrator.yaml --
# there is no hardcoded project-specific default (the old "career-ops/"
# default was a leftover from this harness's original single-consumer
# extraction; project-agnostic by design now that every project is its own
# clone). Missing/malformed config means EMPTY protected_paths, not a
# widened set of blocked writes. This does NOT unprotect the harness core:
# script-exec/git-ops are separately covered by guard.sh's own G-series
# rules, and hook CONFIG (.claude/, .agents/) is separately covered by
# orc_is_harness_config_path below -- neither depends on this
# project-configurable list (a missing/empty protected_paths
# must never leave .claude/settings.json or .agents/hooks.json editable,
# since those wire the guards themselves).
#
# Path resolution: ORC_CONFIG_FILE overrides (tests use this); otherwise
# "orchestrator.yaml" resolved relative to CWD, since guard hooks and `orc`
# both run with CWD at the project repo root.

ORC_DEFAULT_PROTECTED_PATHS=""

_ORC_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./cmd-inspect-lib.sh
source "$_ORC_CONFIG_LIB_DIR/cmd-inspect-lib.sh"

# orc_harness_config_dirs -- one hardcoded default-protected dir per line:
# .claude/ and .agents/, which wire the harness's OWN enforcement (guard.sh,
# guard-write.sh, quota-stop-gate.sh, the Stop hook, agy's guard hooks).
# These must be protected BY DEFAULT,
# independent of orchestrator.yaml's protected_paths -- otherwise a missing
# config entry (or an adversarial/malfunctioning agent editing
# orchestrator.yaml first) leaves the config that wires a guard editable by
# the very agent that guard is meant to constrain. Single source list so
# guard.sh's Bash-command check and guard-write.sh's Write/Edit-path check
# (via orc_is_harness_config_path below) can never drift apart.
orc_harness_config_dirs() {
  printf '%s\n' ".claude/" ".agents/"
}

# orc_is_harness_config_path <path> -- true if path falls under one of
# orc_harness_config_dirs. Used by guard-write.sh (Write/Edit tool calls).
orc_is_harness_config_path() {
  case "$1" in
    .claude/*|*/.claude/*|.agents/*|*/.agents/*) return 0 ;;
    *) return 1 ;;
  esac
}

# orc_enforcement_layer_dirs -- hooks/ lib/ bin/, one per line: the room
# root's own LIVE, wired enforcement scripts (guard.sh/guard-write.sh
# themselves live in lib/, the PreToolUse hooks live in hooks/, bin/ holds
# orc/orc-protect/orc-install-skills). A DELIBERATE SIBLING to
# orc_harness_config_dirs above, not a merge into it (issue #189, live
# incident) -- these three are excluded from bin/orc-protect's kernel-
# immutability target set on purpose (git pull/merge must keep writing
# them on the room root with no protect-off/on dance); the root-anchored
# software check in orc_is_enforcement_layer_path below is their whole
# backstop, not a supplement to a kernel one. Do not widen
# orc_is_harness_config_path's segment-matched list to cover these --
# that match style (`*/hooks/*`) would block a Builder's legitimate
# worktree edits, which the resolved-path check below is built to allow.
orc_enforcement_layer_dirs() {
  printf '%s\n' "hooks/" "lib/" "bin/"
}

# orc_is_protected_path <file_path> <root> -- true if file_path resolves
# to an orchestrator.yaml-configured protected_paths entry at the room
# ROOT -- NOT inside <root>/.worktrees/**, which is exempt for the SAME
# reason orc_is_enforcement_layer_path exempts it there: protection is
# about a DIRECT, unreviewed edit to the live root copy, not about the
# normal branch+PR+review workflow a worktree's own copy still has to go
# through -- bin/orc-protect's kernel immutability (layer 1) already
# never touches .worktrees/ copies either, it only ever chflags/chattr's
# the room ROOT's own instance, so this brings the software check in
# line with what the kernel layer already does.
#
# ROOT-ANCHORED against the path taken RELATIVE TO ROOT -- NOT a raw
# substring match anywhere in the full (often absolute) string, which is
# what this function replaces (agy's dedicated security review of issue
# #189's diff, round 2: `case "$FILE_PATH" in *"/$protected"*)` matched
# an absolute path's protected-looking substring UNCONDITIONALLY,
# including one sitting inside a worktree's own .worktrees/issue-N/
# prefix -- exactly the same false-positive class hooks/lib/bin already
# had to be fixed against). Reads protected_paths from THIS root
# explicitly (a local ORC_CONFIG_FILE override, same idiom bin/orc's
# orc_watch_identity already uses) rather than orc_protected_paths'
# own $PWD-relative default, so the result doesn't depend on the
# caller's current directory.
orc_is_protected_path() {
  local file_path="$1" root="$2" resolved root_normalized wt_prefix rel p
  [ -z "$file_path" ] && return 1
  [ -z "$root" ] && return 1
  resolved="$(orc_physical_normalize "$file_path")" || return 1
  root_normalized="$(orc_physical_normalize "$root")" || return 1
  wt_prefix="$root_normalized/.worktrees"
  case "$resolved" in
    "$wt_prefix"|"$wt_prefix"/*) return 1 ;;
  esac
  case "$resolved" in
    "$root_normalized"/*) rel="${resolved#"$root_normalized"/}" ;;
    *) rel="$resolved" ;;
  esac
  local ORC_CONFIG_FILE="$root/orchestrator.yaml"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$rel" in
      "$p"*) return 0 ;;
    esac
  done < <(orc_protected_paths)
  return 1
}

# orc_is_enforcement_layer_path <file_path> <root> -- true if file_path
# resolves to somewhere under <root>/hooks, <root>/lib, or <root>/bin --
# UNLESS it resolves under <root>/.worktrees, which is exempt (a Builder
# legitimately edits hooks/lib/bin inside .worktrees/issue-N/, the dogfood
# room's own daily workflow; only the ROOT's own live wired copies are
# protected here). A RESOLVED-PATH check via orc_lexical_normalize
# (lib/cmd-inspect-lib.sh), not a string prefix or path-segment match --
# a naive prefix check on the UNNORMALIZED path would let
# ".worktrees/../hooks/x" spoof the exemption (it string-prefixes under
# .worktrees/ while actually resolving to <root>/hooks/x); normalizing
# BEFORE comparing collapses the ".." first, so the spoof can't survive.
orc_is_enforcement_layer_path() {
  local file_path="$1" root="$2" resolved root_normalized wt_prefix d dir_path
  [ -z "$file_path" ] && return 1
  [ -z "$root" ] && return 1
  # orc_physical_normalize, not orc_lexical_normalize -- a symlink can
  # otherwise spoof the .worktrees exemption below (agy's dedicated
  # security review of this diff, finding 1; see that function's own
  # header for the exact repro). Both sides resolved the SAME way so
  # they stay comparable regardless of which one a caller passes
  # pre-resolved vs raw.
  resolved="$(orc_physical_normalize "$file_path")" || return 1
  root_normalized="$(orc_physical_normalize "$root")" || return 1
  wt_prefix="$root_normalized/.worktrees"
  case "$resolved" in
    "$wt_prefix"|"$wt_prefix"/*) return 1 ;;
  esac
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    dir_path="$root_normalized/${d%/}"
    case "$resolved" in
      "$dir_path"|"$dir_path"/*) return 0 ;;
    esac
  done < <(orc_enforcement_layer_dirs)
  return 1
}

orc_config_file() {
  echo "${ORC_CONFIG_FILE:-orchestrator.yaml}"
}

# orc_get_scalar <key> -- prints a top-level `key: value` scalar, stripping
# optional quotes. Prints nothing (not even a blank line) if the file is
# missing or the key isn't a top-level scalar line.
orc_get_scalar() {
  local key="$1"
  local yaml
  yaml="$(orc_config_file)"
  [ -f "$yaml" ] || return 0

  awk -v k="^${key}:" '
    $0 ~ k {
      line = $0
      sub(k "[[:space:]]*", "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      gsub(/^"|"$/, "", line)
      gsub(/^'"'"'|'"'"'$/, "", line)
      print line
      exit
    }
  ' "$yaml"
}

# orc_protected_paths -- prints one protected path per line, or nothing at
# all if the config is missing, has no protected_paths key, or the key
# parses to an empty list (ORC_DEFAULT_PROTECTED_PATHS is empty --
# see the header comment above).
orc_protected_paths() {
  local yaml
  yaml="$(orc_config_file)"

  if [ ! -f "$yaml" ]; then
    [ -n "$ORC_DEFAULT_PROTECTED_PATHS" ] && echo "$ORC_DEFAULT_PROTECTED_PATHS"
    return 0
  fi

  local paths
  paths="$(awk '
    /^protected_paths:[[:space:]]*\[/ {
      line = $0
      sub(/^protected_paths:[[:space:]]*\[/, "", line)
      sub(/\].*$/, "", line)
      n = split(line, items, ",")
      for (i = 1; i <= n; i++) {
        v = items[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        gsub(/^'"'"'|'"'"'$/, "", v)
        if (v != "") print v
      }
      next
    }
    /^protected_paths:[[:space:]]*$/ { in_list = 1; next }
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      gsub(/^"|"$/, "", line)
      gsub(/^'"'"'|'"'"'$/, "", line)
      if (line != "") print line
      next
    }
    in_list && /^[^[:space:]]/ { in_list = 0 }
  ' "$yaml")"

  if [ -z "$paths" ]; then
    [ -n "$ORC_DEFAULT_PROTECTED_PATHS" ] && echo "$ORC_DEFAULT_PROTECTED_PATHS"
    return 0
  fi

  echo "$paths"
}

# orc_github_repo -- prints the top-level github_repo scalar ONLY if it
# matches ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ (a plain owner/repo slug);
# anything else (missing key, missing file, extra segments, whitespace,
# shell metacharacters) reads as empty. Fail closed by design -- this
# value is interpolated into `gh --repo` on every scripted watcher call
# site, so a malformed value must never reach a command line unvalidated.
orc_github_repo() {
  local val
  val="$(orc_get_scalar github_repo)"
  if [[ "$val" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "$val"
  fi
}

# orc_get_role_model <role> -- prints roles.<role>.model. Supports the block
# mapping style: `roles:\n  <role>:\n    model: x\n    effort: y`.
orc_get_role_model() {
  local role="$1"
  local yaml
  yaml="$(orc_config_file)"
  [ -f "$yaml" ] || return 0

  awk -v role_key="${role}:" '
    /^roles:[[:space:]]*$/ { in_roles = 1; next }
    in_roles && /^[^[:space:]]/ { in_roles = 0 }
    in_roles {
      trimmed = $0
      gsub(/^[[:space:]]+/, "", trimmed)
      if (trimmed == role_key) { in_role = 1; role_indent = length($0) - length(trimmed); next }
      if (in_role) {
        indent = length($0) - length(trimmed)
        if (trimmed ~ /^[^[:space:]]/ && indent <= role_indent) { in_role = 0 }
      }
      if (in_role && trimmed ~ /^model:/) {
        line = trimmed
        sub(/^model:[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line)
        gsub(/^'"'"'|'"'"'$/, "", line)
        print line
        exit
      }
    }
  ' "$yaml"
}

# orc_get_role_effort <role> -- prints roles.<role>.effort. Same nested-
# lookup shape as orc_get_role_model above (orc_init_force's
# bare --force needs to recover BOTH model and effort from an existing
# orchestrator.yaml to resync via the same answers-file pipeline fresh
# init uses).
orc_get_role_effort() {
  local role="$1"
  local yaml
  yaml="$(orc_config_file)"
  [ -f "$yaml" ] || return 0

  awk -v role_key="${role}:" '
    /^roles:[[:space:]]*$/ { in_roles = 1; next }
    in_roles && /^[^[:space:]]/ { in_roles = 0 }
    in_roles {
      trimmed = $0
      gsub(/^[[:space:]]+/, "", trimmed)
      if (trimmed == role_key) { in_role = 1; role_indent = length($0) - length(trimmed); next }
      if (in_role) {
        indent = length($0) - length(trimmed)
        if (trimmed ~ /^[^[:space:]]/ && indent <= role_indent) { in_role = 0 }
      }
      if (in_role && trimmed ~ /^effort:/) {
        line = trimmed
        sub(/^effort:[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line)
        gsub(/^'"'"'|'"'"'$/, "", line)
        print line
        exit
      }
    }
  ' "$yaml"
}

# orc_get_budget_pct <pool> -- prints budgets.<pool>.failsafe_pct. Supports
# the block mapping style: `budgets:\n  <pool>:\n    failsafe_pct: X` -- same
# nested-lookup shape as orc_get_role_model (roles.<role>.model) above.
# orc_get_scalar only reads TOP-LEVEL `key: value` lines, so it
# can't address a nested key like this directly; reuses that function's
# proven indent-tracking awk technique rather than hand-rolling a second
# yaml parser. Prints nothing if the file, the budgets: block, the pool, or
# the failsafe_pct key is missing -- callers must supply their own fallback.
orc_get_budget_pct() {
  local pool="$1"
  local yaml
  yaml="$(orc_config_file)"
  [ -f "$yaml" ] || return 0

  awk -v pool_key="${pool}:" '
    /^budgets:[[:space:]]*$/ { in_budgets = 1; next }
    in_budgets && /^[^[:space:]]/ { in_budgets = 0 }
    in_budgets {
      trimmed = $0
      gsub(/^[[:space:]]+/, "", trimmed)
      if (trimmed == pool_key) { in_pool = 1; pool_indent = length($0) - length(trimmed); next }
      if (in_pool) {
        indent = length($0) - length(trimmed)
        if (trimmed ~ /^[^[:space:]]/ && indent <= pool_indent) { in_pool = 0 }
      }
      if (in_pool && trimmed ~ /^failsafe_pct:/) {
        line = trimmed
        sub(/^failsafe_pct:[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line)
        gsub(/^'"'"'|'"'"'$/, "", line)
        print line
        exit
      }
    }
  ' "$yaml"
}

# orc_get_nested <section> <key> -- prints <section>.<key> from a two-level
# block mapping (`section:\n  key: value`). Same indent-tracking awk shape
# as orc_get_role_model/orc_get_budget_pct above, generalized for the
# `dispatch:`/`watch:` config blocks. Prints nothing if the file,
# the section, or the key is missing -- callers must supply their own
# fallback (every key read here ships with a live consumer).
orc_get_nested() {
  local section="$1" key="$2"
  local yaml
  yaml="$(orc_config_file)"
  [ -f "$yaml" ] || return 0

  awk -v sec="^${section}:[[:space:]]*$" -v key_re="^${key}:" '
    $0 ~ sec { in_sec = 1; next }
    in_sec && /^[^[:space:]]/ { in_sec = 0 }
    in_sec {
      trimmed = $0
      gsub(/^[[:space:]]+/, "", trimmed)
      if (trimmed ~ key_re) {
        sub(key_re "[[:space:]]*", "", trimmed)
        sub(/[[:space:]]*#.*$/, "", trimmed)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
        gsub(/^"|"$/, "", trimmed)
        gsub(/^'"'"'|'"'"'$/, "", trimmed)
        print trimmed
        exit
      }
    }
  ' "$yaml"
}

# orc_session_name [fallback] -- derives the tmux SESSION name this
# project's control room runs under, from orchestrator.yaml's `project`
# scalar (falling back to the given default, or "harness", if unset).
#
# `orc up` and dispatch.sh/watch.sh's pane
# targeting both used to default to a hardcoded "harness" session name --
# harmless with one project running, but with two clone-per-project
# control rooms live at once, a hardcoded default nudges the WRONG
# project's session (live-repro'd: dispatch nudged a stale
# `harness:0.1` pane instead of the actual project's session). Deriving
# from THIS project's own orchestrator.yaml (the same file bin/orc and
# dispatch.sh already resolve against) means every clone's session name is
# unique to its own project by construction, not by convention.
#
# '.' and ':' are sanitized to '-' since tmux reserves both as separators
# in its own session:window.pane target syntax (a literal '.' or ':' in a
# session name would make `$session:0.0`-style targets ambiguous).
#
# Sanitization widened from just '.'/':' to EVERY
# character outside [A-Za-z0-9_-]. The session name is interpolated into
# dozens of tmux target strings and -- since the attach-snap hook -- into
# a command string `/bin/sh` executes at hook-fire time: a space in the
# project name word-splits that command apart, and a single quote closes
# the sh string early = arbitrary shell injection. A closed charset at
# the source makes every downstream interpolation safe by construction
# (orc_build_session additionally REFUSES a hand-set ORC_SESSION that
# bypasses this derivation). '\n' stays in tr's keep-set so the trailing
# newline of echo survives instead of becoming a '-'.
orc_session_name() {
  local fallback="${1:-harness}"
  local name
  name="$(orc_get_scalar project)"
  name="${name:-$fallback}"
  echo "$name" | tr -c 'A-Za-z0-9_\n-' '-'
}
