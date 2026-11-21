#!/usr/bin/env bats
# Not gitbash-tagged: the Git Bash job budget (#962 measured ~28 min with it);
# its Windows evidence is the hand-run file in the issue directory.
# tests/next-hold.bats — #962: next.sh's question_stop. A question STUCK stops
# every call with exit `operator-question`; an open record for the current or
# just-dispatched step prints the ASK block (interactive) or becomes a hold
# (unattended). Script-backed holds run a fixture step in a staged tree.
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

NEXT="$PLUGIN_ROOT/scripts/next.sh"
H="$PLUGIN_ROOT/scripts/hold.sh"

# _at_commit: rows 5 improve and 6 prune done, so commit is the first unchecked row.
_at_commit() {
  sed -i -e 's/^- \[~\]  5\. improve/- [x]  5. improve/' -e 's/^- \[ \]  6\. prune/- [x]  6. prune/' "$CK"
}

# _step <hold 0|1> <exit>: stage a tree whose scripts/commit.sh is the fixture
# step. Sets TREE, COUNTER and QF.
_step() {
  _tree
  COUNTER="$BATS_TEST_TMPDIR/counter"
  QF="$BATS_TEST_TMPDIR/q.md"
  _q "$QF"
  sed -e "s|@COUNTER@|$COUNTER|" -e "s|@HOLD@|$1|" -e "s|@EXIT@|$2|" -e "s|@QFILE@|$QF|" \
    "$PLUGIN_ROOT/tests/fixtures/hold/holding-step.sh" > "$TREE/scripts/commit.sh"
  chmod +x "$TREE/scripts/commit.sh"
  : > "$COUNTER"
  _at_commit
}

_runs() { wc -l < "$COUNTER" | tr -d ' '; }

# _held_lines: the three hold lines for Issue-7's STUCK.
_held_lines() {
  local step="$1" num="$2"
  printf '%s\n' "OPERATOR QUESTION: toy/Issue-7 is held at step $num ($step); nothing was run." \
    "  Question: $D/STUCK" \
    "  Answer:   $(sed -n '/^## How to answer$/,$p' "$D/STUCK" | grep -m1 '^/devagent:answer ')"
}

@test "next: a question STUCK stops the call with operator-question and prints the STUCK path and the answer line" {
  _tset active_issue '"Issue-8"'
  _tset issue_dir "\"$DEVDOC/Issue-8\""
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 DEVAGENT_ACTIVE_PROJECT=toy DEVAGENT_ACTIVE_ISSUE=Issue-7 run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 0 ]
  local st i
  st="$(sha256sum < "$DA_HOME/state/toy.toml")"
  for i in 1 2; do
    DEVAGENT_ACTIVE_PROJECT=toy DEVAGENT_ACTIVE_ISSUE=Issue-7 run --separate-stderr "$NEXT" toy
    [ "$status" -eq "$OQ" ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
    [ "$output" = "$(_held_lines improve 5)" ]
    [[ "$output" != *dispatch:* ]]
    [ "$(sha256sum < "$DA_HOME/state/toy.toml")" = "$st" ]
  done
  grep -q '^/devagent:answer toy Issue-7 01 a$' "$D/STUCK"
}

@test "next: after an unpinned hold next reports No active issue" {
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 0 ]
  run --separate-stderr "$NEXT" toy
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"No active issue for project 'toy'"* ]]
}

@test "next: a script step that holds makes the same call exit operator-question" {
  local pin code n=0
  for pin in "" Issue-7; do
    for code in 0 5; do
      _toy
      rm -rf "$D/STUCK" "$D/questions" "$(NF)"
      _step 1 "$code"
      DEVAGENT_UNATTENDED=1 DEVAGENT_ACTIVE_PROJECT=${pin:+toy} DEVAGENT_ACTIVE_ISSUE="$pin" \
        run --separate-stderr "$TREE/scripts/next.sh" toy --auto
      [ "$status" -eq "$OQ" ] || { echo "pin=$pin code=$code rc=$status out=$output err=$stderr" >&2; return 1; }
      [[ "$output" == *"dispatch: toy/Issue-7 — step 12 (commit), script-backed"* ]]
      [[ "$output" == *"OPERATOR QUESTION: toy/Issue-7 is held at step 12 (commit); nothing was run."* ]]
      [[ "$stderr" != *"did not mark itself"* ]]
      [ "$(_runs)" = 1 ]
      [ "$(_lines)" = 1 ]
      n=$((n + 1))
    done
  done
  [ "$n" -eq 4 ]
}

