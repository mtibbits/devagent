#!/usr/bin/env bats
# Not gitbash-tagged: the Git Bash job budget (#962 projected ~28.5 min with it,
# from Linux time x3; not measured on Git Bash);
# its Windows evidence is the hand-run file in the issue directory.
# tests/hold.bats — #962: scripts/hold.sh (ask, --no-ask, the hold, re-entry,
# one stop at a time) and park.sh's --reason and kept `[?]`.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'
load 'lib/hold-fixture'

setup() {
  setup_tmp_devagent_home
  _toy
}
teardown() { teardown_tmp_devagent_home; }

# ---- park.sh (Task 4) ----

@test "park: --reason writes the reason to the checklist log and the parked entry stays a boolean" {
  run "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7 --reason "waiting on legal"
  [ "$status" -eq 0 ]
  grep -qE '^- [0-9-]+ [0-9:]+  park: issue parked .*: waiting on legal$' "$CK"
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  run ! grep -rq 'waiting on legal' "$DA_HOME/state"
}

@test "park: a reason starting operator question is refused with exit 2 unless a question STUCK exists" {
  local before
  before="$(_snap)"
  run --separate-stderr "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7 --reason "operator question 9999: x"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"reserved for hold.sh"* ]]
  [ "$(_snap)" = "$before" ]
}

@test "hold: a reason that quotes another question's number does not move the numbering" {
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run --separate-stderr "$PLUGIN_ROOT/scripts/hold.sh" toy Issue-7 --step improve \
    --reason "see notes: operator question 9998: y" --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$(question_number_of "$D/STUCK")" = 01 ]
  _lib
  [ "$(question_next_number "$D")" = 02 ]
}

@test "park: with a question STUCK no row is marked P" {
  _question_stuck commit 12
  sed -i 's/^- \[ \] 12\. commit/- [?] 12. commit/' "$CK"
  local before
  before="$(_rows "$CK")"
  run "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7
  [ "$status" -eq 0 ]
  [ "$(_rows "$CK")" = "$before" ]
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  grep -qE '^- [0-9-]+ [0-9:]+  park: issue parked$' "$CK"
}

@test "park: a STUCK of another kind keeps the [P] mark" {
  local k n=0
  for k in "" frobnicate; do
    _toy
    if [ -z "$k" ]; then
      printf 'Step:        5 improve\nReason:      x\n' > "$D/STUCK"
    else
      printf 'Kind:        %s\nStep:        5 improve\n' "$k" > "$D/STUCK"
    fi
    run "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7
    [ "$status" -eq 0 ]
    grep -qE '^- \[P\]  5\. improve$' "$CK"
    rm -f "$D/STUCK"
    n=$((n + 1))
  done
  [ "$n" -eq 2 ]
}

@test "park: an unknown flag, a third positional and a missing, empty, =-form or multi-line reason exit 2 and write nothing" {
  local before n=0
  before="$(_snap)"
  _row() {
    run --separate-stderr "$PLUGIN_ROOT/scripts/park.sh" "$@"
    [ "$status" -eq 2 ] || { echo "rc=$status for: $*" >&2; return 1; }
    [ "$stderr" = "park.sh: usage: park.sh <project> [issue-id] [--reason <text>]" ] || { echo "stderr=$stderr" >&2; return 1; }
    [ "$(_snap)" = "$before" ] || { echo "wrote for: $*" >&2; return 1; }
    n=$((n + 1))
  }
  _row toy Issue-7 --bogus
  _row toy Issue-7 --reason waiting on
  _row toy Issue-7 --reason
  _row toy Issue-7 --reason ""
  _row toy Issue-7 --reason=waiting
  _row toy Issue-7 --reason $'two\nlines'
  [ "$n" -eq 6 ]
}

@test "park: the log entry records the parked row and its earlier mark" {
  run "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7
  [ "$status" -eq 0 ]
  grep -qE '^- \[P\]  5\. improve$' "$CK"
  grep -qE '^- [0-9-]+ [0-9:]+  park: issue parked \(row 5 improve was \[~\]\)$' "$CK"
  # A re-park records no `was [P]`: the first entry keeps the earlier mark.
  run "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^- [0-9-]+ [0-9:]+  park: issue parked' "$CK")" -eq 2 ]
  run ! grep -qE 'was \[P\]' "$CK"
}

