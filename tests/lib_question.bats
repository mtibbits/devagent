#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/lib_question.bats — #962: the STUCK kind reader (stuck_kind in
# scripts/lib/checklist.sh) and the question library
# (scripts/lib/question-actions.sh): grammar, renderer, number, open-record
# finder, lock, no-clobber publish and the option-tag registry.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'
load 'lib/hold-fixture'   # _q and _lib

setup() {
  setup_tmp_devagent_home
  _lib
  D="$BATS_TEST_TMPDIR/Issue-7"
  mkdir -p "$D"
  printf '[project.toy]\ndevdoc_dir = "%s"\n' "$BATS_TEST_TMPDIR" > "$DA_HOME/config.toml"
}

# _render <file> [NN]: the fixture's render arguments.
_render() {
  question_render "$1" toy Issue-7 improve 5 "improve: 14 bugs after round 3 of 3" "4 scope" "${2:-03}" 2026-11-20T10:31:00-05:00
}

# _libs: a `source` line for the same libraries _lib loads, for a child bash.
_libs() {
  local l sep=""
  for l in paths io config checklist question-actions; do
    printf '%ssource %q' "$sep" "$PLUGIN_ROOT/scripts/lib/$l.sh"
    sep="; "
  done
  printf '\n'
}
teardown() { teardown_tmp_devagent_home; }

# ---- stuck_kind (Task 1) ----

@test "kind: prints none when there is no STUCK" {
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "kind: a STUCK with no Kind line reads stuck" {
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$D"
  "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$D" "needs help" >/dev/null
  [ -f "$D/STUCK" ]
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = stuck ]
}

@test "kind: question, watchdog and an unknown value print as written" {
  local n=0 k
  for k in question watchdog frobnicate; do
    printf 'Kind:        %s\nStep:        5 improve\n' "$k" > "$D/STUCK"
    run stuck_kind "$D"
    [ "$status" -eq 0 ]
    [ "$output" = "$k" ]
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "kind: a Kind line after the first blank line or a heading is ignored" {
  printf 'Step:        5 improve\n\nKind:        question\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$output" = stuck ]
  printf 'Step:        5 improve\n## Question\nKind:        question\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$output" = stuck ]
}

@test "kind: a CRLF STUCK reads the same as LF" {
  printf 'Kind:        question\r\nStep:        5 improve\r\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = question ]
}

@test "kind: an empty Kind value and a STUCK that is a directory read stuck" {
  printf 'Kind:   \nStep:        5 improve\n' > "$D/STUCK"
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = stuck ]
  rm -f "$D/STUCK"; mkdir "$D/STUCK"
  run stuck_kind "$D"
  [ "$status" -eq 0 ]
  [ "$output" = stuck ]
}

# ---- the question library (Task 3) ----

