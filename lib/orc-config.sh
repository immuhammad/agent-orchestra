#!/bin/bash
# .harness/orc-config.sh — minimal orchestrator.yaml v1 reader.
#
# No yq/PyYAML dependency (neither is guaranteed present) -- this is a
# purpose-built reader for the small, fixed schema in orchestrator.yaml, not a
# general YAML parser. It supports scalars (`key: value`) and `protected_paths`
# as either an inline list (`[a, b]`) or a block list (`- a` / `- b`).
#
# issue #18 (B-i): protected_paths comes ONLY from orchestrator.yaml --
# there is no hardcoded project-specific default (the old "career-ops/"
# default was a leftover from this harness's original single-consumer
# extraction; project-agnostic by design now that every project is its own
# clone). Missing/malformed config means EMPTY protected_paths, not a
# widened set of blocked writes. This does NOT unprotect the harness core:
# script-exec/git-ops are separately covered by guard.sh's own G-series
# rules, and hook CONFIG (.claude/, .agents/) is separately covered by
# orc_is_harness_config_path below -- neither depends on this
# project-configurable list (issue #31: a missing/empty protected_paths
# must never leave .claude/settings.json or .agents/hooks.json editable,
# since those wire the guards themselves).
#
# Path resolution: ORC_CONFIG_FILE overrides (tests use this); otherwise
# "orchestrator.yaml" resolved relative to CWD, since guard hooks and `orc`
# both run with CWD at the project repo root.

ORC_DEFAULT_PROTECTED_PATHS=""

# orc_harness_config_dirs -- one hardcoded default-protected dir per line:
# .claude/ and .agents/, which wire the harness's OWN enforcement (guard.sh,
# guard-write.sh, quota-stop-gate.sh, the Stop hook, agy's guard hooks).
# Issue #31 (agy's probe-3 on PR #30): these must be protected BY DEFAULT,
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
# parses to an empty list (ORC_DEFAULT_PROTECTED_PATHS is empty, issue #18
# B-i -- see the header comment above).
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

# orc_get_budget_pct <pool> -- prints budgets.<pool>.failsafe_pct. Supports
# the block mapping style: `budgets:\n  <pool>:\n    failsafe_pct: X` -- same
# nested-lookup shape as orc_get_role_model (roles.<role>.model) above.
# issue #86: orc_get_scalar only reads TOP-LEVEL `key: value` lines, so it
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

# orc_session_name [fallback] -- derives the tmux SESSION name this
# project's control room runs under, from orchestrator.yaml's `project`
# scalar (falling back to the given default, or "harness", if unset).
#
# issue #18 item 7 + issue #19: `orc up` and dispatch.sh/watch.sh's pane
# targeting both used to default to a hardcoded "harness" session name --
# harmless with one project running, but with two clone-per-project
# control rooms live at once, a hardcoded default nudges the WRONG
# project's session (live-repro'd in issue #19: dispatch nudged a stale
# `harness:0.1` pane instead of the actual project's session). Deriving
# from THIS project's own orchestrator.yaml (the same file bin/orc and
# dispatch.sh already resolve against) means every clone's session name is
# unique to its own project by construction, not by convention.
#
# '.' and ':' are sanitized to '-' since tmux reserves both as separators
# in its own session:window.pane target syntax (a literal '.' or ':' in a
# session name would make `$session:0.0`-style targets ambiguous).
orc_session_name() {
  local fallback="${1:-harness}"
  local name
  name="$(orc_get_scalar project)"
  name="${name:-$fallback}"
  echo "$name" | tr '.:' '--'
}