# ---- hold.sh entry, validation and the ask (Task 5) ----

H="$PLUGIN_ROOT/scripts/hold.sh"

# _refused <id>: the last run exited 2 with that refusal id on stderr.
_refused() {
  [ "$status" -eq 2 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [[ "$stderr" == "hold.sh: refused ($1): "* ]] || { echo "want $1, stderr=$stderr" >&2; return 1; }
}

@test "hold: hold.sh is tracked 100755" {
  run git -C "$PLUGIN_ROOT" ls-files -s scripts/hold.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755\ * ]]
}

@test "hold: usage errors exit 2 and write nothing" {
  _q "$BATS_TEST_TMPDIR/q.md"
  local q="$BATS_TEST_TMPDIR/q.md" before n=0
  before="$(_snap)"
  _row() {
    local id="$1"; shift
    run --separate-stderr "$H" "$@"
    _refused "$id" || { echo "row: $*" >&2; return 1; }
    [ "$(_snap)" = "$before" ] || { echo "wrote: $*" >&2; return 1; }
    n=$((n + 1))
  }
  _row usage toy Issue-7 --reason r --question-file "$q"
  _row usage toy Issue-7 --step improve --reason r --question-file "$q" --bogus
  _row usage toy Issue-7 --step improve --reason r
  _row usage toy Issue-7 --step improve
  _row usage toy Issue-7 --step "" --reason r --question-file "$q"
  _row usage nope Issue-7 --step improve --reason r --question-file "$q"
  _row step toy Issue-7 --step spike --reason r --question-file "$q"
  printf '%s\n' '' '## Revision 2' '' '- [ ]  6. prune' >> "$CK"
  before="$(_snap)"
  _row step toy Issue-7 --step improve --reason r --question-file "$q"
  [ "$n" -eq 8 ]
}

@test "hold: an issue id outside the tracker id shape is refused usage before the entry checks" {
  _q "$BATS_TEST_TMPDIR/q.md"
  local before id m n=0
  before="$(_snap)"
  for id in ./Issue-7 Issue-8/../Issue-7 .. Issue-7.1; do
    for m in "" 1; do
      DEVAGENT_UNATTENDED="$m" run --separate-stderr "$H" toy "$id" --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
      _refused usage || { echo "id=$id marker=$m" >&2; return 1; }
      [ "$(_snap)" = "$before" ]
      n=$((n + 1))
    done
  done
  [ "$n" -eq 8 ]
}

@test "hold: an empty, multi-line or 201-byte reason exits 2 and writes nothing" {
  _q "$BATS_TEST_TMPDIR/q.md"
  local before long n=0 r m
  long="$(printf '€%.0s' $(seq 1 67))"   # 67 three-byte characters: 201 bytes
  [ "$(printf '%s' "$long" | LC_ALL=C wc -c)" -eq 201 ]
  before="$(_snap)"
  for r in " " $'two\nlines' "$long"; do
    for m in "" 1; do
      DEVAGENT_UNATTENDED="$m" LC_ALL=C.UTF-8 run --separate-stderr "$H" toy Issue-7 --step improve --reason "$r" --question-file "$BATS_TEST_TMPDIR/q.md"
      _refused reason
      [ "$(_snap)" = "$before" ]
      n=$((n + 1))
    done
  done
  [ "$n" -eq 6 ]
}

@test "hold: a checklist with no Log section exits 2 no-log and writes nothing" {
  _q "$BATS_TEST_TMPDIR/q.md"
  sed -i '/^## Log$/d' "$CK"
  local before
  before="$(_snap)"
  run --separate-stderr "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  _refused no-log
  [ "$(_snap)" = "$before" ]
}

@test "hold: a step marked [x] or [-] exits 2 step-done and writes nothing" {
  _q "$BATS_TEST_TMPDIR/q.md"
  sed -i 's/^- \[ \]  6\. prune/- [-]  6. prune/' "$CK"
  local before s n=0
  before="$(_snap)"
  for s in scope prune; do
    run --separate-stderr "$H" toy Issue-7 --step "$s" --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
    _refused step-done
    [ "$(_snap)" = "$before" ]
    n=$((n + 1))
  done
  [ "$n" -eq 2 ]
}

