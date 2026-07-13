#!/bin/bash
# lib/cmd-inspect-lib.sh — shared quote-aware Bash command-string parsing.
# Used by BOTH lib/quota-stop-lib.sh (gated-Bash allow-list, unmodified
# behavior) and lib/guard.sh (#39: resolved write-target protected-path
# check, replacing a whole-string substring grep that was both bypassable
# — a variable or `cd` made the literal path text vanish while the shell
# still wrote exactly there — and a false-positive generator — it blocked
# any command whose TEXT merely mentioned a protected path, including
# read-only commands and unrelated write DATA that happened to describe
# the bug). ONE quote-aware scanner so the two guards can never drift on
# how they see quoting/escaping; #39's root cause was inspecting raw TEXT
# instead of what a real shell would actually execute, and a second
# hand-rolled parser here would just reopen that same class of hole
# somewhere else.
set -uo pipefail

# orc_lexical_normalize <path> -- resolves "." and ".." path components
# PURELY LEXICALLY (no filesystem access, so it works for a target that
# doesn't exist yet -- e.g. a Write about to CREATE a new inbox .msg, or a
# guard.sh write-target that hasn't been created yet either). Echoes the
# normalized absolute path and returns 0, or returns 1 (nothing echoed) if
# ".." would climb above the root -- that can never resolve to anything
# inside a bounded prefix, so it's an unconditional reject. Originally
# lib/quota-stop-lib.sh's qsg_lexical_normalize (moved here, #39, so
# guard.sh's resolved write-target check can reuse the exact same
# traversal-safe normalization instead of a second copy — quota-stop-lib.sh
# now keeps qsg_lexical_normalize as a thin alias). Bash 3.2 safe (plain
# indexed array, no associative arrays).
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
# the segment for orc_tokenize_words to recognize later, same as before.
# Quote-aware: a separator character inside a single- or double-quoted
# argument is passed through as literal text, not treated as a split
# point. Unlike lib/quota-stop-lib.sh's qsg_split_top_level (built on top
# of this), this does NOT reject on redirection -- it only splits;
# callers decide what to do with an embedded `<`/`>`. Bash 3.2 safe
# (character-by-character scan, no regex extensions).
orc_split_top_level_segments() {
  local s="$1" i c quote="" cur="" len
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ -n "$quote" ]; then
      cur="${cur}${c}"
      [ "$c" = "$quote" ] && quote=""
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
# Quote-aware for the same reason the split above is. Used by
# lib/quota-stop-lib.sh's qsg_split_top_level to reproduce its original
# "any unquoted redirect anywhere -> hard reject" behavior on top of the
# shared segmenter.
orc_segment_has_unquoted_redirect() {
  local s="$1" i c quote="" len
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ -n "$quote" ]; then
      [ "$c" = "$quote" ] && quote=""
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

# orc_tokenize_words <segment> -- echoes one shell "word" per line,
# splitting on UNQUOTED whitespace, quote-aware (the quote characters
# themselves are stripped from the emitted word, matching how a real shell
# hands the argument to a program). Output-redirect operators (`>`, `>>`,
# fd-prefixed `N>`/`N>>` via the bare-digit word immediately before a `>`,
# `&>`, `&>>`) are emitted as their OWN word even with no surrounding
# whitespace (`>file` tokenizes as ">", "file") so callers can walk the
# word stream looking for an operator followed by its target word. `<` is
# left embedded in whatever word it's part of -- guard.sh only cares about
# OUTPUT redirects (writes), not input.
orc_tokenize_words() {
  local s="$1" i c quote="" cur="" len
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then
        quote=""
      else
        cur="${cur}${c}"
      fi
      i=$((i + 1))
      continue
    fi
    case "$c" in
      "'"|'"')
        quote="$c"
        ;;
      ' '|$'\t')
        [ -n "$cur" ] && { echo "$cur"; cur=""; }
        ;;
      '>')
        [ -n "$cur" ] && { echo "$cur"; cur=""; }
        if [ "${s:$((i + 1)):1}" = ">" ]; then
          echo ">>"
          i=$((i + 1))
        else
          echo ">"
        fi
        ;;
      '&')
        if [ "${s:$((i + 1)):1}" = ">" ]; then
          [ -n "$cur" ] && { echo "$cur"; cur=""; }
          if [ "${s:$((i + 2)):1}" = ">" ]; then
            echo "&>>"
            i=$((i + 2))
          else
            echo "&>"
            i=$((i + 1))
          fi
        else
          cur="${cur}${c}"
        fi
        ;;
      *)
        cur="${cur}${c}"
        ;;
    esac
    i=$((i + 1))
  done
  [ -n "$cur" ] && echo "$cur"
  return 0
}