@test "next: a script step whose hold.sh exits 3 prints ASK, the fallback line and the continue line and exits 0" {
  _step 1 3
  run --separate-stderr "$TREE/scripts/next.sh" toy --auto
  [ "$status" -eq 0 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  local rec="$D/questions/01-commit.md"
  [ -f "$rec" ]
  grep -qxF "ASK: $rec" <<<"$output"
  grep -qxF "  After the reply is recorded, continue: /devagent:next toy --auto" <<<"$output"
  grep -qxF "  No answer in the session: hold.sh toy Issue-7 --step commit --no-ask" <<<"$output"
  ! grep -q 'bash ' <<<"$output"
  ! grep -q '/scripts/' <<<"$output"
  [[ "$stderr" != *"did not mark itself"* ]]
  [ ! -e "$D/STUCK" ]
  # the printed fallback, run as the skill line runs it, holds.
  local args
  args="$(sed -n 's/^  No answer in the session: hold\.sh //p' <<<"$output")"
  # shellcheck disable=SC2086  # the printed arguments, word-split as the model passes them
  run bash "$TREE/scripts/hold.sh" $args
  [ "$status" -eq 0 ]
  grep -q '^Kind:        question$' "$D/STUCK"
  [ ! -e "$rec" ]
}

@test "next: a second call before the reply prints the same ASK and dispatches nothing" {
  _step 1 3
  run "$TREE/scripts/next.sh" toy --auto
  [ "$status" -eq 0 ]
  local first
  first="$(grep -A2 '^ASK: ' <<<"$output")"
  [ "$(_runs)" = 1 ]
  run --separate-stderr "$TREE/scripts/next.sh" toy --auto
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(_runs)" = 1 ]
}

@test "next: with the marker set an open record for the current step becomes a hold and the call exits operator-question" {
  _q "$BATS_TEST_TMPDIR/q.md"
  run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  _lib
  question_render "$BATS_TEST_TMPDIR/q.md" toy Issue-7 improve 5 r "4 scope" 02 t | sed '1a Blocking:    no' > "$D/questions/02-improve.md"
  local nb
  nb="$(sha256sum < "$D/questions/02-improve.md")"
  DEVAGENT_UNATTENDED=1 run --separate-stderr "$NEXT" toy --auto
  [ "$status" -eq "$OQ" ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ "$output" = "$(_held_lines improve 5)" ]
  [ -z "$(question_open_record "$D" improve)" ]
  [ "$(sha256sum < "$D/questions/02-improve.md")" = "$nb" ]
  [ "$(_lines)" = 1 ]
}

@test "next: when the takeover hold fails next exits with its code and dispatches nothing" {
  _q "$BATS_TEST_TMPDIR/q.md"
  run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  sed -i '/^- `b`/a - not an option' "$D/questions/01-improve.md"
  DEVAGENT_UNATTENDED=1 run --separate-stderr "$NEXT" toy --auto
  [ "$status" -eq 2 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [[ "$output" != *dispatch:* ]]
  [[ "$stderr" == *"hold.sh: refused (option): "* ]]
  [ ! -e "$D/STUCK" ]
}

@test "next: a missing hold line is written by the next call once the appender works" {
  mkdir -p "$(NF)"
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 1 ]
  DEVAGENT_ACTIVE_PROJECT=toy DEVAGENT_ACTIVE_ISSUE=Issue-7 run --separate-stderr "$NEXT" toy
  [ "$status" -eq "$OQ" ]
  [[ "$stderr" == *"next.sh: WARNING: hold not completed (hold.sh exit 1)"* ]]
  [ "$output" = "$(_held_lines improve 5)" ]
  ! grep -q 'hold line written' "$CK"
  rmdir "$(NF)"
  DEVAGENT_ACTIVE_PROJECT=toy DEVAGENT_ACTIVE_ISSUE=Issue-7 run --separate-stderr "$NEXT" toy
  [ "$status" -eq "$OQ" ]
  [[ "$stderr" != *WARNING* ]]
  [ "$(_lines)" = 1 ]
  grep -qE '  improve: hold line written for question 01$' "$CK"
}

@test "next: after a refused park an unpinned next on the still-active issue exits operator-question" {
  _tree
  printf '#!/usr/bin/env bash\nexit 11\n' > "$TREE/scripts/park.sh"
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run "$TREE/scripts/hold.sh" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 11 ]
  grep -q '^active_issue = "Issue-7"$' "$DA_HOME/state/toy.toml"
  run --separate-stderr "$TREE/scripts/next.sh" toy
  [ "$status" -eq "$OQ" ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ "$output" = "$(_held_lines improve 5)" ]
}

@test "next: a hold stopped after STUCK, after the mark and after the park exits operator-question when pinned" {
  local stage n=0
  for stage in stuck mark park; do
    _toy
    rm -rf "$D/questions" "$D/STUCK" "$(NF)"
    _question_stuck improve 5
    [ "$stage" = stuck ] || checklist_mark_by_name "$CK" improve '?'
    [ "$stage" != park ] || "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7 --reason "operator question 01: r" 2>/dev/null
    DEVAGENT_ACTIVE_PROJECT=toy DEVAGENT_ACTIVE_ISSUE=Issue-7 run --separate-stderr "$NEXT" toy --auto
    [ "$status" -eq "$OQ" ] || { echo "$stage: rc=$status out=$output err=$stderr" >&2; return 1; }
    [[ "$output" != *dispatch:* ]]
    [ "$(_lines)" = 1 ]
    run "$H" toy Issue-7 --step improve --no-ask
    [ "$status" -eq 0 ]
    [ "$(_lines)" = 1 ]
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "next: a question STUCK whose row is not yet [?] stops the same way and another [?] row keeps the park hint" {
  _question_stuck improve 5
  grep -qE '^- \[~\]  5\. improve$' "$CK"
  run --separate-stderr "$NEXT" toy --auto
  [ "$status" -eq "$OQ" ]
  [ "$output" = "$(_held_lines improve 5)" ]
  # no question STUCK: a [?] row is the old external wait.
  _toy
  rm -f "$D/STUCK" "$(NF)"
  sed -i 's/^- \[~\]  5\. improve/- [?]  5. improve/' "$CK"
  run --separate-stderr "$NEXT" toy --auto
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Step 5 (improve) is [?] blocked-on-external. Consider /devagent:park."* ]]
}

@test "next: a failing script step with no hold still exits with its own status" {
  local code n=0
  for code in 5 3; do
    _toy
    rm -rf "$D/questions"
    _step 0 "$code"
    run --separate-stderr "$TREE/scripts/next.sh" toy --auto
    [ "$status" -eq "$code" ] || { echo "code=$code rc=$status err=$stderr" >&2; return 1; }
    [[ "$output" != *ASK:* ]]
    n=$((n + 1))
  done
  [ "$n" -eq 2 ]
}
