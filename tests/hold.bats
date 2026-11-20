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
