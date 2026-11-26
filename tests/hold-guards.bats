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
# each leg starts from a fresh _toy. A failing leg fails the test (errexit).
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
    # Called plainly, never under `||`: errexit is off inside a function run
    # in a conditional context, which would skip every bare assertion.
    echo "# leg: $1 $k" >&2
    "$@" "$k"
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

# ---- Task 3: unstuck and checklist-unstuck refuse a question STUCK ----------

# _revised_held: an older block with a [!] draft row, the current block with
# _toy's rows, then the hold (Issue-7 still active).
_revised_held() {
  { printf '%s\n' '## Revision 1' '' '- [!]  2. draft' '' '## Revision 2' ''
    _rows "$CK"
    printf '%s\n' '' '## Log'
  } > "$CK.new"
  mv "$CK.new" "$CK"
  _held_active
}

@test "unstuck: an older-block [!] does not clear a question; both unstuck commands refuse" {
  _revised_held
  grep -q '^- \[!\]  2\. draft' "$CK"
  local before ans; before="$(_snap)"
  ans="$( (_lib; question_answer_line "$D/STUCK") )"
  [ -n "$ans" ]
  run --separate-stderr "$S/unstuck.sh" toy
  [ "$status" -eq "$OQ" ] || { echo "unstuck rc=$status err=$stderr" >&2; return 1; }
  [[ "$stderr" == *"  Answer:   $ans"* ]]
  [[ "$stderr" == *"  Question: $D/STUCK"* ]]
  run --separate-stderr "$S/checklist-unstuck.sh" --pending "$D"
  [ "$status" -eq "$OQ" ] || { echo "checklist-unstuck rc=$status err=$stderr" >&2; return 1; }
  [[ "$stderr" == *"  Answer:   $ans"* ]]
  [ "$(_snap)" = "$before" ]
}

_leg_unstuck() {
  "$S/checklist-mark.sh" "$D" 5 '!' improve >/dev/null
  run --separate-stderr "$S/unstuck.sh" toy
  [ "$status" -eq 0 ] || { echo "unstuck rc=$status err=$stderr" >&2; return 1; }
  [ ! -e "$D/STUCK" ]
  grep -q '^- \[~\]  5\. improve' "$CK"
}
_leg_checklist_unstuck() {
  "$S/checklist-mark.sh" "$D" 5 '!' improve >/dev/null
  run --separate-stderr "$S/checklist-unstuck.sh" --pending "$D"
  [ "$status" -eq 0 ] || { echo "checklist-unstuck rc=$status err=$stderr" >&2; return 1; }
  [ ! -e "$D/STUCK" ]
  grep -q '^- \[ \]  5\. improve' "$CK"
}

@test "other kinds: both unstuck commands clear as today" {
  _kinds _leg_unstuck
  _kinds _leg_checklist_unstuck
}

# ---- Task 4: checklist-stuck and stuck refuse under the question lock -------

@test "race: checklist-stuck and stuck wait for a hold in progress, then refuse" {
  _tree
  printf '#!/usr/bin/env bash\nexit 11\n' > "$TREE/scripts/park.sh"
  _q "$BATS_TEST_TMPDIR/q.md"
  local shim="$BATS_TEST_TMPDIR/shim" real t="$BATS_TEST_TMPDIR"
  real="$(command -v date)"
  mkdir -p "$shim"
  # The first `date -Iseconds` call (hold.sh's _render_to, under the lock and
  # before STUCK exists: U1) signals `ready` and waits for `go`.
  cat > "$shim/date" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -Iseconds "*)
    if mkdir "$t/armed" 2>/dev/null; then
      : > "$t/ready"
      while [ ! -e "$t/go" ]; do sleep 0.05; done
    fi ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$shim/date"
  PATH="$shim:$PATH" DEVAGENT_UNATTENDED=1 "$TREE/scripts/hold.sh" toy Issue-7 --step improve --reason r \
    --question-file "$t/q.md" > "$t/hold.out" 2>&1 3>&- &
  local hp=$! i
  for i in $(seq 200); do [ -e "$t/ready" ] && break; sleep 0.05; done
  [ -e "$t/ready" ]
  [ -e "$D/questions/.lock" ]
  "$S/checklist-stuck.sh" "$D" r > "$t/cs.out" 2>&1 3>&- &
  local cp=$!
  "$S/stuck.sh" toy r > "$t/st.out" 2>&1 3>&- &
  local sp=$!
  sleep 1
  kill -0 "$cp"
  kill -0 "$sp"
  [ ! -e "$D/STUCK" ]
  : > "$t/go"
  local hrc=0 crc=0 src=0
  wait "$hp" || hrc=$?
  wait "$cp" || crc=$?
  wait "$sp" || src=$?
  [ "$hrc" -eq 11 ] || { cat "$t/hold.out" >&2; return 1; }
  [ "$crc" -eq "$OQ" ] || { echo "checklist-stuck rc=$crc" >&2; cat "$t/cs.out" >&2; return 1; }
  [ "$src" -eq "$OQ" ] || { echo "stuck rc=$src" >&2; cat "$t/st.out" >&2; return 1; }
  [ "$(head -1 "$D/STUCK")" = "Kind:        question" ]
  grep -q '^- \[?\]  5\. improve' "$CK"
  ! grep -q '^- \[!\]' "$CK"
  [ ! -e "$D/questions" ]
}

