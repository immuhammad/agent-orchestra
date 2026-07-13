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

_QSG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./harness-root.sh
source "$_QSG_LIB_DIR/harness-root.sh"
# shellcheck source=./cmd-inspect-lib.sh
source "$_QSG_LIB_DIR/cmd-inspect-lib.sh"

# qsg_resolve_canon_dir -- fail-CLOSED project-root resolution (finding 3,
# agy's dedicated security review of PR #17's rework request). The
# original version of the two hooks called harness_canonical_dir "$PWD"
# alone and failed OPEN (allowed the tool) if that came back empty -- an
# agent could `cd /tmp` (or anywhere with no discoverable
# orchestrator.yaml) and every subsequent tool call bypassed the gate
# entirely, flag or no flag.
#
# Tries $CLAUDE_PROJECT_DIR FIRST (Claude Code always sets it for the
# whole session, so resolution succeeds even from a cwd with nothing
# discoverable via ancestor walk-up), falling back to $PWD-based walk-up
# (harness_canonical_dir's own ancestor search) if that's unset. Only
# when BOTH fail does the caller fail closed. FLAG (per this ticket's
# instructions): agy's own equivalent anchor env var, if one exists,
# isn't confirmed in this codebase -- add it to the candidate list below
# once known; until then agy sessions rely on the $PWD walk-up alone,
# same as before.
#
# Echoes the canonical dir and returns 0 on success; returns 1 (nothing
# echoed) only if every candidate fails, at which point the caller has no
# way to know whether a quota-stop flag exists and must fail closed.
qsg_resolve_canon_dir() {
  local dir
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && dir="$(harness_canonical_dir "$CLAUDE_PROJECT_DIR" 2>/dev/null)"; then
    echo "$dir"
    return 0
  fi
  if dir="$(harness_canonical_dir "$PWD" 2>/dev/null)"; then
    echo "$dir"
    return 0
  fi
  return 1
}

# qsg_lexical_normalize <path> -- thin alias for lib/cmd-inspect-lib.sh's
# orc_lexical_normalize (#39: moved there so guard.sh's resolved
# write-target check can reuse the exact same traversal-safe
# normalization instead of a second copy). Kept under its original name
# since qsg_path_allowed/qsg_read_allowed/_qsg_normalize_target below
# already call it by this name.
qsg_lexical_normalize() {
  orc_lexical_normalize "$@"
}

# _qsg_normalize_target <file_path> -- resolves file_path to an absolute
# path (relative to $PWD if not already absolute) and lexically normalizes
# it. Shared by every path-allow-list function below so there is exactly
# ONE normalize+anchor implementation for both read and write checks (#40
# -- do not fork a second copy of this logic).
_qsg_normalize_target() {
  local file_path="$1" resolved
  [ -z "$file_path" ] && return 1
  case "$file_path" in
    /*) resolved="$file_path" ;;
    *) resolved="$PWD/$file_path" ;;
  esac
  qsg_lexical_normalize "$resolved"
}

# qsg_path_allowed <file_path> <canon_dir> -- the ONLY Write/Edit targets a
# gated session may still touch: its own handoff.md update and
# decisions.log append (AGENTS.md Quota Failsafe: "update handoff.md
# fully" before asking), plus inbox .ack/.msg so a blocked agent can still
# park honestly and report back (this ticket's own REPORT-BACK instruction
# requires writing a .msg via dispatch.sh even while gated). ANCHORED to
# canon_dir AFTER LEXICAL NORMALIZATION -- the original version of this
# function (a) only matched a bare basename/suffix (let /tmp/evil/handoff.md
# through regardless of location), and even the canon_dir-anchored version
# that fixed that (b) matched the RAW string before resolving "..", so
# "inbox/builder/../../../../etc/evil.msg" string-glob-matched
# "$canon_dir/inbox/*/*.msg" (bash's case `*` matches "/" too) while the
# OS would actually resolve it somewhere entirely outside canon_dir; both
# caught in agy's dedicated security review of this diff (finding 2). Both
# file_path and canon_dir are normalized before comparison so a traversal
# component can never survive into the match.
qsg_path_allowed() {
  local file_path="$1" canon_dir="$2" normalized canon_normalized
  normalized="$(_qsg_normalize_target "$file_path")" || return 1
  canon_normalized="$(qsg_lexical_normalize "$canon_dir")" || return 1
  case "$normalized" in
    "$canon_normalized/handoff.md"|"$canon_normalized/decisions.log") return 0 ;;
    "$canon_normalized"/inbox/*/*.ack|"$canon_normalized"/inbox/*/*.msg) return 0 ;;
    *) return 1 ;;
  esac
}

