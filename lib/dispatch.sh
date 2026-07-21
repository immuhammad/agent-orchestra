#!/bin/bash
# .harness/dispatch.sh <verb> <agent> <issue> <msg> [timeout_s]
#
# Three-verb file-inbox dispatch for ALL agents (orchestra, builder, agy,
# copilot) -- replaces tmux-team/tmt (T17, Q1). A message is always a
# durable file (.harness/inbox/<agent>/<ts>-<issue>.msg); a receiver
# acknowledges by writing the matching .ack next to it.
#
#   handoff  -- write .msg, nudge if idle, then POLL for the matching .ack,
#               bounded by timeout_s (default 120). Use when you must block
#               on the result (e.g. a synchronous review-and-report).
#   assign   -- write .msg, nudge if idle, return immediately. No wait.
#               Use for fire-and-forget work (e.g. a reviewer handover).
#   message  -- write .msg only. No nudge, no ack expected. Use for FYI
#               notes the receiver will pick up on its own schedule.
#
# This script only ever touches its OWN pane's tmux target when nudging a
# DIFFERENT agent's pane -- never call `dispatch.sh <verb> <your-own-agent>`
# from inside that agent's own pane, since a self-nudge types into your own
# live input.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./send-lib.sh
source "$DIR/send-lib.sh"
# shellcheck source=./harness-root.sh
source "$DIR/harness-root.sh"
# shellcheck source=./orc-config.sh
source "$DIR/orc-config.sh"
# shellcheck source=./pane-state-lib.sh
source "$DIR/pane-state-lib.sh"
# issue #99: inbox/deferred-nudges are per-repo STATE, not per-checkout --
# every worktree has its own gitignored .harness/inbox, so a dispatch run
# from inside a worktree must still land in the MAIN checkout's inbox, not
# the worktree's own empty copy. CANON_DIR is that canonical .harness dir,
# resolved off the CALLER's cwd (issue #116: these scripts no longer live
# inside the project they serve). DISPATCH_CANON_DIR overrides outright.
if [ -n "${DISPATCH_CANON_DIR:-}" ]; then
  CANON_DIR="$DISPATCH_CANON_DIR"
elif ! CANON_DIR="$(harness_canonical_dir "$PWD")"; then
  echo "dispatch.sh: could not resolve project root (see error above); set ORC_PROJECT_ROOT or run from inside a project with orchestrator.yaml" >&2
  exit 1
fi

# issue #33: pane-state-lib.sh's PANE_STATE_DIR default resolves off
# CANON_DIR at SOURCE time, which was too early above (CANON_DIR wasn't
# resolved yet) -- set it explicitly now that CANON_DIR is known, so
# pane_is_idle's hook-state read (below) lands in the same place
# hooks/pane-state.sh writes to.
PANE_STATE_DIR="$CANON_DIR/state/pane-state"

# T24 (issue #34): deferred nudges used to be fire-and-forget -- if a nudge
# was skipped because the target pane was busy, nothing ever retried it, so
# every busy-pane dispatch (copilot's, in practice) needed a manual
# re-nudge. This file is a durable queue of agent names whose last nudge
# was deferred; watch.sh's retry_deferred_nudges() drains it on each loop
# iteration. DISPATCH_DEFERRED_FILE overrides the path (tests use this to
# avoid touching the real queue).
DEFERRED_FILE="${DISPATCH_DEFERRED_FILE:-$CANON_DIR/deferred-nudges}"

# issue #105: which tmux session pane_for_agent targets. Overridable so a
# caller that's NOT a human at the real control room (gatekeeper.sh's
# quota-crossing alerts, tests) can redirect every pane target to a
# throwaway session instead -- without this, gatekeeper.sh's own
# session-isolation override (GATEKEEPER_NOTIFY_SESSION) had no effect on
# dispatch-routed alerts, since pane_for_agent hardcoded "harness"
# regardless (found writing this ticket's own tests: a real 80%+ crossing
# during a test run would have nudged the REAL harness:0.0 pane).
#
# issue #19 (cross-project nudge collision, live-repro'd): a hardcoded
# "harness" default is harmless with ONE project's control room running,
# but with two clone-per-project rooms live at once it nudges the WRONG
# project's session -- dispatch.sh sent `check inbox` keystrokes into a
# stale, unrelated project's pane instead of the actual target's. Derive
# the default from THIS project's own orchestrator.yaml (orc_session_name,
# same helper `orc up` uses) via CANON_DIR's project root, so every
# project's session name is unique to it by construction, not convention.
DISPATCH_SESSION="${DISPATCH_SESSION:-$(ORC_CONFIG_FILE="$(dirname "$CANON_DIR")/orchestrator.yaml" orc_session_name harness)}"

