#!/bin/bash
# lib/quota-stop-lib.sh — shared allow-list/message logic for issue #10's
# quota-stop PreToolUse gate. Sourced by BOTH hooks/quota-stop-gate.sh
# (Claude Code's exit-code protocol, wired via .claude/settings.json) and
# lib/guard-quota-stop-agy.sh (agy's JSON-decision protocol, wired via
# .agents/hooks.json) -- mirrors this codebase's existing guard.sh /
# guard-agy.sh split (one protocol per file) rather than inventing a novel
# dual-protocol single file, so the allow-list can't drift between the two
# callers.
set -uo pipefail

# qsg_path_allowed <file_path> <canon_dir> -- the ONLY Write/Edit targets a
# gated session may still touch: its own handoff.md update and
# decisions.log append (AGENTS.md Quota Failsafe: "update handoff.md
# fully" before asking), plus inbox .ack/.msg so a blocked agent can still
# park honestly and report back (this ticket's own REPORT-BACK instruction
# requires writing a .msg via dispatch.sh even while gated). ANCHORED to
# canon_dir -- a bare basename/suffix match (the original version of this
# function) let a Write to ANY path ending in e.g. "handoff.md" through
# regardless of location (/tmp/evil/handoff.md, another project's
# decisions.log, ...); caught in agy's dedicated security review of this
# diff. file_path is resolved against $PWD when relative, matching how
# Claude Code/agy actually report tool_input.file_path.
qsg_path_allowed() {
  local file_path="$1" canon_dir="$2" resolved
  [ -z "$file_path" ] && return 1
  case "$file_path" in
    /*) resolved="$file_path" ;;
    *) resolved="$PWD/$file_path" ;;
  esac
  case "$resolved" in
    "$canon_dir/handoff.md"|"$canon_dir/decisions.log") return 0 ;;
    "$canon_dir"/inbox/*/*.ack|"$canon_dir"/inbox/*/*.msg) return 0 ;;
    *) return 1 ;;
  esac
}

# qsg_split_top_level <command string> -- echoes one shell "segment" per
# line, splitting on UNQUOTED ; && || |. Quote-aware: a separator
# character inside a single- or double-quoted argument is passed through
# as literal text, not treated as a split point. This matters concretely
# here -- lib/log-decision.sh's own documented argument shape is a single
# pipe-delimited string ("role|model|decision"), and a naive
# separator-split (this function's first version, a straight `sed -E
# 's/(;|&&|\|\||\|)/\n/g'`, the same idiom guard.sh itself uses for its
# blocklist) broke that exact legitimate call by splitting inside the
# quotes. guard.sh can afford that imprecision (it's a blocklist -- a
# false split there only makes it MORE likely to block, still safe); an
# allow-list splitting the same naive way fails the opposite direction
# (a call that should be allowed gets rejected), which is safe but wrong,
# not a security hole -- still worth being precise about since it broke a
# real, expected caller. Bash 3.2 safe (character-by-character scan, no
# regex extensions).
qsg_split_top_level() {
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
        else
          cur="${cur}${c}"
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

# qsg_command_allowed <command string> -- the ONLY Bash invocations let
# through: decisions.log append, inbox dispatch (report-back), and the
# explicit manual quota-stop clear (lib/quota-stop-clear.sh -- the "Ahmad's
# a/b/c answer was recorded" signal, see that file's own header for why
# this is a deliberate human action, not an inferred heuristic).
#
# Requires the ENTIRE command to be (optionally through an interpreter and
# the orc-exec.sh trampoline) exactly one of those three invocations --
# NOT merely contain the script name anywhere in the string. The original
# version of this function used an unanchored `grep` substring search,
# which let a compound command smuggle anything alongside an allow-listed
# clause (`rm -rf /whatever && bash lib/dispatch.sh assign orchestra x
# DONE` passed whole); caught in agy's dedicated security review of this
# diff. Command substitution/backtick/backgrounding are rejected outright
# and UNCONDITIONALLY (even inside quotes) -- none of the three
# allow-listed scripts legitimately needs `$(...)`, backticks, or `&` in
# an argument, so being maximally strict there costs nothing. Every
# remaining UNQUOTED top-level segment (qsg_split_top_level) must
# independently match the allow-list, anchored at the segment's start.
qsg_command_allowed() {
  local cmd="$1" seg trimmed rest
  [ -z "$cmd" ] && return 1
  case "$cmd" in
    *'$('*|*'`'*|*'&'*) return 1 ;;
  esac
  while IFS= read -r seg; do
    trimmed="$(echo "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$trimmed" ] && continue
    rest="$trimmed"
    case "$rest" in
      bash\ *) rest="${rest#bash }" ;;
      sh\ *) rest="${rest#sh }" ;;
    esac
    case "$rest" in
      *orc-exec.sh\ *) rest="${rest#*orc-exec.sh }" ;;
    esac
    case "$rest" in
      lib/dispatch.sh|lib/dispatch.sh\ *|*/lib/dispatch.sh|*/lib/dispatch.sh\ *) ;;
      lib/log-decision.sh|lib/log-decision.sh\ *|*/lib/log-decision.sh|*/lib/log-decision.sh\ *) ;;
      lib/quota-stop-clear.sh|lib/quota-stop-clear.sh\ *|*/lib/quota-stop-clear.sh|*/lib/quota-stop-clear.sh\ *) ;;
      *) return 1 ;;
    esac
  done <<< "$(qsg_split_top_level "$cmd")"
  return 0
}

# qsg_failsafe_message <flag_path> -- echoes AGENTS.md's Quota Failsafe
# question, verbatim, filled from the flag written by
# ar_write_quota_stop_flag (lib/auto-resume.sh). Keep the (a)/(b)/(c)
# structure EXACTLY (AGENTS.md's own wording requirement) -- this is the
# single source both hook dialects call so the two callers can never drift
# on the exact phrasing.
qsg_failsafe_message() {
  local flag_path="$1" pool pct fallback
  pool="$(jq -r '.pool // "quota"' "$flag_path" 2>/dev/null)"
  pct="$(jq -r '.pct // "?"' "$flag_path" 2>/dev/null)"
  fallback="$(jq -r '.fallback // "none"' "$flag_path" 2>/dev/null)"
  echo "Quota ${pool} at ${pct}%. Options: (a) switch to ${fallback} (b) throttle models (c) continue. Pick one."
}
