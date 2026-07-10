#!/bin/bash
# .harness/guard.sh — PreToolUse guard for Bash tool calls.
# Blocks destructive/forbidden commands per AGENTS.md Hard Rules.
set -euo pipefail

GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./orc-config.sh
source "$GUARD_SCRIPT_DIR/orc-config.sh"

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
# for commands with no leading cd.
guard_cwd="$PWD"

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
      main|uat)
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
      main|uat)
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
  if echo "$trimmed" | grep -Eq '^(bash|sh|zsh|source|\.)[[:space:]]+[^[:space:]-]'; then
    SCRIPT="$(echo "$trimmed" | awk '{print $2}')"
    case "$SCRIPT" in
      .harness/*|./.harness/*|*/.harness/*)
        : # trusted location, allow
        ;;
      *)
        echo "guard.sh: blocked script execution outside .harness/ (bypasses command-string inspection, see G13): $trimmed" >&2
        exit 2
        ;;
    esac
  fi
done <<< "$(echo "$COMMAND" | sed -E 's/(;|\&\&|\|\||\|)/\n/g')"

# This check stays whole-string (not position-anchored like the dangerous-
# command check above): a redirect like `echo hi > career-ops/x` legitimately
# has its `>` mid-command, so anchoring to segment-start would miss real
# writes. It shares the same accepted FP class as a result -- e.g. prose
# mentioning both "career-ops/" and a write verb (a commit message describing
# this very rule triggered it during T3) -- accepted per T3 policy rather
# than loosening the destructive-write rule.
# T21: protected paths now come from orchestrator.yaml (project, protected_paths)
# via orc-config.sh, falling back to the hardcoded career-ops/ default if the
# config is missing/malformed (fail closed -- see orc-config.sh's contract).
if echo "$COMMAND" | grep -Eq '>|>>|tee |cp |mv |touch |mkdir |sed -i|rm '; then
  while IFS= read -r protected; do
    [ -z "$protected" ] && continue
    protected_re="$(echo "$protected" | sed -E 's/[][(){}.*+?^$|\\]/\\&/g')"
    if echo "$COMMAND" | grep -Eq "$protected_re"; then
      echo "guard.sh: blocked write inside protected path '$protected' (see AGENTS.md / orchestrator.yaml): $COMMAND" >&2
      exit 2
    fi
  done <<< "$(orc_protected_paths)"
fi

exit 0