# Pane map (see AGENTS.md Dispatch Protocol): tmux session $DISPATCH_SESSION
# (production: "harness"), window 0, tiled. Agents without a live pane in
# the orc.sh layout (or an unmapped/typo'd name) just don't get nudged --
# the .msg is still written and will be picked up whenever the receiver
# polls its inbox. scribe/copilot deliberately have NO entry here (issue
# #89: pane 3 retired) -- dispatch_main special-cases them to
# scribe_spawn_headless before pane_for_agent/nudge_agent are ever
# consulted, so falling through to the empty-mapping default here is
# correct, not a gap.
pane_for_agent() {
  case "$1" in
    orchestra) echo "$DISPATCH_SESSION:0.0" ;;
    builder)   echo "$DISPATCH_SESSION:0.1" ;;
    agy)       echo "$DISPATCH_SESSION:0.2" ;;
    *)         echo "" ;;
  esac
}

# inbox_dir_name <agent> -- resolves the on-disk inbox directory for an
# agent name. `scribe` is the current display name (issue #89) AND the
# current physical directory -- a fresh clone-per-project room is seeded
# with inbox/scribe/, not inbox/copilot/ (issue #22: aliasing scribe TO
# copilot made dispatch hard-fail in every fresh room, since no clone has a
# copilot/ dir or history to preserve). `copilot` is kept as a legacy verb
# that aliases INTO scribe/, so a caller still using the old name lands
# somewhere valid instead of failing outright; it is not itself a live
# inbox directory in any room this repo creates.
inbox_dir_name() {
  case "$1" in
    copilot) echo "scribe" ;;
    *)       echo "$1" ;;
  esac
}

# pane_busy_markers <agent> -- busy-indicator regex (kept accepting an
# agent arg for call-site compatibility; no longer used, see below).
# issue #97 review round 2 (agy finding 2, reproduced live): a bare-word
# substring match anywhere in the tail false-flagged busy on ORDINARY
# PROSE merely containing one of these words on a genuinely idle pane
# (e.g. "...thinking about this differently, working through the edge
# cases...") -- this, not the prompt regex, was the real cause of the
# 00:16 agy false-busy incident. Reworked to match how a real busy
# indicator actually RENDERS instead of bare words anywhere: a
# spinner-glyph-prefixed line (agy's confirmed "⣟ Working...", Claude's
# own confirmed "✢ <whimsical loading text> (1m 20s · ↓ 2.8k tokens)" --
# note that example doesn't even CONTAIN a status word, the glyph prefix
# IS the signal), a token/time-counter parenthetical shape, the literal
# "esc to interrupt" hint (specific enough to be safe as a bare phrase --
# unlike single common words, this exact compound phrase essentially never
# appears in ordinary prose), or a status word that IS the entire
# (trimmed) line rather than embedded mid-sentence. No longer per-agent:
# a shape-anchored match is precise enough to be safe for every TUI, so
# the old agy-only 'working' carve-out (and the false-idle gap it
# otherwise left open for a no-agent-hint call) is no longer needed.
pane_busy_markers() {
  # A Unicode RANGE inside this bracket expression (e.g. `[⠀-⣿...]` for the
  # whole Braille block) is NOT safe here: confirmed live on this machine's
  # grep -E (BSD grep) -- combining a wide codepoint range with other
  # discrete characters in one bracket expression matched completely
  # unrelated lines (❯, ─, ⏵, ← all falsely matched), the exact same class
  # of byte-level UTF-8 mishandling already hit and worked around in this
  # file's awk usage above. Explicit alternation of only the specific
  # glyphs actually confirmed real (agy's "⣟ Working...", Claude's own
  # "✢ ... (1m 20s · ↓ 2.8k tokens)") plus a few common asterisk-style
  # spinner symbols and a literal '*' -- each verified individually, no
  # range operator, before landing.
  echo '^[[:space:]]*(⣟|✢|✳|✻|✵|⏺|✶|✦|\*)|\([0-9]+[ms][^)]*tokens?\)|esc to interrupt|^[[:space:]]*(thinking|working|compacting|generating|running)\.\.\.[[:space:]]*$'
}

