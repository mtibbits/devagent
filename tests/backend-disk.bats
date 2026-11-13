#!/usr/bin/env bats
# tests/backend-disk.bats — #1009: the disk issue backend, scripts/issue/disk.sh.
# Every verb and every cell of its exit table (spec §9.1). The backend reads and
# writes issue files only through scripts/lib/disk-issue.py (#1008). Run on its
# own or nested by tests/backend-contract.bats.
bats_require_minimum_version 1.5.0   # run --separate-stderr wherever stdout or stderr is pinned

load 'lib/bats-helpers'

FIX="$BATS_TEST_DIRNAME/fixtures/disk-issue"

setup() {
  setup_tmp_devagent_home
  DISK="$PLUGIN_ROOT/scripts/issue/disk.sh"
  DI="$PLUGIN_ROOT/scripts/lib/disk-issue.py"
  # The folder's path holds a unique marker: no verb may print it (I-1).
  MARK="MARK-$$-${BATS_TEST_NUMBER}"
  ROOT="$BATS_TEST_TMPDIR/$MARK"
  D="$ROOT/issues"
  mkdir -p "$D"
}

teardown() { teardown_tmp_devagent_home; }

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# no_mark: neither stdout nor stderr of the last `run` names the folder.
no_mark() {
  local rc=0
  printf '%s\n%s\n' "$output" "${stderr:-}" | grep -qF "$MARK" || rc=$?
  [ "$rc" -eq 1 ] || { echo "folder path leaked: $output ${stderr:-}" >&2; return 1; }
}

# jq-free JSON field read: json_get <json> <python-expression over `o`>
json_get() { python3 -c 'import json,sys; o=json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2]), ensure_ascii=False))' "$1" "$2"; }

FULL_FETCH='# disk#2 — Add a dark-mode toggle to the settings page

- State: closed
- Author: @local
- Labels: 
- URL: disk:2
- Created: 2026-11-01

---

The settings page should have a switch that flips the site between light and dark.
Done when the choice survives a page reload.

---

## Comments (3)

### @local · 2026-11-10

on_draft_start: status In Progress

### @local · 2026-11-10

on_ship: status In Review

### @local · 2026-11-11

on_merge: status Done, closed'

# ---------------------------------------------------------------- Task 2: scaffold

@test "disk: disk.sh is executable and tracked 100755" {
  [ -x "$DISK" ]
  run git -C "$PLUGIN_ROOT" ls-files -s scripts/issue/disk.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755\ * ]]
}

@test "disk: no verb, -h or an unknown verb exits 2" {
  local v
  run --separate-stderr "$DISK"
  [ "$status" -eq 2 ]
  for v in -h --help frob; do
    run --separate-stderr "$DISK" "$v"
    [ "$status" -eq 2 ] || { echo "$v: $status" >&2; false; }
    [[ "$stderr" == *"Usage: disk.sh"* ]]
  done
}

@test "disk: events, events --kinds, comment-records and whoami exit 78 with the not-implemented message, with and without arguments" {
  local args
  for args in "events" "events $D 1" "events --kinds" "events --kinds $D" \
              "comment-records" "comment-records $D 1" "whoami" "whoami $D"; do
    # shellcheck disable=SC2086
    run --separate-stderr "$DISK" $args
    [ "$status" -eq 78 ] || { echo "$args: $status" >&2; false; }
    [[ "$stderr" == *'disk backend: verb "'*'" is not implemented'* ]]
    [ -z "$output" ]
  done
}

@test "disk: an empty, relative or missing folder exits 1 naming issue_source.repo, never the path" {
  local f v n=0
  for f in "" "rel/issues" "./issues" "$ROOT/missing"; do
    for v in "fetch|1" "state|1" "comment-list|1" "state-list" "issue-list" "state-class|1" "state-exists|Done"; do
      local verb="${v%%|*}" arg=()
      [[ "$v" == *"|"* ]] && arg=("${v#*|}")
      run --separate-stderr "$DISK" "$verb" "$f" "${arg[@]}"
      [ "$status" -eq 1 ] || { echo "$verb '$f': $status" >&2; false; }
      [[ "$stderr" == *"issue_source.repo"* ]]
      [ -z "$output" ]
      no_mark
      n=$((n + 1))
    done
  done
  [ "$n" -eq 28 ]
}

@test "disk: an unreadable folder exits 1" {
  is_git_bash && skip "Git Bash: no POSIX folder modes"
  [ "$(id -u)" -ne 0 ] || skip "root reads any folder"
  cp "$FIX/full.md" "$D/2.md"
  chmod 000 "$D"
  run --separate-stderr "$DISK" fetch "$D" 2
  chmod 755 "$D"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"the issues folder named by issue_source.repo is missing or unreadable"* ]]
  no_mark
}

@test "disk: /x and ~/x give the same state-list output" {
  cp "$FIX/full.md" "$D/2.md"
  cp "$FIX/minimal.md" "$D/5.md"
  run --separate-stderr "$DISK" state-list "$D"
  [ "$status" -eq 0 ]
  [ "$output" = $'2\tdone\n5\topen' ]
  local abs="$output"
  # shellcheck disable=SC2088
  HOME="$ROOT" run --separate-stderr "$DISK" state-list '~/issues'
  [ "$status" -eq 0 ]
  [ "$output" = "$abs" ]
}