@test "hold: a malformed question file exits 2 with its id and writes nothing in both modes" {
  local q="$BATS_TEST_TMPDIR/q.md" f="$BATS_TEST_TMPDIR/bad.md" before n=0 m
  _q "$q"
  before="$(_snap)"
  _row() {
    for m in "" 1; do
      DEVAGENT_UNATTENDED="$m" run --separate-stderr "$H" toy Issue-7 --step improve --reason r --question-file "$f"
      _refused "$1"
      [ "$(_snap)" = "$before" ]
      [[ "$stderr" != *Proceed* ]]
    done
    n=$((n + 1))
  }
  awk '/^## /{skip = ($0 == "## Evidence")} !skip' "$q" > "$f";  _row section
  sed '/^- `/d' "$q" > "$f";                                     _row option
  sed 's/^- `b`/- `b` (recommended)/' "$q" > "$f";               _row recommended
  sed 's/^- `b`/- `a`/' "$q" > "$f";                             _row option-id
  sed 's/^- `b`/- `b` [probe: ok]/' "$q" > "$f";                 _row tag
  [ "$n" -eq 5 ]
}

@test "hold: a registered tag whose check fails exits 2 and writes nothing" {
  _tree
  cat "$PLUGIN_ROOT/tests/fixtures/hold/test-tag.sh" >> "$TREE/scripts/lib/question-actions.sh"
  local q="$BATS_TEST_TMPDIR/q.md" before m
  _q "$q"
  sed -i 's/^- `b`/- `b` [probe: no]/' "$q"
  before="$(_snap)"
  for m in "" 1; do
    DEVAGENT_UNATTENDED="$m" run --separate-stderr "$TREE/scripts/hold.sh" toy Issue-7 --step improve --reason r --question-file "$q"
    _refused tag-check
    [ "$(_snap)" = "$before" ]
  done
  sed -i 's/\[probe: no\]/[probe: ok]/' "$q"
  run --separate-stderr "$TREE/scripts/hold.sh" toy Issue-7 --step improve --reason r --question-file "$q"
  [ "$status" -eq 3 ]
}

