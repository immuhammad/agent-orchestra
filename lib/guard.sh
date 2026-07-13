#!/bin/bash
# .harness/guard.sh — PreToolUse guard for Bash tool calls.
# Blocks destructive/forbidden commands per AGENTS.md Hard Rules.
set -euo pipefail

GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./orc-config.sh
source "$GUARD_SCRIPT_DIR/orc-config.sh"
# shellcheck source=./cmd-inspect-lib.sh
source "$GUARD_SCRIPT_DIR/cmd-inspect-lib.sh"
# issue #116 follow-up (agy REQUEST-CHANGES on PR #3): this guard.sh
# itself always lives in an orc installation's own lib/ -- ORC_INSTALL_ROOT
# is that installation's root, used below to trust script-exec calls into
# its own bin/lib/hooks/tests the same way .harness/ was always trusted,
# without trusting any arbitrary directory that happens to also be named
# lib/hooks/tests elsewhere.
ORC_INSTALL_ROOT="$(cd "$GUARD_SCRIPT_DIR/.." && pwd)"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Split on command separators (; && || |) and check each sub-command's OWN
# leading tokens for a banned pattern. This anchors matches to command
# position instead of grepping the whole string, so trigger text sitting
# inside a quoted argument or heredoc body no longer false-positives simply
# by appearing somewhere in the line (hit this in a prior session).
# Documented accepted FP class: quoted/heredoc text that itself begins right
# after a separator with a banned token (e.g. "... ; rm -rf is dangerous")
# can still trip this — accepted rather than loosening the destructive rules.
DANGEROUS_RE='^(rm -rf|git push --force|push -f|git reset --hard|reset --hard|git clean)'

# T29 (issue #55): guard.sh runs as a PreToolUse hook that fires BEFORE the
# guarded command executes, at the hook process's own CWD -- normally the
# main checkout. A command like `cd .claude/worktrees/issue-N && git push`
# actually pushes from the worktree's branch, but a bare `git rev-parse
# --abbrev-ref HEAD` run at the hook's CWD would read the main checkout's
# branch instead (typically uat), producing a false block. Track a virtual
# "current directory" across the command's own leading `cd` segments (in
# execution order) so the branch-resolution fallback below asks git at the
# directory the guarded command will actually be running in by that point,
# not the hook's fixed CWD. Starts at the hook's real $PWD, same as before,
# for commands with no leading cd. #39: this is ALSO the anchor every
# resolved write-target below is relative to.
GUARD_ROOT="$PWD"
guard_cwd="$GUARD_ROOT"
# issue #116 follow-up (agy REQUEST-CHANGES on PR #3): protected branches
# must include the CONFIGURED integration_branch, not just the hardcoded
# main/uat pair -- orc-worktree.sh already respects a custom
# integration_branch (issue #116), and guard.sh not doing the same left a
# real gap: a project configuring integration_branch: develop could
# git push/merge straight to it, completely unguarded. Kept main/uat as
# defaults too (not just a fallback) since real deployments commonly use
# uat as well as main -- configuring one custom branch shouldn't silently
# un-protect the other common name.
CONFIGURED_INTEGRATION_BRANCH="$(orc_get_scalar integration_branch)"

# #39: variable tracking for the resolved write-target check below. Bash
# 3.2 has no associative arrays, so this is two parallel indexed arrays
# (name, value); a lookup scans from the END so the MOST RECENT assignment
# wins (correct shadowing across segments: `V=a; V=b; ... $V` sees "b").
# GUARD_VAR_UNRESOLVED marks a variable whose value we saw change to
# something we can't safely reason about (a nested expansion, command
# substitution, glob) -- once a variable hits that state, any LATER use of
# it must fail closed rather than silently falling back to a stale trusted
# value from an earlier assignment.
GUARD_VAR_NAMES=()
GUARD_VAR_VALS=()
GUARD_VAR_UNRESOLVED="__GUARD_VAR_UNRESOLVED__"

guard_var_track() { # $1=name $2=value (or $GUARD_VAR_UNRESOLVED)
  GUARD_VAR_NAMES+=("$1")
  GUARD_VAR_VALS+=("$2")
}