# Idle heuristic (T17 VERIFY: must be documented, not just implemented):
# - pane_current_command is a plain shell (bash/zsh/sh/fish, or empty) ->
#   idle, nothing running in it. NOTE: Claude Code panes report
#   pane_current_command as a version string (e.g. "2.1.206"), not
#   "claude" -- that still falls through to the TUI branch below correctly
#   (it matches none of bash/zsh/sh/fish), just worth knowing when reading
#   this case statement (issue #86 Task 3 live observation).
# - otherwise (a TUI: claude, agy, copilot, node, ...) -> capture the last
#   10 lines and look for busy markers (spinner/status text a TUI shows
#   mid-generation), using that AGENT's own marker set (see
#   pane_busy_markers above). No busy marker AND a bare prompt line
#   present -> idle. A bare prompt is ">" (agy/copilot TUIs) or "❯" (Claude
#   Code) with only whitespace after it; a prompt with pending text stays
#   "busy" so a nudge never appends to someone's half-typed input.
# This is a heuristic on TUI rendering, not a guarantee: different TUI
# versions render idle/busy differently. On doubt this errs toward "busy"
# (skip the nudge) rather than "idle" (nudge) -- a delayed pickup just costs
# time, but a nudge into a genuinely busy pane injects stray keystrokes into
# whatever it's mid-generating.
pane_is_idle() {
  local target="$1" agent="${2:-}" cmd tail markers pane_id hook_state
  # issue #33: a Claude Code pane's own hooks (UserPromptSubmit/
  # PreToolUse -> busy, Stop -> idle) write ground truth, keyed by
  # $TMUX_PANE -- authoritative wherever it's fresh, since it needs no
  # guessing about what's rendered on screen (unlike the capture-pane
  # heuristic below, which cannot tell Claude Code's input hint/ghost text
  # from real pending content and misreads busy/idle as a result). A pane
  # with no fresh hook state (agy's pane -- a different TUI whose process
  # never fires these hooks -- or a pane whose hook hasn't written yet)
  # falls through to the screen-scrape heuristic unchanged.
  pane_id="$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || echo '')"
  if [ -n "$pane_id" ]; then
    hook_state="$(pane_state_read "$pane_id" 2>/dev/null || echo '')"
    case "$hook_state" in
      idle) return 0 ;;
      busy) return 1 ;;
    esac
  fi
  cmd="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || echo '')"
  case "$cmd" in
    ""|bash|zsh|sh|fish) return 0 ;;
  esac
  # send_meaningful_tail (send-lib.sh), not a raw capture-pane|tail -10: a
  # tall pane blank-pads below its real content, and a naive tail on the
  # unfiltered capture can grab pure padding instead of text (issue #86,
  # found dogfooding Task 3's own test).
  tail="$(send_meaningful_tail "$target" 10)"
  markers="$(pane_busy_markers "$agent")"
  if echo "$tail" | grep -Eiq "$markers"; then
    return 1
  fi
  # Bare idle prompt: a line that is JUST >/❯, nothing else (not even a
  # ghost-text/hint suffix on the SAME line) -- the original, strict check.
  if echo "$tail" | grep -Eq '^[[:space:]]*[>❯][[:space:]]*$'; then
    return 0
  fi
  # issue #97 review round 2 (agy finding 1, reproduced live): an EARLIER
  # version of this fix dropped the anchor entirely (matched a prompt char
  # at the start of ANY line, trailing content or not) to handle stuck
  # unsubmitted nudge text on the prompt line -- but that also matches any
  # GENERATED line starting with '>' (a markdown blockquote, a quoted
  # shell transcript), and once the real busy marker scrolls out of the
  # 10-line tail window on a long response, that reads a genuinely busy
  # pane as idle (confirmed by direct reproduction) -- exactly the
  # AGENTS.md-forbidden outcome (nudge keystrokes injected mid-generation).
  # Scoped instead to the ACTUAL input-box shape: a prompt-shaped line
  # (with or without trailing text) immediately followed by a border line
  # (a run of box-drawing dashes). That framing is Claude Code's own fixed
  # UI chrome around its input box -- rendered regardless of what's typed
  # on the prompt line -- and essentially never appears immediately after
  # an arbitrary line of generated output. Still recognizes the original
  # stranded-nudge bug (stuck "check inbox" text on the FRAMED prompt
  # line, e.g. immediately followed by Claude Code's own separator) without
  # reopening the blockquote false-IDLE risk: an isolated '> quoted text'
  # deep in scrolled output is never followed by that same framing.
  #
  # A pure-bash line-walk, not awk: macOS's awk ("one true awk") mishandles
  # a `{8,}` interval combined with a multi-byte UTF-8 character class --
  # confirmed live, every line falsely matched the border regex regardless
  # of content once both were combined in one awk pattern. grep -E does not
  # have this problem (already proven correct elsewhere in this exact file,
  # e.g. the `[>❯]` prompt-char class), so the line-by-line comparison is
  # done with grep instead.
  local prev_line cur_line
  prev_line=""
  while IFS= read -r cur_line; do
    if [ -n "$prev_line" ] && echo "$prev_line" | grep -Eq '^[[:space:]]*[>❯]' \
      && echo "$cur_line" | grep -Eq '[─━]{8,}'; then
      return 0
    fi
    prev_line="$cur_line"
  done <<< "$tail"
  return 1
}

