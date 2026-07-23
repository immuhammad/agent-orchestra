#!/bin/bash
# lib/cmd-inspect-lib.sh — shared quote-aware Bash command-string
# splitting. Used by lib/guard.sh (the thin destructive-command deny
# list, #141 layer 3 — anchors every check at a split segment's leading
# tokens) and lib/quota-stop-lib.sh (the quota gate's allow-list, built on
# the same segmenter plus the unquoted-redirect check below). ONE
# quote-aware scanner so the two guards can never drift on how they see
# quoting/escaping; #39's original root cause was inspecting raw TEXT
# instead of what a real shell would actually execute, and a second
# hand-rolled parser here would just reopen that same class of hole
# somewhere else.
#
# The tokenizer / write-target resolution half that used to live here
# (orc_tokenize_words, orc_segment_write_targets, orc_is_opaque_executor
# and everything built on top of them) was PRUNED in #139: #141's
# guard-layer redesign moved protected-path enforcement to bin/orc-protect
# (kernel immutability) and GitHub branch protection, and #147's guard.sh
# rewrite dropped its last consumer here.
set -uo pipefail

# orc_lexical_normalize <path> -- resolves "." and ".." path components
# PURELY LEXICALLY (no filesystem access, so it works for a target that
# doesn't exist yet -- e.g. a Write about to CREATE a new inbox .msg, or a
# guard.sh write-target that hasn't been created yet either). Echoes the
# normalized absolute path and returns 0, or returns 1 (nothing echoed) if
# ".." would climb above the root -- that can never resolve to anything
# inside a bounded prefix, so it's an unconditional reject. Originally
# lib/quota-stop-lib.sh's qsg_lexical_normalize (moved here, #39, to share
# one traversal-safe normalization implementation instead of forking a
# second copy — quota-stop-lib.sh keeps qsg_lexical_normalize as a thin
# alias). Bash 3.2 safe (plain indexed array, no associative arrays).
orc_lexical_normalize() {
  local path="$1" part
  local -a stack
  stack=()
  local IFS='/'
  for part in $path; do
    case "$part" in
      ''|'.') continue ;;
      '..')
        if [ "${#stack[@]}" -eq 0 ]; then
          return 1
        fi
        unset 'stack[${#stack[@]}-1]'
        ;;
      *) stack+=("$part") ;;
    esac
  done
  local result="" p
  for p in "${stack[@]}"; do
    result="${result}/${p}"
  done
  [ -z "$result" ] && result="/"
  echo "$result"
  return 0
}

# orc_split_top_level_segments <command string> -- echoes one shell
# "segment" per line, splitting on UNQUOTED ; && || | AND a bare unquoted
# `&` (backgrounding -- `cmd1 & cmd2` runs cmd1 in the background and
# cmd2 as an ordinary NEXT command; #39 round 2, agy's dedicated security
# pass on PR #57: a bare `&` used to be appended to the current segment
# instead of splitting it, so `echo a & tee .claude/settings.json` was
# seen as ONE segment whose leading verb is "echo", hiding the `tee` from
# the write-verb check entirely). A `&` immediately followed by `>` is
# the `&>`/`&>>` redirect operator, not backgrounding -- left embedded in
# the segment so callers see it as one shell metacharacter, same as a
# real shell would. Quote-aware: a separator character inside a single- or
# double-quoted argument is passed through as literal text, not treated as
# a split point -- INCLUDING a backslash-escaped double-quote inside an
# already-open double-quoted argument (#139: the original scan closed the
# quote on ANY matching quote char with no backslash lookback, so
# `"a\"b;c"` desynced after the escaped `"` and the embedded `;` split as
# if unquoted). Single quotes are deliberately NOT given the same
# lookback: POSIX gives backslash no special meaning inside single quotes
# at all, so a `'` there always closes the string regardless of what
# precedes it. Bash 3.2 safe (character-by-character scan, no regex
# extensions).
orc_split_top_level_segments() {
  local s="$1" i c quote="" cur="" len escape=0
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ -n "$quote" ]; then
      cur="${cur}${c}"
      if [ "$escape" -eq 1 ]; then
        escape=0
      elif [ "$quote" = '"' ] && [ "$c" = '\' ]; then
        escape=1
      elif [ "$c" = "$quote" ]; then
        quote=""
      fi
      i=$((i + 1))
      continue
    fi
    case "$c" in
      "'"|'"')
        quote="$c"
        cur="${cur}${c}"
        ;;
      ';')
        echo "$cur"; cur=""
        ;;
      '&')
        if [ "${s:$((i + 1)):1}" = "&" ]; then
          echo "$cur"; cur=""
          i=$((i + 1))
        elif [ "${s:$((i + 1)):1}" = ">" ]; then
          cur="${cur}${c}"
        else
          echo "$cur"; cur=""
        fi
        ;;
      '|')
        if [ "${s:$((i + 1)):1}" = "|" ]; then
          echo "$cur"; cur=""
          i=$((i + 1))
        else
          echo "$cur"; cur=""
        fi
        ;;
      *)
        cur="${cur}${c}"
        ;;
    esac
    i=$((i + 1))
  done
  echo "$cur"
}

# orc_segment_has_unquoted_redirect <segment> -- true if an unquoted `<` or
# `>` appears anywhere (fd-prefixed or not; the fd digit/`&` itself isn't a
# redirect char so this only needs to watch for the `<`/`>` proper).
# Quote-aware for the same reason the split above is -- including the same
# backslash lookback for an escaped double-quote (#139; see
# orc_split_top_level_segments's header for the failure shape). Used by
# lib/quota-stop-lib.sh's qsg_split_top_level to reproduce its original
# "any unquoted redirect anywhere -> hard reject" behavior on top of the
# shared segmenter.
orc_segment_has_unquoted_redirect() {
  local s="$1" i c quote="" len escape=0
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ -n "$quote" ]; then
      if [ "$escape" -eq 1 ]; then
        escape=0
      elif [ "$quote" = '"' ] && [ "$c" = '\' ]; then
        escape=1
      elif [ "$c" = "$quote" ]; then
        quote=""
      fi
      i=$((i + 1))
      continue
    fi
    case "$c" in
      "'"|'"') quote="$c" ;;
      '<'|'>') return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}
