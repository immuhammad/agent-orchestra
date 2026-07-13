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
# Kept as a small, independently-testable primitive for "is there ANY
# live substitution at all" -- orc_segment_has_suspicious_substitution
# below no longer calls this (it does its own equivalent tracking as part
# of a single integrated pass, #72), but the quoting rules are identical
# and reused by callers that only need the yes/no question.
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

# _orc_verb_is_write_suggestive <string> <start-index> -- (#72) resolves
# the leading COMMAND WORD of a fresh command line starting at
# <start-index> in <string> -- i.e. what real bash would actually treat
# as argv[0] once quote-removal and backslash-unescaping happen -- and
# returns 0 if that word (or its basename, for a path) is a known write
# verb. Skips any number of leading NAME=value env-prefix words first
# (`FOO=bar tee x` really runs tee), same reasoning
# orc_segment_leading_verb below already applies at the top level.
#
# This replaced #70's word extraction (_orc_next_word_is_write_verb),
# which only read a contiguous run of [A-Za-z] characters and so was
# defeated by ANYTHING else appearing before the verb resolves to plain
# text: an absolute path (`/usr/bin/tee` -- breaks at `/`), a quoted verb
# (`'tee'`/`"tee"` -- breaks at the quote char), or a backslash-escaped
# verb (`\tee` -- breaks at `\`) all evaded it even though real bash
# executes tee in every one of those forms (confirmed live by agy's PR
# #70 round-2 security pass and independently by Orchestra against
# already-merged main). This function instead walks character-by-character
# doing REAL quote-removal/unescaping to build the resolved word, so a
# quote or backslash changes how the word is BUILT rather than ending the
# scan.
#
# FAILS CLOSED (returns 0, i.e. "treat as write-suggestive") whenever the
# word can't be confidently resolved to a plain literal: a live
# construct ($/`) appearing IN the word itself -- most importantly, a
# NESTED substitution used as the verb (`$( $(echo tee) file )`) -- can't
# be known without executing it, and an unterminated quote can't be
# trusted either. This is the same "can't verify -> block" posture guard.sh
# already applies everywhere else (_guard_resolve_word, write-target
# resolution); the alternative (silently allow) is exactly how the #72
# evasions worked in the first place.
_orc_verb_is_write_suggestive() {
  local s="$1" i="$2" len="${#s}" c word quote escape base
  while :; do
    while [ "$i" -lt "$len" ]; do
      c="${s:$i:1}"
      case "$c" in
        ' '|$'\t') i=$((i + 1)); continue ;;
      esac
      break
    done
    [ "$i" -ge "$len" ] && return 1

    word=""
    quote=""
    escape=0
    while [ "$i" -lt "$len" ]; do
      c="${s:$i:1}"
      if [ "$escape" -eq 1 ]; then
        word="${word}${c}"
        escape=0
        i=$((i + 1))
        continue
      fi
      if [ "$quote" = "'" ]; then
        if [ "$c" = "'" ]; then quote=""; else word="${word}${c}"; fi
        i=$((i + 1))
        continue
      fi
      if [ "$quote" = '"' ]; then
        case "$c" in
          '\') escape=1 ;;
          '"') quote="" ;;
          '$'|'`') return 0 ;;
          *) word="${word}${c}" ;;
        esac
        i=$((i + 1))
        continue
      fi
      case "$c" in
        ' '|$'\t') break ;;
        '\') escape=1 ;;
        "'") quote="'" ;;
        '"') quote='"' ;;
        '$'|'`') return 0 ;;
        *) word="${word}${c}" ;;
      esac
      i=$((i + 1))
    done
    [ -n "$quote" ] && return 0

    if [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
      continue
    fi
    # agy's dedicated security pass on PR #78 round 3: this resolved word
    # is exactly what guard.sh's SIBLING top-level check
    # (orc_segment_leading_verb, consumed by guard.sh's own leading_verb
    # case) already fails closed on when it's the leading word of an
    # ordinary segment -- grouping ('{'/'(') and command executors that
    # wrap/hide a real verb from word-based inspection the same way
    # inside a live substitution as they do at the top level ($({ tee
    # .claude/settings.json; }), $(eval "tee ...")). This check MUST stay
    # in lockstep with guard.sh's list -- the whole reason #39 round 2
    # added it there in the first place is that these constructs are
    # opaque to word matching, and that opacity is exactly as real one
    # level down inside a substitution.
    base="${word##*/}"
    case "$base" in
      tee|cp|mv|touch|mkdir|sed|dd|rm) return 0 ;;
      # issue #72 round 4 (agy's dedicated security pass on PR #78): find
      # -exec is the same class of opaque executor as eval/sudo/time --
      # added here in lockstep with guard.sh's own leading_verb list
      # above, same reasoning: find . -exec tee <protected-path> \; runs
      # tee via an argument find itself parses, invisible to word-based
      # matching against the write-verb list alone.
      '{'|'('|eval|env|time|sudo|nice|nohup|exec|xargs|command|builtin|find) return 0 ;;
      *) return 1 ;;
    esac
  done
}