@test "disk: C:/x and C:\\x exit 1 on Linux" {
  is_git_bash && skip "Git Bash reads a drive letter as absolute"
  local f
  for f in 'C:/x' 'C:\x' 'c:/issues'; do
    run --separate-stderr "$DISK" fetch "$f" 1
    [ "$status" -eq 1 ] || { echo "$f: $status" >&2; false; }
    [[ "$stderr" == *"issue_source.repo must name the issues folder by an absolute path"* ]]
  done
}

@test "disk: Git Bash /c/x, C:/x and C:\\x give the same output" {
  is_git_bash || skip "Git Bash only (the drive-letter forms are relative paths elsewhere)"
  cp "$FIX/full.md" "$D/2.md"
  local posix mixed win want
  posix="$(cd "$D" && pwd)"
  mixed="$(cygpath -m "$D")"
  win="$(cygpath -w "$D")"
  run --separate-stderr "$DISK" fetch "$posix" 2
  [ "$status" -eq 0 ]
  want="$output"
  run --separate-stderr "$DISK" fetch "$mixed" 2
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  run --separate-stderr "$DISK" fetch "$win" 2
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "disk: fetch prints the pinned shape" {
  cp "$FIX/full.md" "$D/2.md"
  touch -d '2026-11-01 12:00' "$D/2.md"
  run --separate-stderr "$DISK" fetch "$D" 2
  [ "$status" -eq 0 ]
  [ "$output" = "$FULL_FETCH" ]
  # one LF at the end, never two
  "$DISK" fetch "$D" 2 > "$BATS_TEST_TMPDIR/out"
  [ "$(tail -c 2 "$BATS_TEST_TMPDIR/out" | od -An -c | tr -d ' ')" = 'd\n' ]
  no_mark
}

@test "disk: fetch of a minimal file has an empty Labels line and Comments (0)" {
  cp "$FIX/minimal.md" "$D/1.md"
  "$DISK" fetch "$D" 1 > "$BATS_TEST_TMPDIR/out"
  grep -qx -- '- Labels: ' "$BATS_TEST_TMPDIR/out"
  grep -qx -- '- State: open' "$BATS_TEST_TMPDIR/out"
  grep -qx '# disk#1 — Add a dark-mode toggle to the settings page' "$BATS_TEST_TMPDIR/out"
  [ "$(tail -n 1 "$BATS_TEST_TMPDIR/out")" = "## Comments (0)" ]
  [ "$(tail -c 1 "$BATS_TEST_TMPDIR/out" | od -An -c | tr -d ' ')" = '\n' ]
}

@test "disk: fetch renders labels, a non-ASCII title and a /-leading title byte for byte" {
  printf '%s\n' '# /devagent:file to a disk folder — café ✓' 'labels: ui, settings' '' '## Prompt' 'Ünïcode prose.' > "$D/3.md"
  "$DISK" fetch "$D" 3 > "$BATS_TEST_TMPDIR/out"
  grep -qx '# disk#3 — /devagent:file to a disk folder — café ✓' "$BATS_TEST_TMPDIR/out"
  grep -qx -- '- Labels: ui, settings' "$BATS_TEST_TMPDIR/out"
  grep -qx 'Ünïcode prose.' "$BATS_TEST_TMPDIR/out"
}

@test "disk: comment-list equals the Comments section of fetch; state prints closed and open" {
  cp "$FIX/full.md" "$D/2.md"
  cp "$FIX/minimal.md" "$D/1.md"
  run --separate-stderr "$DISK" comment-list "$D" 2
  [ "$status" -eq 0 ]
  [ "$output" = "${FULL_FETCH#*$'---\n\n'*$'---\n\n'}" ]
  [[ "$output" == "## Comments (3)"* ]]
  run --separate-stderr "$DISK" comment-list "$D" 1
  [ "$output" = "## Comments (0)" ]
  run --separate-stderr "$DISK" state "$D" 2
  [ "$status" -eq 0 ]
  [ "$output" = closed ]
  run --separate-stderr "$DISK" state "$D" 1
  [ "$output" = open ]
}

@test "disk: fetch, state and comment-list exit 4 for a missing <N>.md and 5 for a faulty one, with empty stdout" {
  local v
  printf '%s\n' '# T' 'state: maybe' > "$D/7.md"
  for v in fetch state comment-list; do
    run --separate-stderr "$DISK" "$v" "$D" 9
    [ "$status" -eq 4 ] || { echo "$v missing: $status" >&2; false; }
    [ -z "$output" ]
    [[ "$stderr" == *"no issue 9 in the folder named by issue_source.repo"* ]]
    no_mark
    run --separate-stderr "$DISK" "$v" "$D" 7
    [ "$status" -eq 5 ] || { echo "$v faulty: $status" >&2; false; }
    [ -z "$output" ]
    [[ "$stderr" == *"7.md:2:"* ]]
    [[ "$stderr" == *"7.md fails the format check; see docs/disk-issues.md" ]]
    no_mark
  done
}

@test "disk: fetch, state and comment-list exit 2 for wrong arguments" {
  local v a
  cp "$FIX/full.md" "$D/2.md"
  for v in fetch state comment-list; do
    run --separate-stderr "$DISK" "$v" "$D"
    [ "$status" -eq 2 ] || { echo "$v no N: $status" >&2; false; }
    for a in 0 01 abc -1; do
      run --separate-stderr "$DISK" "$v" "$D" "$a"
      [ "$status" -eq 2 ] || { echo "$v $a: $status" >&2; false; }
    done
    run --separate-stderr "$DISK" "$v" "$D" 2 extra
    [ "$status" -eq 2 ] || { echo "$v extra: $status" >&2; false; }
    run --separate-stderr "$DISK" "$v"
    [ "$status" -eq 2 ]
  done
}

@test "disk: a plugin path with a space works, and a decoy python3 in the issues folder never runs" {
  local P="$BATS_TEST_TMPDIR/plug in"
  mkdir -p "$P"
  cp -R "$PLUGIN_ROOT/scripts" "$P/scripts"
  cp "$FIX/full.md" "$D/2.md"
  touch -d '2026-11-01 12:00' "$D/2.md"
  run --separate-stderr "$P/scripts/issue/disk.sh" fetch "$D" 2
  [ "$status" -eq 0 ]
  [ "$output" = "$FULL_FETCH" ]
  printf '#!/bin/sh\ntouch "%s/decoy-ran"; exit 1\n' "$BATS_TEST_TMPDIR" > "$D/python3"
  chmod +x "$D/python3"
  PATH=".:$PATH" run --separate-stderr "$DISK" fetch "$D" 2
  [ "$status" -eq 0 ]
  [ "$output" = "$FULL_FETCH" ]
  [ ! -e "$BATS_TEST_TMPDIR/decoy-ran" ]
}

# ---------------------------------------------------------------- Task 3: create

# body <text>: a prompt file in the test's temp dir, outside the issues folder.
body() { printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/body.md"; }

# py_shim <script-body>: a python3 first on PATH that runs <script-body> (with
# $REALPY the real interpreter) and then forwards to the real one.
py_shim() {
  local realpy; realpy="$(command -v python3)"
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  { printf '#!/usr/bin/env bash\nREALPY=%q\n' "$realpy"; printf '%s\n' "$1"; printf 'exec "$REALPY" "$@"\n'; } \
    > "$BATS_TEST_TMPDIR/shim/python3"
  chmod +x "$BATS_TEST_TMPDIR/shim/python3"
  export PATH="$BATS_TEST_TMPDIR/shim:$PATH"
}

issue_count() { find "$D" -maxdepth 1 -name '[1-9]*.md' | wc -l | tr -d ' '; }

@test "disk: the first create in an empty folder prints 1" {
  body "Some prose."
  run --separate-stderr "$DISK" create "$D" "First issue" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  [ -f "$D/1.md" ]
  [ "$(cat "$D/.last-number")" = 1 ]
  [ ! -e "$D/.disk.lock" ]
  run --separate-stderr python3 "$DI" parse "$D/1.md"
  [ "$(json_get "$output" 'o["title"], o["prompt"]')" = '["First issue", "Some prose."]' ]
}

@test "disk: create resolves a relative body file against the caller's folder" {
  body "Relative prose."
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr "$DISK" create "$D" "Rel" body.md
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  grep -qx 'Relative prose.' "$D/1.md"
}

@test "disk: create makes a missing folder whose parent exists; a missing parent exits 1" {
  body "x"
  rmdir "$D"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  [ -f "$D/1.md" ]
  run --separate-stderr "$DISK" create "$ROOT/no/such" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot create the issues folder named by issue_source.repo; its parent folder must exist"* ]]
  no_mark
  [ ! -e "$ROOT/no" ]
}

@test "disk: create uses one more than the larger of the top file and .last-number" {
  body "x"
  cp "$FIX/minimal.md" "$D/9.md"
  cp "$FIX/minimal.md" "$D/10.md"
  printf '4\n' > "$D/.last-number"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$output" = 11 ]
  printf '20\n' > "$D/.last-number"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$output" = 21 ]
  [ "$(cat "$D/.last-number")" = 21 ]
}

@test "disk: deleting the top file and creating again gives a new number" {
  body "x"
  run "$DISK" create "$D" "A" "$BATS_TEST_TMPDIR/body.md"
  [ "$output" = 1 ]
  run "$DISK" create "$D" "B" "$BATS_TEST_TMPDIR/body.md"
  [ "$output" = 2 ]
  rm "$D/2.md"
  run "$DISK" create "$D" "C" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
}

@test "disk: two creates started together give two different numbers and two files" {
  body "x"
  local i a b
  for i in 1 2 3 4 5; do
    "$DISK" create "$D" "A$i" "$BATS_TEST_TMPDIR/body.md" > "$BATS_TEST_TMPDIR/a" &
    "$DISK" create "$D" "B$i" "$BATS_TEST_TMPDIR/body.md" > "$BATS_TEST_TMPDIR/b" &
    wait %1 && wait %2
    a="$(cat "$BATS_TEST_TMPDIR/a")" b="$(cat "$BATS_TEST_TMPDIR/b")"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || { echo "round $i: '$a' '$b'" >&2; false; }
  done
  [ "$(issue_count)" -eq 10 ]
  [ "$(cat "$D/.last-number")" = 10 ]
  [ ! -e "$D/.disk.lock" ]
}

@test "disk: a create whose number is taken retries the next one" {
  body "x"
  py_shim "if [ \"\${2:-}\" = create ]; then echo \"\$4\" >> \"$BATS_TEST_TMPDIR/creates\"; [ -e \"$BATS_TEST_TMPDIR/took\" ] || { touch \"$BATS_TEST_TMPDIR/took\"; cp \"$FIX/minimal.md\" \"\$4.md\"; }; fi"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/creates")" = $'1\n2' ]
  [ "$(cat "$D/.last-number")" = 2 ]
}

@test "disk: 100 taken numbers exit 1 after exactly 100 create calls" {
  body "x"
  py_shim "if [ \"\${2:-}\" = create ]; then echo \"\$4\" >> \"$BATS_TEST_TMPDIR/creates\"; cp \"$FIX/minimal.md\" \"\$4.md\"; fi"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no free issue number after 100 tries"* ]]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/creates")" -eq 100 ]
  [ -z "$output" ]
}