# orc_segment_write_targets <segment> -- echoes one candidate write-target
# WORD per line (unresolved -- no cwd/variable substitution here, that's
# the caller's job since it needs state tracked ACROSS segments). Finds:
#   - the word immediately after an unquoted output-redirect operator
#     (`>`, `>>`, `&>`, `&>>`, or a bare-digit word immediately before `>`
#     or `>>`, e.g. `2>`/`2>>`)
#   - the destination argument(s) of a fixed set of write verbs (tee, cp,
#     mv, touch, mkdir, rm: all non-flag args; sed with -i: last non-flag
#     arg; dd: the value of an `of=` arg) when that verb is the segment's
#     own leading command, after skipping an optional simple VAR=value
#     env-prefix or a bash/sh interpreter word.
# These are exactly the shapes #39 and agy's dedicated security pass were
# asked to probe (variables, quoting, fd-prefixed redirects, tee, dd of=,
# cp/mv). Deliberately does NOT look at any other argument (a quoted
# message, a git commit -m body, etc.) -- that's the other half of #39,
# the false-positive an unanchored whole-string grep was causing.
# orc_segment_leading_verb <segment> -- echoes the segment's own leading
# command word after skipping any VAR=value env-prefix and an optional
# bash/sh/zsh interpreter word, or nothing if the segment is a pure
# assignment with no command. Shared leading-word resolution for
# orc_segment_write_targets AND guard.sh's opaque-construct check
# (grouping/executors, #39 round 2 finding 3) -- one leading-word
# resolver, not two.
orc_segment_leading_verb() {
  local segment="$1"
  local -a words=()
  local w
  while IFS= read -r w; do
    words+=("$w")
  done < <(orc_tokenize_words "$segment")
  local n="${#words[@]}" idx=0
  while [ "$idx" -lt "$n" ] && [[ "${words[$idx]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    idx=$((idx + 1))
  done
  [ "$idx" -ge "$n" ] && return 0
  local verb="${words[$idx]}"
  case "$verb" in
    bash|sh|zsh)
      idx=$((idx + 1))
      [ "$idx" -ge "$n" ] && return 0
      verb="${words[$idx]}"
      ;;
  esac
  echo "$verb"
}

# orc_segment_has_suspicious_substitution <segment> -- (#39 round 2,
# finding 2 of agy's dedicated security pass on PR #57) true if the
# segment contains an unquoted command substitution ($(...) or backticks)
# that ALSO looks write-suggestive: a bare redirect operator token
# anywhere, or a word that -- after stripping any leading `$(`/`(`/
# backtick and trailing `)`/backtick wrapper characters -- exactly
# matches a known write verb. `echo $(tee .claude/settings.json)` hides
# "tee" from orc_segment_write_targets entirely (the word is literally
# "$(tee", which matches no verb); this codebase cannot safely evaluate
# what a substitution actually runs, so a segment matching this heuristic
# fails CLOSED rather than being silently let through -- the same posture
# already used everywhere else something can't be verified. NOT triggered
# by an ordinary, non-write substitution (`echo "$(git branch
# --show-current)"`) so this doesn't reopen #39's false-positive half for
# the (very common) legitimate use of command substitution.
# orc_string_has_live_command_substitution <text> -- (#61) true if <text>
# contains a $(...) or backtick command substitution that a REAL shell
# would actually expand: unquoted, or inside DOUBLE quotes (bash still
# expands $()/`` inside "..."). False for one that real bash would NEVER
# expand: inside SINGLE quotes (which suppress all expansion), or
# immediately preceded by a backslash escaping the `$`/backtick itself.
# This existed because the raw-substring check this replaced (`case
# "$segment" in *'$('*|*'`'*)`) matched the TEXT "$(" or "`" anywhere,
# with zero regard for quoting -- so a single-quoted, purely illustrative
# example like '$(tee)' (exactly the shape a decisions.log entry or a
# --title would use to CITE a bypass, not run one) read identically to a
# live, unquoted $(tee) once further downstream logic tokenizes it, and
# tripped the same fail-closed write-verb heuristic as a genuine bypass.
# A plain character scan (not the tokenizer above) because quote state
# must be tracked continuously across the WHOLE string, including
# whitespace and separator characters the tokenizer/segmenter treat
# specially -- this only needs to answer "is there a live $(/`` anywhere",
# not produce a word stream. Bash 3.2 safe.
#
# agy's dedicated security pass on PR #70 found a real bypass in an
# earlier version of this function: a single shared `case "$c"` handled
# quote/escape/substitution detection regardless of what quote state we
# were already in, so a LITERAL single-quote encountered while ALREADY
# inside double quotes fell through to the same `"'") quote="'" ;;`
# branch used for a real single-quote-open and unconditionally switched
# state to single-quoted -- e.g. `echo "'$(tee .claude/settings.json)'"`
# was read as "enters double quotes, then single quotes, so the $( that
# follows is inert" and returned false (not live). Real bash disagrees: a
# `'` has NO special meaning at all while already inside double quotes
# (quote types don't nest), so the $( right after it is fully live and
# WOULD have run tee against the protected file -- a genuine guard
# bypass, verified live by agy. Fixed by giving each of the three states
# (unquoted / single-quoted / double-quoted) its OWN dedicated handling
# block instead of one shared case statement, so a quote character can
# only ever change state out of the state it's actually a delimiter for
# -- the same "one active quote at a time, no reinterpretation" posture
# orc_split_top_level_segments above already uses correctly.
orc_string_has_live_command_substitution() {
  local s="$1" i c nc quote="" escape=0 len
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ "$escape" -eq 1 ]; then
      escape=0
      i=$((i + 1))
      continue
    fi

    if [ "$quote" = "'" ]; then
      # Single-quoted: bash suppresses EVERY expansion and every other
      # quote character's special meaning here -- the only thing that can
      # end this state is the matching closing single quote.
      [ "$c" = "'" ] && quote=""
      i=$((i + 1))
      continue
    fi

    if [ "$quote" = '"' ]; then
      # Double-quoted: a literal `'` is just data (must NOT toggle any
      # quote state) -- but $()/`` are still LIVE here, same as unquoted.
      case "$c" in
        '\')
          escape=1
          ;;
        '"')
          quote=""
          ;;
        '`')
          return 0
          ;;
        '$')
          nc="${s:$((i + 1)):1}"
          [ "$nc" = "(" ] && return 0
          ;;
      esac
      i=$((i + 1))
      continue
    fi

    # Unquoted.
    case "$c" in
      '\')
        escape=1
        ;;
      "'")
        quote="'"
        ;;
      '"')
        quote='"'
        ;;
      '`')
        return 0
        ;;
      '$')
        nc="${s:$((i + 1)):1}"
        [ "$nc" = "(" ] && return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# _orc_next_word_is_write_verb <string> <start-index> -- echoes nothing,
