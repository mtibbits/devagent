#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/hold.bats — #962: scripts/hold.sh (ask, --no-ask, the hold, re-entry,
# one stop at a time) and park.sh's --reason and kept `[?]`.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  _toy
}
teardown() { teardown_tmp_devagent_home; }

# _toy: project `toy`, active Issue-7 (rows 0 pull, 2 draft, 4 scope done; 5
# improve in progress; 6 prune and 12 commit pending; a Log), and Issue-8.
_toy() {
  DEVDOC="$BATS_TEST_TMPDIR/devdoc"
  SRC="$BATS_TEST_TMPDIR/src"
  D="$DEVDOC/Issue-7"
  CK="$D/checklist.md"
  mkdir -p "$D" "$DEVDOC/Issue-8" "$SRC"
  cat > "$DA_HOME/config.toml" <<EOF
[project.toy]
source_dir = "$SRC"
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/toy.toml" <<EOF
active_issue = "Issue-7"
issue_dir = "$D"
EOF
  cat > "$CK" <<'EOF'
- [x]  0. pull
- [x]  2. draft
- [x]  4. scope
- [~]  5. improve
- [ ]  6. prune
- [ ] 12. commit

## Log
EOF
  printf '%s\n' '- [~]  5. improve' '' '## Log' > "$DEVDOC/Issue-8/checklist.md"
}

# _q <file>: a valid question file (options a recommended, b).
_q() {
  cat > "$1" <<'Q'
## Question

Proceed with round 4?

## Impediment

improve found 14 bugs after round 3 of 3.

## Options

- `a` (recommended) Run round 4.
- `b` Stop and prune.

## Evidence

analysis/2026-11-20-improve.md
Q
}

# _snap: every path under the devdoc and the state dir, then each file's
# checksum — the "nothing was written" witness.
_snap() {
  find "$DEVDOC" "$DA_HOME/state" | sort
  find "$DEVDOC" "$DA_HOME/state" -type f -exec sha256sum {} + | sort
}

# _rows <checklist>: the step rows, verbatim.
_rows() { grep -E '^- \[.\] +[0-9]+\.' "$1"; }

# _lib: source the libraries a test reads the format through.
_lib() {
  local l
  for l in paths io config checklist question-actions; do
    # shellcheck source=/dev/null
    source "$PLUGIN_ROOT/scripts/lib/$l.sh"
  done
}

# _question_stuck <step> <N> [kind]: a rendered question STUCK for <step>.
_question_stuck() {
  _lib
  _q "$BATS_TEST_TMPDIR/q.md"
  question_render "$BATS_TEST_TMPDIR/q.md" toy Issue-7 "$1" "$2" "r" "4 scope" 01 2026-11-20T10:31:00-05:00 > "$D/STUCK"
  [ -z "${3:-}" ] || sed -i "1s/.*/Kind:        $3/" "$D/STUCK"
}

# ---- park.sh (Task 4) ----

@test "park: --reason writes the reason to the checklist log and the parked entry stays a boolean" {
  run "$PLUGIN_ROOT/scripts/park.sh" toy Issue-7 --reason "waiting on legal"
  [ "$status" -eq 0 ]
  grep -qE '^- [0-9-]+ [0-9:]+  park: issue parked .*: waiting on legal$' "$CK"
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  ! grep -rq 'waiting on legal' "$DA_HOME/state"
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

# _tree: a copy of scripts/ and templates/ for a test that needs the probe tag,
# a stub park.sh or a fixture step. Sets TREE.
_tree() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE"
  cp -r "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/templates" "$TREE/"
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
  [ "$(sed -n 1,5p "$r" | cut -c1-13)" = "Kind:        
Step:        
Reason:      
Last good:   
Created:     " ]
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
  ! grep -q 'Proceed' "$D/questions/01-improve.md"
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

NF() { printf '%s\n' "$DA_HOME/state/notifications.jsonl"; }
_lines() { if [ -f "$(NF)" ]; then wc -l < "$(NF)" | tr -d ' '; else echo 0; fi; }
_field() { python3 "$PLUGIN_ROOT/tests/helpers/notify_probe.py" field "$(NF)" -1 "$1"; }
_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s\n' "$1"; fi; }
question_number_of() { ( _lib; question_number "$1" ); }
_parks() { grep -cE '^- [0-9-]+ [0-9:]+  park: issue parked' "$CK" || true; }

# _hold [args...]: an unattended hold of Issue-7 at improve with _q's question.
_hold() {
  _q "$BATS_TEST_TMPDIR/q.md"
  DEVAGENT_UNATTENDED=1 run --separate-stderr "$H" toy Issue-7 --step "${1:-improve}" --reason "improve: 14 bugs" --question-file "$BATS_TEST_TMPDIR/q.md"
}

@test "hold: an unpinned hold writes the question STUCK, marks [?], parks and appends one hold line" {
  _hold
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$(sed -n 1,4p "$D/STUCK")" = "Kind:        question
Step:        5 improve
Reason:      improve: 14 bugs
Last good:   4 scope" ]
  sed -n 5p "$D/STUCK" | grep -qE '^Created:     [0-9]{4}-[0-9]{2}-[0-9]{2}T'
  [ "$(grep '^## ' "$D/STUCK" | tr '\n' '|')" = "## Question|## Impediment|## Options|## Evidence|## How to answer|" ]
  grep -qE '^- \[\?\]  5\. improve$' "$CK"
  ! grep -qE '^- \[P\]' "$CK"
  grep -qE '^Issue-7 *= *true$' "$DA_HOME/state/toy.toml"
  ! grep -qE '^active_issue' "$DA_HOME/state/toy.toml"
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
  sed -i 's/^active_issue = .*/active_issue = "Issue-8"/' "$DA_HOME/state/toy.toml"
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
  ! grep -qE '^- \[P\]' "$CK"
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
  ! grep -q 'hold line written' "$CK"
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
  mkdir -p "$DEVDOC/_7"
  cp "$CK" "$DEVDOC/_7/checklist.md"
  _q "$BATS_TEST_TMPDIR/q.md"
  local before
  before="$(_snap)"
  DEVAGENT_UNATTENDED=1 run --separate-stderr "$H" toy _7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  _refused notify
  [ "$(_snap)" = "$before" ]
}