@test "disk: out of numbers at 18 digits exits 1" {
  body "x"
  printf '999999999999999999\n' > "$D/.last-number"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"out of issue numbers: the next number would have more than 18 digits"* ]]
  [ "$(issue_count)" -eq 0 ]
  rm "$D/.last-number"
  cp "$FIX/minimal.md" "$D/1234567890123456789.md"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"out of issue numbers"* ]]
  # a retry that steps past 18 digits is out of numbers too
  rm "$D/1234567890123456789.md"
  printf '999999999999999998\n' > "$D/.last-number"
  cp "$FIX/minimal.md" "$D/999999999999999999.md"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"out of issue numbers"* ]]
}

@test "disk: a .last-number that is not a number exits 1 and writes nothing" {
  body "x"
  local bad
  for bad in "abc" "0" "01" "1234567890123456789" ""; do
    printf '%s\n' "$bad" > "$D/.last-number"
    run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
    [ "$status" -eq 1 ] || { echo "'$bad': $status" >&2; false; }
    [[ "$stderr" == *".last-number in the folder named by issue_source.repo is not an issue number"* ]]
    [ "$(issue_count)" -eq 0 ]
    [ "$(cat "$D/.last-number")" = "$bad" ]
  done
}

@test "disk: --label X --label Y writes labels: X, Y" {
  body "x"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md" --label ui --label "dark mode"
  [ "$status" -eq 0 ]
  run --separate-stderr python3 "$DI" parse "$D/1.md"
  [ "$(json_get "$output" 'o["keys"]["labels"]')" = '["ui", "dark mode"]' ]
}