@test "ask: with the marker unset hold.sh writes the open record, prints its path and exits 3" {
  _q "$BATS_TEST_TMPDIR/q.md"
  local ck st
  ck="$(sha256sum < "$CK")" st="$(sha256sum < "$DA_HOME/state/toy.toml")"
  run --separate-stderr "$H" toy Issue-7 --step improve --reason "improve: 14 bugs" --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  [ "$output" = "$D/questions/01-improve.md" ]
  local r="$D/questions/01-improve.md"
  [ "$(sed -n 1,5p "$r" | cut -c1-13)" = "$(printf '%-13s\n' Kind: Step: Reason: 'Last good:' Created:)" ]
  [ "$(sed -n 1,4p "$r")" = "Kind:        question
Step:        5 improve
Reason:      improve: 14 bugs
Last good:   4 scope" ]
  sed -n 5p "$r" | grep -qE '^Created:     [0-9]{4}-[0-9]{2}-[0-9]{2}T'
  [ "$(grep '^## ' "$r" | tr '\n' '|')" = "## Question|## Impediment|## Options|## Evidence|## How to answer|" ]
  [ ! -e "$D/STUCK" ]
  [ "$(sha256sum < "$CK")" = "$ck" ]
  [ "$(sha256sum < "$DA_HOME/state/toy.toml")" = "$st" ]
  [ ! -e "$DA_HOME/state/notifications.jsonl" ]
  [ ! -e "$D/questions/.lock" ]
  [ "$(find "$D/questions" -type f | wc -l)" -eq 1 ]
}

@test "ask: a second call for the step reuses the number and rewrites the record" {
  _q "$BATS_TEST_TMPDIR/q.md"
  run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  sed 's/Proceed with round 4?/Stop now?/' "$BATS_TEST_TMPDIR/q.md" > "$BATS_TEST_TMPDIR/q2.md"
  run "$H" toy Issue-7 --step improve --reason r2 --question-file "$BATS_TEST_TMPDIR/q2.md"
  [ "$status" -eq 3 ]
  [ "$output" = "$D/questions/01-improve.md" ]
  [ "$(find "$D/questions" -type f | wc -l)" -eq 1 ]
  grep -q '^Stop now?$' "$D/questions/01-improve.md"
  run ! grep -q 'Proceed' "$D/questions/01-improve.md"
}

@test "ask: DEVAGENT_CHAIN_ACTIVE does not change the mode" {
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_CHAIN_ACTIVE=1 run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  [ ! -e "$D/STUCK" ]
}

@test "ask: a notify-only or answered record for the step is not reused" {
  _q "$BATS_TEST_TMPDIR/q.md"
  _lib
  mkdir -p "$D/questions"
  question_render "$BATS_TEST_TMPDIR/q.md" toy Issue-7 improve 5 r "4 scope" 01 t > "$D/questions/01-improve.md"
  printf '\n## Answer\n\na\n' >> "$D/questions/01-improve.md"
  local a b
  a="$(sha256sum < "$D/questions/01-improve.md")"
  run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  [ "$output" = "$D/questions/02-improve.md" ]
  [ "$(sha256sum < "$D/questions/01-improve.md")" = "$a" ]
  sed -i '1a Blocking:    no' "$D/questions/02-improve.md"
  b="$(sha256sum < "$D/questions/02-improve.md")"
  run "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  [ "$output" = "$D/questions/03-improve.md" ]
  [ "$(sha256sum < "$D/questions/02-improve.md")" = "$b" ]
}

# ---- the hold (Task 6) ----

# _hold [args...]: an unattended hold of Issue-7 at improve with _q's question.
_hold() {
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run --separate-stderr "$H" toy Issue-7 --step "${1:-improve}" --reason "improve: 14 bugs" --question-file "$BATS_TEST_TMPDIR/q.md"
}

@test "hold: an unpinned hold writes the question STUCK, marks [?], parks and appends one hold line" {
  _hold
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$output" = "$D/STUCK" ]
  [ "$(sed -n 1,4p "$D/STUCK")" = "Kind:        question
Step:        5 improve
Reason:      improve: 14 bugs
Last good:   4 scope" ]
  sed -n 5p "$D/STUCK" | grep -qE '^Created:     [0-9]{4}-[0-9]{2}-[0-9]{2}T'
  [ "$(grep '^## ' "$D/STUCK" | tr '\n' '|')" = "## Question|## Impediment|## Options|## Evidence|## How to answer|" ]
  grep -qE '^- \[\?\]  5\. improve$' "$CK"
  run ! grep -qE '^- \[P\]' "$CK"
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  run ! grep -qE '^active_issue' "$DA_HOME/state/toy.toml"
  [ "$(_lines)" = 1 ]
  [ "$(_field event)" = hold ]
  [ "$(_field question)" = "$(_native "$D/STUCK")" ]
  [ "$(_field detail)" = "operator question 01 at improve; parked" ]
  grep -qE '^- [0-9-]+ [0-9:]+  improve: hold line written for question 01$' "$CK"
  grep -qE '^- [0-9-]+ [0-9:]+  park: issue parked: operator question 01: improve: 14 bugs$' "$CK"
  [ ! -e "$D/questions/.lock" ]
}

@test "hold: the STUCK has the umask mode" {
  case "$(uname -s)" in MINGW*|MSYS*) skip "POSIX modes: Git Bash has no umask-driven file modes" ;; esac
  umask 022
  _hold
  [ "$status" -eq 0 ]
  assert_file_mode "$D/STUCK" 644
}

@test "hold: a pinned hold leaves the shared active issue unchanged" {
  _tset active_issue '"Issue-8"'
  DEVAGENT_ACTIVE_PROJECT=toy DEVAGENT_ACTIVE_ISSUE=Issue-7 _hold
  [ "$status" -eq 0 ]
  grep -qE '^active_issue = "Issue-8"$' "$DA_HOME/state/toy.toml"
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  [ "$(_lines)" = 1 ]
}

@test "hold: a hold naming a later row leaves the earlier row unchanged and no [P] row" {
  _hold commit
  [ "$status" -eq 0 ]
  grep -qE '^- \[~\]  5\. improve$' "$CK"
  grep -qE '^- \[\?\] 12\. commit$' "$CK"
  run ! grep -qE '^- \[P\]' "$CK"
  [ "$(_field detail)" = "operator question 01 at commit; parked" ]
}

@test "hold: on a parked issue it writes STUCK, marks [?] and one line with already parked" {
  "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7
  local parks
  parks="$(_parks)"
  [ "$parks" -eq 1 ]
  _hold
  [ "$status" -eq 0 ]
  [ -f "$D/STUCK" ]
  grep -qE '^- \[\?\]  5\. improve$' "$CK"
  [ "$(_lines)" = 1 ]
  [ "$(_field detail)" = "operator question 01 at improve; already parked" ]
  [ "$(_parks)" -eq "$parks" ]
}

@test "hold: a [P] row on another row returns to its earlier mark" {
  "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7
  grep -qE '^- \[P\]  5\. improve$' "$CK"
  _hold commit
  [ "$status" -eq 0 ]
  grep -qE '^- \[~\]  5\. improve$' "$CK"
  grep -qE '^- \[\?\] 12\. commit$' "$CK"
  # an older park entry that records no mark: the row returns to [ ].
  _toy
  sed -i 's/^- \[~\]  5\. improve/- [P]  5. improve/' "$CK"
  printf '%s\n' '- 2026-11-01 09:00  park: issue parked' >> "$CK"
  printf '\n[parked]\nIssue-7 = true\n' >> "$DA_HOME/state/toy.toml"
  rm -f "$D/STUCK"; rm -rf "$D/questions"; rm -f "$(NF)"
  _hold commit
  [ "$status" -eq 0 ]
  grep -qE '^- \[ \]  5\. improve$' "$CK"
  grep -qE '^- \[\?\] 12\. commit$' "$CK"
}

@test "hold: a refused park leaves STUCK and [?], names the refusal in the one line and exits with park's code" {
  _tree
  local code want
  for code in 11 3; do
    _toy
    rm -f "$D/STUCK" "$(NF)"; rm -rf "$D/questions"
    printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$TREE/scripts/park.sh"
    _q "$BATS_TEST_TMPDIR/q.md"
    DEVAGENT_UNATTENDED=1 run --separate-stderr "$TREE/scripts/hold.sh" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
    want="$code"; [ "$code" != 3 ] || want=1
    [ "$status" -eq "$want" ] || { echo "park $code: rc=$status err=$stderr" >&2; return 1; }
    [ -f "$D/STUCK" ]
    grep -qE '^- \[\?\]  5\. improve$' "$CK"
    [ "$(_lines)" = 1 ]
    [ "$(_field detail)" = "operator question 01 at improve; park refused (exit $code)" ]
  done
}

@test "hold: a failing appender parks, exits 1 and logs no hold line" {
  mkdir -p "$(NF)"   # U2: a directory where the file goes makes the append fail
  _hold
  [ "$status" -eq 1 ]
  [ -f "$D/STUCK" ]
  grep -qE '^- \[\?\]  5\. improve$' "$CK"
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  run ! grep -q 'hold line written' "$CK"
}

@test "hold: a second question after a hand-removed STUCK gets a new number, parks and writes its line" {
  _hold
  [ "$status" -eq 0 ]
  rm -f "$D/STUCK"
  # resume by hand: unpark and make Issue-7 active again, row 5 back to [~].
  printf 'active_issue = "Issue-7"\nissue_dir = "%s"\n' "$D" > "$DA_HOME/state/toy.toml"
  sed -i 's/^- \[?\]  5\. improve/- [~]  5. improve/' "$CK"
  _hold
  [ "$status" -eq 0 ]
  [ "$(question_number_of "$D/STUCK")" = 02 ]
  [ "$(_lines)" = 2 ]
  [ "$(_field detail)" = "operator question 02 at improve; parked" ]
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
}

@test "hold: a line the notify check refuses exits 2 before anything is written" {
  # a relative devdoc_dir gives a relative STUCK path, which the line's
  # `question` rule (absolute) refuses; the issue id itself is refused earlier.
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.toy.devdoc_dir '"devdoc"'
  _q "$BATS_TEST_TMPDIR/q.md"
  local before
  before="$(_snap)"
  cd "$BATS_TEST_TMPDIR"
  DEVAGENT_UNATTENDED=1 run --separate-stderr "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  _refused notify
  [ "$(_snap)" = "$before" ]
}

# ---- --no-ask, takeover, re-entry and one stop (Task 7) ----

# _ask: the interactive ask, leaving the open record questions/01-improve.md.
_ask() {
  _q "$BATS_TEST_TMPDIR/q.md"
  run "$H" toy Issue-7 --step improve --reason "improve: 14 bugs" --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 3 ]
  REC="$D/questions/01-improve.md"
  [ -f "$REC" ]
}