# qsg_read_allowed <file_path> <canon_dir> -- (#40) the ONLY Read targets a
# gated session may still touch. Before this, qsg_path_allowed's coverage
# was Write/Edit only -- a gated agent was ordered by the failsafe message
# to "update handoff.md" while unable to READ handoff.md, decisions.log,
# the inbox, or even this hook to find where the flag lives, a real
# deadlock hit live by Orchestra (2026-07-12, .harness/decisions.log).
# Everything qsg_path_allowed covers, PLUS the flag itself (a gated agent
# needs to be able to see what's blocking it). Shares
# _qsg_normalize_target/qsg_lexical_normalize with qsg_path_allowed -- same
# traversal guard, so a `..` escape is rejected here exactly like it is
# for writes.
qsg_read_allowed() {
  local file_path="$1" canon_dir="$2" normalized canon_normalized
  normalized="$(_qsg_normalize_target "$file_path")" || return 1
  canon_normalized="$(qsg_lexical_normalize "$canon_dir")" || return 1
  case "$normalized" in
    "$canon_normalized/handoff.md"|"$canon_normalized/decisions.log") return 0 ;;
    "$canon_normalized"/inbox/*/*.ack|"$canon_normalized"/inbox/*/*.msg) return 0 ;;
    "$canon_normalized/state/quota-stop") return 0 ;;
    *) return 1 ;;
  esac
}

# __QSG_REJECT__ is not a valid shell segment (a bare double-underscore
# token), so it's safe as an unambiguous sentinel for "this command must
# be rejected outright" from qsg_split_top_level below.
QSG_REJECT_SENTINEL="__QSG_REJECT__"

# qsg_split_top_level <command string> -- echoes one shell "segment" per
# line, splitting on UNQUOTED ; && || |, via lib/cmd-inspect-lib.sh's
# shared orc_split_top_level_segments (#39: this used to be its own
# hand-rolled character scan; guard.sh needed the SAME quote-aware
# splitting for its resolved-write-target check, and a second copy here is
# exactly the kind of drift #39's root cause warns about -- one scanner,
# two callers). This matters concretely here -- lib/log-decision.sh's own
# documented argument shape is a single pipe-delimited string
# ("role|model|decision"), and a naive separator-split (guard.sh's own
# blocklist idiom, `sed -E 's/(;|&&|\|\||\|)/\n/g'`) would break that exact
# legitimate call by splitting inside the quotes -- guard.sh can afford
# that imprecision (a blocklist false-split only makes it MORE likely to
# block, still safe); an allow-list splitting the same naive way fails the
# opposite direction (a call that should be allowed gets rejected), which
# is safe but wrong, not a security hole -- still worth being precise
# about since it broke a real, expected caller.
#
# ALSO hard-rejects (echoes ONLY $QSG_REJECT_SENTINEL and stops) if ANY
# segment has an UNQUOTED `<` or `>` anywhere -- a redirection target is
# not part of an allow-listed command's own arguments; letting `bash
# lib/dispatch.sh ... > /etc/passwd` pass the allow-list as "one matching
# segment" was a real bypass (finding 1, agy's dedicated security review
# of PR #17's rework request) -- the segment split alone doesn't stop the
# shell from still honoring the redirection. Quote-aware for the SAME
# reason the separator split is: a report-back message legitimately
# containing a literal "<" or ">" inside quotes (e.g. "usage < 50%") must
# not be blocked, only an actual unquoted redirection operator. Quotes
# never span a segment boundary (the shared scanner never splits ON an
# unquoted separator while still inside a quote), so re-checking each
# already-split segment independently, with a fresh quote state, is
# equivalent to the original single combined scan.
qsg_split_top_level() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    if orc_segment_has_unquoted_redirect "$seg"; then
      echo "$QSG_REJECT_SENTINEL"
      return 0
    fi
  done <<< "$(orc_split_top_level_segments "$cmd")"
  orc_split_top_level_segments "$cmd"
}

