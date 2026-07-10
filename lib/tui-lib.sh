#!/bin/bash
# .harness/tui-lib.sh — shared color/clear-screen helpers for gatekeeper.sh
# and watch.sh dashboard panes (T33, issue #77). Colors and screen-clearing
# auto-disable when stdout is not a tty or NO_COLOR is set, so redirected
# output (tests, `| head`, log capture) stays plain text -- nothing here
# should ever change what a test greps for, only how a live tmux pane looks.
set -uo pipefail

tui_color_enabled() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

_tui_code() { # $@ = tput capability args, e.g. "setaf 2"
  tui_color_enabled && tput "$@" 2>/dev/null
}

tui_green()  { echo "$(_tui_code setaf 2)$1$(_tui_code sgr0)"; }
tui_yellow() { echo "$(_tui_code setaf 3)$1$(_tui_code sgr0)"; }
tui_red()    { echo "$(_tui_code setaf 1)$1$(_tui_code sgr0)"; }
tui_bold()   { echo "$(_tui_code bold)$1$(_tui_code sgr0)"; }

# tui_traffic_light <pct> <text> -- wraps text per the quota failsafe
# thresholds: green <60, yellow 60-79, red >=80 (THRESHOLD in gatekeeper.sh).
tui_traffic_light() {
  local pct="$1" text="$2"
  if [ "$pct" -ge 80 ]; then tui_red "$text"
  elif [ "$pct" -ge 60 ]; then tui_yellow "$text"
  else tui_green "$text"; fi
}

# tui_clear -- no-op outside a real tty (piped/redirected output, tests)
# so nothing but a live tmux pane ever sees the clear sequence.
tui_clear() {
  tui_color_enabled && tput clear 2>/dev/null
  return 0
}

tui_section() { # $1 = section title
  tui_bold "== $1 =="
}
