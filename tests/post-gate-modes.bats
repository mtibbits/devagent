#!/usr/bin/env bats
# #966: the leak gate's rows that need POSIX file modes (a mode-000 list,
# record or post). Not tagged for Git Bash: NTFS has no such modes, and a
# skipped test would say nothing there. The portable twins (a directory where
# the file belongs) run in the tagged tests/post-gate-names.bats.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/post-gate-fixture'

setup() {
  pg_setup
}

teardown() {
  # bats removes the temp dir itself; a mode-000 file inside must not stop it.
  chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# _modes: every test here is about a mode-000 file.
_modes() {
  skip_on_git_bash "chmod 000"
  [[ $(id -u) == 0 ]] && skip "root reads mode-000 files"
  pg_post
}

@test "modes: an unreadable denylist holds denylist-missing-unrecorded, or denylist-missing once recorded" {
  _modes
  chmod 000 "$PG_LIST"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing-unrecorded" ]
  pg_holds names denylist-missing-unrecorded
  [ ! -e "$PG_RECORDED" ]
  pg_resolved "$PG_LIST" > "$PG_RECORDED"
  pg_names
  [ "$stderr" = "post-gate: names hold denylist-missing" ]
  pg_holds names denylist-missing
  # control: readable again, the same run passes.
  chmod 600 "$PG_LIST"
  pg_names
  pg_passes names
}

@test "modes: denylist-status reads an unreadable list as absent, or missing once recorded" {
  _modes
  chmod 000 "$PG_LIST"
  pg_run "$PG" denylist-status
  [ "$status" -eq 0 ]
  [ "$output" = absent ]
  pg_resolved "$PG_LIST" > "$PG_RECORDED"
  pg_run "$PG" denylist-status
  [ "$status" -eq 0 ]
  [ "$output" = missing ]
}

@test "modes: record-denylist refuses an unreadable list with gate-error" {
  _modes
  chmod 000 "$PG_LIST"
  pg_run "$PG" record-denylist --project alpha --issue Issue-7
  pg_holds names gate-error list-missing
  [ ! -e "$PG_RECORDED" ]
  [ "$(pg_notify_count)" = 0 ]
}

@test "modes: an unreadable record file holds gate-error" {
  _modes
  pg_resolved "$PG_LIST" > "$PG_RECORDED"
  chmod 000 "$PG_RECORDED"
  pg_names
  pg_holds names gate-error record-malformed
  pg_run "$PG" denylist-status
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "modes: an unreadable post holds gate-error" {
  _modes
  chmod 000 "$POST"
  pg_names
  pg_holds names gate-error file-unreadable
  [ ! -e "$PG_RECORDED" ]
}