@test "disk: a /-leading, non-ASCII title round-trips byte for byte" {
  body "Ünïcode prose."
  run --separate-stderr "$DISK" create "$D" "/devagent:file to a disk folder — café" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  head -n 1 "$D/1.md" | grep -qx '# /devagent:file to a disk folder — café'
}

@test "disk: a label with a comma, an empty --label, an unknown option or a missing body file exits 2, and a prompt with an unfenced ## Comments line exits 2" {
  body "x"
  printf '3\n' > "$D/.last-number"
  local B="$BATS_TEST_TMPDIR/body.md"
  local -a c
  for c in "--label|a,b" "--label|" "--label" "--force" "stray"; do
    IFS='|' read -r -a args <<<"$c"
    run --separate-stderr "$DISK" create "$D" "T" "$B" "${args[@]}"
    [ "$status" -eq 2 ] || { echo "$c: $status" >&2; false; }
  done
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 2 ]
  run --separate-stderr "$DISK" create "$D" "T"
  [ "$status" -eq 2 ]
  printf '%s\n' 'prose' '## Comments' 'more' > "$B"
  run --separate-stderr "$DISK" create "$D" "T" "$B"
  [ "$status" -eq 2 ]
  no_mark
  [ "$(issue_count)" -eq 0 ]
  [ "$(cat "$D/.last-number")" = 3 ]
  [ ! -e "$D/.disk.lock" ]
}

@test "disk: a held .disk.lock makes create exit 1 naming the lock, writing nothing" {
  body "x"
  : > "$D/.disk.lock"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"the issues folder named by issue_source.repo is locked (.disk.lock); remove it if no devagent command is running"* ]]
  [ "$(issue_count)" -eq 0 ]
  [ ! -e "$D/.last-number" ]
  [ -f "$D/.disk.lock" ]
}

# ---------------------------------------------------------------- Task 4: transition

# map_stages: the project p maps the three stages, as the skeleton does.
map_stages() {
  cat > "$DA_HOME/config.toml" <<'TOML'
[project.p.issue_workflow]
on_draft_start = "In Progress"
on_ship        = "In Review"
on_merge       = "Done"
TOML
}

# set_log: a python3 shim that logs each module `set` argv (one line each) to
# $SETLOG, then forwards it.
set_log() {
  SETLOG="$BATS_TEST_TMPDIR/setlog"
  : > "$SETLOG"
  py_shim "if [ \"\${2:-}\" = set ]; then printf '%s|' \"\${@:3}\" >> \"$SETLOG\"; echo >> \"$SETLOG\"; fi"
}

tr_disk() { DEVAGENT_DATE_OVERRIDE=2026-11-10 run --separate-stderr "$DISK" transition "$D" "$@"; }