guard_var_lookup() { # $1=name -> echoes value, or fails (incl. untracked/unresolved)
  local name="$1" idx
  for ((idx = ${#GUARD_VAR_NAMES[@]} - 1; idx >= 0; idx--)); do
    if [ "${GUARD_VAR_NAMES[$idx]}" = "$name" ]; then
      [ "${GUARD_VAR_VALS[$idx]}" = "$GUARD_VAR_UNRESOLVED" ] && return 1
      echo "${GUARD_VAR_VALS[$idx]}"
      return 0
    fi
  done
  return 1
}

# guard_track_assignments_if_any <trimmed segment, already tokenized words>
# -- a segment is a real, PERSISTENT shell assignment statement (`V=.claude`,
# or `A=1 B=2`, with no command after it) only if EVERY word in it looks
# like NAME=value; a SCOPED env-prefix before a real command (`V=x cmd
# args`) does NOT persist in a real shell and must not be tracked as if it
# did. A value containing anything outside a safe literal-path character
# set (letters/digits/./_/-) is tracked as UNRESOLVED rather than skipped
# outright -- skipping would let a later use of the SAME name silently
# fall back to an OLDER, now-stale tracked value.
guard_track_assignments_if_any() {
  local -a words=("$@")
  local n="${#words[@]}" w
  [ "$n" -eq 0 ] && return 0
  for w in "${words[@]}"; do
    if [[ ! "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
      return 0
    fi
  done
  local vname vval
  for w in "${words[@]}"; do
    vname="${w%%=*}"
    vval="${w#*=}"
    if [[ "$vval" =~ ^[A-Za-z0-9_./-]*$ ]]; then
      guard_var_track "$vname" "$vval"
    else
      guard_var_track "$vname" "$GUARD_VAR_UNRESOLVED"
    fi
  done
}

# _guard_resolve_word <word> -- echoes the word with at most ONE leading
# $VAR/${VAR} reference substituted from the tracked table, or fails
# (nothing echoed, return 1) if the word can't be confidently resolved:
# command substitution ($(...) or backticks) anywhere, an unrecognized/
# untracked variable, or a SECOND expansion left in the remainder after
# substitution. A word with no "$" at all is already fully literal and
# passes through unchanged. Failing closed here (rather than guessing) is
# the same posture qsg_resolve_canon_dir already holds elsewhere in this
# codebase: an enforcement check that can't verify a target must not
# silently allow it.
_guard_resolve_word() {
  local word="$1" varname rest val
  case "$word" in
    *'$('*|*'`'*) return 1 ;;
  esac
  case "$word" in
    *'$'*) : ;;
    *) echo "$word"; return 0 ;;
  esac
  if [[ "$word" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; then
    varname="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  elif [[ "$word" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
    varname="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  case "$rest" in
    *'$'*) return 1 ;;
  esac
  val="$(guard_var_lookup "$varname")" || return 1
  echo "${val}${rest}"
  return 0
}

# #39: protected-dir registration, done ONCE up front. Each protected
# entry (the two hardcoded-by-default harness config dirs, PLUS whatever
# orchestrator.yaml's protected_paths configures) gets resolved to an
# absolute path two ways: LEXICALLY (pure string `.`/`..` collapse,
# qsg_lexical_normalize's sibling in lib/cmd-inspect-lib.sh -- always
# succeeds, works even for a path that doesn't exist on disk yet) and, if
# the directory actually exists, PHYSICALLY (`cd` + `pwd -P`, which also
# resolves symlinks). A write target is checked against BOTH forms below;
# either matching is enough to block -- the physical form is what catches
# a symlink planted to make a protected dir look like it's somewhere else.
DEFAULT_LEX=(); DEFAULT_PHYS=(); DEFAULT_LABEL=()
CUSTOM_LEX=();  CUSTOM_PHYS=();  CUSTOM_LABEL=()

_guard_resolve_protected() { # $1=relative-or-absolute path -> echoes "lex\tphys" (phys may be empty)
  local rel="$1" abs lex phys
  case "$rel" in
    /*) abs="$rel" ;;
    *) abs="$GUARD_ROOT/$rel" ;;
  esac
  lex="$(orc_lexical_normalize "$abs")" || return 1
  lex="${lex%/}"
  phys="$(cd "$lex" 2>/dev/null && pwd -P)" || phys=""
  printf '%s\t%s\n' "$lex" "$phys"
}

while IFS= read -r d; do
  [ -z "$d" ] && continue
  resolved="$(_guard_resolve_protected "$d")" || continue
  DEFAULT_LEX+=("${resolved%%$'\t'*}")
  DEFAULT_PHYS+=("${resolved#*$'\t'}")
  DEFAULT_LABEL+=("$d")
done <<< "$(orc_harness_config_dirs)"

while IFS= read -r p; do
  [ -z "$p" ] && continue
  resolved="$(_guard_resolve_protected "$p")" || continue
  CUSTOM_LEX+=("${resolved%%$'\t'*}")
  CUSTOM_PHYS+=("${resolved#*$'\t'}")
  CUSTOM_LABEL+=("$p")
done <<< "$(orc_protected_paths)"

# _guard_matched_label <target_lex> <target_phys> -- echoes
# "default\t<label>" or "custom\t<label>" if the target falls under (or
# equals) any registered protected dir, or nothing at all if it doesn't.
# ALWAYS returns 0 -- under this file's `set -e`, a plain `var="$(fn)"`
# assignment treats ANY non-zero exit from fn as a script-aborting failure
# (a well-known bash gotcha, not conditional on the assignment being
# checked), so signaling "match vs no match vs which kind" via exit code
# would silently kill the guard mid-check instead of blocking or passing
# as intended. Encoding the result in stdout instead sidesteps that
# entirely. Checked default-dirs-first so the blocked-tool message can say
# WHICH kind of protection fired, matching this file's pre-#39 message
# split (default .claude/.agents/ vs orchestrator.yaml protected_paths).
_guard_matched_label() {
  local target_lex="$1" target_phys="$2" idx
  target_lex="${target_lex%/}"
  for ((idx = 0; idx < ${#DEFAULT_LEX[@]}; idx++)); do
    case "$target_lex" in
      "${DEFAULT_LEX[$idx]}"|"${DEFAULT_LEX[$idx]}"/*)
        printf 'default\t%s\n' "${DEFAULT_LABEL[$idx]}"; return 0 ;;
    esac
    if [ -n "${DEFAULT_PHYS[$idx]}" ] && [ -n "$target_phys" ]; then
      case "$target_phys" in
        "${DEFAULT_PHYS[$idx]}"|"${DEFAULT_PHYS[$idx]}"/*)
          printf 'default\t%s\n' "${DEFAULT_LABEL[$idx]}"; return 0 ;;
      esac
    fi
  done
  for ((idx = 0; idx < ${#CUSTOM_LEX[@]}; idx++)); do
    case "$target_lex" in
      "${CUSTOM_LEX[$idx]}"|"${CUSTOM_LEX[$idx]}"/*)
        printf 'custom\t%s\n' "${CUSTOM_LABEL[$idx]}"; return 0 ;;
    esac
    if [ -n "${CUSTOM_PHYS[$idx]}" ] && [ -n "$target_phys" ]; then
      case "$target_phys" in
        "${CUSTOM_PHYS[$idx]}"|"${CUSTOM_PHYS[$idx]}"/*)
          printf 'custom\t%s\n' "${CUSTOM_LABEL[$idx]}"; return 0 ;;
      esac
    fi
  done
  return 0
}

# guard_check_write_targets <trimmed segment> -- (#39) the write-target
# check replacing the old whole-command substring grep. Inspects the
# RESOLVED, lexically-normalized write target(s) of THIS segment (redirect
# targets + write-verb file arguments, see
# lib/cmd-inspect-lib.sh:orc_segment_write_targets) against the protected
# dirs registered above, using the virtual guard_cwd/variable table tracked
# across the command's own segments -- a `cd`, a variable, or quote-split
# text can no longer hide a write's real destination from this check the
# way it could hide it from a raw-string grep. A target that can't be
# confidently resolved (untracked variable, command substitution) fails
# CLOSED rather than being silently let through, same posture as every
# other "can't verify" case in this codebase.
guard_check_write_targets() {
  local trimmed="$1" target resolved_word abs_path lex_norm target_phys matched match_kind match_label
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    resolved_word="$(_guard_resolve_word "$target")" || {
      echo "guard.sh: blocked -- write target could not be verified (unresolved variable or command substitution in '$target'), failing closed: $COMMAND" >&2
      exit 2
    }
    [ -z "$resolved_word" ] && continue
    case "$resolved_word" in
      /*) abs_path="$resolved_word" ;;
      *) abs_path="$guard_cwd/$resolved_word" ;;
    esac
    lex_norm="$(orc_lexical_normalize "$abs_path")" || {
      echo "guard.sh: blocked -- write target path could not be normalized ('$target'), failing closed: $COMMAND" >&2
      exit 2
    }
    lex_norm="${lex_norm%/}"
    target_phys="$(cd "$(dirname "$lex_norm")" 2>/dev/null && echo "$(pwd -P)/$(basename "$lex_norm")")" || target_phys=""
    matched="$(_guard_matched_label "$lex_norm" "$target_phys")"
    if [ -n "$matched" ]; then
      match_kind="${matched%%$'\t'*}"
      match_label="${matched#*$'\t'}"
      if [ "$match_kind" = "default" ]; then
        echo "guard.sh: blocked write into '$match_label' -- .claude/ and .agents/ are protected by default (they wire guard.sh/guard-write.sh/quota-stop-gate.sh/the Stop hook). To change hook wiring: edit templates/settings.json or templates/agents-hooks.json (the tracked source of truth) and re-sync into this room: $COMMAND" >&2
      else
        echo "guard.sh: blocked write inside protected path '$match_label' (resolved target: $lex_norm; see AGENTS.md / orchestrator.yaml): $COMMAND" >&2
      fi
      exit 2
    fi
  done < <(orc_segment_write_targets "$trimmed")
}

while IFS= read -r seg; do
  trimmed="$(echo "$seg" | sed -E 's/^[[:space:]]*//')"
  [ -z "$trimmed" ] && continue

  if echo "$trimmed" | grep -Eq '^cd([[:space:]]|$)'; then
    cd_arg="$(echo "$trimmed" | sed -E 's/^cd[[:space:]]*//; s/[[:space:]]+$//')"
    cd_arg="${cd_arg%\"}"; cd_arg="${cd_arg#\"}"
    cd_arg="${cd_arg%\'}"; cd_arg="${cd_arg#\'}"
    if [ -n "$cd_arg" ] && [ "$cd_arg" != "-" ]; then
      new_cwd="$(cd "$guard_cwd" 2>/dev/null && cd "$cd_arg" 2>/dev/null && pwd)"
      [ -n "$new_cwd" ] && guard_cwd="$new_cwd"
    fi
  fi

  if echo "$trimmed" | grep -Eq "$DANGEROUS_RE"; then
    echo "guard.sh: blocked dangerous command: $COMMAND" >&2
    exit 2
  fi

  # T15 merge-discipline guard: agents open PRs, they never merge (see
  # AGENTS.md Hard Rules: "Never merge to uat or main yourself. Ever.").
  # `git merge` has no destination argument -- it merges INTO whatever is
  # currently checked out -- so the only way to know if it targets a
  # protected branch is to ask git for the current HEAD.
  if echo "$trimmed" | grep -Eq '^git[[:space:]]+merge([[:space:]]|$)'; then
    current_branch="$(git -C "$guard_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    case "$current_branch" in
      main|uat|"$CONFIGURED_INTEGRATION_BRANCH")
        # Allow a fast-forward SYNC of the local protected branch to its OWN
        # remote-tracking ref (e.g. `git merge --ff-only origin/uat` while on
        # uat) -- that only advances local to the commit Ahmad already merged
        # on the remote; a --ff-only merge cannot create a merge commit or
        # introduce un-PR'd work. A non-ff merge, or a --ff-only merge of
        # anything OTHER than origin/<same-branch>, stays blocked.
        if echo "$trimmed" | grep -Eq -- '(^|[[:space:]])--ff-only([[:space:]]|$)' \
          && echo "$trimmed" | grep -Eq "(^|[[:space:]])origin/${current_branch}([[:space:]]|\$)"; then
          : # allowed: local sync to the already-merged remote, not a work merge
        else
          echo "guard.sh: blocked git merge into protected branch '$current_branch' (see AGENTS.md Hard Rules): $COMMAND" >&2
          exit 2
        fi
        ;;
    esac
  fi

  if echo "$trimmed" | grep -Eq '^gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
    echo "guard.sh: blocked gh pr merge (agents PR to uat/main, Ahmad merges -- see AGENTS.md Hard Rules): $COMMAND" >&2
    exit 2
  fi

  if echo "$trimmed" | grep -Eq '^git[[:space:]]+push([[:space:]]|$)'; then
    push_args="$(echo "$trimmed" | sed -E 's/^git[[:space:]]+push[[:space:]]*//')"
    # Collect non-flag tokens: `git push [remote] [refspec]`. A flag like
    # -u/--force-with-lease can appear anywhere, so filter rather than
    # position-index the raw args.
    non_flag_tokens=()
    for tok in $push_args; do
      case "$tok" in
        -*) continue ;;
        *) non_flag_tokens+=("$tok") ;;
      esac
    done
    refspec="${non_flag_tokens[1]:-}"
    if [ -n "$refspec" ]; then
      # `remote:branch` or `local:branch` -> the part after the colon is the
      # destination ref; no colon -> pushing a local branch to the
      # same-named remote branch, so the refspec itself is the destination.
      dest_ref="${refspec#*:}"
    else
      # No explicit refspec (`git push`, `git push origin`) -- git pushes
      # the current branch, so the destination is whatever HEAD is. Resolve
      # at guard_cwd (see T29 note above), not the hook's raw $PWD, so a
      # leading `cd <worktree> &&` in this same command is honored.
      dest_ref="$(git -C "$guard_cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    fi
    case "$dest_ref" in
      main|uat|"$CONFIGURED_INTEGRATION_BRANCH")
        echo "guard.sh: blocked git push targeting protected branch '$dest_ref' (see AGENTS.md Hard Rules): $COMMAND" >&2
        exit 2
        ;;
    esac
  fi

  # Script-exec bypass (confirmed G13): `bash script.sh` / `sh script.sh` /
  # `source script.sh` runs the script's CONTENTS unguarded — this hook only
  # ever sees the interpreter invocation, not what's inside the file. Policy:
  # scripts under .harness/ are trusted (version-controlled, reviewable);
  # ad-hoc scripts anywhere else (scratch, /tmp, issue-body-generated) are
  # blocked so dangerous ops can't be smuggled past this guard in a file.
  #
  # issue #116 follow-up (agy REQUEST-CHANGES on PR #3): this whitelist
  # only ever covered .harness/ -- fine when every harness script lived
  # there, but this repo's own scripts (bin/, lib/, hooks/, tests/) now
  # live in a SEPARATE orc installation. Without this, `bash
  # tests/guard.test.sh` (documented in docs/getting-started.md, and the
  # exact command that got blocked here repeatedly while writing this
  # fix) or a consumer running `bash ../agent-orchestra/lib/orc-worktree.sh
  # finish 116` would be blocked as untrusted. Trust is resolved by actual
  # LOCATION (does the script fall under THIS guard.sh's own installation
  # root, ORC_INSTALL_ROOT, computed above), not by directory NAME -- an
  # arbitrary directory elsewhere named lib/hooks/tests is still blocked.
  #
  # issue #18 item 8 (B1) / agy REQUEST-CHANGES on PR #17 (path-traversal
  # fix): clone-per-project self-dogfood rooms nest the dev-target clone
  # under this installation's own project/<name>/ (see this repo's own
  # project/agent-orchestra/). This USED to be trusted by a raw NAME-glob
  # match on $SCRIPT with no resolution at all -- `bash
  # project/../../../tmp/evil.sh` satisfied the glob outright (it starts
  # with "project/"), bypassing the ORC_INSTALL_ROOT location check below
  # entirely. Fixed by resolving project/<name>/... the SAME way as every
  # other script -- to its REAL canonicalized directory, required to fall
  # under ORC_INSTALL_ROOT -- except the base it resolves FROM is
  # ORC_INSTALL_ROOT itself (project/ is always this installation's OWN
  # nested dir, so this doesn't depend on guard_cwd already sitting inside
  # this installation's tree, which is what the old glob shortcut was
  # working around). project/<name>/'s worktrees resolve the same way,
  # arbitrary depth, since they're still real subdirectories under
  # ORC_INSTALL_ROOT/project/<name>/.
  if echo "$trimmed" | grep -Eq '^(bash|sh|zsh|source|\.)[[:space:]]+[^[:space:]-]'; then
    SCRIPT="$(echo "$trimmed" | awk '{print $2}')"
    case "$SCRIPT" in
      .harness/*|./.harness/*|*/.harness/*)
        : # trusted location, allow
        ;;
      *)
        case "$SCRIPT" in
          project/*|./project/*)
            resolve_base="$ORC_INSTALL_ROOT"
            ;;
          *)
            resolve_base="$guard_cwd"
            ;;
        esac
        # `|| true`: under `set -e`, a plain assignment from a failing
        # command substitution (the cd chain fails when SCRIPT's directory
        # doesn't exist) aborts the whole script here instead of falling
        # through to the empty-resolved_dir blocked branch below. `pwd -P`
        # (not plain `pwd`) canonicalizes symlinks too, so a project/<name>/
        # symlink (or an out-pointing symlink anywhere else in this check)
        # can't smuggle a path outside ORC_INSTALL_ROOT either.
        resolved_dir="$(cd "$resolve_base" 2>/dev/null && cd "$(dirname "$SCRIPT")" 2>/dev/null && pwd -P)" || true
        if [ -n "$resolved_dir" ] && [[ "$resolved_dir" == "$ORC_INSTALL_ROOT"* ]]; then
          : # trusted: this orc installation's own bin/lib/hooks/tests/project/etc.
        else
          echo "guard.sh: blocked script execution outside .harness/ or this orc installation ($ORC_INSTALL_ROOT) (bypasses command-string inspection, see G13): $trimmed" >&2
          exit 2
        fi
        ;;
    esac
  fi

  # #39 round 2 finding 3 (agy's dedicated security pass on PR #57):
  # grouping ({ ... }, ( ... )) and command executors (eval/env/time/
  # sudo/...) hid the real verb from every check below -- the segment's
  # leading word was "{"/"("/"eval"/etc, none of which is a known write
  # verb, so `{ tee .claude/settings.json; }` and `eval "tee
  # .claude/settings.json"` sailed through untouched. This codebase
  # cannot safely unwrap/recurse into these (eval's argument is a whole
  # NEW command line that would need re-parsing from scratch), so fail
  # CLOSED outright rather than pretend to understand them.
  #
  # issue #72 round 5 (Ahmad's parity directive, after agy's review of PR
  # #78 found bash/python/find/process-substitution evading the INNER
  # substitution scanner one round at a time): this now calls
  # orc_is_opaque_executor (cmd-inspect-lib.sh) -- the ONE shared
  # definition _orc_verb_is_write_suggestive ALSO calls -- instead of its
  # own copy of the list. Two lists meant to match will drift; one
  # function can't.
  leading_verb="$(orc_segment_leading_verb "$trimmed")"
  if orc_is_opaque_executor "$leading_verb"; then
    echo "guard.sh: blocked -- '$leading_verb' wraps or groups another command that can't be safely inspected for a hidden write, failing closed: $COMMAND" >&2
    exit 2
  fi

  # #39 round 2 finding 2 (agy's dedicated security pass on PR #57):
  # command substitution ($(...)/backticks) can hide a write verb from
  # every word-based check above -- `echo $(tee .claude/settings.json)`'s
  # leading verb is "echo", and "tee" never appears as its own clean
  # word (it's fused into "$(tee"). Fails CLOSED only when the
  # substitution ALSO looks write-suggestive (a bare redirect token, or a
  # write-verb word once wrapper characters are stripped) -- see
  # orc_segment_has_suspicious_substitution's header for why this is
  # deliberately conditional, not a blanket ban on $()/backticks (those
  # are extremely common for entirely benign uses like
  # `$(git rev-parse HEAD)`).
  if orc_segment_has_suspicious_substitution "$trimmed"; then
    echo "guard.sh: blocked -- command substitution in this segment cannot be safely verified for a hidden write, failing closed: $COMMAND" >&2
    exit 2
  fi

  # #39: variable-assignment tracking, then the resolved write-target
  # check -- both need this segment's own tokenized words, and both must
  # see guard_cwd/the variable table as they stand AFTER any earlier
  # segments (a leading `cd`/`VAR=val` segment) but BEFORE this segment's
  # own write, matching real left-to-right shell execution order.
  seg_words=()
  while IFS= read -r w; do seg_words+=("$w"); done < <(orc_tokenize_words "$trimmed")
  guard_track_assignments_if_any "${seg_words[@]}"
  guard_check_write_targets "$trimmed"
done <<< "$(orc_split_top_level_segments "$COMMAND")"

exit 0