@test "lock timeout: a stale lock delays but does not stop a real stop, and a held issue still refuses" {
  # Leg A: no STUCK. A dead pid's lock stands in for a hold.
  mkdir -p "$D/questions"
  echo 999999 > "$D/questions/.lock"
  run --separate-stderr "$S/checklist-stuck.sh" "$D" "real stop"
  [ "$status" -eq 0 ] || { echo "A rc=$status err=$stderr" >&2; return 1; }
  grep -q '^- \[!\]  5\. improve' "$CK"
  grep -q '^Reason:      real stop$' "$D/STUCK"
  ! grep -q '^Kind:' "$D/STUCK"
  [[ "$stderr" == *"hold: lock busy: $D/questions/.lock"* ]]
  # Leg B: held, then the stale lock.
  rm -rf "$DEVDOC" "$DA_HOME/state"/*
  _toy
  _held_active
  mkdir -p "$D/questions"
  echo 999999 > "$D/questions/.lock"
  local before; before="$(_snap)"
  run --separate-stderr "$S/checklist-stuck.sh" "$D" "real stop"
  [ "$status" -eq "$OQ" ] || { echo "B rc=$status err=$stderr" >&2; return 1; }
  [ "$(_snap)" = "$before" ]
}

@test "no directory: checklist-stuck on an issue that never held creates no questions/" {
  # A `date` shim records, at the STUCK write's `date -Iseconds`, whether
  # questions/ exists then: an EXIT trap that removes it afterwards cannot
  # hide a lock taken without the directory.
  local shim="$BATS_TEST_TMPDIR/shim" real; real="$(command -v date)"
  mkdir -p "$shim"
  printf '%s\n' '#!/usr/bin/env bash' \
    "case \" \$* \" in *' -Iseconds '*) if [ -e '$D/questions' ]; then echo yes; else echo no; fi >> '$BATS_TEST_TMPDIR/seen' ;; esac" \
    "exec '$real' \"\$@\"" > "$shim/date"
  chmod +x "$shim/date"
  PATH="$shim:$PATH" run --separate-stderr "$S/checklist-stuck.sh" "$D" r
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/seen")" = no ]
  [ ! -e "$D/questions" ]
}

@test "other kinds: checklist-stuck writes under the lock and releases it" {
  _question_stuck improve 5
  sed -i 1d "$D/STUCK"
  mkdir -p "$D/questions"
  echo kept > "$D/questions/notes.txt"
  run --separate-stderr "$S/checklist-stuck.sh" "$D" "new reason"
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  grep -q '^Reason:      new reason$' "$D/STUCK"
  [ ! -e "$D/questions/.lock" ]
  [ -f "$D/questions/notes.txt" ]
  # The lock is free: after an ordinary unstuck, a hold runs without the wait.
  "$S/unstuck.sh" toy >/dev/null
  _q "$BATS_TEST_TMPDIR/q.md"
  local t0=$SECONDS
  DEVAGENT_UNATTENDED=1 run "$S/hold.sh" toy Issue-7 --step improve --reason r --question-file "$BATS_TEST_TMPDIR/q.md"
  [ "$status" -eq 0 ] || { echo "hold rc=$status out=$output" >&2; return 1; }
  [ $((SECONDS - t0)) -lt 5 ]
}

@test "no overwrite: checklist-stuck and stuck refuse on a held issue and leave it byte-identical" {
  _held_active
  local before; before="$(_snap)"
  run --separate-stderr "$S/checklist-stuck.sh" "$D" r
  [ "$status" -eq "$OQ" ] || { echo "cs rc=$status err=$stderr" >&2; return 1; }
  [ "$stderr" = "$(_refusal_lines checklist-stuck)" ]
  run --separate-stderr "$S/stuck.sh" toy r
  [ "$status" -eq "$OQ" ] || { echo "stuck rc=$status err=$stderr" >&2; return 1; }
  [ "$stderr" = "$(_refusal_lines stuck)" ]
  [ "$(_snap)" = "$before" ]
}

_leg_checklist_stuck() {
  run --separate-stderr "$S/checklist-stuck.sh" "$D" "overwritten $1"
  [ "$status" -eq 0 ] || { echo "cs rc=$status err=$stderr" >&2; return 1; }
  grep -q "^Reason:      overwritten $1\$" "$D/STUCK"
}
_leg_stuck() {
  run --separate-stderr "$S/stuck.sh" toy "overwritten $1"
  [ "$status" -eq 0 ] || { echo "stuck rc=$status err=$stderr" >&2; return 1; }
  grep -q "^Reason:      overwritten $1\$" "$D/STUCK"
}

@test "other kinds: checklist-stuck and stuck overwrite as today" {
  _kinds _leg_checklist_stuck
  _kinds _leg_stuck
}

# ---- Task 5: sync skips the held closeout row; reap skips a question STUCK --

# _closeout: Issue-7 shipped (18), mergetoall blocked [?] (19), impact in
# progress (22), held at impact; mr_url set; mr-state answers MERGED.
_closeout() {
  printf '%s\n' '- [x]  0. pull' '- [x] 18. ship' '- [?] 19. mergetoall' '- [~] 22. impact' \
    '- [ ] 24. cleanup' '' '## Log' > "$CK"
  cat >> "$DA_HOME/config.toml" <<'EOF2'

[project.toy.code_source]
backend = "stub"
EOF2
  local cb="$BATS_TEST_TMPDIR/code"
  mkdir -p "$cb"
  printf '#!/usr/bin/env bash\n[ "$1" = mr-state ] && echo MERGED\n' > "$cb/stub.sh"
  chmod +x "$cb/stub.sh"
  export DEVAGENT_CODE_BACKEND_DIR="$cb"
  _held_active "${1:-impact}"
  _tset mr_url '"https://example.invalid/pull/1"'
}

_sync_asserts() {
  grep -q '^- \[?\] 22\. impact' "$CK"
  grep -q '^- \[ \] 19\. mergetoall' "$CK"
  [ "$(head -1 "$D/STUCK")" = "Kind:        question" ]
  grep -q 'sync: unblocked 1 closeout step(s)' "$CK"
}

@test "sync: a held closeout row stays [?] through both paths while other closeout [?] rows flip" {
  _closeout
  # Path B: no merge marker; mr-state says merged.
  run --separate-stderr "$S/sync.sh" toy
  [ "$status" -eq 0 ] || { echo "B rc=$status err=$stderr" >&2; return 1; }
  _sync_asserts
  # Path A: the merge marker is present.
  ! (source "$S/lib/merge-marker.sh"; merge_marker_present "$CK")
  printf '%s\n' "- 2026-11-26 10:00  sync: on_merge fired; MR merged" >> "$CK"
  (source "$S/lib/merge-marker.sh"; merge_marker_present "$CK")
  sed -i 's/^- \[ \] 19\. mergetoall/- [?] 19. mergetoall/' "$CK"
  sed -i '/sync: unblocked 1 closeout/d' "$CK"
  run --separate-stderr "$S/sync.sh" toy
  [ "$status" -eq 0 ] || { echo "A rc=$status err=$stderr" >&2; return 1; }
  _sync_asserts
}

@test "sync: a question STUCK with no Step: line flips no closeout row" {
  _closeout
  sed -i '/^Step:/d' "$D/STUCK"
  run --separate-stderr "$S/sync.sh" toy
  [ "$status" -eq 0 ] || { echo "rc=$status err=$stderr" >&2; return 1; }
  grep -q '^- \[?\] 22\. impact' "$CK"
  grep -q '^- \[?\] 19\. mergetoall' "$CK"
  ! grep -q 'sync: unblocked' "$CK"
}

_reap() {
  DEVAGENT_DEVDOC_DIR="$DEVDOC" DEVAGENT_PROJECT=toy DEVAGENT_PLUGIN_DIR="$PLUGIN_ROOT" \
    DEVAGENT_STATE_DIR="$BATS_TEST_TMPDIR/rstate" run --separate-stderr "$S/capture/reap.sh" --dry-run
  [ "$status" -eq 0 ] || { echo "reap rc=$status err=$stderr" >&2; return 1; }
}
_reap_count() { grep -c $'\t'"$1"$'/STUCK\t' <<<"$output" || true; }

@test "reap: no candidate for a question STUCK, one for a plain STUCK elsewhere" {
  _held
  printf '%s\n' 'Step:        5 improve' 'Reason:      plain stop' 'Created:     2026-11-20 10:00' > "$DEVDOC/Issue-8/STUCK"
  _reap
  [ "$(_reap_count Issue-7)" -eq 0 ]
  [ "$(_reap_count Issue-8)" -eq 1 ]
}

_leg_sync() {
  printf '%s\n' '- [x]  0. pull' '- [x] 18. ship' '- [?] 19. mergetoall' '- [?] 22. impact' \
    '- [ ] 24. cleanup' '' '## Log' > "$CK"
  sed -i 's/^Step: .*/Step:        22 impact/' "$D/STUCK"
  cat >> "$DA_HOME/config.toml" <<'EOF2'

[project.toy.code_source]
backend = "stub"
EOF2
  local cb="$BATS_TEST_TMPDIR/code"
  mkdir -p "$cb"
  printf '#!/usr/bin/env bash\n[ "$1" = mr-state ] && echo MERGED\n' > "$cb/stub.sh"
  chmod +x "$cb/stub.sh"
  _tset mr_url '"https://example.invalid/pull/1"'
  DEVAGENT_CODE_BACKEND_DIR="$cb" run --separate-stderr "$S/sync.sh" toy
  [ "$status" -eq 0 ] || { echo "sync rc=$status err=$stderr" >&2; return 1; }
  grep -q '^- \[ \] 22\. impact' "$CK"
  grep -q '^- \[ \] 19\. mergetoall' "$CK"
}
_leg_reap() {
  _reap
  [ "$(_reap_count Issue-7)" -eq 1 ]
}