@test "disk: on_draft_start writes status and one entry in a single set" {
  map_stages; set_log
  cp "$FIX/minimal.md" "$D/1.md"
  tr_disk 1 on_draft_start --project p
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SETLOG")" -eq 1 ]
  [ "$(cat "$SETLOG")" = '1.md|status=In Progress|--comment|on_draft_start: status In Progress|' ]
  grep -qx 'status: In Progress' "$D/1.md"
  grep -qx -- '- 2026-11-10 on_draft_start: status In Progress' "$D/1.md"
  [ ! -e "$D/.disk.lock" ]
}

@test "disk: a mapped on_merge writes status, state and entry in one set" {
  map_stages; set_log
  cp "$FIX/minimal.md" "$D/1.md"
  tr_disk 1 on_merge --project p
  [ "$status" -eq 0 ]
  [ "$(cat "$SETLOG")" = '1.md|status=Done|state=closed|--comment|on_merge: status Done, closed|' ]
  grep -qx 'state: closed' "$D/1.md"
  grep -qx 'status: Done' "$D/1.md"
  grep -qx -- '- 2026-11-10 on_merge: status Done, closed' "$D/1.md"
}

@test "disk: an unmapped on_merge writes state: closed and \"on_merge: closed\"" {
  set_log
  cp "$FIX/minimal.md" "$D/1.md"
  tr_disk 1 on_merge --project p
  [ "$status" -eq 0 ]
  [ "$(cat "$SETLOG")" = '1.md|state=closed|--comment|on_merge: closed|' ]
  grep -qx 'state: closed' "$D/1.md"
  run ! grep -q '^status:' "$D/1.md"
  grep -qx -- '- 2026-11-10 on_merge: closed' "$D/1.md"
}

@test "disk: an unmapped on_ship warns and changes nothing" {
  set_log
  cp "$FIX/minimal.md" "$D/1.md"
  cp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
  tr_disk 1 on_ship --project p
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no tracker state mapped for 'on_ship'"* ]]
  cmp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
  [ ! -s "$SETLOG" ]
}

@test "disk: a transition already at its target leaves the bytes unchanged" {
  map_stages; set_log
  local stage
  cp "$FIX/full.md" "$D/2.md"
  # full.md is at every stage's identity except status (Done): on_merge is
  # at its target; on_draft_start and on_ship carry their entries but not
  # their status, so they are not.
  cp "$D/2.md" "$BATS_TEST_TMPDIR/orig"
  tr_disk 2 on_merge --project p
  [ "$status" -eq 0 ]
  cmp "$D/2.md" "$BATS_TEST_TMPDIR/orig"
  [ ! -s "$SETLOG" ]
  for stage in on_draft_start on_ship; do
    : > "$SETLOG"
    cp "$FIX/minimal.md" "$D/1.md"
    tr_disk 1 "$stage" --project p
    cp "$D/1.md" "$BATS_TEST_TMPDIR/once"
    : > "$SETLOG"
    tr_disk 1 "$stage" --project p
    [ "$status" -eq 0 ]
    cmp "$D/1.md" "$BATS_TEST_TMPDIR/once"
    [ ! -s "$SETLOG" ] || { echo "$stage wrote again" >&2; false; }
  done
  # the status already set but no entry for the stage: one set, no status= change
  printf '%s\n' '# T' 'status: In Review' '' '## Prompt' 'x' > "$D/3.md"
  : > "$SETLOG"
  tr_disk 3 on_ship --project p
  [ "$status" -eq 0 ]
  [ "$(cat "$SETLOG")" = '3.md|--comment|on_ship: status In Review|' ]
}

@test "disk: a transition on a file that fails check exits 5 and leaves it unchanged" {
  map_stages; set_log
  printf '%s\n' '# T' 'state: maybe' > "$D/7.md"
  cp "$D/7.md" "$BATS_TEST_TMPDIR/orig"
  tr_disk 7 on_ship --project p
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"7.md:2:"* ]]
  cmp "$D/7.md" "$BATS_TEST_TMPDIR/orig"
  [ ! -s "$SETLOG" ]
  no_mark
}

@test "disk: transition exits 4 for a missing file, 2 for wrong arguments, quarantine or an unknown stage, and 1 for a folder fault or an unreadable config" {
  map_stages
  cp "$FIX/minimal.md" "$D/1.md"
  tr_disk 9 on_ship --project p
  [ "$status" -eq 4 ]
  no_mark
  local a
  for a in "1" "0|on_ship" "01|on_ship" "x|on_ship" "1|quarantine" "1|on_frob" "1|on_ship|--project" "1|on_ship|--bogus"; do
    IFS='|' read -r -a args <<<"$a"
    tr_disk "${args[@]}"
    [ "$status" -eq 2 ] || { echo "$a: $status" >&2; false; }
  done
  tr_disk 1 quarantine --project p
  [[ "$stderr" == *"transition quarantine is not supported on disk"* ]]
  run --separate-stderr "$DISK" transition rel/issues 1 on_ship --project p
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"issue_source.repo"* ]]
  cp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
  printf '[project.p\nbroken = \n' > "$DA_HOME/config.toml"
  tr_disk 1 on_ship --project p
  [ "$status" -eq 1 ]
  cmp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
  no_mark
}

