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
  run --separate-stderr "$DISK" fetch "$D" 2
  [ "$status" -eq 0 ]
  local abs="$output"
  # shellcheck disable=SC2088
  HOME="$ROOT" run --separate-stderr "$DISK" fetch '~/issues' 2
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
