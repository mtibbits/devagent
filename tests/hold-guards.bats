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

# ---- Task 2: pull, switch, resume and revise refuse a held issue -----------

# _pullable: toy gains an issue source and the gh-stub (argv logged).
_pullable() {
  cat >> "$DA_HOME/config.toml" <<EOF2

[project.toy.issue_source]
backend = "github"
repo = "o/toy"
dir_prefix = "Issue-"
EOF2
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH" GH_STUB_CASE=standard GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
}

_active8() {
  _tset active_issue '"Issue-8"'
  _tset issue_dir "\"$DEVDOC/Issue-8\""
}

@test "pull: a held parked issue is refused with operator-question and nothing changes" {
  _pullable
  _held
  local leg before
  for leg in none issue-8; do
    [ "$leg" = none ] || _active8
    before="$(_snap)"
    run --separate-stderr "$S/pull.sh" toy 7
    [ "$status" -eq "$OQ" ] || { echo "leg $leg rc=$status err=$stderr" >&2; return 1; }
    [ "$(_snap)" = "$before" ]
    [ ! -s "$GH_STUB_ARGV_LOG" ]
    [ "$stderr" = "$(_refusal_lines pull)" ]
  done
}

@test "pull: a trust refusal still wins over a held issue" {
  _pullable
  _held
  trust_home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$trust_home/.config/devagent/trust"
  printf 'x = [\n' > "$trust_home/.config/devagent/trust/policy.toml"
  HOST="$(bash -c 'source "$1"; trust_exit_code host' _ "$PLUGIN_ROOT/scripts/lib/refusals.sh")"
  HOME="$trust_home" run --separate-stderr "$S/pull.sh" toy 7
  [ "$status" -eq "$HOST" ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$HOST" -ne "$OQ" ]
}

@test "switch: a held target is refused and the current issue is not parked" {
  _held
  _active8
  local before; before="$(_snap)"
  run --separate-stderr "$S/switch.sh" toy Issue-7
  [ "$status" -eq "$OQ" ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  grep -q '^active_issue = "Issue-8"$' "$DA_HOME/state/toy.toml"
  ! grep -q '\[P\]' "$DEVDOC/Issue-8/checklist.md"
  [ "$(_snap)" = "$before" ]
  [ "$stderr" = "$(_refusal_lines switch)" ]
}

@test "resume: a held parked issue is refused" {
  _held
  local before; before="$(_snap)"
  run --separate-stderr "$S/resume.sh" toy Issue-7
  [ "$status" -eq "$OQ" ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$(_snap)" = "$before" ]
  [ "$stderr" = "$(_refusal_lines resume)" ]
}

@test "revise: a held active issue is refused, with and without --retier" {
  _held_active
  mkdir -p "$D/revisions/r1" && : > "$D/revisions/r1/comments.md"
  local before; before="$(_snap)"
  run --separate-stderr "$S/revise.sh" toy --no-chain
  [ "$status" -eq "$OQ" ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$stderr" = "$(_refusal_lines revise)" ]
  run --separate-stderr "$S/revise.sh" toy --retier standard --no-chain
  [ "$status" -eq "$OQ" ] || { echo "retier rc=$status err=$stderr" >&2; return 1; }
  [ "$(_snap)" = "$before" ]
}

_leg_resume() {
  "$S/park.sh" toy >/dev/null
  run --separate-stderr "$S/resume.sh" toy Issue-7
  [ "$status" -eq 0 ] || { echo "resume rc=$status err=$stderr" >&2; return 1; }
  grep -q '^- \[~\]  5\. improve' "$CK"
}
_leg_switch() {
  "$S/park.sh" toy >/dev/null
  run --separate-stderr "$S/switch.sh" toy Issue-7
  [ "$status" -eq 0 ] || { echo "switch rc=$status err=$stderr" >&2; return 1; }
}
_leg_revise() {
  mkdir -p "$D/revisions/r1" && : > "$D/revisions/r1/comments.md"
  run --separate-stderr "$S/revise.sh" toy --no-chain
  [ "$status" -eq 0 ] || { echo "revise rc=$status err=$stderr" >&2; return 1; }
  grep -q '^## Revision' "$CK"
}
_leg_pull() {
  _pullable
  "$S/park.sh" toy >/dev/null
  run --separate-stderr "$S/pull.sh" toy 7
  [ "$status" -eq 0 ] || { echo "pull rc=$status err=$stderr" >&2; return 1; }
  grep -q 'issue' "$GH_STUB_ARGV_LOG"
}

@test "other kinds: pull, switch, resume and revise act as today" {
  _kinds _leg_resume
  _kinds _leg_switch
  _kinds _leg_revise
  _kinds _leg_pull
}
