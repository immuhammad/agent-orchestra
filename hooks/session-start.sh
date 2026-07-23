#!/bin/bash
# SessionStart hook: mark session start + surface quota reminder.
# Scope addition: one-line role->skills auto-use reminder,
# since skills must be auto-used per AGENTS.md's Skills table, not just
# invocable on request. Kept role-agnostic (this hook fires identically for
# every session/role) -- full detail lives in AGENTS.md's Skills table.
# issue #23: a one-shot/headless spawn (e.g. the dispatched scribe) must
# run with MINIMAL context -- just its dispatched task, already given
# directly in its own prompt -- not this pane-agent room-state briefing. A
# scribe spawn was observed booting, reading the "read handoff.md" + quota
# rule instructions below, concluding from a STALE handoff.md that the room
# was quota-parked, and self-aborting instead of doing its dispatched task.
# A one-shot has no standing pane and no handoff.md duty (its own Stop hook
# already exempts it via this same ORC_ONESHOT marker, see
# check-handoff.sh), so it should never see this briefing at all.
set -uo pipefail

# Read once, up front (same discipline as hooks/pane-state.sh): the OS pipe
# holds this fine even on the ORC_ONESHOT early-exit path below, but
# reading it unconditionally means every later branch can just use $INPUT.
INPUT="$(cat)"

if [ "${ORC_ONESHOT:-0}" = "1" ]; then
  echo '{}'
  exit 0
fi

touch .harness/.session-start

BASE_CONTEXT="HARNESS ACTIVE. Read .harness/handoff.md (current task state, ephemeral -- replaced each session) and .harness/decisions.log (durable cross-session context, append-only) before any work. Quota rule: at 80% of any window, stop, update handoff, ask Ahmad about fallback switch. Ahmad: run /usage to check Claude quota, agy quota screen for Google pool. Skills auto-use by role (see AGENTS.md Skills table): Builder -- test-driven-development, systematic-debugging, verification-before-completion, using-git-worktrees; Reviewer -- code-review (applies review-protocol.md); Orchestra -- brainstorming, writing-plans (+ fan-out skills, Orchestra-only). Inbox .msg bodies: caveman mode; handoff.md/decisions.log/PR descriptions/issue comments stay full English."

# issue #6: session lifecycle classification (resumed|rebuilt|fresh).
# ORC_SESSION_CLASS is set by bin/orc's launch command (lib/session-
# lifecycle.sh's sl_build_launch_cmd) for the ACTUAL process env var
# claude itself was exec'd under -- so it's set here regardless of
# "source", but only a genuine process launch (source "startup" or
# "resume") is a real classification event. "clear"/"compact" re-fire this
# SAME hook inside an already-classified, already-running process; acting
# on those again would re-flag Orchestra and re-write role-session state
# for a pane that never actually rebuilt (the dedup this ticket asks for).
# No ORC_ROLE/ORC_SESSION_CLASS at all means a session started outside
# `orc up` -- same "untracked, never nagged" precedent as ORC_ROLE below.
LIFECYCLE_CONTEXT=""
SOUL_CONTEXT=""
ROLE="${ORC_ROLE:-}"
CLASS="${ORC_SESSION_CLASS:-}"
HOOK_SOURCE="$(echo "$INPUT" | jq -r '.source // empty' 2>/dev/null || echo '')"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo '')"

if [ -n "$ROLE" ] && [ -n "$CLASS" ]; then
  case "$HOOK_SOURCE" in
    startup|resume)
      DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
      # shellcheck source=../lib/harness-root.sh
      source "$DIR/../lib/harness-root.sh"
      CANON_DIR="$(harness_canonical_dir "$PWD" 2>/dev/null || echo '')"
      if [ -n "$CANON_DIR" ]; then
        PANE_STATE_DIR="$CANON_DIR/state/pane-state"
        ROLE_SESSION_DIR="$CANON_DIR/state/role-session"
        # shellcheck source=../lib/pane-state-lib.sh
        source "$DIR/../lib/pane-state-lib.sh"
        # shellcheck source=../lib/session-lifecycle.sh
        source "$DIR/../lib/session-lifecycle.sh"

        [ -n "${TMUX_PANE:-}" ] && pane_state_write "$TMUX_PANE" idle "$SESSION_ID" "$CLASS"
        [ -n "$SESSION_ID" ] && sl_write_role_session "$ROLE" "$SESSION_ID"

        # issue #12: per-role SOUL.md identity card -- CANON_DIR is the
        # project's .harness dir (see harness-root.sh), so its parent is
        # the project root souls/ lives in, sibling to AGENTS.md. Read
        # fresh every startup/resume (the card is meant to be re-read each
        # session, per the issue title) rather than cached in state. A
        # room that never ran `orc init`'s soul step (or an older room)
        # just has no file here -- silently no SOUL line, same "untracked,
        # never nagged" precedent as no-ORC_ROLE above.
        SOUL_FILE="$(dirname "$CANON_DIR")/souls/${ROLE}.md"
        if [ -f "$SOUL_FILE" ]; then
          SOUL_CONTEXT=" SOUL: $(cat "$SOUL_FILE")"
        fi

        case "$CLASS" in
          resumed)
            LIFECYCLE_CONTEXT=" SESSION LIFECYCLE: RESUMED -- this pane's prior session (${SESSION_ID:-unknown}) was continued successfully."
            ;;
          rebuilt)
            LIFECYCLE_CONTEXT=" SESSION LIFECYCLE: REBUILT -- the prior session for this pane could NOT be resumed; this is a fresh process with NO memory of earlier work in this pane. Do not assume continuity -- treat handoff.md and decisions.log as your only source of truth for what happened before now. Orchestra has been flagged."
            DISPATCH_CANON_DIR="$CANON_DIR" bash "$DIR/../lib/dispatch.sh" message orchestra "lifecycle-${ROLE}" "FLAG: pane '${ROLE}' REBUILT -- its prior session could not be resumed; it started fresh instead (new session ${SESSION_ID:-unknown}). Verify no in-flight work from that pane was lost." >/dev/null 2>&1 || true
            ;;
          fresh)
            LIFECYCLE_CONTEXT=" SESSION LIFECYCLE: FRESH -- no prior session was recorded for the '${ROLE}' role; this is a new pane/room."
            ;;
        esac
      fi
      ;;
  esac
fi

jq -n --arg ctx "${BASE_CONTEXT}${SOUL_CONTEXT}${LIFECYCLE_CONTEXT}" '{additionalContext: $ctx}'