# returns 0 if the run of letters starting at <start-index> (after
# skipping leading spaces/tabs) exactly equals a known write verb
# (tee/cp/mv/touch/mkdir/sed/dd/rm). Used to inspect what immediately
# follows a LIVE `$(`/backtick directly off the character stream, at the
# exact index the scanner found it live -- NOT via the word tokenizer,
# which strips quote characters before this ever sees the word and would
# let a stray literal quote character (agy's PR #70 finding) glue onto
# the verb and defeat an exact match (e.g. the tokenized word for
# "'$(tee ...)'" is "'tee" once quotes are stripped, which matches no
# verb even though "tee" is what actually runs).
_orc_next_word_is_write_verb() {
  local s="$1" i="$2" c word="" len="${#s}"
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    case "$c" in
      ' '|$'\t') i=$((i + 1)); continue ;;
    esac
    break
  done
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z]) word="${word}${c}" ;;
      *) break ;;
    esac
    i=$((i + 1))
  done
  case "$word" in
    tee|cp|mv|touch|mkdir|sed|dd|rm) return 0 ;;
    *) return 1 ;;
  esac
}

# orc_segment_has_suspicious_substitution <segment> -- see the header
# comment above orc_string_has_live_command_substitution for the quoting
# rules this shares. Walks <segment> with the SAME quote/escape state
# machine (its own pass, not a reuse of the tokenizer above) and returns
# true the moment it finds either: a LIVE, unquoted `>` (a bare `>`
# outside any quotes is ALWAYS a real shell redirect in bash, never plain
# data -- this only ever runs once the caller already knows a live
# substitution is present, so flagging any unquoted `>` here is exactly
# as targeted as the old "redirect token in the tokenized word stream"
# check it replaces), or a LIVE $(...)/`` whose content opens with a
# known write verb.
orc_segment_has_suspicious_substitution() {
  local segment="$1"
  orc_string_has_live_command_substitution "$segment" || return 1
  local s="$segment" i c nc quote="" escape=0 len
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ "$escape" -eq 1 ]; then
      escape=0
      i=$((i + 1))
      continue
    fi
    if [ "$quote" = "'" ]; then
      [ "$c" = "'" ] && quote=""
      i=$((i + 1))
      continue
    fi
    if [ "$quote" = '"' ]; then
      case "$c" in
        '\')
          escape=1
          ;;
        '"')
          quote=""
          ;;
        '`')
          _orc_next_word_is_write_verb "$s" $((i + 1)) && return 0
          ;;
        '$')
          nc="${s:$((i + 1)):1}"
          if [ "$nc" = "(" ]; then
            _orc_next_word_is_write_verb "$s" $((i + 2)) && return 0
          fi
          ;;
      esac
      i=$((i + 1))
      continue
    fi
    # Unquoted.
    case "$c" in
      '\')
        escape=1
        ;;
      "'")
        quote="'"
        ;;
      '"')
        quote='"'
        ;;
      '>')
        return 0
        ;;
      '`')
        _orc_next_word_is_write_verb "$s" $((i + 1)) && return 0
        ;;
      '$')
        nc="${s:$((i + 1)):1}"
        if [ "$nc" = "(" ]; then
          _orc_next_word_is_write_verb "$s" $((i + 2)) && return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

