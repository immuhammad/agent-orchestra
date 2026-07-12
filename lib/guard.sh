#!/bin/bash
# .harness/guard.sh — PreToolUse guard for Bash tool calls.
# Blocks destructive/forbidden commands per AGENTS.md Hard Rules.
set -euo pipefail

GUARD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./orc-config.sh
source "$GUARD_SCRIPT_DIR/orc-config.sh"
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
# for commands with no leading cd.
guard_cwd="$PWD"
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
  # issue #18 item 8 (B1): clone-per-project self-dogfood rooms nest the
  # dev-target clone under this installation's own project/<name>/ (see
  # this repo's own project/agent-orchestra/) -- trusted by NAME, same as
  # .harness/, since the ORC_INSTALL_ROOT/resolved_dir check below requires
  # the referenced directory to actually exist under guard_cwd to `cd` into
  # it, which fails for a relative project/<name>/... path whenever
  # guard_cwd isn't already sitting inside this installation's own tree
  # (e.g. a throwaway/relocated hook CWD). project/<name>/'s worktrees
  # (project/<name>/.worktrees/<branch>/...) match the same glob, arbitrary
  # depth, exactly like .harness/'s own nesting.
  if echo "$trimmed" | grep -Eq '^(bash|sh|zsh|source|\.)[[:space:]]+[^[:space:]-]'; then
    SCRIPT="$(echo "$trimmed" | awk '{print $2}')"
    case "$SCRIPT" in
      .harness/*|./.harness/*|*/.harness/*)
        : # trusted location, allow
        ;;
      project/*|./project/*|*/project/*)
        : # trusted: nested clone-per-project dev target (+ its worktrees)
        ;;
      *)
        # `|| true`: under `set -e`, a plain assignment from a failing
        # command substitution (the cd chain fails when SCRIPT's directory
        # doesn't exist) aborts the whole script here instead of falling
        # through to the empty-resolved_dir blocked branch below.
        resolved_dir="$(cd "$guard_cwd" 2>/dev/null && cd "$(dirname "$SCRIPT")" 2>/dev/null && pwd)" || true
        if [ -n "$resolved_dir" ] && [[ "$resolved_dir" == "$ORC_INSTALL_ROOT"* ]]; then
          : # trusted: this orc installation's own bin/lib/hooks/tests/etc.
        else
          echo "guard.sh: blocked script execution outside .harness/ or this orc installation ($ORC_INSTALL_ROOT) (bypasses command-string inspection, see G13): $trimmed" >&2
          exit 2
        fi
        ;;
    esac
  fi
done <<< "$(echo "$COMMAND" | sed -E 's/(;|\&\&|\|\||\|)/\n/g')"

# This check stays whole-string (not position-anchored like the dangerous-
# command check above): a redirect like `echo hi > vendor/x` legitimately
# has its `>` mid-command, so anchoring to segment-start would miss real
# writes. It shares the same accepted FP class as a result -- e.g. prose
# mentioning both a protected path and a write verb (a commit message
# describing this very rule triggered it during T3, against career-ops/,
# this repo's protected path at the time) -- accepted per T3 policy rather
# than loosening the destructive-write rule.
# T21: protected paths come ONLY from orchestrator.yaml (project,
# protected_paths) via orc-config.sh -- EMPTY if the config is
# missing/malformed (issue #18 B-i: no hardcoded project-specific default;
# the harness core itself is separately protected by this script's own
# G-series rules, not this list).
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
