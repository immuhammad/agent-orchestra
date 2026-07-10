#!/bin/bash
# .harness/orc-config.sh — minimal orchestrator.yaml v1 reader (T21, issue #26).
#
# No yq/PyYAML dependency (neither is guaranteed present) -- this is a
# purpose-built reader for the small, fixed schema in orchestrator.yaml, not a
# general YAML parser. It supports scalars (`key: value`) and `protected_paths`
# as either an inline list (`[a, b]`) or a block list (`- a` / `- b`).
#
# Fail-closed contract (guards depend on this): if the config file is
# missing, unreadable, or the requested key isn't found/parseable,
# orc_protected_paths always falls back to the hardcoded default
# (career-ops/) rather than returning nothing -- a missing/broken config
# must never widen what's writable.
#
# Path resolution: ORC_CONFIG_FILE overrides (tests use this); otherwise
# "orchestrator.yaml" resolved relative to CWD, since guard hooks and `orc`
# both run with CWD at the project repo root.

ORC_DEFAULT_PROTECTED_PATHS="career-ops/"

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

# orc_protected_paths -- prints one protected path per line. Falls back to
# the hardcoded default if the config is missing, has no protected_paths
# key, or the key parses to an empty list (all treated as "malformed" per
# the fail-closed contract in T21's ticket).
orc_protected_paths() {
  local yaml
  yaml="$(orc_config_file)"

  if [ ! -f "$yaml" ]; then
    echo "$ORC_DEFAULT_PROTECTED_PATHS"
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
    echo "$ORC_DEFAULT_PROTECTED_PATHS"
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