nudge_agent() {
  local agent="$1" target
  target="$(pane_for_agent "$agent")"
  if [ -z "$target" ]; then
    echo "dispatch.sh: no pane mapping for agent '$agent', skipping nudge" >&2
    return 0
  fi
  # T24: check the session the TARGET pane actually lives in, not a
  # hardcoded "harness" -- lets tests point pane_for_agent at a throwaway
  # session and exercise the busy/idle branches for real instead of only
  # ever hitting this early "no session" return (production targets are
  # always "harness:0.N" so this is a no-op behavior change there).
  if ! tmux has-session -t "${target%%:*}" 2>/dev/null; then
    echo "dispatch.sh: no tmux '${target%%:*}' session running, skipping nudge" >&2
    return 0
  fi
  if pane_is_idle "$target" "$agent"; then
    # issue #86 finding 1: nudge_agent is the HIGHEST-frequency send path of
    # the three (dispatch/gatekeeper/auto-resume) but was the only one still
    # on a bare send-keys burst with no confirm/retry -- routed through the
    # same shared send_submit (send-lib.sh) as the other two now.
    send_submit "$target" "check inbox"
    echo "dispatch.sh: nudged $agent ($target)"
  else
    echo "dispatch.sh: $agent ($target) is busy, deferred nudge"
    if ! grep -qxF "$agent" "$DEFERRED_FILE" 2>/dev/null; then
      echo "$agent" >> "$DEFERRED_FILE"
    fi
  fi
}

