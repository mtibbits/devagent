#!/usr/bin/env bats
# #909: one STUCK header for every writer. The writer half (W*) pins the header
# that checklist-stuck.sh and stuck.sh both write through stuck_write
# (scripts/lib/checklist.sh) and holds the question STUCK's renderer to it. The
# reader half (R*) drives every in-repo reader's real entry point over the new
# output and over each pre-#909 form (tests/lib/stuck-forms.bash).

load 'lib/bats-helpers'
load 'lib/hold-fixture'   # _lib and _question_stuck

setup() {
  . "$BATS_TEST_DIRNAME/lib/stuck-forms.bash"
  _lib
  setup_tmp_devagent_home
  DEVDOC="$BATS_TEST_TMPDIR/devdoc"
  D="$DEVDOC/Issue-1"
  CK="$D/checklist.md"
  mkdir -p "$D"
  cat > "$DA_HOME/config.toml" <<EOF
[project.toy]
devdoc_dir = "$DEVDOC"
EOF
  cat > "$DA_HOME/state/toy.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$D"
EOF
}

teardown() { teardown_tmp_devagent_home; }

# _ck <shape>: write $CK as one of four checklists.
#   flat     rows 0-7: x - x - x x ~ ' ' (current step 6, last good 5)
#   none     0 pull and 2 draft pending (current step 0; the walk never runs)
#   none2    0 pull [-], 2 draft pending, row 1 absent (the walk runs, exhausts)
#   revised  revision 1 done to 5; revision 2 re-opens 2, 4, 5 (current step 5)
_ck() {
  case "$1" in
    flat) printf '%s\n' '- [x]  0. pull' '- [-]  1. research' '- [x]  2. draft' \
            '- [-]  3. spike' '- [x]  4. scope' '- [x]  5. improve' '- [~]  6. prune' \
            '- [ ]  7. tighten' '' '## Log' > "$CK" ;;
    none) printf '%s\n' '- [ ]  0. pull' '- [ ]  2. draft' '' '## Log' > "$CK" ;;
    none2) printf '%s\n' '- [-]  0. pull' '- [ ]  2. draft' '' '## Log' > "$CK" ;;
    revised) printf '%s\n' '## Revision 1' '' '- [x]  0. pull' '- [-]  1. research' \
               '- [x]  2. draft' '- [-]  3. spike' '- [x]  4. scope' '- [x]  5. improve' \
               '' '## Log' '' '## Revision 2' '' '- [-]  2. draft' '- [-]  4. scope' \
               '- [ ]  5. improve' > "$CK" ;;
    *) echo "_ck: unknown shape '$1'" >&2; return 2 ;;
  esac
}

# _both <shape> <reason> [<status>]: run stuck.sh, then checklist-stuck.sh, each
# on a fresh <shape> checklist, assert each exits <status> (default 0), and only
# then keep its STUCK as $BATS_TEST_TMPDIR/out-sh/STUCK and out-cs/STUCK. A
# writer failure is reported as its exit status, never as `cp: cannot stat`.
_both() {
  local shape="$1" reason="$2" want="${3:-0}"
  mkdir -p "$BATS_TEST_TMPDIR/out-sh" "$BATS_TEST_TMPDIR/out-cs"
  _ck "$shape"; rm -f "$D/STUCK"
  run "$PLUGIN_ROOT/scripts/stuck.sh" toy "$reason"
  [ "$status" -eq "$want" ] \
    || { echo "stuck.sh on $shape: status $status, want $want: $output" >&2; return 1; }
  cp "$D/STUCK" "$BATS_TEST_TMPDIR/out-sh/STUCK"
  _ck "$shape"; rm -f "$D/STUCK"
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" "$D" "$reason"
  [ "$status" -eq "$want" ] \
    || { echo "checklist-stuck.sh on $shape: status $status, want $want: $output" >&2; return 1; }
  cp "$D/STUCK" "$BATS_TEST_TMPDIR/out-cs/STUCK"
}

