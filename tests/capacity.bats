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
# called directly (capacity.py resolve <config> [project...]). Sets DOOR_CFG to the config
# path that door prints. Door 2 runs from $DA_HOME with the relative path: Git Bash
# (MSYS) rewrites an absolute /tmp/... argument to a native program into C:/..., so an
# absolute path would print in a form the test cannot predict.
_door() {
  local n="$1"; shift
  if [[ "$n" == 1 ]]; then
    DOOR_CFG="$CFG"
    run --separate-stderr "$CAP"
  else
    DOOR_CFG="config.toml"
    cd "$DA_HOME"
    run --separate-stderr python3 "$CAPPY" resolve config.toml "$@"
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
    [ "$stderr" = "capacity: config not readable: $DOOR_CFG" ]
  done
}

@test "config: invalid TOML exits 4" {
  install_fixture_config config-malformed.toml
  local d
  for d in 1 2; do
    _door "$d"
    [ "$status" -eq 4 ]
    [ -z "$output" ]
    [ "$stderr" = "capacity: config is not valid TOML: $DOOR_CFG" ]
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
    [ "$stderr" = "capacity: config is not valid TOML: $DOOR_CFG" ]
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
_full() { install_fixture_config capacity/full.toml; }

@test "resolve: the full fixture equals the golden" {
  _full
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/doc.json"
  jq -n -e --slurpfile a "$BATS_TEST_TMPDIR/doc.json" \
    --slurpfile b "$(fixtures_dir)/capacity/full.expected.json" '$a[0] == $b[0]'
  jq -e '.projects[] | select(.name == "gamma") | [to_entries[] | select(.key != "name") | .value.source] | length == 6 and all(. == "default")' <<<"$output"
}

@test "resolve: twelve projects and a pool of three are each uncapped at priority 5" {
  cap_config </dev/null
  cap_shared
  cap_projects p01 p02 p03 p04 p05 p06 p07 p08 p09 p10 p11 p12
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

# --- Task 3: key-local violations ---

# _expect3 <stderr> — the reader exits 3 with an empty stdout and exactly this stderr.
_expect3() {
  run --separate-stderr "$CAP"
  [ "$status" -eq 3 ] || { printf 'want status 3, got %s; stderr:\n%s\n' "$status" "$stderr" >&2; return 1; }
  [ -z "$output" ]
  [ "$stderr" = "$1" ] || { printf 'want stderr:\n%s\ngot:\n%s\n' "$1" "$stderr" >&2; return 1; }
}

# _expect0 — the reader exits 0 with an empty stderr.
_expect0() {
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ] || { printf 'want status 0, got %s; stderr:\n%s\n' "$status" "$stderr" >&2; return 1; }
  [ -z "$stderr" ]
}

# _shared [cap_shared args] — a fresh config holding only the [capacity] table.
_shared() { cap_config </dev/null; cap_shared "$@"; }

# _alpha <toml line>... — a fresh config: a valid [capacity] table and project alpha
# whose capacity table holds the given lines.
_alpha() {
  _shared
  cap_projects alpha
  cap_table alpha "$@"
}

@test "violation: missing required key" {
  local k
  for k in operator_hours_per_week lane_hours_per_week max_lanes tokens_per_week tokens_per_window windows_per_week; do
    _shared "-$k"
    _expect3 "capacity: capacity.$k: missing required key"
  done
}

@test "violation: wrong type: expected number" {
  _shared operator_hours_per_week=true
  _expect3 "capacity: capacity.operator_hours_per_week: wrong type: expected number"
  _shared 'operator_hours_per_week="20"'
  _expect3 "capacity: capacity.operator_hours_per_week: wrong type: expected number"
}

@test "violation: wrong type: expected integer" {
  _shared max_lanes=3.0
  _expect3 "capacity: capacity.max_lanes: wrong type: expected integer"
  _shared max_lanes=true
  _expect3 "capacity: capacity.max_lanes: wrong type: expected integer"
  _shared 'tokens_per_week="1"'
  _expect3 "capacity: capacity.tokens_per_week: wrong type: expected integer"
  _alpha 'priority = 1.5'
  _expect3 "capacity: project.alpha.capacity.priority: wrong type: expected integer"
}

@test "violation: wrong type: expected boolean" {
  _alpha 'paused = "yes"'
  _expect3 "capacity: project.alpha.capacity.paused: wrong type: expected boolean"
  _alpha 'paused = 1'
  _expect3 "capacity: project.alpha.capacity.paused: wrong type: expected boolean"
}

@test "violation: wrong type: expected date" {
  local v
  for v in 20261231 2026-12-31T00:00:00 true; do
    _alpha "deadline = $v"
    _expect3 "capacity: project.alpha.capacity.deadline: wrong type: expected date"
  done
}

@test "violation: wrong type: expected table" {
  cap_config_raw <<TOML
capacity = 5

[defaults]

[project.alpha]
source_dir = "$BATS_TEST_TMPDIR/alpha"

[project.alpha.capacity]
priority = 2
TOML
  _expect3 "capacity: capacity: wrong type: expected table"
  _shared
  cap_append <<TOML
[project.alpha]
source_dir = "$BATS_TEST_TMPDIR/alpha"
capacity = "x"
TOML
  _expect3 "capacity: project.alpha.capacity: wrong type: expected table"
}

@test "violation: out of range: 0 < x <= 168" {
  local v
  for v in 0 168.5 -1; do
    _shared "operator_hours_per_week=$v"
    _expect3 "capacity: capacity.operator_hours_per_week: out of range: 0 < x <= 168"
  done
  _shared lane_hours_per_week=169
  _expect3 "capacity: capacity.lane_hours_per_week: out of range: 0 < x <= 168"
  for v in 168 0.5; do
    _shared "operator_hours_per_week=$v" "lane_hours_per_week=$v"
    _expect0
  done
}

@test "violation: out of range: 1 <= x <= 9007199254740991" {
  _shared max_lanes=0
  _expect3 "capacity: capacity.max_lanes: out of range: 1 <= x <= 9007199254740991"
  _alpha 'priority = 0'
  _expect3 "capacity: project.alpha.capacity.priority: out of range: 1 <= x <= 9007199254740991"
  _alpha 'max_lanes = 0'
  _expect3 "capacity: project.alpha.capacity.max_lanes: out of range: 1 <= x <= 9007199254740991"
  _alpha 'priority = 9007199254740992'
  _expect3 "capacity: project.alpha.capacity.priority: out of range: 1 <= x <= 9007199254740991"
  _shared max_lanes=9007199254740991
  cap_projects alpha
  _expect0
}

@test "violation: out of range: 0 < x <= 9007199254740991" {
  _shared tokens_per_week=0
  _expect3 "capacity: capacity.tokens_per_week: out of range: 0 < x <= 9007199254740991"
  _shared tokens_per_window=-1
  _expect3 "capacity: capacity.tokens_per_window: out of range: 0 < x <= 9007199254740991"
  _shared tokens_per_week=9007199254740992
  _expect3 "capacity: capacity.tokens_per_week: out of range: 0 < x <= 9007199254740991"
  _shared tokens_per_week=9007199254740991
  _expect0
}

@test "violation: out of range: 0 < x <= 33.6" {
  local v
  for v in 0 33.7; do
    _shared "windows_per_week=$v"
    _expect3 "capacity: capacity.windows_per_week: out of range: 0 < x <= 33.6"
  done
  _shared windows_per_week=33.6
  _expect0
}

@test "violation: out of range: 0 <= x <= 9007199254740991" {
  local r='out of range: 0 <= x <= 9007199254740991'
  _alpha 'reserve_operator_hours_per_week = -0.5'
  _expect3 "capacity: project.alpha.capacity.reserve_operator_hours_per_week: $r"
  _alpha 'reserve_tokens_per_week = -1'
  _expect3 "capacity: project.alpha.capacity.reserve_tokens_per_week: $r"
  _shared operator_hours_per_agent_hour=-0.1
  _expect3 "capacity: capacity.operator_hours_per_agent_hour: $r"
  _shared operator_hours_per_agent_hour=1e300
  _expect3 "capacity: capacity.operator_hours_per_agent_hour: $r"
  _alpha 'reserve_operator_hours_per_week = 0' 'reserve_tokens_per_week = 0'
  _expect0
  _shared operator_hours_per_agent_hour=0
  _expect0
}

@test "violation: a non-finite number is out of range" {
  _shared operator_hours_per_agent_hour=inf
  _expect3 "capacity: capacity.operator_hours_per_agent_hour: out of range: 0 <= x <= 9007199254740991"
  _alpha 'reserve_operator_hours_per_week = nan'
  _expect3 "capacity: project.alpha.capacity.reserve_operator_hours_per_week: out of range: 0 <= x <= 9007199254740991"
  _shared windows_per_week=nan
  _expect3 "capacity: capacity.windows_per_week: out of range: 0 < x <= 33.6"
}

@test "violation: a 400-digit integer is out of range, never a crash" {
  local big
  big="$(printf '9%.0s' {1..400})"
  _shared "tokens_per_window=$big" windows_per_week=5.5
  _expect3 "capacity: capacity.tokens_per_window: out of range: 0 < x <= 9007199254740991"
  _alpha "reserve_operator_hours_per_week = $big"
  _expect3 "capacity: project.alpha.capacity.reserve_operator_hours_per_week: out of range: 0 <= x <= 9007199254740991"
}

@test "violation: not a calendar date" {
  local v
  for v in '"2026-02-30"' '"2026-2-3"' '"next friday"' '"２０２６-１２-３１"'; do
    _alpha "deadline = $v"
    _expect3 "capacity: project.alpha.capacity.deadline: not a calendar date"
  done
  for v in '"2026-12-31"' 2026-12-31; do
    _alpha "deadline = $v"
    _expect0
    jq -e '.projects[0].deadline == {"value":"2026-12-31","source":"config"}' <<<"$output"
  done
}

@test "violation: [capacity] table missing" {
  cap_config </dev/null
  cap_projects alpha beta
  printf '[project.alpha.capacity]\npriority = 2\n' | cap_append
  _expect3 "capacity: project.alpha.capacity: [capacity] table missing"
  printf '[project.beta.capacity]\npriority = 0\n' | cap_append
  _expect3 "capacity: project.alpha.capacity: [capacity] table missing
capacity: project.beta.capacity: [capacity] table missing
capacity: project.beta.capacity.priority: out of range: 1 <= x <= 9007199254740991"
}

@test "where: a project name TOML must quote is a JSON string" {
  _shared
  cap_append <<TOML
[project."my proj"]
source_dir = "$BATS_TEST_TMPDIR/my proj"

[project."my proj".capacity]
priority = 0
TOML
  _expect3 'capacity: project."my proj".capacity.priority: out of range: 1 <= x <= 9007199254740991'
}

# --- Task 4: pool rules, paused, order, suppression, sums, warnings ---

HOURS_POOL='capacity: pool: reserve_operator_hours_per_week sum exceeds capacity.operator_hours_per_week'
TOKENS_POOL='capacity: pool: reserve_tokens_per_week sum exceeds the effective weekly token budget'

# _reserving <shared args> -- <project>=<hours> ... — a fresh config: [capacity] from the
# shared args, then one project per pair (in that file order) reserving those hours.
_reserving() {
  local shared=() pair
  while [[ $# -gt 0 && "$1" != -- ]]; do shared+=("$1"); shift; done
  shift
  _shared ${shared[@]+"${shared[@]}"}
  for pair in "$@"; do
    cap_projects "${pair%%=*}"
    cap_table "${pair%%=*}" "reserve_operator_hours_per_week = ${pair#*=}"
  done
}

@test "pool: a project cap exceeds capacity.max_lanes" {
  _alpha 'max_lanes = 4'
  _expect3 "capacity: project.alpha.capacity.max_lanes: exceeds capacity.max_lanes"
  _alpha 'max_lanes = 4' 'paused = true'
  _expect3 "capacity: project.alpha.capacity.max_lanes: exceeds capacity.max_lanes"
  _alpha 'max_lanes = 3'
  _expect0
}

@test "pool: the operator-hours reservations exceed the shared value" {
  _reserving -- alpha=12.5 beta=8
  _expect3 "$HOURS_POOL"
  _reserving -- alpha=12 beta=8
  _expect0
}

@test "pool: the token reservations exceed the effective budget" {
  _shared windows_per_week=5.5
  cap_projects alpha beta
  cap_table alpha 'reserve_tokens_per_week = 200000000'
  cap_table beta 'reserve_tokens_per_week = 200000000'
  _expect3 "$TOKENS_POOL"
  _shared windows_per_week=5.5
  cap_projects alpha beta
  cap_table alpha 'reserve_tokens_per_week = 165000000'
  cap_table beta 'reserve_tokens_per_week = 165000000'
  _expect0
}

@test "paused: a paused project resolves paused and leaves the pool sums" {
  local p
  for p in true false; do
    _shared
    cap_projects alpha beta
    cap_table alpha 'reserve_operator_hours_per_week = 15' 'reserve_tokens_per_week = 300000000'
    cap_table beta 'reserve_operator_hours_per_week = 15' 'reserve_tokens_per_week = 300000000' "paused = $p"
    if [[ "$p" == true ]]; then
      _expect0
      jq -e '.projects[1].name == "beta" and .projects[1].paused == {"value":true,"source":"config"}' <<<"$output"
    else
      _expect3 "$HOURS_POOL
$TOKENS_POOL"
    fi
  done
}

@test "sums: hours reservations add left to right and compare within 1e-9" {
  _reserving -- a=4.4 b=11.8 c=3.8
  _expect0
  _reserving -- c=3.8 b=11.8 a=4.4
  _expect0
  _reserving operator_hours_per_week=0.6 -- a=0.1 b=0.2 c=0.3
  _expect0
  _reserving operator_hours_per_week=0.6 -- c=0.3 b=0.2 a=0.1
  _expect0
  _reserving -- a=10 b=10.000001
  _expect3 "$HOURS_POOL"
}

@test "order: shared keys, then projects in config order, then pool" {
  _shared lane_hours_per_week=0
  cap_projects beta alpha
  cap_table beta 'priority = 0' 'reserve_tokens_per_week = 300000000'
  cap_table alpha 'priority = 0' 'reserve_tokens_per_week = 300000000'
  _expect3 "capacity: capacity.lane_hours_per_week: out of range: 0 < x <= 168
capacity: project.beta.capacity.priority: out of range: 1 <= x <= 9007199254740991
capacity: project.alpha.capacity.priority: out of range: 1 <= x <= 9007199254740991
$TOKENS_POOL"
}

@test "suppression: a rule that would read an invalid value is skipped" {
  _shared -operator_hours_per_week 'max_lanes="three"'
  cap_projects alpha
  cap_table alpha 'max_lanes = 9' 'reserve_operator_hours_per_week = 50' 'reserve_tokens_per_week = 600000000'
  _expect3 "capacity: capacity.operator_hours_per_week: missing required key
capacity: capacity.max_lanes: wrong type: expected integer
$TOKENS_POOL"
}

@test "warning: an unknown key in [capacity]" {
  _shared max_lane=3
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  [ "$stderr" = "capacity: warning: capacity.max_lane: unknown key (ignored)" ]
  jq -e '.shared | has("max_lane") | not' <<<"$output"
}

@test "warning: an unknown key in a project table" {
  _alpha 'priorty = 2'
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  [ "$stderr" = "capacity: warning: project.alpha.capacity.priorty: unknown key (ignored)" ]
  jq -e '.projects[0].priority.source == "default"' <<<"$output"
}

@test "warning: a project whose only key is capacity" {
  _shared
  printf '[project.alphaa.capacity]\npriority = 2\n' | cap_append
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  [ "$stderr" = "capacity: warning: project.alphaa: only key is capacity (misspelled project name?)" ]
  jq -e '[.projects[].name] | index("alphaa") != null' <<<"$output"
}

@test "warning: warnings follow violations and leave exit 3" {
  _shared -max_lanes max_lane=3
  _expect3 "capacity: capacity.max_lanes: missing required key
capacity: warning: capacity.max_lane: unknown key (ignored)"
}

@test "suppression: a project capacity that is not a table leaves the pool rules running" {
  _shared
  cap_projects alpha
  cap_table alpha 'reserve_operator_hours_per_week = 25'
  cap_append <<TOML
[project.beta]
source_dir = "$BATS_TEST_TMPDIR/beta"
capacity = "x"
TOML
  _expect3 "capacity: project.beta.capacity: wrong type: expected table
$HOURS_POOL"
}

@test "warning: a key with a newline is escaped on one line" {
  _shared '"max_lane\n"=3'
  run --separate-stderr "$CAP"
  [ "$status" -eq 0 ]
  [ "$stderr" = 'capacity: warning: capacity."max_lane\n": unknown key (ignored)' ]
  "$CAP" 2>"$BATS_TEST_TMPDIR/err" >/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/err")" -eq 1 ]
}

# --- Task 6: documentation and its guards ---

DOC_HOMES=(templates/config.toml.skel docs/configuration.md docs/specs/2026-05-19-devagent-plugin-design.md)

# _capacity_section — docs/configuration.md from "## Capacity" to the next "## " heading.
_capacity_section() {
  awk '/^## Capacity$/ { on = 1; print; next } on && /^## / { exit } on { print }' \
    "$PLUGIN_ROOT/docs/configuration.md"
}

# _states_limit_size <line> — THE predicate for "a shipped line states a size for the
# subscription's limits": the line names the limits AND carries a size (a number with a
# magnitude word or a token unit). Blind spots: a size on a line without the vocabulary
# (the vocabulary on the line before), and a bare number with neither a magnitude word
# nor a token unit. Review covers those.
_states_limit_size() {
  printf '%s\n' "$1" | grep -qiE 'subscription|usage limit|five-hour|5-hour|weekly cap' || return 1
  printf '%s\n' "$1" | grep -qiE '[0-9][0-9_,.]*[[:space:]]*((k|m|b|thousand|million|billion)([^_[:alnum:]]|$)|(weighted[[:space:]]+)?(input[- ])?tokens?([^_[:alnum:]]|$))'
}

@test "docs: configuration.md lists every rule string, type, range and warning" {
  local section
  section="$(_capacity_section)"
  local pins=(
    'missing required key'
    'wrong type: expected number'
    'wrong type: expected integer'
    'wrong type: expected boolean'
    'wrong type: expected date'
    'wrong type: expected table'
    'out of range: 0 < x <= 168'
    'out of range: 1 <= x <= 9007199254740991'
    'out of range: 0 < x <= 9007199254740991'
    'out of range: 0 < x <= 33.6'
    'out of range: 0 <= x <= 9007199254740991'
    'not a calendar date'
    'exceeds capacity.max_lanes'
    'reserve_operator_hours_per_week sum exceeds capacity.operator_hours_per_week'
    'reserve_tokens_per_week sum exceeds the effective weekly token budget'
    '[capacity] table missing'
    'capacity: warning: <path of the key>: unknown key (ignored)'
    'capacity: warning: project.<name>: only key is capacity (misspelled project name?)'
    'capacity: config not readable: <path>'
    'capacity: config is not valid TOML: <path>'
    'capacity: cannot list projects: <path>'
    '`capacity_schema`'
    '`declared`'
    '`token_unit`'
    '`shared`'
    '`effective_tokens_per_week`'
    '`projects`'
    '`tokens_per_week`'
    '`tokens_per_window_x_windows_per_week`'
    '`"1.0"`'
    'weighted_input_token_equivalents'
  )
  [ "${#pins[@]}" -eq 31 ]
  local p missing=()
  for p in "${pins[@]}"; do
    grep -qF -- "$p" <<<"$section" || missing+=("$p")
  done
  [ "${#missing[@]}" -eq 0 ] || { printf 'not in ## Capacity: %s\n' "${missing[@]}" >&2; false; }
}

@test "docs: every example value is marked, in all three homes" {
  local home keys
  for home in "${DOC_HOMES[@]}"; do
    keys="$(cap_doc_tables "$PLUGIN_ROOT/$home" | grep '=')" || { echo "no tables in $home" >&2; false; }
    [ "$(wc -l <<<"$keys")" -eq 13 ] || { printf '%s: %s key lines\n' "$home" "$(wc -l <<<"$keys")" >&2; false; }
    ! grep -v '# example' <<<"$keys" || { echo "unmarked example line in $home" >&2; false; }
  done
}

@test "docs: the example tables, uncommented, are a declaration capacity.sh accepts" {
  local home
  for home in "${DOC_HOMES[@]}"; do
    cap_config </dev/null
    cap_projects alpha
    cap_doc_tables "$PLUGIN_ROOT/$home" \
      | sed -E 's/^\[project\.[^]]*\.capacity\]/[project.alpha.capacity]/' | cap_append
    run --separate-stderr "$CAP"
    [ "$status" -eq 0 ] || { printf '%s: status %s\n%s\n' "$home" "$status" "$stderr" >&2; false; }
    [ -z "$stderr" ]
    jq -e '.declared == true' <<<"$output"
    jq -e '.projects[0].name == "alpha" and .projects[0].priority.source == "config"' <<<"$output"
  done
}

@test "docs: the disclaimer, the priority rule and the optional key are stated" {
  local home
  for home in "${DOC_HOMES[@]}"; do
    grep -qF "devagent does not know the subscription's limits" "$PLUGIN_ROOT/$home" \
      || { echo "no disclaimer in $home" >&2; false; }
    # The issue's API section: the token numbers are the operator's own declaration.
    grep -qF "the token numbers are the operator's own" "$PLUGIN_ROOT/$home" \
      || { echo "no operator's-own sentence in $home" >&2; false; }
  done
  for home in docs/configuration.md docs/specs/2026-05-19-devagent-plugin-design.md; do
    grep -qF 'ties go to the project holding fewer lanes, then by name' "$PLUGIN_ROOT/$home" \
      || { echo "no tie rule in $home" >&2; false; }
    grep -qF 'weight 1/priority' "$PLUGIN_ROOT/$home" || { echo "no weight rule in $home" >&2; false; }
    grep -qF 'every key except `operator_hours_per_agent_hour` is required' "$PLUGIN_ROOT/$home" \
      || { echo "no optional-key line in $home" >&2; false; }
  done
}

@test "docs: no shipped file states a size for the subscription's limits" {
  # The predicate trips on each planted sentence...
  local s
  for s in 'the weekly cap is 500M tokens' \
           'a five-hour window holds 220,000 tokens' \
           'the weekly cap is 500M weighted input tokens' \
           'the weekly cap is about 500 million.' \
           'the five-hour window is 220k' \
           'the weekly cap is 500000000 weighted input-token equivalents'; do
    _states_limit_size "$s" || { echo "predicate missed: $s" >&2; false; }
  done
  # ...and not on the shipped controls: the disclaimer and the skeleton's
  # tokens_per_window example line.
  local ctl
  # (`[ ] && ! pred` cannot fail a bats test away from its last line: errexit ignores both.)
  ctl="$(grep -m1 -F "devagent does not know the subscription's limits" "$PLUGIN_ROOT/templates/config.toml.skel")"
  [ -n "$ctl" ]
  if _states_limit_size "$ctl"; then echo "control tripped: $ctl" >&2; false; fi
  ctl="$(grep -m1 -E '^# tokens_per_window[[:space:]]*=' "$PLUGIN_ROOT/templates/config.toml.skel")"
  [ -n "$ctl" ]
  if _states_limit_size "$ctl"; then echo "control tripped: $ctl" >&2; false; fi
  # The tracked set (#566), this file excluded: it holds the planted sentences.
  local subjects=0 offenders=() line text
  while IFS= read -r line; do
    subjects=$((subjects + 1))
    text="${line#*:}"; text="${text#*:}"
    _states_limit_size "$text" && offenders+=("$line")
  done < <(git -C "$PLUGIN_ROOT" grep -n -I -i -E 'subscription|usage limit|five-hour|5-hour|weekly cap' \
             -- . ':!tests/capacity.bats')
  [ "$subjects" -ge 3 ] || { echo "only $subjects subject line(s): the disclaimers are missing" >&2; false; }
  [ "${#offenders[@]}" -eq 0 ] || { printf 'states a size: %s\n' "${offenders[@]}" >&2; false; }
}

@test "docs: commands/doctor.md names the reader and its lines" {
  local p
  for p in 'scripts/capacity.sh' '[capacity]' 'not declared (forecasting off)' 'reader failed (exit'; do
    grep -qF -- "$p" "$PLUGIN_ROOT/commands/doctor.md" || { echo "commands/doctor.md lacks: $p" >&2; false; }
  done
}