# scribe_spawn_headless <msg_file> <ack_file> -- issue #89 (T38): scribe has
# no standing pane anymore (pane 3 retired -- no recurring scribe job
# remained after #85's mechanical issue-close). A dispatch to scribe/copilot
# spawns a ONE-SHOT headless run instead of nudging a pane: `claude -p
# --model haiku` reads the .msg content, does the judgment task, and writes
# its own one-line receipt to the .ack path, then exits. The inbox stays
# the durable record either way -- this just changes who/what performs the
# task, not where the record lives. Split out (like mw_fetch_merged_prs
# etc. elsewhere in this harness) so tests can override this function
# directly instead of spawning a real `claude` process. Runs in the
# background: `assign` returns immediately regardless, and `handoff`'s
# existing poll loop below already waits for the .ack to appear no matter
# who writes it.
scribe_spawn_headless() {
  local msg_file="$1" ack_file="$2" msg_body prompt project_name allowed_tools log_file
  local spawn_id scratch_dir
  msg_body="$(cat "$msg_file" 2>/dev/null)"
  # issue #18 B3: this used to hardcode "career-ops-harness" (this
  # harness's original single-consumer project) -- project-agnostic now,
  # reading THIS project's own name from orchestrator.yaml like every
  # other role/session-name derivation in this file.
  project_name="$(orc_get_scalar project)"
  project_name="${project_name:-this project}"

  # $$ (this shell's PID), not just a timestamp: date has no portable
  # sub-second resolution (GNU %N isn't available on macOS/BSD date), and
  # two scribe spawns landing in the same second would otherwise clobber
  # each other's log file/scratch dir.
  spawn_id="$(date '+%Y%m%d%H%M%S')-$$"
  mkdir -p "$CANON_DIR/state"
  log_file="$CANON_DIR/state/scribe-${spawn_id}.log"
  # agy PROBE 1 (PR #30 REQUEST-CHANGES): gh issue/pr comment needs
  # --body-file <tmpfile> (the guard false-positives on inline --body), and
  # creating that tmpfile is a Write to a path that is NOT $ack_file -- the
  # scribe deadlocked on an unanswerable permission prompt the moment it
  # tried to post a real comment. Give it a scratch dir it owns, created
  # BEFORE the spawn so the grant below is real, not aspirational.
  scratch_dir="$CANON_DIR/state/scribe-${spawn_id}"
  mkdir -p "$scratch_dir"

  # Plain concatenation, not a heredoc: an unquoted heredoc's lexer tracks
  # quote state while scanning for $(...)/`...`, and a stray apostrophe in
  # prose (e.g. "doesn't") opens an unterminated single-quote from its
  # point of view -- breaks the WHOLE script's parse, not just this
  # function (found the hard way writing this very function).
  prompt="You are the scribe agent for ${project_name}, spawned one-shot to handle a single dispatched task (issue #89: scribe has no standing pane -- this headless run IS the scribe for this one message).

Dispatch message:
$msg_body

Do the judgment task described above. If you need to post a gh issue/PR comment with a multi-line body, write the body text to a file under this scratch directory first (e.g. ${scratch_dir}/comment.md), using the Write tool, then pass it as --body-file to gh -- do not use an inline --body argument. This scratch directory is yours alone; do not write anywhere else except your own ack file below.
When finished, write exactly one line -- what you did, or SKIPPED: <reason> if it does not apply -- to this file: $ack_file
Do nothing else outside the scope of this message."

  # issue #23, reworked after agy's PR #30 REQUEST-CHANGES (3 findings):
  #  (a) ORC_ONESHOT=1 tells check-handoff.sh's Stop hook to exempt this
  #      session -- a one-shot's own .session-start marker is always newer
  #      than any handoff.md written before it spawned, and per AGENTS.md's
  #      single-writer rule the scribe must never write that file anyway.
  #      SAFE ONLY because issue #31 protects .claude/.agents/ by default
  #      now (see check-handoff.sh's comment) -- otherwise this flag would
  #      be spoofable by editing the Stop hook's own command.
  #  (b) --allowedTools grants EXACTLY what the scribe's job needs: the gh
  #      subcommands AGENTS.md scopes Reviewer/Scribe output to (scoped to
  #      specific subcommands -- comment/close/view -- with the colon-
  #      prefix form, not a bare 'gh pr'/'gh issue' string prefix, which
  #      would also match any hypothetical subcommand merely sharing that
  #      prefix), a Write grant scoped to its own scratch dir (PROBE 1) plus
  #      its ack file, and log-decision.sh. Never blocks on a permission
  #      prompt a headless `-p` run cannot answer. This narrows what Claude
  #      attempts without asking -- the PreToolUse guards (guard.sh/
  #      guard-write.sh) still run underneath it, so this is not a
  #      --dangerously-skip-permissions substitute.
  #  (c) stdout+stderr go to a real log file, not /dev/null -- and if the
  #      process exits without ever writing $ack_file, we write a
  #      SPAWN-FAILED ack ourselves so a dead/blocked/crashed run is never
  #      silent again (previously indistinguishable from a never-started
  #      one).
  allowed_tools="Read,Grep,Glob,Bash(gh issue comment:*),Bash(gh issue close:*),Bash(gh issue view:*),Bash(gh pr comment:*),Bash(gh pr view:*),Bash(bash lib/log-decision.sh:*),Write($scratch_dir/**),Write($ack_file)"

  (
    ORC_ONESHOT=1 claude -p --model haiku --allowedTools "$allowed_tools" "$prompt" >"$log_file" 2>&1
    if [ ! -s "$ack_file" ]; then
      echo "SPAWN-FAILED: headless scribe exited without writing an ack -- see $log_file" > "$ack_file"
    fi
  ) &
}