# _line <file> <N> <want>: line <N> of <file> is exactly <want>.
_line() {
  local got; got="$(sed -n "${2}p" "$1")"
  [ "$got" = "$3" ] || { echo "$1 line $2: got [$got], want [$3]" >&2; return 1; }
}

# _hdr <file> <step> <reason> <last-good>: exactly four lines, lines 1-3 as
# given (literals independent of stuck_render), line 4 the unified Created.
_hdr() {
  local f="$1" n
  n="$(wc -l < "$f")"
  [ "$n" -eq 4 ] || { echo "$f: $n lines, want 4:" >&2; cat "$f" >&2; return 1; }
  _line "$f" 1 "Step:        $2"
  _line "$f" 2 "Reason:      $3"
  _line "$f" 3 "Last good:   $4"
  [[ "$(sed -n 4p "$f")" =~ $STUCK_CREATED_RE ]] \
    || { echo "$f line 4 is not a date -Iseconds Created: [$(sed -n 4p "$f")]" >&2; return 1; }
}

# _same: the two writers' files are identical but for the Created: value (the
# only normalisation).
_same() {
  local s
  for s in sh cs; do
    sed -E 's/^(Created:     ).*/\1T/' "$BATS_TEST_TMPDIR/out-$s/STUCK" > "$BATS_TEST_TMPDIR/norm-$s"
  done
  cmp "$BATS_TEST_TMPDIR/norm-sh" "$BATS_TEST_TMPDIR/norm-cs" \
    || { diff "$BATS_TEST_TMPDIR/norm-sh" "$BATS_TEST_TMPDIR/norm-cs" >&2; return 1; }
}

# ---- writer half -------------------------------------------------------------

@test "#909 stuck_render prints the four header lines byte for byte" {
  stuck_render 6 prune 'waiting on 100% of C:\tok' '5 improve' 2026-11-26T10:00:00+00:00 \
    > "$BATS_TEST_TMPDIR/got"
  printf '%s\n' 'Step:        6 prune' 'Reason:      waiting on 100% of C:\tok' \
    'Last good:   5 improve' 'Created:     2026-11-26T10:00:00+00:00' > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/got"
}

@test "#909 stuck_last_good: revision-scoped per number, else the first file-wide match" {
  # Characterizes the current walk (register Issue-933), not a spec: per number,
  # the active revision block when the number is there, else the first row in the
  # whole file. A change here is editing a characterization.
  _ck flat
  run stuck_last_good "$CK" 6
  [ "$status" -eq 0 ]; [ "$output" = '5 improve' ]
  run stuck_last_good "$CK" 4
  [ "$status" -eq 0 ]; [ "$output" = '2 draft' ]        # skips 3 spike [-]
  _ck none
  run stuck_last_good "$CK" 0
  [ "$status" -eq 0 ]; [ "$output" = '(none)' ]
  _ck none2
  run stuck_last_good "$CK" 2
  [ "$status" -eq 0 ]; [ "$output" = '(none)' ]         # visits absent 1, then 0 [-]
  _ck revised
  run stuck_last_good "$CK" 5
  [ "$status" -eq 0 ]; [ "$output" = '0 pull' ]
}

@test "#909 both writers write one STUCK for a flat checklist" {
  _both flat 'waiting on 100% of C:\tok'
  _hdr "$BATS_TEST_TMPDIR/out-sh/STUCK" '6 prune' 'waiting on 100% of C:\tok' '5 improve'
  _hdr "$BATS_TEST_TMPDIR/out-cs/STUCK" '6 prune' 'waiting on 100% of C:\tok' '5 improve'
  _same
}

@test "#909 both writers write (none) when no earlier row is [x]" {
  local shape
  for shape in none none2; do
    _both "$shape" why
    _line "$BATS_TEST_TMPDIR/out-sh/STUCK" 3 'Last good:   (none)'
    _line "$BATS_TEST_TMPDIR/out-cs/STUCK" 3 'Last good:   (none)'
    _same
  done
}