_noask() { run --separate-stderr "$H" toy Issue-7 --step "${1:-improve}" --no-ask "${@:2}"; }

@test "no-ask: with an open record and no question file it holds with the record's question, reason and number" {
  _ask
  _lib
  question_body "$REC" > "$BATS_TEST_TMPDIR/rec-body"
  _noask
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$output" = "$D/STUCK" ]
  question_body "$D/STUCK" > "$BATS_TEST_TMPDIR/stuck-body"
  cmp "$BATS_TEST_TMPDIR/rec-body" "$BATS_TEST_TMPDIR/stuck-body"
  [ "$(question_reason "$D/STUCK")" = "improve: 14 bugs" ]
  [ "$(question_number "$D/STUCK")" = 01 ]
  [ ! -e "$REC" ]
  grep -qE '^- \[\?\]  5\. improve$' "$CK"
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  [ "$(_lines)" = 1 ]
}

@test "no-ask: with a question file it holds with the file's question and the record's number" {
  _ask
  sed 's/Proceed with round 4?/Stop now?/' "$BATS_TEST_TMPDIR/q.md" > "$BATS_TEST_TMPDIR/q2.md"
  _noask improve --reason "dismissed" --question-file "$BATS_TEST_TMPDIR/q2.md"
  [ "$status" -eq 0 ]
  grep -q '^Stop now?$' "$D/STUCK"
  grep -q '^Reason:      dismissed$' "$D/STUCK"
  [ "$(question_number_of "$D/STUCK")" = 01 ]
  [ ! -e "$REC" ]
  [ "$(_lines)" = 1 ]
}