@test "question: a valid file renders the header, four sections and the answer block" {
  _q "$BATS_TEST_TMPDIR/q.md"
  run _render "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 0 ]
  [ "$output" = 'Kind:        question
Step:        5 improve
Reason:      improve: 14 bugs after round 3 of 3
Last good:   4 scope
Created:     2026-11-20T10:31:00-05:00

## Question

Proceed with round 4?

## Impediment

improve found 14 bugs after round 3 of 3.

## Options

- `a` (recommended) Run round 4.
- `b` Stop and prune.

## Evidence

analysis/2026-11-20-improve.md

## How to answer

/devagent:answer toy Issue-7 03 a
Other options: b' ]
}

@test "question: each malformed file is refused with its id" {
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/tests/fixtures/hold/test-tag.sh"
  local q="$BATS_TEST_TMPDIR/q.md" f="$BATS_TEST_TMPDIR/bad.md" n=0
  _q "$q"
  _case() { # <want-id>: validate $f and expect that refusal id
    run question_validate "$f"
    [ "$status" -eq 2 ] && [ "$output" = "$1" ] || { echo "row $((n + 1)) want $1 got rc=$status out=$output" >&2; return 1; }
    n=$((n + 1))
  }
  local sec
  for sec in Question Impediment Options Evidence; do
    awk -v s="## $sec" '/^## /{skip = ($0 == s)} !skip' "$q" > "$f"; _case section
  done
  sed '/^improve found/d' "$q" > "$f";                         _case section
  { cat "$q"; printf '\n## Answer\n\na\n'; } > "$f";           _case heading
  { printf 'preface\n'; cat "$q"; } > "$f";                    _case heading
  { cat "$q"; printf '\n## \n\nx\n'; } > "$f";                 _case heading
  sed '/^- `/d' "$q" > "$f";                                   _case option
  sed 's/^- `b` Stop/- b Stop/' "$q" > "$f";                   _case option
  sed 's/^- `b`/- `B`/' "$q" > "$f";                           _case option
  sed 's/^- `b`/- `-b`/' "$q" > "$f";                          _case option
  sed 's/^- `b`/- `a`/' "$q" > "$f";                           _case option-id
  sed 's/ (recommended)//' "$q" > "$f";                        _case recommended
  sed 's/^- `b`/- `b` (recommended)/' "$q" > "$f";             _case recommended
  sed 's/^- `b`/- `b` [grant: x]/' "$q" > "$f";                _case tag
  sed 's/^- `b`/- `b` [probe: no]/' "$q" > "$f";               _case tag-check
  # a malformed mark or tag is never prose (review I2)
  sed 's/^- `b` Stop and prune\.$/- `b` (recommended)/' "$q" > "$f";      _case option
  sed 's/^- `b` Stop and prune\.$/- `b` [nosuchtag: x]/' "$q" > "$f";     _case option
  sed 's/^- `b`/- `b` [nosuchtag: x] /' "$q" > "$f";                       _case option
  sed 's/^- `b`/- `b` [nosuchtag:x]/' "$q" > "$f";                         _case option
  sed 's/^- `b`/- `b` [NoSuch: x]/' "$q" > "$f";                           _case option
  [ "$n" -eq 22 ]
  sed 's/^- `b`/- `b` [probe: ok]/' "$q" > "$f"
  run question_validate "$f"
  [ "$status" -eq 0 ]
  run question_validate "$q"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "question: a CRLF file renders byte-identical to its LF twin" {
  _q "$BATS_TEST_TMPDIR/lf.md"
  sed 's/$/\r/' "$BATS_TEST_TMPDIR/lf.md" > "$BATS_TEST_TMPDIR/crlf.md"
  grep -q $'\r' "$BATS_TEST_TMPDIR/crlf.md"
  run question_validate "$BATS_TEST_TMPDIR/crlf.md"
  [ "$status" -eq 0 ]
  _render "$BATS_TEST_TMPDIR/lf.md" > "$BATS_TEST_TMPDIR/a.out"
  _render "$BATS_TEST_TMPDIR/crlf.md" > "$BATS_TEST_TMPDIR/b.out"
  cmp "$BATS_TEST_TMPDIR/a.out" "$BATS_TEST_TMPDIR/b.out"
}

@test "question: the number, step, reason and body read back from a rendered file" {
  _q "$BATS_TEST_TMPDIR/q.md"
  _render "$BATS_TEST_TMPDIR/q.md" > "$D/STUCK"
  [ "$(question_number "$D/STUCK")" = 03 ]
  [ "$(question_answer_line "$D/STUCK")" = "/devagent:answer toy Issue-7 03 a" ]
  [ "$(question_step "$D/STUCK")" = improve ]
  [ "$(question_reason "$D/STUCK")" = "improve: 14 bugs after round 3 of 3" ]
  question_body "$D/STUCK" > "$BATS_TEST_TMPDIR/body.md"
  cmp "$BATS_TEST_TMPDIR/body.md" "$BATS_TEST_TMPDIR/q.md"
  run question_answered "$D/STUCK"
  [ "$status" -eq 1 ]
  _render "$BATS_TEST_TMPDIR/body.md" > "$BATS_TEST_TMPDIR/again"
  cmp "$BATS_TEST_TMPDIR/again" "$D/STUCK"
  printf '\n## Answer\n\na\n' >> "$D/STUCK"
  question_answered "$D/STUCK"
}

@test "question: the next number follows the highest record and open STUCK number" {
  [ "$(question_next_number "$D")" = 01 ]
  mkdir -p "$D/questions"
  : > "$D/questions/08-improve.md"; : > "$D/questions/09-prune.md"
  [ "$(question_next_number "$D")" = 10 ]
  _q "$BATS_TEST_TMPDIR/q.md"
  _render "$BATS_TEST_TMPDIR/q.md" 12 > "$D/STUCK"
  [ "$(question_next_number "$D")" = 13 ]
}

@test "question: the finder returns only the step's open in-session record" {
  _q "$BATS_TEST_TMPDIR/q.md"
  mkdir -p "$D/questions"
  _render "$BATS_TEST_TMPDIR/q.md" 01 > "$D/questions/01-improve.md"
  printf '\n## Answer\n\na\n' >> "$D/questions/01-improve.md"
  _render "$BATS_TEST_TMPDIR/q.md" 02 | sed '1a Blocking:    no' > "$D/questions/02-improve.md"
  grep -q '^Blocking:    no$' "$D/questions/02-improve.md"
  _render "$BATS_TEST_TMPDIR/q.md" 03 > "$D/questions/03-prune.md"
  run question_open_record "$D" improve
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  _render "$BATS_TEST_TMPDIR/q.md" 04 > "$D/questions/04-improve.md"
  _render "$BATS_TEST_TMPDIR/q.md" 05 > "$D/questions/05-improve.md"
  run question_open_record "$D" improve
  [ "$output" = "$D/questions/05-improve.md" ]
  run question_open_record "$D" prune
  [ "$output" = "$D/questions/03-prune.md" ]
}

@test "registry: no production tag is registered" {
  run question_action_tags
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "registry: the probe tag checks, performs once per question, and a duplicate or undefined registration fails" {
  # shellcheck source=/dev/null
  source "$PLUGIN_ROOT/tests/fixtures/hold/test-tag.sh"
  export PROBE_LOG="$BATS_TEST_TMPDIR/probe.log"
  [ "$(question_action_tags)" = probe ]
  run question_action_check probe ok;    [ "$status" -eq 0 ]
  run question_action_check probe no;    [ "$status" -eq 1 ]
  run question_action_check grant x;     [ "$status" -eq 2 ]
  question_action_perform probe ok toy Issue-7 03
  question_action_perform probe ok toy Issue-7 03
  [ "$(wc -l < "$PROBE_LOG")" -eq 1 ]
  question_action_perform probe ok toy Issue-7 04
  [ "$(wc -l < "$PROBE_LOG")" -eq 2 ]
  run question_action_perform probe no toy Issue-7 05
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$PROBE_LOG")" -eq 2 ]
  [ ! -e "$D/questions/.lock" ]
  # A re-source re-registers the same functions (0, listed once); the tag with
  # other functions is a duplicate (1).
  question_action_register probe _probe_check _probe_perform
  run question_action_register probe _probe_check _probe_check;    [ "$status" -eq 1 ]
  run question_action_register other _probe_check _no_such_fn;     [ "$status" -eq 1 ]
  run question_action_register Bad _probe_check _probe_perform;    [ "$status" -eq 1 ]
  [ "$(question_action_tags)" = probe ]
}

@test "question: an answer line quoted in a body section does not change the number" {
  _q "$BATS_TEST_TMPDIR/q.md"
  printf '/devagent:answer toy Issue-7 07 a\n' >> "$BATS_TEST_TMPDIR/q.md"
  _render "$BATS_TEST_TMPDIR/q.md" 03 > "$D/STUCK"
  [ "$(question_number "$D/STUCK")" = 03 ]
  [ "$(question_next_number "$D")" = 04 ]
}

@test "question: a CRLF checklist's hold-line entry still reads as logged" {
  printf '%s\r\n' '- [?]  5. improve' '' '## Log' \
    '- 2026-11-20 10:31  improve: hold line written for question 04' > "$D/checklist.md"
  question_line_logged "$D" improve 04
  run question_line_logged "$D" improve 05
  [ "$status" -eq 1 ]
}

@test "question: the next number skips numbers named in the log" {
  printf '%s\n' '- [~]  5. improve' '' '## Log' \
    '- 2026-11-20 10:31  improve: hold line written for question 04' > "$D/checklist.md"
  [ ! -e "$D/questions" ]
  [ ! -e "$D/STUCK" ]
  [ "$(question_next_number "$D")" = 05 ]
}

@test "lock: a second taker returns 1 after its wait and the lock file is unchanged" {
  question_lock "$D"
  local before
  before="$(cat "$D/questions/.lock")"
  [ "$before" = "$BASHPID" ]
  run --separate-stderr bash -c "$(_libs); question_lock '$D' 1"
  [ "$status" -eq 1 ]
  [ "$stderr" = "hold: lock busy: $D/questions/.lock (remove it if no devagent command is running)" ]
  [ "$(cat "$D/questions/.lock")" = "$before" ]
  question_unlock
  [ ! -e "$D/questions/.lock" ]
}

@test "lock: a waiting taker still takes the lock after the holder removes an empty questions directory" {
  question_lock "$D"
  local rcf="$BATS_TEST_TMPDIR/rc"
  ( rc=0; bash -c "$(_libs); question_lock '$D' 5" 2>/dev/null || rc=$?; echo "$rc" > "$rcf" ) &
  sleep 0.5
  question_unlock
  # As hold.sh's EXIT trap: the waiter may take the lock between the unlock and
  # the rmdir (under load it does), so a non-empty questions/ is not a failure.
  rmdir "$D/questions" 2>/dev/null || true
  wait
  [ "$(cat "$rcf")" = 0 ]
}

@test "lock: 20 concurrent allocators take 20 distinct numbers" {
  local i libs
  libs="$(_libs)"
  for i in $(seq 1 20); do
    bash -c "$libs; question_lock '$D' 60 || exit 1; n=\$(question_next_number '$D'); : > '$D/questions/'\$n-x$i.md; question_unlock" &
  done
  wait
  [ "$(find "$D/questions" -name '*.md' | wc -l)" -eq 20 ]
  [ "$(find "$D/questions" -name '*.md' -printf '%f\n' | cut -d- -f1 | sort -u | wc -l)" -eq 20 ]
  [ ! -e "$D/questions/.lock" ]
}

@test "publish: an existing target is never replaced" {
  printf 'theirs\n' > "$BATS_TEST_TMPDIR/T"
  printf 'mine\n' > "$BATS_TEST_TMPDIR/t1"
  run question_publish "$BATS_TEST_TMPDIR/t1" "$BATS_TEST_TMPDIR/T"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/T")" = theirs ]
  [ ! -e "$BATS_TEST_TMPDIR/t1" ]
  local i libs w
  libs="$(_libs)"
  mkdir -p "$BATS_TEST_TMPDIR/race"
  for i in $(seq 1 20); do
    for w in x y; do
      bash -c "$libs; printf '%s\n' $w > '$BATS_TEST_TMPDIR/race/$i.$w'; if question_publish '$BATS_TEST_TMPDIR/race/$i.$w' '$BATS_TEST_TMPDIR/race/T$i'; then echo $w > '$BATS_TEST_TMPDIR/race/win$i.$w'; fi" &
    done
  done
  wait
  for i in $(seq 1 20); do
    [ "$(ls "$BATS_TEST_TMPDIR/race"/win"$i".* | wc -l)" -eq 1 ]
    w="$(cat "$BATS_TEST_TMPDIR/race"/win"$i".*)"
    [ "$(cat "$BATS_TEST_TMPDIR/race/T$i")" = "$w" ]
    [ ! -e "$BATS_TEST_TMPDIR/race/$i.x" ]
    [ ! -e "$BATS_TEST_TMPDIR/race/$i.y" ]
  done
}