# retry_deferred_nudges (T24) -- drains DEFERRED_FILE, re-attempting a nudge
# for each queued agent. An agent whose pane is idle now gets nudged (and
# drops out of the queue); one still busy gets re-queued by the same
# nudge_agent() call above, so nothing is lost across iterations.
retry_deferred_nudges() {
  [ -s "$DEFERRED_FILE" ] || return 0
  local agents
  agents="$(sort -u "$DEFERRED_FILE")"
  : > "$DEFERRED_FILE"
  local agent
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    nudge_agent "$agent"
  done <<< "$agents"
}

# dispatch_write_msg <base_path_without_ext> <body_file (or empty)> <msg (or empty, used only if body_file is empty)>
# -- issue #90. Allocates a collision-free "<base>[-N].msg" filename and
# writes it ATOMICALLY (temp file in the SAME directory, then `mv -n`),
# so a half-written file is never observable as complete and two
# concurrent writers can never silently clobber each other. Prints the
# final path on success.
#
# `mv -n` (BSD and GNU) exits 0 whether or not it actually moved anything
# -- confirmed empirically on macOS: given an existing target, it leaves
# BOTH files in place (does not overwrite, does not error). Success is
# therefore detected by the temp file no longer existing afterward, not
# by mv's exit status -- this is the load-bearing check, not a style
# choice. mktemp alongside the target (not $TMPDIR) guarantees the mv is
# same-filesystem, same precedent as gatekeeper.sh's heartbeat write.
dispatch_write_msg() {
  local base="$1" body_file="$2" msg="$3" suffix=1 target tmp
  while :; do
    if [ "$suffix" -eq 1 ]; then
      target="${base}.msg"
    else
      target="${base}-${suffix}.msg"
    fi
    tmp="$(mktemp "${target}.XXXXXX")" || return 1
    if [ -n "$body_file" ]; then
      cp "$body_file" "$tmp"
    else
      echo "$msg" > "$tmp"
    fi
    mv -n "$tmp" "$target" 2>/dev/null
    if [ ! -e "$tmp" ]; then
      echo "$target"
      return 0
    fi
    # mv -n refused -- target already existed (a genuine same-second
    # collision). Clean up our temp file and try the next suffix.
    rm -f "$tmp"
    suffix=$((suffix + 1))
  done
}

