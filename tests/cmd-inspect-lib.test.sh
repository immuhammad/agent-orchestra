#!/bin/bash
# tests/cmd-inspect-lib.test.sh — unit tests for lib/cmd-inspect-lib.sh's
# surviving quote-aware scanners (#139: the tokenizer/write-target half
# was pruned as consumer-less after #147's thin guard.sh dropped its last
# caller; orc_lexical_normalize, orc_split_top_level_segments, and
# orc_segment_has_unquoted_redirect remain, all consumed by
# lib/quota-stop-lib.sh's qsg_split_top_level, and the splitter is also
# guard.sh's own anchor for its destructive-command deny list). Focus:
# the no-backslash-lookback quote-desync bug (#139) -- a backslash-
# escaped double-quote inside an already-open double-quoted argument was
# treated as a real closing quote, letting the arg's remaining text
# (which can contain `;`/`&&`/`>`) be seen as unquoted. Run: bash
# tests/cmd-inspect-lib.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/cmd-inspect-lib.sh
source "$(cd "$DIR/../lib" && pwd)/cmd-inspect-lib.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# single-char building blocks -- avoids fragile nested-escaping in the
# literal test strings below.
DQ='"'
SQ="'"
BS='\'

# assert_segments <desc> <input> <expected segment>...
assert_segments() {
  local desc="$1" input="$2"; shift 2
  local -a expected=("$@")
  local -a actual=()
  local line
  while IFS= read -r line; do
    actual+=("$line")
  done < <(orc_split_top_level_segments "$input")
  if [ "${#actual[@]}" -eq "${#expected[@]}" ]; then
    local i ok=1
    for i in "${!expected[@]}"; do
      [ "${actual[$i]}" = "${expected[$i]}" ] || ok=0
    done
    if [ "$ok" -eq 1 ]; then
      pass "$desc"
      return
    fi
  fi
  fail "$desc (got: $(printf '%q ' "${actual[@]}"), want: $(printf '%q ' "${expected[@]}"))"
}

expect_redirect() {
  local desc="$1" segment="$2"
  if orc_segment_has_unquoted_redirect "$segment"; then
    pass "$desc"
  else
    fail "$desc (expected a redirect to be detected)"
  fi
}

expect_no_redirect() {
  local desc="$1" segment="$2"
  if orc_segment_has_unquoted_redirect "$segment"; then
    fail "$desc (expected NO redirect to be detected)"
  else
    pass "$desc"
  fi
}

echo "== #139: escaped double-quote inside a quoted arg must not desync quote state =="
assert_segments "escaped-quote arg keeps its embedded ; literal (no false split)" \
  "echo ${DQ}a${BS}${DQ}b;c${DQ} d" \
  "echo ${DQ}a${BS}${DQ}b;c${DQ} d"

assert_segments "escaped-quote arg keeps its embedded && literal (no false split)" \
  "echo ${DQ}a${BS}${DQ}b && rm -rf /${DQ} d" \
  "echo ${DQ}a${BS}${DQ}b && rm -rf /${DQ} d"

expect_no_redirect "escaped-quote arg keeps its embedded > literal (no false redirect)" \
  "echo ${DQ}a${BS}${DQ}b>c${DQ} d"

assert_segments "escaped backslash (\\\\) before a REAL closing quote still closes it, and the split after it still fires" \
  "echo ${DQ}a${BS}${BS}${DQ} ; echo b" \
  "echo ${DQ}a${BS}${BS}${DQ} " \
  " echo b"

echo "== single-quote/backslash interaction: reviewed, deliberately unchanged (POSIX: no escaping inside single quotes) =="
assert_segments "backslash inside single quotes is plain literal text, ; inside stays literal too" \
  "echo ${SQ}a${BS};b${SQ} c" \
  "echo ${SQ}a${BS};b${SQ} c"

assert_segments "a trailing backslash does NOT escape the single-quote close (closes immediately, split after it fires)" \
  "echo ${SQ}a${BS}${SQ} ; true" \
  "echo ${SQ}a${BS}${SQ} " \
  " true"

expect_redirect "single-quoted trailing backslash does not suppress a later real unquoted redirect" \
  "echo ${SQ}a${BS}${SQ} > out.txt"

echo "== regression: existing quoting/splitting behavior unaffected =="
assert_segments "plain unquoted split on ;" "echo a; echo b" "echo a" " echo b"
assert_segments "quoted ; (no backslash involved) stays inside" "echo ${DQ}a;b${DQ}" "echo ${DQ}a;b${DQ}"
expect_redirect "plain unquoted redirect" "echo hi > out.txt"
expect_no_redirect "quoted redirect char is not a redirect" "echo ${DQ}usage < 50%${DQ}"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
