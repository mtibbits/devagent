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

# --- Task 2: declared resolution, the contract test, the summary verb ---

# _full — install the full fixture (all keys declared) as the config.
_full() { cp "$PLUGIN_ROOT/tests/fixtures/capacity/full.toml" "$CFG"; }

@test "resolve: the full fixture equals the golden" {
  _full
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/doc.json"
  jq -n -e --slurpfile a "$BATS_TEST_TMPDIR/doc.json" \
    --slurpfile b "$PLUGIN_ROOT/tests/fixtures/capacity/full.expected.json" '$a[0] == $b[0]'
  jq -e '.projects[] | select(.name == "gamma") | [to_entries[] | select(.key != "name") | .value.source] | length == 6 and all(. == "default")' <<<"$output"
}

@test "resolve: twelve projects and a pool of three are each uncapped at priority 5" {
  cap_config </dev/null
  cap_shared
  cap_healthy_projects 12
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  jq -e '.projects | length == 12' <<<"$output"
  jq -e 'all(.projects[]; .max_lanes.value == null and .priority.value == 5 and .priority.source == "default")' <<<"$output"
  jq -e '.shared.max_lanes.value == 3' <<<"$output"
}

@test "binding: tokens_per_week is the smaller term, and wins a tie" {
  cap_config </dev/null
  cap_shared
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  jq -e '.effective_tokens_per_week == {"value":500000000,"binding":"tokens_per_week"}' <<<"$output"
  cap_config </dev/null
  cap_shared tokens_per_week=600000000   # 60000000 x 10: a tie
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  jq -e '.effective_tokens_per_week == {"value":600000000,"binding":"tokens_per_week"}' <<<"$output"
}

@test "binding: the window product is the smaller term" {
  cap_config </dev/null
  cap_shared windows_per_week=5.5
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  jq -e '.effective_tokens_per_week.value == 330000000' <<<"$output"
  jq -e '.effective_tokens_per_week.binding == "tokens_per_window_x_windows_per_week"' <<<"$output"
}

@test "contract: field names, capacity_schema and token_unit" {
  local top='["capacity_schema","declared","effective_tokens_per_week","projects","shared","token_unit"]'
  local proj='[["deadline","max_lanes","name","paused","priority","reserve_operator_hours_per_week","reserve_tokens_per_week"]]'
  # The declared form.
  _full
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  jq -e --argjson t "$top" 'keys == $t' <<<"$output"
  jq -e '.shared | keys == ["lane_hours_per_week","max_lanes","operator_hours_per_agent_hour","operator_hours_per_week","tokens_per_week","tokens_per_window","windows_per_week"]' <<<"$output"
  jq -e '[.shared[] | keys] | unique == [["source","value"]]' <<<"$output"
  jq -e '.effective_tokens_per_week | keys == ["binding","value"]' <<<"$output"
  jq -e --argjson p "$proj" '[.projects[] | keys] | unique == $p' <<<"$output"
  jq -e '[(.shared[] | .source), (.projects[] | to_entries[] | select(.key != "name") | .value.source)] | unique == ["config","default"]' <<<"$output"
  jq -e '[.projects[] | to_entries[] | select(.key != "name") | .value | keys] | unique == [["source","value"]]' <<<"$output"
  jq -e '.capacity_schema == "1.0" and .token_unit == "weighted_input_token_equivalents"' <<<"$output"
  # The not-declared form: the same top level; every source is one of the two values.
  cap_config </dev/null
  cap_projects alpha
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  jq -e --argjson t "$top" 'keys == $t' <<<"$output"
  jq -e --argjson p "$proj" '[.projects[] | keys] | unique == $p' <<<"$output"
  jq -e '[.projects[] | to_entries[] | select(.key != "name") | .value.source] | unique - ["config","default"] == []' <<<"$output"
  jq -e '.capacity_schema == "1.0" and .token_unit == "weighted_input_token_equivalents"' <<<"$output"
}

@test "summary: the declared line" {
  cap_config </dev/null
  cap_shared
  "$CAP" >"$BATS_TEST_TMPDIR/doc.json"
  run --separate-stderr python3 "$CAPPY" summary <"$BATS_TEST_TMPDIR/doc.json"
  [ "$status" -eq 0 ]
  [ "$output" = "20 operator h/week, pool of 3 lanes, 500000000 weighted tokens/week (tokens_per_week)" ]
}

@test "summary: an integral float prints with no fraction" {
  cap_config </dev/null
  cap_shared windows_per_week=5.5 operator_hours_per_week=17.5
  "$CAP" >"$BATS_TEST_TMPDIR/doc.json"
  run --separate-stderr python3 "$CAPPY" summary <"$BATS_TEST_TMPDIR/doc.json"
  [ "$status" -eq 0 ]
  [ "$output" = "17.5 operator h/week, pool of 3 lanes, 330000000 weighted tokens/week (tokens_per_window_x_windows_per_week)" ]
}

@test "summary: the not-declared line" {
  cap_config </dev/null
  "$CAP" >"$BATS_TEST_TMPDIR/doc.json"
  run --separate-stderr python3 "$CAPPY" summary <"$BATS_TEST_TMPDIR/doc.json"
  [ "$status" -eq 0 ]
  [ "$output" = "not declared (forecasting off)" ]
}

@test "summary: anything but a capacity document exits 1" {
  cap_config </dev/null
  cap_shared
  "$CAP" | jq '.capacity_schema = "2.0"' >"$BATS_TEST_TMPDIR/v2.json"
  local input
  for input in '' 'null' '[]' '{"declared":"no"}' "$(cat "$BATS_TEST_TMPDIR/v2.json")"; do
    run --separate-stderr python3 "$CAPPY" summary <<<"$input"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  # Control: the same document at major 1 is accepted.
  run --separate-stderr python3 "$CAPPY" summary < <(jq '.capacity_schema = "1.0"' "$BATS_TEST_TMPDIR/v2.json")
  [ "$status" -eq 0 ]
}