@test "other kinds: sync flips and reap emits as today" {
  _kinds _leg_sync
  _kinds _leg_reap
}

# ---- operator-questions.md's manual clear (until #964) ----------------------

# _manual_clear: the steps skills/next/references/operator-questions.md gives
# for clearing a hold by hand, in its order.
_manual_clear() {
  "$S/checklist-log.sh" "$D" improve "operator answer to question 01: a" >/dev/null
  rm "$D/STUCK"
  "$S/checklist-mark.sh" "$D" 5 ' ' improve >/dev/null
  if grep -q '^Issue-7 = ' "$DA_HOME/state/toy.toml"; then "$S/resume.sh" toy Issue-7 >/dev/null 2>&1; fi
}

@test "manual clear: the documented steps let next run the held step again, parked or not" {
  local leg
  for leg in parked active; do
    rm -rf "$DEVDOC" "$DA_HOME/state"/*
    _toy
    if [ "$leg" = parked ]; then _held; else _held_active; fi
    _manual_clear
    run --separate-stderr "$S/next.sh" toy
    [ "$status" -eq 0 ] || { echo "$leg rc=$status out=$output err=$stderr" >&2; return 1; }
    [[ "$output$stderr" != *"blocked-on-external"* ]] || { echo "$leg: $output $stderr" >&2; return 1; }
    [[ "$output" == *"/devagent:improve toy"* ]] || { echo "$leg: $output" >&2; return 1; }
  done
}
