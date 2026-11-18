#!/usr/bin/env bats
# tests/doctor-capacity.bats — #743: doctor's [capacity] section. Global mode only,
# after the per-project checks; doctor runs scripts/capacity.sh and branches on its
# exit code. The violation tests run the real reader; the reader-fault tests run a
# COPY of the plugin whose capacity.sh is a stub (doctor derives PLUGIN_ROOT from its
# own path, as tests/doctor.bats's fixture-removal test does), so there is no env seam.
# Untagged like every doctor test file: the doctor harness is unproven under Git Bash.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'
load 'lib/doctor-harness'
load 'lib/capacity-fixture'

setup() {
  setup_tmp_devagent_home
  seed_doctor_project
  stub_claude_cli enabled   # the quiet state: no live `claude plugin list` (#585)
}

teardown() { teardown_tmp_devagent_home; }

# _stub_reader <body> — a plugin copy whose scripts/capacity.sh is a stub with this
# body; sets STUB_DOCTOR to the copy's doctor.sh. The copy leaves out .git, the venv
# and every cache: another job's git or python can rename files there mid-copy.
_stub_reader() {
  mkdir -p "$BATS_TEST_TMPDIR/plugin"
  tar -C "$PLUGIN_ROOT" --exclude=./.git --exclude=./.venv --exclude=__pycache__ \
    --exclude=./.mypy_cache --exclude=./.pytest_cache --exclude=./.ruff_cache -cf - . \
    | tar -C "$BATS_TEST_TMPDIR/plugin" -xf -
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$BATS_TEST_TMPDIR/plugin/scripts/capacity.sh"
  chmod 755 "$BATS_TEST_TMPDIR/plugin/scripts/capacity.sh"
  STUB_DOCTOR="$BATS_TEST_TMPDIR/plugin/scripts/doctor.sh"
}

# _line_no <fixed string> — the line number of the first output line equal to it.
_line_no() { printf '%s\n' "$output" | grep -nxF -- "$1" | head -1 | cut -d: -f1; }

# _fails_with <line> — doctor exits 1 with exactly one error, and this FAIL line.
_fails_with() {
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 1 ] || { printf 'want status 1, got %s\n%s\n' "$status" "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -qxF -- "  FAIL $1" || { printf 'no line: FAIL %s\n%s\n' "$1" "$output" >&2; return 1; }
  [ "${lines[-1]}" = "FAIL (1 error(s))" ]
}

@test "doctor capacity: not declared adds the header and one OK line" {
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c capacity)" -eq 2 ]
  local hdr last_proj
  hdr="$(_line_no '[capacity]')"
  last_proj="$(printf '%s\n' "$output" | grep -n '^\[project: ' | tail -1 | cut -d: -f1)"
  [ -n "$hdr" ]
  [ -n "$last_proj" ]
  [ "$hdr" -gt "$last_proj" ]
  [ "$(printf '%s\n' "$output" | sed -n "$((hdr + 1))p")" = "  OK   capacity: not declared (forecasting off)" ]
}