# _orc_skip_matching_paren <string> <start-index> -- <start-index> is the
# character immediately after an already-consumed "$(". Echoes the index
# of the matching closing ")" (tracking nesting depth: a NESTED "$(" or a
# bare subshell "(" inside this substitution's own content opens another
# level, quote-aware so an embedded "(" / ")" inside quotes doesn't count),
# or <the string's length> if unterminated. Callers treat "ran off the
# end" as "content is everything to the end of the string, and the outer
# scan should stop there" -- an unterminated $(...) is a syntax error in
# real bash (nothing would execute at all), so there is no live command to
# miss either way.
_orc_skip_matching_paren() {
  local s="$1" i="$2" len="${#s}" c quote="" escape=0 depth=1
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
        '\') escape=1 ;;
        '"') quote="" ;;
      esac
      i=$((i + 1))
      continue
    fi
    case "$c" in
      '\') escape=1 ;;
      "'") quote="'" ;;
      '"') quote='"' ;;
      '(') depth=$((depth + 1)) ;;
      ')')
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then
          echo "$i"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done
  echo "$len"
  return 1
}

# _orc_skip_matching_backtick <string> <start-index> -- <start-index> is
# the character immediately after an already-consumed opening backtick.
# Echoes the index of the next unescaped backtick (real bash's own
# backtick-matching rule -- no nesting without escaping the inner one),
# or <the string's length> if unterminated.
_orc_skip_matching_backtick() {
  local s="$1" i="$2" len="${#s}" c escape=0
  while [ "$i" -lt "$len" ]; do
    c="${s:$i:1}"
    if [ "$escape" -eq 1 ]; then
      escape=0
      i=$((i + 1))
      continue
    fi
    case "$c" in
      '\') escape=1 ;;
      '`')
        echo "$i"
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  echo "$len"
  return 1
}