@test "disk: DEVAGENT_DISK_STATUS_ON_SHIP overrides issue_workflow" {
  map_stages
  cp "$FIX/minimal.md" "$D/1.md"
  DEVAGENT_DISK_STATUS_ON_SHIP="Review: env" tr_disk 1 on_ship --project p
  [ "$status" -eq 0 ]
  grep -qx 'status: Review: env' "$D/1.md"
  grep -qx -- '- 2026-11-10 on_ship: status Review: env' "$D/1.md"
}

@test "disk: an interrupted transition leaves the file unchanged, and the retry writes status, state and entry together" {
  map_stages
  cp "$FIX/minimal.md" "$D/1.md"
  cp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
  py_shim "if [ \"\${2:-}\" = set ]; then shift; exec \"\$REALPY\" \"$PLUGIN_ROOT/tests/helpers/disk_issue_inject.py\" kill-before-replace -- \"\$@\"; fi"
  tr_disk 1 on_merge --project p
  [ "$status" -eq 1 ]
  cmp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
  [ ! -e "$D/.disk.lock" ]
  PATH="${PATH#"$BATS_TEST_TMPDIR/shim:"}"
  tr_disk 1 on_merge --project p
  [ "$status" -eq 0 ]
  grep -qx 'state: closed' "$D/1.md"
  grep -qx 'status: Done' "$D/1.md"
  grep -qx -- '- 2026-11-10 on_merge: status Done, closed' "$D/1.md"
}

@test "disk: two on_merge transitions started together append one entry" {
  map_stages
  local i
  for i in 1 2 3; do
    cp "$FIX/minimal.md" "$D/$i.md"
    "$DISK" transition "$D" "$i" on_merge --project p 2>/dev/null &
    "$DISK" transition "$D" "$i" on_merge --project p 2>/dev/null &
    wait %1 && wait %2
    [ "$(grep -c 'on_merge:' "$D/$i.md")" -eq 1 ] || { cat "$D/$i.md" >&2; false; }
  done
}

@test "disk: a held .disk.lock makes transition exit 1, writing nothing" {
  map_stages
  cp "$FIX/minimal.md" "$D/1.md"
  cp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
  : > "$D/.disk.lock"
  tr_disk 1 on_ship --project p
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"is locked (.disk.lock)"* ]]
  cmp "$D/1.md" "$BATS_TEST_TMPDIR/orig"
}

# ---------------------------------------------------------------- Task 5: list verbs

# list_fixture: a closed, an in-progress (by a case-only status match) and an
# open issue, plus the names every list verb ignores.
list_fixture() {
  cp "$FIX/full.md" "$D/1.md"                      # closed, parent: 3
  printf '%s\n' '# Second' 'status: in progress' 'labels: ui, dark mode' '' '## Prompt' 'Ünïcode body.' > "$D/2.md"
  cp "$FIX/minimal.md" "$D/3.md"
  printf '3\n' > "$D/.last-number"
  printf 'not an issue\n' > "$D/README.md"
  cp "$FIX/minimal.md" "$D/.x.md"
  touch -d '2026-03-03 12:00' "$D/1.md" "$D/2.md" "$D/3.md"
  cat > "$DA_HOME/config.toml" <<'TOML'
[project.p.issue_workflow]
on_draft_start = "In Progress"
TOML
}

@test "disk: state-list prints done, in_progress and open sorted by N and passes wbs-tracker.py check" {
  list_fixture
  DEVAGENT_PROJECT=p run --separate-stderr "$DISK" state-list "$D"
  [ "$status" -eq 0 ]
  [ "$output" = $'1\tdone\n2\tin_progress\n3\topen' ]
  run --separate-stderr bash -c 'DEVAGENT_PROJECT=p "$1" state-list "$2" | python3 "$3/scripts/lib/wbs-tracker.py" check' _ "$DISK" "$D" "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  # no on_draft_start mapping (or no project): no issue is in progress
  run --separate-stderr "$DISK" state-list "$D"
  [ "$output" = $'1\tdone\n2\topen\n3\topen' ]
  DEVAGENT_PROJECT=other run --separate-stderr "$DISK" state-list "$D"
  [ "$output" = $'1\tdone\n2\topen\n3\topen' ]
}

@test "disk: issue-list passes wbs-import.py check and carries the pinned fields" {
  list_fixture
  DEVAGENT_PROJECT=p run --separate-stderr "$DISK" issue-list "$D"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  run --separate-stderr bash -c 'DEVAGENT_PROJECT=p "$1" issue-list "$2" | python3 "$3/scripts/lib/wbs-import.py" check' _ "$DISK" "$D" "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  DEVAGENT_PROJECT=p run --separate-stderr "$DISK" issue-list "$D"
  [ "$(json_get "${lines[0]}" 'list(o)')" = '["id", "title", "body", "state", "class", "created", "closed", "milestone", "labels", "type", "parent", "blocked_by", "url"]' ]
  [ "$(json_get "${lines[0]}" '[o["id"], o["state"], o["class"], o["parent"], o["url"], o["closed"], o["milestone"], o["type"], o["blocked_by"]]')" = '["1", "closed", "done", "disk:3", "disk:1", "2026-11-11", null, null, []]' ]
  [ "$(json_get "${lines[1]}" '[o["id"], o["title"], o["body"], o["state"], o["class"], o["labels"], o["parent"], o["closed"], o["created"]]')" = '["2", "Second", "Ünïcode body.", "open", "in_progress", ["ui", "dark mode"], null, null, "2026-03-03"]' ]
  [ "$(json_get "${lines[2]}" '[o["class"], o["labels"], o["url"]]')" = '["open", [], "disk:3"]' ]
  run --separate-stderr "$DISK" issue-list "$D"
  [ "$(json_get "${lines[1]}" 'o["class"]')" = '"open"' ]
}

