#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/capacity.bats — #743: the capacity reader. scripts/capacity.sh resolves and
# validates the [capacity] and [project.<name>.capacity] tables into a JSON document;
# scripts/lib/capacity.py owns every rule, the document and the message text.
# The doctor section that reports it is tests/doctor-capacity.bats.
bats_require_minimum_version 1.5.0   # run --separate-stderr: stdout and stderr are both pinned

load 'lib/bats-helpers'
load 'lib/capacity-fixture'

setup() {
  setup_tmp_devagent_home
  CAP="$PLUGIN_ROOT/scripts/capacity.sh"
  CAPPY="$PLUGIN_ROOT/scripts/lib/capacity.py"
  CFG="$DA_HOME/config.toml"
}

teardown() { teardown_tmp_devagent_home; }

# _door <n> [project...] — door 1 is the entry point (capacity.sh), door 2 the helper
# called directly (capacity.py resolve <config> [project...]).
_door() {
  local n="$1"; shift
  if [[ "$n" == 1 ]]; then
    run --separate-stderr "$CAP"
  else
    run --separate-stderr python3 "$CAPPY" resolve "$CFG" "$@"
  fi
}

# --- Task 1: entry point, exits 2 and 4, the not-declared document ---

@test "usage: an argument exits 2 with the usage line" {
  local arg
  for arg in extra --json; do
    run --separate-stderr "$CAP" "$arg"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [ "$stderr" = "capacity: unexpected argument '$arg' (usage: capacity.sh)" ]
  done
}

@test "usage: --help exits 0" {
  local arg
  for arg in --help -h; do
    run --separate-stderr "$CAP" "$arg"
    [ "$status" -eq 0 ]
    [ "$output" = "usage: capacity.sh" ]
    [ -z "$stderr" ]
  done
}

@test "config: a missing config exits 4" {
  local d
  for d in 1 2; do
    _door "$d"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    [ "$stderr" = "capacity: config not readable: $CFG" ]
  done
}

@test "config: invalid TOML exits 4" {
  install_fixture_config config-malformed.toml
  local d
  for d in 1 2; do
    _door "$d"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    [ "$stderr" = "capacity: config is not valid TOML: $CFG" ]
  done
}

@test "config: an integer past the conversion limit exits 4" {
  local big
  big="$(printf '9%.0s' {1..5000})"
  cap_config <<TOML
[capacity]
tokens_per_week = $big
TOML
  local d
  for d in 1 2; do
    _door "$d"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    [ "$stderr" = "capacity: config is not valid TOML: $CFG" ]
  done
}

@test "not declared: exit 0, declared false, projects at defaults" {
  cap_config </dev/null
  cap_projects alpha beta
  local d k
  for d in 1 2; do
    _door "$d" alpha beta
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    jq -e '.declared == false and .shared == null and .effective_tokens_per_week == null' <<<"$output"
    jq -e '[.projects[].name] == ["alpha","beta"]' <<<"$output"
    jq -e 'all(.projects[]; .priority == {"value":5,"source":"default"} and .paused.value == false)' <<<"$output"
    for k in max_lanes deadline reserve_operator_hours_per_week reserve_tokens_per_week; do
      jq -e --arg k "$k" 'all(.projects[]; .[$k] == {"value":null,"source":"default"})' <<<"$output"
    done
  done
  # One LF at the end, no CR anywhere (the stream setup of _toml.py:344-353).
  "$CAP" >"$BATS_TEST_TMPDIR/out"
  [ "$(tail -c 1 "$BATS_TEST_TMPDIR/out" | od -An -c | tr -d ' ')" = '\n' ]
  [ "$(tail -c 2 "$BATS_TEST_TMPDIR/out" | od -An -c | tr -d ' ')" = '}\n' ]
  ! grep -q $'\r' "$BATS_TEST_TMPDIR/out"
}

@test "not declared: no projects gives an empty list" {
  cap_config </dev/null
  local d
  for d in 1 2; do
    _door "$d"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    jq -e '.projects == [] and .declared == false' <<<"$output"
  done
}
