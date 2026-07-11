#!/bin/bash
# .harness/handoff-lib.sh — shared helper (T31, issue #68 item A).
#
# handoff.md is now a REPLACED current-state file, not an append log (git
# history is the archive: `git log -p .harness/handoff.md`). Hook scripts
# that used to `>>` a fresh dated section onto the end every time they
# fired (PreCompact checkpoints, StopFailure rate-limit notes) would defeat
# that by re-growing the file forever. handoff_replace_section lets a hook
# strip its OWN previous section before appending a fresh one, so repeated
# firings update in place instead of accumulating.
set -uo pipefail

# handoff_replace_section <file> <header-prefix>
# Removes any existing "<header-prefix>..." line (matched at the START of
# a "## " header line) through the next "## " header or EOF, in place.
# No-op if <file> doesn't exist yet or has no matching section. Caller
# appends the fresh section immediately after calling this.
handoff_replace_section() {
  local file="$1" prefix="$2"
  [ -f "$file" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v prefix="$prefix" '
    /^## / {
      if (index($0, prefix) == 1) { skip = 1; next }
      skip = 0
    }
    !skip { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}