# git_at <date> <args…>: git with every date pinned and a fixed identity.
git_at() {
  GIT_AUTHOR_DATE="$1T12:00:00Z" GIT_COMMITTER_DATE="$1T12:00:00Z" \
    git -C "$ROOT" -c user.name=t -c user.email=t@example.com "${@:2}"
}

@test "disk: issue-list dates come from the git walk, the on_merge entry and the mtime" {
  git -C "$ROOT" init -q
  # 1: added 2026-01-05, closed by hand 2026-02-07
  printf '%s\n' '# One' '' '## Prompt' 'x' > "$D/1.md"
  # 3: added 2026-01-06, closed by on_merge (entry 2026-01-20), committed 2026-01-21
  printf '%s\n' '# Three' '' '## Prompt' 'x' > "$D/3.md"
  mkdir "$D/sub"
  printf '%s\n' '# Sub' '' '## Prompt' 'x' > "$D/sub/5.md"
  git_at 2026-01-05 add issues/1.md issues/sub/5.md
  git_at 2026-01-05 commit -qm one
  git_at 2026-01-06 add issues/3.md
  git_at 2026-01-06 commit -qm three
  printf '%s\n' '# One' 'state: closed' '' '## Prompt' 'x' > "$D/1.md"
  git_at 2026-02-07 commit -qam close-one
  printf '%s\n' '# Three' 'state: closed' '' '## Prompt' 'x' '' '## Comments' '- 2026-01-20 on_merge: closed' > "$D/3.md"
  git_at 2026-01-21 commit -qam close-three
  # 2: untracked, open; 4: untracked, closed by hand
  printf '%s\n' '# Two' '' '## Prompt' 'x' > "$D/2.md"
  printf '%s\n' '# Four' 'state: closed' '' '## Prompt' 'x' > "$D/4.md"
  touch -d '2026-03-03 12:00' "$D/2.md" "$D/4.md"
  touch -d '2026-04-04 12:00' "$D/1.md" "$D/3.md"
  run --separate-stderr "$DISK" issue-list "$D"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "$(json_get "${lines[0]}" '[o["id"], o["created"], o["closed"]]')" = '["1", "2026-01-05", "2026-02-07"]' ]
  [ "$(json_get "${lines[1]}" '[o["id"], o["created"], o["closed"]]')" = '["2", "2026-03-03", null]' ]
  [ "$(json_get "${lines[2]}" '[o["id"], o["created"], o["closed"]]')" = '["3", "2026-01-06", "2026-01-20"]' ]
  [ "$(json_get "${lines[3]}" '[o["id"], o["created"], o["closed"]]')" = '["4", "2026-03-03", "2026-03-03"]' ]
  # fetch carries the same created date
  "$DISK" fetch "$D" 1 > "$BATS_TEST_TMPDIR/out"
  grep -qx -- '- Created: 2026-01-05' "$BATS_TEST_TMPDIR/out"
}

@test "disk: a git history the folder cannot read exits 1, never falling back to the mtime" {
  git -C "$ROOT" init -q
  cp "$FIX/minimal.md" "$D/1.md"
  GIT_TEST_ASSUME_DIFFERENT_OWNER=1 run --separate-stderr "$DISK" issue-list "$D"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot read the git history of the folder named by issue_source.repo"* ]]
  no_mark
}

@test "disk: state-list and issue-list exit 5 on a faulty file with empty stdout and a last stderr line naming <N>.md" {
  list_fixture
  printf '%s\n' '# T' 'state: maybe' > "$D/7.md"
  local v
  for v in state-list issue-list; do
    run --separate-stderr "$DISK" "$v" "$D"
    [ "$status" -eq 5 ] || { echo "$v: $status" >&2; false; }
    [ -z "$output" ]
    [[ "${stderr##*$'\n'}" == "1 issue file(s) in issue_source.repo fail the format check; first: 7.md:2: "* ]]
    no_mark
  done
}

@test "disk: an unreadable issue file exits 5 naming it; an unreadable folder exits 1" {
  is_git_bash && skip "Git Bash: no POSIX file modes"
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  list_fixture
  chmod 000 "$D/2.md"
  run --separate-stderr "$DISK" state-list "$D"
  chmod 644 "$D/2.md"
  [ "$status" -eq 5 ]
  [[ "${stderr##*$'\n'}" == *"first: 2.md:1: cannot read: "* ]]
  chmod 300 "$D"
  run --separate-stderr "$DISK" state-list "$D"
  chmod 755 "$D"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"the issues folder named by issue_source.repo is missing or unreadable"* ]]
  no_mark
}