# _orc_scan_write_suggestive <string> <outer-quote> <depth> -- (#72) the
# core of orc_segment_has_suspicious_substitution. Walks <string> under
# outer quote context <outer-quote> ("" / "'" / '"') and returns 0 the
# moment it finds a LIVE, write-suggestive construct:
#   - an unquoted `>` (always a real shell redirect in bash, never plain
#     data -- this only ever runs once a live substitution context is
#     already open, so it's exactly as targeted as the "redirect token"
#     check it replaces);
#   - a LIVE $(...)/`` whose resolved leading verb is a write verb (or is
#     unresolvable -- see _orc_verb_is_write_suggestive's fail-closed
#     rule);
#   - anything write-suggestive found by RECURSING into that
#     substitution's own content, on a FRESH quote context -- real bash
#     always starts $(...) as a brand new command line, independent of
#     whatever quote it's textually sitting inside (#72's core insight:
#     the OLD scanner tracked a single flat quote state across the whole
#     string, so it could never model this). This also catches a write
#     verb that isn't the immediate leading word at all, e.g.
#     `$(git log; tee .claude/settings.json)`.
# <depth> bounds recursion (cheap insurance against pathological input --
# not the threat model here, but free to add) at 20 levels; hitting the
# cap fails CLOSED rather than silently stopping the scan.
_orc_scan_write_suggestive() {
  local s="$1" quote="${2:-}" depth="${3:-0}" len i c nc escape close content
  [ "$depth" -ge 20 ] && return 0
  len=${#s}
  i=0
  escape=0
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
          i=$((i + 1))
          continue
          ;;
        '"')
          quote=""
          i=$((i + 1))
          continue
          ;;
        '`')
          close="$(_orc_skip_matching_backtick "$s" $((i + 1)))"
          content="${s:$((i + 1)):$((close - i - 1))}"
          _orc_verb_is_write_suggestive "$content" 0 && return 0
          _orc_scan_write_suggestive "$content" "" $((depth + 1)) && return 0
          i=$((close + 1))
          continue
          ;;
        '$')
          nc="${s:$((i + 1)):1}"
          if [ "$nc" = "(" ]; then
            close="$(_orc_skip_matching_paren "$s" $((i + 2)))"
            content="${s:$((i + 2)):$((close - i - 2))}"
            _orc_verb_is_write_suggestive "$content" 0 && return 0
            _orc_scan_write_suggestive "$content" "" $((depth + 1)) && return 0
            i=$((close + 1))
            continue
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
        # agy's dedicated security pass on PR #78 round 3: '>(' is
        # PROCESS SUBSTITUTION -- its content runs as a live command
        # exactly like '$(' does, regardless of the redirect direction
        # (verified live: `echo hello < <(tee ...)` still runs tee even
        # though only the substitution's OUTPUT is read). Real bash only
        # recognizes this UNQUOTED (never inside any quotes, unlike
        # $()/`` which stay live in double quotes), which is exactly
        # where this branch runs. Treated identically to '$(': same
        # matching-paren tracking, same recursive verb/content check.
        nc="${s:$((i + 1)):1}"
        if [ "$nc" = "(" ]; then
          close="$(_orc_skip_matching_paren "$s" $((i + 2)))"
          content="${s:$((i + 2)):$((close - i - 2))}"
          _orc_verb_is_write_suggestive "$content" 0 && return 0
          _orc_scan_write_suggestive "$content" "" $((depth + 1)) && return 0
          i=$((close + 1))
          continue
        fi
        # A redirect is only THIS function's business when it's hiding
        # inside a substitution's content (depth > 0) -- guard.sh's
        # separate write-target resolution (orc_segment_write_targets /
        # guard_check_write_targets) already owns a plain TOP-LEVEL
        # redirect. Flagging depth-0 here would fire on every ordinary
        # `cmd > file` with no substitution anywhere in the segment,
        # double-guarding (and, for an unprotected target, wrongly
        # blocking) something the write-target check already resolves
        # correctly on its own.
        [ "$depth" -gt 0 ] && return 0
        ;;
      '<')
        # Input process substitution '<(...)' -- same live-command
        # reasoning as '>(' above; a bare '<' with no following '(' is
        # an ordinary input redirect, which never writes anywhere and is
        # not this function's concern.
        nc="${s:$((i + 1)):1}"
        if [ "$nc" = "(" ]; then
          close="$(_orc_skip_matching_paren "$s" $((i + 2)))"
          content="${s:$((i + 2)):$((close - i - 2))}"
          _orc_verb_is_write_suggestive "$content" 0 && return 0
          _orc_scan_write_suggestive "$content" "" $((depth + 1)) && return 0
          i=$((close + 1))
          continue
        fi
        ;;
      '`')
        close="$(_orc_skip_matching_backtick "$s" $((i + 1)))"
        content="${s:$((i + 1)):$((close - i - 1))}"
        _orc_verb_is_write_suggestive "$content" 0 && return 0
        _orc_scan_write_suggestive "$content" "" $((depth + 1)) && return 0
        i=$((close + 1))
        continue
        ;;
      '$')
        nc="${s:$((i + 1)):1}"
        if [ "$nc" = "(" ]; then
          close="$(_orc_skip_matching_paren "$s" $((i + 2)))"
          content="${s:$((i + 2)):$((close - i - 2))}"
          _orc_verb_is_write_suggestive "$content" 0 && return 0
          _orc_scan_write_suggestive "$content" "" $((depth + 1)) && return 0
          i=$((close + 1))
          continue
        fi
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# orc_segment_has_suspicious_substitution <segment> -- see
# _orc_scan_write_suggestive above for the actual walk.
orc_segment_has_suspicious_substitution() {
  _orc_scan_write_suggestive "$1" ""
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
