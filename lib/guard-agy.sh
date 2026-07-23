#!/bin/bash
# .harness/guard-agy.sh — PreToolUse guard for agy (Antigravity CLI), wired
# via .agents/hooks.json. Denies any command matching a line in
# banned-patterns.txt.
#
# banned-patterns.txt now also denies `git restore`, `git
# checkout`, `git commit`, and `git reset` for agy specifically -- the
# single-writer rule (see AGENTS.md Dispatch Protocol) makes Reviewer/Scribe
# output-only to the PR, the inbox .ack, and decisions.log (via
# log-decision.sh); they never write to the shared checkout's git state or
# edit handoff.md. This follows a confirmed live collision: agy edited
# handoff.md concurrently with the Builder, then `git restore`d
# decisions.log mid-append (destroying two uncommitted Builder lines), then
# briefly committed onto local uat. Read ops (diff/log/show/status/branch
# --contains, gh pr diff/view) are deliberately NOT banned -- review needs
# those.
set -euo pipefail

# Find the directory where this script resides to locate banned-patterns.txt
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./orc-config.sh
source "$DIR/orc-config.sh"
# shellcheck source=./cmd-inspect-lib.sh
source "$DIR/cmd-inspect-lib.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.toolCall.args.CommandLine // .toolCall.args.commandLine // empty')

if [ -z "$COMMAND" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

BANNED_FILE="$DIR/banned-patterns.txt"

if echo "$COMMAND" | grep -Eq -f "$BANNED_FILE"; then
  echo '{"decision":"deny", "reason":"guard-agy.sh: Command blocked by banned patterns"}'
  exit 0
fi

# issue #15: protected_paths enforcement, parameterized from
# orchestrator.yaml via orc_protected_paths -- the SAME source
# guard.sh/guard-write.sh read, so all three guards enforce one policy.
# Before this, guard-agy.sh did ZERO path-based enforcement: PR #17
# removed the hardcoded career-ops/ special case but left a real gap
# ("the reviewer is the agent least bound by the project's own rules").
#
# Uses the shared, hardened write-target extraction from cmd-inspect-
# lib.sh (orc_split_top_level_segments/orc_segment_write_targets)
# rather than a raw substring grep against $COMMAND -- issue #39's own
# history (guard.sh's original whole-string grep was both bypassable
# via cd/variables AND a false-positive generator on read-only commands
# merely mentioning a path) is exactly the bug class a naive
# reimplementation here would reopen in a second file.
#
# Scope, deliberately narrower than guard.sh: tracks `cd` across
# segments (closes the same relative-write bypass guard.sh closes), but
# does NOT replicate guard.sh's variable-substitution table
# (_guard_resolve_word/guard_var_lookup) -- instead FAILS CLOSED (deny)
# on any write-target word that still contains an unresolved $VAR or
# command substitution after tokenizing. That's a strictly SAFER (if
# occasionally more conservative) subset of guard.sh's own fail-closed
# posture, not a weaker one -- reasonable for a single ticket given
# agy's already-narrow blast radius (banned-patterns.txt above already
# blocks every git write op for it). If review finds this insufficient,
# it's a fix-round away from guard.sh's fuller table, not a redesign.

_guard_agy_deny() {
  jq -n --arg reason "$1" '{decision:"deny", reason:$reason}'
  exit 0
}

_guard_agy_resolve_protected() {
  local rel="$1" abs
  case "$rel" in
    /*) abs="$rel" ;;
    *) abs="$PWD/$rel" ;;
  esac
  orc_lexical_normalize "$abs" | sed 's:/$::'
}

AGY_DEFAULT_LEX=(); AGY_DEFAULT_LABEL=()
while IFS= read -r d; do
  [ -z "$d" ] && continue
  resolved="$(_guard_agy_resolve_protected "$d")" || continue
  AGY_DEFAULT_LEX+=("$resolved")
  AGY_DEFAULT_LABEL+=("$d")
done <<< "$(orc_harness_config_dirs)"

AGY_CUSTOM_LEX=(); AGY_CUSTOM_LABEL=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  resolved="$(_guard_agy_resolve_protected "$p")" || continue
  AGY_CUSTOM_LEX+=("$resolved")
  AGY_CUSTOM_LABEL+=("$p")
done <<< "$(orc_protected_paths)"

# _guard_agy_matched_label <lexically-normalized target> -- echoes
# "default\t<label>" or "custom\t<label>" on a match, nothing otherwise.
_guard_agy_matched_label() {
  local target="${1%/}" idx
  for ((idx = 0; idx < ${#AGY_DEFAULT_LEX[@]}; idx++)); do
    case "$target" in
      "${AGY_DEFAULT_LEX[$idx]}"|"${AGY_DEFAULT_LEX[$idx]}"/*)
        printf 'default\t%s\n' "${AGY_DEFAULT_LABEL[$idx]}"; return 0 ;;
    esac
  done
  for ((idx = 0; idx < ${#AGY_CUSTOM_LEX[@]}; idx++)); do
    case "$target" in
      "${AGY_CUSTOM_LEX[$idx]}"|"${AGY_CUSTOM_LEX[$idx]}"/*)
        printf 'custom\t%s\n' "${AGY_CUSTOM_LABEL[$idx]}"; return 0 ;;
    esac
  done
  return 0
}

guard_agy_cwd="$PWD"

while IFS= read -r seg; do
  trimmed="$(echo "$seg" | sed -E 's/^[[:space:]]*//')"
  [ -z "$trimmed" ] && continue

  if echo "$trimmed" | grep -Eq '^cd([[:space:]]|$)'; then
    cd_arg="$(echo "$trimmed" | sed -E 's/^cd[[:space:]]*//; s/[[:space:]]+$//')"
    cd_arg="${cd_arg%\"}"; cd_arg="${cd_arg#\"}"
    cd_arg="${cd_arg%\'}"; cd_arg="${cd_arg#\'}"
    if [ -n "$cd_arg" ] && [ "$cd_arg" != "-" ]; then
      new_cwd="$(cd "$guard_agy_cwd" 2>/dev/null && cd "$cd_arg" 2>/dev/null && pwd)"
      [ -n "$new_cwd" ] && guard_agy_cwd="$new_cwd"
    fi
  fi

  while IFS= read -r target; do
    [ -z "$target" ] && continue
    case "$target" in
      *'$('*|*'`'*|*'$'*)
        _guard_agy_deny "guard-agy.sh: write target could not be verified (unresolved variable or command substitution in '$target'), failing closed"
        ;;
    esac
    case "$target" in
      /*) abs_path="$target" ;;
      *) abs_path="$guard_agy_cwd/$target" ;;
    esac
    lex_norm="$(orc_lexical_normalize "$abs_path")" || {
      _guard_agy_deny "guard-agy.sh: write target path could not be normalized ('$target'), failing closed"
    }
    lex_norm="${lex_norm%/}"
    matched="$(_guard_agy_matched_label "$lex_norm")"
    if [ -n "$matched" ]; then
      match_kind="${matched%%$'\t'*}"
      match_label="${matched#*$'\t'}"
      if [ "$match_kind" = "default" ]; then
        _guard_agy_deny "guard-agy.sh: blocked write into '$match_label' -- .claude/ and .agents/ are protected by default (they wire the guards themselves)"
      else
        _guard_agy_deny "guard-agy.sh: blocked write inside protected path '$match_label' (see orchestrator.yaml protected_paths)"
      fi
    fi
  done < <(orc_segment_write_targets "$trimmed")
done < <(orc_split_top_level_segments "$COMMAND")

echo '{"decision":"allow"}'
exit 0