@test "disk: state-list, issue-list and state-class never exit 2" {
  list_fixture
  local a
  for a in "state-list" "issue-list" "state-list|$D|x" "issue-list|$D|x" "state-class" "state-class|$D" \
           "state-class|$D|x" "state-class|$D|0" "state-class|$D|1|x"; do
    IFS='|' read -r -a args <<<"$a"
    run --separate-stderr "$DISK" "${args[@]}"
    [ "$status" -eq 1 ] || { echo "$a: $status" >&2; false; }
  done
}

@test "disk: state-class prints done\\tcompleted and open\\t-; 4 missing; 5 faulty" {
  list_fixture
  printf '%s\n' '# T' 'state: maybe' > "$D/7.md"
  DEVAGENT_PROJECT=p run --separate-stderr "$DISK" state-class "$D" 1
  [ "$status" -eq 0 ]
  [ "$output" = $'done\tcompleted' ]
  DEVAGENT_PROJECT=p run --separate-stderr "$DISK" state-class "$D" 2
  [ "$output" = $'open\t-' ]
  run --separate-stderr "$DISK" state-class "$D" 9
  [ "$status" -eq 4 ]
  run --separate-stderr "$DISK" state-class "$D" 7
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "disk: state-exists exits 0 for any status, 2 for an empty one, 1 for a folder fault" {
  run --separate-stderr "$DISK" state-exists "$D" "Anything at all"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr "$DISK" state-exists "$D" ""
  [ "$status" -eq 2 ]
  run --separate-stderr "$DISK" state-exists "$D"
  [ "$status" -eq 2 ]
  run --separate-stderr "$DISK" state-exists "$D" a b
  [ "$status" -eq 2 ]
  run --separate-stderr "$DISK" state-exists "$ROOT/missing" Done
  [ "$status" -eq 1 ]
  no_mark
}

@test "disk: an empty folder lists nothing and exits 0" {
  local v
  for v in state-list issue-list; do
    run --separate-stderr "$DISK" "$v" "$D"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "disk: no verb's stdout or stderr names the folder" {
  list_fixture
  printf '%s\n' '# T' 'state: maybe' > "$D/7.md"
  printf 'x\n' > "$BATS_TEST_TMPDIR/body.md"
  local n=0 c
  # positive control: a planted leak is seen
  output="leak: $D" stderr=""
  run ! no_mark
  for c in "fetch|$D|1" "fetch|$D|7" "fetch|$D|9" "state|$D|7" "comment-list|$D|9" \
           "create|$D|T|$BATS_TEST_TMPDIR/body.md" "create|$D/new|T|$BATS_TEST_TMPDIR/body.md" \
           "create|$ROOT/a/b|T|$BATS_TEST_TMPDIR/body.md" "create|$D|T|$BATS_TEST_TMPDIR/body.md|--label|a,b" \
           "transition|$D|3|on_ship|--project|p" "transition|$D|7|on_draft_start|--project|p" \
           "transition|$D|9|on_merge|--project|p" "state-list|$D" "issue-list|$D" "state-class|$D|7" \
           "state-class|$D|9" "state-exists|$D|x" "state-list|$ROOT/missing" "issue-list|rel"; do
    IFS='|' read -r -a args <<<"$c"
    DEVAGENT_PROJECT=p run --separate-stderr "$DISK" "${args[@]}"
    no_mark || { echo "leak from: $c" >&2; false; }
    n=$((n + 1))
  done
  # a folder that cannot be searched
  if ! is_git_bash && [ "$(id -u)" -ne 0 ]; then
    chmod 600 "$D"
    run --separate-stderr "$DISK" fetch "$D" 1
    chmod 755 "$D"
    [ "$status" -eq 1 ]
    no_mark
    n=$((n + 1))
  fi
  # a folder in a git work tree git refuses (dubious ownership)
  git -C "$ROOT" init -q
  GIT_TEST_ASSUME_DIFFERENT_OWNER=1 run --separate-stderr "$DISK" issue-list "$D"
  no_mark
  n=$((n + 1))
  [ "$n" -ge 20 ]
}

# ---------------------------------------------------------------- final review fixes

@test "disk: a .last-number with CRLF (a Git for Windows checkout) is read as the number" {
  body "x"
  printf '5\r\n' > "$D/.last-number"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = 6 ]
  printf '7' > "$D/.last-number"
  run --separate-stderr "$DISK" create "$D" "T" "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "$output" = 8 ]
}

@test "disk: under Git Bash the module path reaches python in its mixed form" {
  # A cygpath shim maps /x to C:/x; a python3 shim refuses any MSYS-form
  # script path, as native Windows python would (it reads /c/... as C:\c\...).
  mkdir -p "$BATS_TEST_TMPDIR/msys"
  printf '#!/usr/bin/env bash\n[ "$1" = -m ] && shift; case "$1" in /*) printf "C:%%s\\n" "$1" ;; *) printf "%%s\\n" "$1" ;; esac\n' \
    > "$BATS_TEST_TMPDIR/msys/cygpath"
  chmod +x "$BATS_TEST_TMPDIR/msys/cygpath"
  export PATH="$BATS_TEST_TMPDIR/msys:$PATH"
  py_shim 'case "${1:-}" in C:/*) set -- "${1#C:}" "${@:2}" ;; /*disk-issue.py) echo "cannot open $1" >&2; exit 2 ;; esac'
  cp "$FIX/full.md" "$D/2.md"
  run --separate-stderr "$DISK" state "$D" 2
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  [ "$output" = closed ]
}