@test "#909 both writers walk a revised checklist the same way" {
  # Characterizes the current walk (register Issue-933), not a spec: 4, 2 are
  # [-] in revision 2; 3, 1 resolve file-wide to [-]; 0 resolves to revision 1.
  _both revised why
  local s
  for s in sh cs; do
    _line "$BATS_TEST_TMPDIR/out-$s/STUCK" 1 'Step:        5 improve'
    _line "$BATS_TEST_TMPDIR/out-$s/STUCK" 3 'Last good:   0 pull'
  done
  _same
}

@test "#909 checklist-stuck.sh --name mergemr keeps its header" {
  local w="$BATS_TEST_TMPDIR/w5"
  "$PLUGIN_ROOT/scripts/checklist-init.sh" "$w" > /dev/null
  sed -i -E 's/^- \[ \]( +([0-9]|1[0-8])\. )/- [x]\1/' "$w/checklist.md"
  grep -qE '^- \[x\] 18\. ship$' "$w/checklist.md"
  grep -qE '^- \[-\] 19\. mergetoall$' "$w/checklist.md"
  run "$PLUGIN_ROOT/scripts/checklist-stuck.sh" --name mergemr "$w" 'mergemr rule 10: x'
  [ "$status" -eq 0 ]
  _hdr "$w/STUCK" '20 mergemr' 'mergemr rule 10: x' '18 ship'
}

@test "#909 the question STUCK header lines are the shared header" {
  _question_stuck improve 5
  stuck_render 5 improve r '4 scope' 2026-11-20T10:31:00-05:00 > "$BATS_TEST_TMPDIR/sr"
  sed -n 2,5p "$D/STUCK" | cmp "$BATS_TEST_TMPDIR/sr" -
}

@test "#909 each writer's STUCK reads back through stuck_header_value" {
  _both flat r
  local s f created
  for s in sh cs; do
    f="$BATS_TEST_TMPDIR/out-$s/STUCK"
    [ "$(stuck_kind "$BATS_TEST_TMPDIR/out-$s")" = stuck ]
    [ "$(stuck_header_value "$f" Step)" = '6 prune' ]
    [ "$(stuck_header_value "$f" Reason)" = r ]
    [ "$(stuck_header_value "$f" 'Last good')" = '5 improve' ] \
      || { echo "$s: Last good reads [$(stuck_header_value "$f" 'Last good')]" >&2; return 1; }
    created="$(sed -n '4s/^Created:     //p' "$f")"
    [ -n "$created" ]
    [ "$(stuck_header_value "$f" Created)" = "$created" ]
    run grep -c '^$' "$f"
    [ "$output" = 0 ]                                   # no blank line
  done
}

@test "#909 stuck_write fails loudly into a missing directory" {
  run stuck_write "$BATS_TEST_TMPDIR/nope" 6 prune r '5 improve'
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/nope" ]
}

@test "#909 both writers write the same STUCK for a two-line reason and exit 1" {
  # Pins write-before-log_append: log_append refuses a multi-line message after
  # the STUCK is written (a cross-repo contract: Gantry recipes Issue-25/26).
  _both flat $'a\nb' 1
  [ -f "$BATS_TEST_TMPDIR/out-sh/STUCK" ]
  [ -f "$BATS_TEST_TMPDIR/out-cs/STUCK" ]
  _same
}

# ---- reader half -------------------------------------------------------------
# Forms: `new` (stuck.sh's real output) plus STUCK_OLD_FORMS. Each test loops
# over all four, resets the fixture each pass, and ends on a form count.

# _form <form>: a flat checklist stuck at 6 prune whose STUCK is in <form>.
_form() {
  rm -rf "$D"; mkdir -p "$D"
  _ck flat
  if [ "$1" = new ]; then
    "$PLUGIN_ROOT/scripts/stuck.sh" toy 'waiting on the token key' > /dev/null 2>&1 \
      || { echo "_form new: stuck.sh failed" >&2; return 1; }
  else
    sed -i 's/^- \[~\]  6\. prune$/- [!]  6. prune/' "$CK"
    stuck_old_form "$1" "$D/STUCK" 6 prune 'waiting on the token key' 5 improve
  fi
  grep -qxF -- '- [!]  6. prune' "$CK" || { echo "_form $1: row 6 is not [!]" >&2; return 1; }
  [ -f "$D/STUCK" ]
}