@test "no-ask: with neither a question file nor an open record it exits 2" {
  local before
  before="$(_snap)"
  _noask
  _refused no-question
  [ "$(_snap)" = "$before" ]
}

@test "takeover: stopped after STUCK and before the record's removal, a re-run removes the record and leaves one question" {
  _ask
  _lib
  question_body "$REC" > "$BATS_TEST_TMPDIR/b.md"
  question_render "$BATS_TEST_TMPDIR/b.md" toy Issue-7 improve 5 "improve: 14 bugs" "4 scope" 01 t > "$D/STUCK"
  local s
  s="$(sha256sum < "$D/STUCK")"
  _noask
  [ "$status" -eq 0 ]
  [ ! -e "$REC" ]
  [ "$(find "$D/questions" -name '*.md' 2>/dev/null | wc -l)" -eq 0 ]
  [ "$(sha256sum < "$D/STUCK")" = "$s" ]
  [ "$(_lines)" = 1 ]
}

@test "takeover: with the marker set a question file keeps the open record's number and a notify-only record is left alone" {
  _ask
  _lib
  question_render "$BATS_TEST_TMPDIR/q.md" toy Issue-7 improve 5 r "4 scope" 02 t | sed '1a Blocking:    no' > "$D/questions/02-improve.md"
  local nb
  nb="$(sha256sum < "$D/questions/02-improve.md")"
  _hold
  [ "$status" -eq 0 ]
  [ "$(question_number "$D/STUCK")" = 01 ]
  [ ! -e "$REC" ]
  [ "$(sha256sum < "$D/questions/02-improve.md")" = "$nb" ]
}