@test "doctor capacity: twelve projects print the declared OK line" {
  cap_healthy_projects 11
  cap_shared
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^\[project: ')" -eq 12 ]
  local hdr last_proj
  hdr="$(_line_no '[capacity]')"
  last_proj="$(printf '%s\n' "$output" | grep -n '^\[project: ' | tail -1 | cut -d: -f1)"
  [ "$hdr" -gt "$last_proj" ]
  [ "$(printf '%s\n' "$output" | sed -n "$((hdr + 1))p")" = "  OK   capacity: 20 operator h/week, pool of 3 lanes, 500000000 weighted tokens/week (tokens_per_week)" ]
}

@test "doctor capacity: violation row 1: missing required key" {
  cap_shared -max_lanes
  _fails_with "capacity: capacity.max_lanes: missing required key"
}

@test "doctor capacity: violation row 2: wrong type" {
  cap_shared operator_hours_per_week=true
  _fails_with "capacity: capacity.operator_hours_per_week: wrong type: expected number"
}

@test "doctor capacity: violation row 3: out of range" {
  cap_shared operator_hours_per_week=0
  _fails_with "capacity: capacity.operator_hours_per_week: out of range: 0 < x <= 168"
}

@test "doctor capacity: violation row 4: not a calendar date" {
  cap_shared
  cap_table volk 'deadline = "2026-02-30"'
  _fails_with "capacity: project.volk.capacity.deadline: not a calendar date"
}

@test "doctor capacity: violation row 5: exceeds capacity.max_lanes" {
  cap_shared
  cap_table volk 'max_lanes = 4'
  _fails_with "capacity: project.volk.capacity.max_lanes: exceeds capacity.max_lanes"
}

@test "doctor capacity: violation row 6: reserve_operator_hours_per_week sum exceeds capacity.operator_hours_per_week" {
  cap_shared
  cap_table volk 'reserve_operator_hours_per_week = 25'
  _fails_with "capacity: pool: reserve_operator_hours_per_week sum exceeds capacity.operator_hours_per_week"
}

@test "doctor capacity: violation row 7: reserve_tokens_per_week sum exceeds the effective weekly token budget" {
  cap_shared windows_per_week=5.5
  cap_table volk 'reserve_tokens_per_week = 400000000'
  _fails_with "capacity: pool: reserve_tokens_per_week sum exceeds the effective weekly token budget"
}

@test "doctor capacity: violation row 8: [capacity] table missing" {
  cap_table volk 'priority = 2'
  _fails_with "capacity: project.volk.capacity: [capacity] table missing"
}

@test "doctor capacity: a violation leaves the per-project checks running, before the section" {
  cap_shared
  cap_table volk 'max_lanes = 4'
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[project: volk]"* ]]
  [[ "$output" == *"  OK   source_dir exists ("* ]]
  local last_proj first_cap
  last_proj="$(printf '%s\n' "$output" | grep -n '^\[project: ' | tail -1 | cut -d: -f1)"
  first_cap="$(printf '%s\n' "$output" | grep -n 'capacity: ' | head -1 | cut -d: -f1)"
  [ "$last_proj" -lt "$first_cap" ]
  [[ "$output" == *"  FAIL capacity: project.volk.capacity.max_lanes: exceeds capacity.max_lanes"* ]]
}

@test "doctor capacity: single-project mode does not run the section" {
  # Green before the change by design: the control is the previous test, where the
  # same fixture fails in global mode.
  cap_shared
  cap_table volk 'max_lanes = 4'
  run "$PLUGIN_ROOT/scripts/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *capacity* ]]
}

@test "doctor capacity: a reader that exits 1 is reader failed, never not declared" {
  _stub_reader 'echo "boom" >&2; exit 1'
  run "$STUB_DOCTOR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  FAIL capacity: reader failed (exit 1) — boom"* ]]
  [[ "$output" != *"not declared"* ]]
}

@test "doctor capacity: exit 0 without a document is reader failed" {
  local body
  for body in 'exit 0' 'echo null'; do
    _stub_reader "$body"
    run "$STUB_DOCTOR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"  FAIL capacity: reader failed (exit 0: no capacity document)"* ]]
    [[ "$output" != *"not declared"* ]]
    rm -rf "$BATS_TEST_TMPDIR/plugin"
  done
}

@test "doctor capacity: exit 3 without a violation line still fails" {
  _stub_reader 'exit 3'
  run "$STUB_DOCTOR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  FAIL capacity: reader failed (exit 3: no violation lines)"* ]]
}

@test "doctor capacity: an unknown key is a WARN and the exit stays 0" {
  cap_shared max_lane=3
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  WARN capacity: capacity.max_lane: unknown key (ignored)"* ]]
  [[ "${lines[-1]}" == "OK ("* ]]
}

@test "doctor capacity: a capacity-only project table is a WARN that adds no error" {
  cap_shared
  printf '[project.volkk.capacity]\npriority = 2\n' | cap_append
  run "$PLUGIN_ROOT/scripts/doctor.sh"
  [ "$status" -eq 1 ]   # volkk fails the per-project checks (no source_dir), as before
  [[ "$output" == *"  WARN capacity: project.volkk: only key is capacity (misspelled project name?)"* ]]
  local fails n
  fails="$(printf '%s\n' "$output" | grep -c '^  FAIL ')"
  n="$(printf '%s\n' "${lines[-1]}" | sed -n 's/^FAIL (\([0-9]*\) error(s))$/\1/p')"
  [ -n "$n" ]
  [ "$fails" -eq "$n" ]
  [[ "$output" != *"FAIL capacity"* ]]
}