@test "#909 catchup.sh shows a STUCK of every form verbatim" {
  local f n=0 body
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    run "$PLUGIN_ROOT/scripts/catchup.sh" toy
    [ "$status" -eq 0 ]
    body="$(sed 's/^/  /' "$D/STUCK")"
    [[ "$output" == *"STUCK file present:"$'\n'"$body"* ]] || { echo "$f: $output" >&2; return 1; }
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "#909 where.sh shows the STUCK section for every form" {
  local f n=0 body
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    run "$PLUGIN_ROOT/scripts/where.sh" toy
    [ "$status" -eq 0 ]
    body="$(sed 's/^/  /' "$D/STUCK")"
    [[ "$output" == *"STUCK:"$'\n'"$body"$'\n\n'"Run /devagent:unstuck to clear."* ]] \
      || { echo "$f: $output" >&2; return 1; }
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "#909 status.sh prints the Reason of every form" {
  local f n=0
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    run "$PLUGIN_ROOT/scripts/status.sh"
    [ "$status" -eq 0 ]
    grep -qxF '  STUCK: waiting on the token key' <<<"$output" || { echo "$f: $output" >&2; return 1; }
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "#909 unstuck.sh clears every form" {
  local f n=0
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    run "$PLUGIN_ROOT/scripts/unstuck.sh" toy
    [ "$status" -eq 0 ] || { echo "$f: $output" >&2; return 1; }
    grep -qxF -- '- [~]  6. prune' "$CK"
    [ ! -e "$D/STUCK" ]
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "#909 checklist-unstuck.sh clears every form" {
  local f n=0
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    run "$PLUGIN_ROOT/scripts/checklist-unstuck.sh" --pending "$D"
    [ "$status" -eq 0 ] || { echo "$f: $output" >&2; return 1; }
    grep -qxF -- '- [ ]  6. prune' "$CK"
    [ ! -e "$D/STUCK" ]
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "#909 next.sh halts on every form" {
  local f n=0 body
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    run "$PLUGIN_ROOT/scripts/next.sh" toy
    [ "$status" -eq 1 ] || { echo "$f: status $status: $output" >&2; return 1; }
    body="$(sed 's/^/  /' "$D/STUCK")"
    [[ "$output" == *"STUCK: step 6 (prune) is marked [!]. Run /devagent:unstuck to clear."$'\n'"$body"* ]] \
      || { echo "$f: $output" >&2; return 1; }
    [[ "$output" != *"dispatch:"* ]]
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "#909 the shared STUCK predicates read every form" {
  local f n=0 line
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    line="$(grep -nxF -- '- [!]  6. prune' "$CK" | cut -d: -f1)"
    [ "$(stuck_kind "$D")" = stuck ]
    [ "$(stuck_header_value "$D/STUCK" Step)" = '6 prune' ]
    [ "$(stuck_header_value "$D/STUCK" Reason)" = 'waiting on the token key' ]
    [ "$(checklist_sentinel_stall "$D")" = "$line:6" ] || { echo "$f: stall [$(checklist_sentinel_stall "$D")]" >&2; return 1; }
    [ "$(question_next_number "$D")" = 01 ]
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "#909 revise.sh refuses over every form" {
  local f n=0
  for f in new "${STUCK_OLD_FORMS[@]}"; do
    _form "$f"
    cp "$CK" "$BATS_TEST_TMPDIR/before.md"
    run "$PLUGIN_ROOT/scripts/revise.sh" toy Issue-1 --no-chain
    [ "$status" -eq 1 ] || { echo "$f: status $status: $output" >&2; return 1; }
    [[ "$output" == *"is stuck:"* && "$output" == *"Nothing was changed."* ]]
    cmp "$BATS_TEST_TMPDIR/before.md" "$CK"
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}