@test "re-entry: after STUCK, after the mark and after the park a re-run completes the rest and leaves STUCK unchanged with exactly one hold line" {
  local stage s n=0
  for stage in stuck mark park; do
    _toy
    rm -rf "$D/questions" "$D/STUCK" "$(NF)"
    _question_stuck improve 5
    _lib
    [ "$stage" = stuck ] || checklist_mark_by_name "$CK" improve '?'
    [ "$stage" != park ] || "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7 --reason "operator question 01: r" 2>/dev/null
    s="$(sha256sum < "$D/STUCK")"
    _noask
    [ "$status" -eq 0 ] || { echo "$stage: rc=$status err=$stderr" >&2; return 1; }
    [ "$(sha256sum < "$D/STUCK")" = "$s" ]
    grep -qE '^- \[\?\]  5\. improve$' "$CK"
    grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
    [ "$(_lines)" = 1 ]
    [ "$(_field detail)" = "operator question 01 at improve; parked" ]
    [ "$(_parks)" -eq 1 ]
    _noask
    [ "$status" -eq 0 ]
    [ "$(_lines)" = 1 ]
    [ "$(_parks)" -eq 1 ]
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "re-entry: a logged park whose state entry is gone parks again" {
  mkdir -p "$(NF)"
  _hold
  [ "$status" -eq 1 ]
  grep -qE 'park: issue parked: operator question 01: ' "$CK"
  _tunset parked.Issue-7
  rmdir "$(NF)"
  _noask
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  [ "$(_lines)" = 1 ]
  [ "$(_field detail)" = "operator question 01 at improve; parked" ]
  [ "$(_parks)" -eq 2 ]
}

@test "one-stop: a stuck, a watchdog, an answered and another step's question STUCK each exit 2 and write nothing in both modes" {
  _q "$BATS_TEST_TMPDIR/q.md"
  local kind m before n=0
  for kind in stuck watchdog answered other; do
    case "$kind" in
      stuck)    printf 'Step:        5 improve\nReason:      x\n' > "$D/STUCK" ;;
      watchdog) printf 'Kind:        watchdog\nStep:        5 improve\n' > "$D/STUCK" ;;
      answered) _question_stuck improve 5; printf '\n## Answer\n\na\n' >> "$D/STUCK" ;;
      other)    _question_stuck prune 6 ;;
    esac
    before="$(_snap)"
    for m in "" 1; do
      DEVAGENT_UNATTENDED="$m" run --separate-stderr "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
      _refused one-stop || { echo "$kind marker=$m" >&2; return 1; }
      [ "$(_snap)" = "$before" ] || { echo "$kind marker=$m wrote" >&2; return 1; }
      n=$((n + 1))
    done
  done
  [ "$n" -eq 8 ]
}

@test "one-stop: an interactive call for a step with an unanswered question STUCK exits 0 and writes no record" {
  _question_stuck improve 5
  _q "$BATS_TEST_TMPDIR/q.md"
  run --separate-stderr "$H" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$(find "$D/questions" -name '*.md' 2>/dev/null | wc -l)" -eq 0 ]
  grep -qE '^- \[\?\]  5\. improve$' "$CK"
}

@test "re-entry: two concurrent --no-ask re-runs after STUCK write exactly one hold line and park once" {
  _question_stuck improve 5
  local a="$BATS_TEST_TMPDIR/a.rc" b="$BATS_TEST_TMPDIR/b.rc"
  local f
  for f in "$a" "$b"; do
    ( rc=0; "$H" toy Issue-7 --step improve --no-ask >/dev/null 2>"$f.err" || rc=$?; echo "$rc" > "$f" ) &
  done
  wait
  # One run must finish the hold. The other finishes too, or, on a host slow
  # enough that the hold outlasts the fixed lock wait, exits 1 lock-busy and
  # writes nothing: either way one line and one park.
  local rc f2 won=0
  for f2 in "$a" "$b"; do
    rc="$(cat "$f2")"
    if [ "$rc" = 0 ]; then won=1; continue; fi
    { [ "$rc" = 1 ] && grep -q '^hold: lock busy: ' "$f2.err"; } \
      || { echo "rc=$rc"; cat "$f2.err"; return 1; } >&2
  done
  [ "$won" -eq 1 ]
  [ "$(_lines)" = 1 ]
  [ "$(_parks)" -eq 1 ]
}

@test "hold: a failing rm in the exit trap still releases the lock and keeps the exit status" {
  _ask
  local real
  real="$(command -v rm)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\ncase "$*" in *.body.*) exit 1 ;; esac\nexec %q "$@"\n' "$real" > "$BATS_TEST_TMPDIR/bin/rm"
  chmod +x "$BATS_TEST_TMPDIR/bin/rm"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr "$H" toy Issue-7 --step improve --no-ask
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ ! -e "$D/questions/.lock" ]
  [ "$(_lines)" = 1 ]
}
