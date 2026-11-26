#!/usr/bin/env bats
# Not gitbash-tagged: the Git Bash job budget (#1197). Tagging this file is
# #1188's; its Windows evidence is the hand-run file in the issue directory.
# tests/hold-guards.bats — #963: the commands that could undo an operator-
# question hold refuse it (exit `operator-question`) or skip it, through one
# helper, hold_refuse (scripts/lib/checklist.sh). Every refusal asserts the
# exact code and a byte-identical `_snap`; every `other kinds:` test proves a
# non-question STUCK is handled as before #963.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'
load 'lib/hold-fixture'

setup_file() {
  OQ="$(bash -c 'source "$1"; trust_exit_code operator-question' _ "$PLUGIN_ROOT/scripts/lib/refusals.sh")"
  [[ "$OQ" =~ ^[0-9]+$ ]]
  export OQ
}

setup() {
  setup_tmp_devagent_home
  _toy
}
teardown() { teardown_tmp_devagent_home; }

S="$PLUGIN_ROOT/scripts"

# _held: Issue-7 held on a real question (hold.sh, unattended), so parked.
_held() {
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run "$S/hold.sh" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 0 ] || { echo "hold rc=$status out=$output" >&2; return 1; }
  [ "$(head -1 "$D/STUCK")" = "Kind:        question" ]
  grep -q '^\[parked\]' "$DA_HOME/state/toy.toml"
  grep -q '^Issue-7 = ' "$DA_HOME/state/toy.toml"
}

# _held_active: the same hold through a staged tree whose park.sh refuses, so
# Issue-7 stays the active issue (next-hold.bats's "after a refused park").
_held_active() {
  _tree
  printf '#!/usr/bin/env bash\nexit 11\n' > "$TREE/scripts/park.sh"
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run "$TREE/scripts/hold.sh" toy Issue-7 --step "${1:-improve}" --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 11 ] || { echo "hold rc=$status out=$output" >&2; return 1; }
  [ "$(head -1 "$D/STUCK")" = "Kind:        question" ]
  grep -q '^active_issue = "Issue-7"$' "$DA_HOME/state/toy.toml"
}

# _kinds <fn>: run <fn> once per non-question STUCK kind: one with no Kind:
# line (reads `stuck`) and one with an unknown kind. <fn> gets the kind name;
# each leg starts from a fresh _toy.
_kinds() {
  local k
  for k in stuck later-kind; do
    rm -rf "$DEVDOC" "$DA_HOME/state"/*
    _toy
    if [ "$k" = stuck ]; then
      _question_stuck improve 5
      sed -i 1d "$D/STUCK"
    else
      _question_stuck improve 5 later-kind
    fi
    ( _lib; [ "$(stuck_kind "$D")" = "$k" ] ) || { echo "fixture kind != $k" >&2; return 1; }
    "$@" "$k" || { echo "leg $k failed" >&2; return 1; }
  done
}

# _refusal_lines <caller>: the three lines hold_refuse prints for Issue-7.
_refusal_lines() {
  printf '%s\n' "$1: Issue-7 is held on an operator question; nothing was changed." \
    "  Question: $D/STUCK" \
    "  Answer:   ${2:-$( (_lib; question_answer_line "$D/STUCK") )}"
}

# _refuse <caller>: call hold_refuse directly on Issue-7.
_refuse() {
  run --separate-stderr bash -c '
    for l in paths io checklist; do source "$PLUGIN_ROOT/scripts/lib/$l.sh"; done
    hold_refuse "$1" "$2"
    echo "returned"' _ "$1" "$D"
}

# ---- Task 1: hold_refuse ----------------------------------------------------

@test "hold_refuse: the function exists once checklist.sh is sourced" {
  run bash -c 'for l in paths io checklist; do source "$PLUGIN_ROOT/scripts/lib/$l.sh"; done; type -t hold_refuse'
  [ "$status" -eq 0 ]
  [ "$output" = function ]
}

@test "hold_refuse: prints the question path and the answer line on stderr and exits operator-question" {
  _held
  _refuse resume
  [ "$status" -eq "$OQ" ]
  [ -z "$output" ]
  [ "$stderr" = "$(_refusal_lines resume)" ]
  [[ "$stderr" == *"/devagent:answer toy Issue-7 01 a" ]]
}

@test "hold_refuse: an answered STUCK points at --finish" {
  _held
  printf '\n## Answer\n\na\n' >> "$D/STUCK"
  _refuse resume
  [ "$status" -eq "$OQ" ]
  [ "$(sed -n 3p <<<"$stderr")" = "  Answer:   /devagent:answer toy Issue-7 01 --finish" ]
}

@test "hold_refuse: a question STUCK with no answer line still refuses" {
  _held
  sed -i '/^## How to answer$/,$d' "$D/STUCK"
  _refuse resume
  [ "$status" -eq "$OQ" ]
  [ "$(sed -n 3p <<<"$stderr")" = "  Answer:   (no answer line; read the STUCK's ## How to answer section)" ]
}