# qsg_command_allowed <command string> <canon_dir> -- the ONLY Bash
# invocations let through: decisions.log append, inbox dispatch
# (report-back), and the explicit manual quota-stop clear
# (lib/quota-stop-clear.sh -- the "Ahmad's a/b/c answer was recorded"
# signal, see that file's own header for why this is a deliberate human
# action, not an inferred heuristic).
#
# Requires the ENTIRE command to be (optionally through an interpreter)
# exactly one of those three invocations -- NOT merely contain the script
# name anywhere in the string. The original
# version of this function used an unanchored `grep` substring search,
# which let a compound command smuggle anything alongside an allow-listed
# clause (`rm -rf /whatever && bash lib/dispatch.sh assign orchestra x
# DONE` passed whole); caught in agy's dedicated security review of this
# diff. Command substitution/backtick/backgrounding are rejected outright
# and UNCONDITIONALLY (even inside quotes) -- none of the three
# allow-listed scripts legitimately needs `$(...)`, backticks, or `&` in
# an argument, so being maximally strict there costs nothing. An unquoted
# redirection (`>`,`>>`,`<`,`<<`,`<<<`, or fd-prefixed like `2>`/`&>` --
# all of which contain a bare `<`/`>`) is likewise a hard reject via
# qsg_split_top_level's sentinel (finding 1, agy's dedicated security
# review). Every remaining UNQUOTED top-level segment must independently
# match the allow-list, anchored at the segment's start.
#
# agy REQUEST-CHANGES on PR #17: the per-segment check USED to be a glob
# like `*/lib/dispatch.sh\ *` -- the leading `*` matches ANY prefix, so
# `bash /tmp/evil.sh /path/to/lib/dispatch.sh assign orchestra x DONE`
# satisfied it (the string CONTAINS "/lib/dispatch.sh ") even though bash
# actually executes /tmp/evil.sh, with dispatch.sh's path merely an
# ARGUMENT never itself run. Fixed by checking WHAT'S ACTUALLY EXECUTED --
# the segment's FIRST token after stripping an optional bash/sh prefix --
# resolved to its REAL canonicalized path (same `cd` + `pwd -P` approach
# guard.sh's G13 check uses) and required to be EXACTLY one of the three
# allowed scripts under this project's own root (dirname of canon_dir),
# not a substring/glob any leading path can satisfy.
qsg_command_allowed() {
  local cmd="$1" canon_dir="$2" seg trimmed rest exe_token resolved_exe project_root allowed split candidate
  [ -z "$cmd" ] && return 1
  project_root="$(cd "$canon_dir/.." 2>/dev/null && pwd -P)" || return 1
  case "$cmd" in
    *'$('*|*'`'*|*'&'*) return 1 ;;
  esac
  split="$(qsg_split_top_level "$cmd")"
  case "$split" in
    "$QSG_REJECT_SENTINEL"|"$QSG_REJECT_SENTINEL"$'\n'*) return 1 ;;
  esac
  while IFS= read -r seg; do
    trimmed="$(echo "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$trimmed" ] && continue
    rest="$trimmed"
    case "$rest" in
      bash\ *) rest="${rest#bash }" ;;
      sh\ *) rest="${rest#sh }" ;;
    esac
    exe_token="${rest%% *}"
    [ -z "$exe_token" ] && exe_token="$rest"
    # `|| true`: a failing cd (exe_token's directory doesn't exist) must
    # fall through to the empty-resolved_exe reject below, not abort under
    # `set -e` (this file is sourced into callers that have it set).
    resolved_exe="$(cd "$project_root" 2>/dev/null && cd "$(dirname "$exe_token")" 2>/dev/null && echo "$(pwd -P)/$(basename "$exe_token")")" || true
    case "$resolved_exe" in
      "") return 1 ;;
    esac
    allowed=0
    for candidate in lib/dispatch.sh lib/log-decision.sh lib/quota-stop-clear.sh; do
      if [ "$resolved_exe" = "$project_root/$candidate" ]; then
        allowed=1
        break
      fi
    done
    [ "$allowed" -eq 1 ] || return 1
  done <<< "$split"
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