dispatch_main() {
  local USAGE="usage: dispatch.sh <handoff|assign|message> <agent> <issue> <msg>|--body-file <path> [timeout_s]"
  local VERB="${1:?$USAGE}"
  local AGENT="${2:?$USAGE}"
  local ISSUE="${3:?$USAGE}"
  # issue #59: a real dispatch body is 3-8KB of structured text -- passing
  # that as a POSITIONAL string arg forces the CALLER into command
  # substitution ("$(cat file)"), which is exactly the kind of construct
  # guard.sh cannot safely verify and correctly refuses to trust. --body-file
  # lets the caller Write the body to a file and pass a PATH instead: no
  # substitution anywhere in the Bash tool call guard.sh inspects. The body
  # is `cp`'d byte-for-byte (not read into a variable) so a trailing-newline
  # mismatch or embedded NUL-adjacent oddity in the body can't silently
  # change what lands in the inbox. The short positional-string form still
  # works unchanged for short messages.
  local MSG="" BODY_FILE="" TIMEOUT
  if [ "${4:-}" = "--body-file" ]; then
    BODY_FILE="${5:?$USAGE}"
    if [ ! -f "$BODY_FILE" ]; then
      echo "dispatch.sh: --body-file '$BODY_FILE' does not exist" >&2
      return 1
    fi
    TIMEOUT="${6:-120}"
  else
    MSG="${4:?$USAGE}"
    TIMEOUT="${5:-120}"
  fi
  local INBOX="$CANON_DIR/inbox/$(inbox_dir_name "$AGENT")"

  case "$VERB" in
    handoff|assign|message) ;;
    *)
      echo "dispatch.sh: unknown verb '$VERB' (expected handoff|assign|message)" >&2
      return 1
      ;;
  esac

  if [ ! -d "$INBOX" ]; then
    echo "dispatch.sh: no inbox for agent '$AGENT' (expected $INBOX)" >&2
    return 1
  fi

  # issue #90 (live incident): two dispatches to the same agent+issue
  # inside the same wall-clock second used to compute the identical
  # <ts>-<issue>.msg filename, and a plain `>` write let the second
  # silently clobber the first (a builder dead-flag was lost this way).
  # dispatch_write_msg below allocates a collision-free name (the first,
  # non-colliding writer keeps the plain <ts>-<issue>.msg shape untouched
  # -- every existing reader/sweeper keeps working unmodified; only an
  # actual collision appends -2, -3, ... ) and writes atomically.
  local ts file ack
  ts=$(date '+%Y%m%d%H%M%S')
  file="$(dispatch_write_msg "$INBOX/${ts}-${ISSUE}" "$BODY_FILE" "$MSG")" || {
    echo "dispatch.sh: could not allocate a unique inbox filename under $INBOX/${ts}-${ISSUE}*.msg" >&2
    return 1
  }
  ack="${file%.msg}.ack"
  echo "dispatch.sh: wrote $file"

  [ "$VERB" = "message" ] && return 0

  # issue #89: scribe/copilot has no standing pane to nudge -- spawn its
  # one-shot headless run instead. Every other agent still goes through the
  # normal pane nudge.
  case "$AGENT" in
    scribe|copilot)
      echo "dispatch.sh: spawning one-shot headless scribe for $ISSUE"
      scribe_spawn_headless "$file" "$ack"
      ;;
    *)
      nudge_agent "$AGENT"
      ;;
  esac

  [ "$VERB" = "assign" ] && return 0

  # T30 (issue #56): an .ack is meant to be a RECEIPT -- a one-line "what was
  # done / SKIPPED because X" -- not just a marker file. An empty (or
  # whitespace-only) .ack has been seen in the wild (15 stale backfill acks
  # found across agy/copilot's real inboxes, from before this rule
  # existed) and tells the sender nothing. Treat it as suspect: keep
  # polling instead of accepting it, so a genuinely non-empty ack still
  # unblocks handoff normally, but a bare `touch`/`echo "" >` doesn't.
  local elapsed=0 warned_empty=0
  while true; do
    if [ -e "$ack" ]; then
      if [ -n "$(tr -d '[:space:]' < "$ack" 2>/dev/null)" ]; then
        break
      elif [ "$warned_empty" -eq 0 ]; then
        echo "dispatch.sh: $ack exists but is empty/whitespace-only (suspect, not a real receipt) -- still waiting" >&2
        warned_empty=1
      fi
    fi
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      echo "dispatch.sh: timeout waiting for $ack after ${TIMEOUT}s" >&2
      return 2
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "dispatch.sh: received $ack"
}

# Guard so this file can be sourced (for pane_is_idle etc. in tests /
# dispatch-tester.sh) without running dispatch_main as a side effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  dispatch_main "$@"
  exit $?
fi