orc_segment_write_targets() {
  local segment="$1"
  local -a words=()
  local w
  while IFS= read -r w; do
    words+=("$w")
  done < <(orc_tokenize_words "$segment")

  local n="${#words[@]}" idx nxt

  idx=0
  while [ "$idx" -lt "$n" ]; do
    case "${words[$idx]}" in
      '>'|'>>'|'&>'|'&>>')
        nxt=$((idx + 1))
        [ "$nxt" -lt "$n" ] && echo "${words[$nxt]}"
        ;;
    esac
    idx=$((idx + 1))
  done

  idx=0
  while [ "$idx" -lt "$n" ] && [[ "${words[$idx]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    idx=$((idx + 1))
  done
  [ "$idx" -ge "$n" ] && return 0
  local verb="${words[$idx]}"
  case "$verb" in
    bash|sh|zsh)
      idx=$((idx + 1))
      [ "$idx" -ge "$n" ] && return 0
      verb="${words[$idx]}"
      ;;
  esac

  local -a nonflag=()
  local j t has_inplace_flag=0 target_dir_flag=""
  j=$((idx + 1))
  while [ "$j" -lt "$n" ]; do
    t="${words[$j]}"
    case "$t" in
      -i|-i.*) has_inplace_flag=1 ;;
    esac
    # GNU cp/mv -t DIR / --target-directory=DIR inverts which argument is
    # the destination -- #39 round 2 finding 4 (agy's dedicated security
    # pass on PR #57): "always trust the LAST non-flag arg" got the
    # destination backwards for `cp -t .claude/settings.json
    # innocent_source`, checking the harmless-looking source instead of
    # the real target. -t's own value is itself a non-flag-shaped word,
    # so it's captured explicitly here (highest priority below) rather
    # than left to fall into nonflag and be picked by position.
    case "$t" in
      --target-directory=*) target_dir_flag="${t#--target-directory=}" ;;
      -t) nxt=$((j + 1)); [ "$nxt" -lt "$n" ] && target_dir_flag="${words[$nxt]}" ;;
    esac
    case "$t" in
      -*|'>'|'>>'|'&>'|'&>>') : ;;
      *) nonflag+=("$t") ;;
    esac
    j=$((j + 1))
  done

  case "$verb" in
    tee|touch|mkdir|rm)
      for t in "${nonflag[@]:-}"; do
        [ -n "$t" ] && echo "$t"
      done
      ;;
    cp|mv)
      if [ -n "$target_dir_flag" ]; then
        echo "$target_dir_flag"
      else
        local cnt="${#nonflag[@]}"
        [ "$cnt" -ge 1 ] && echo "${nonflag[$((cnt - 1))]}"
      fi
      ;;
    sed)
      # Only sed -i (or -i.bak style, GNU/BSD) actually writes to the
      # file argument -- a plain `sed 's/x/y/' file` reads and prints to
      # stdout, it does not write "file". Checked against the TOKENIZED
      # flag word, not a raw substring of the segment text (a raw
      # substring match on "-i" would false-positive on e.g. `sed
      # 's/find-item/x/' file`, whose script argument merely CONTAINS the
      # two characters "-i").
      if [ "$has_inplace_flag" -eq 1 ]; then
        local cnt="${#nonflag[@]}"
        [ "$cnt" -ge 1 ] && echo "${nonflag[$((cnt - 1))]}"
      fi
      ;;
    dd)
      for t in "${nonflag[@]:-}"; do
        case "$t" in
          of=*) echo "${t#of=}" ;;
        esac
      done
      ;;
  esac
}
