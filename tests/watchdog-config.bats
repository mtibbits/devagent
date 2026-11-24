#!/usr/bin/env bats
# tests/watchdog-config.bats — #932: scripts/lib/watchdog-limits.sh (the limit
# resolver, the --silent window grammar, the --since time) and doctor's
# check_watchdog over the same keys.

bats_require_minimum_version 1.5.0   # run --separate-stderr: the resolver prints nothing

load 'lib/bats-helpers'
load 'lib/doctor-harness'

setup() {
  setup_tmp_devagent_home
  seed_doctor_project
  stub_claude_cli enabled
}
teardown() { teardown_tmp_devagent_home; }

# write_cfg <[defaults] lines> <[project.volk] lines> [<text after the tables>]
# The seeded doctor fixture with extra keys; the project keeps its state file.
write_cfg() {
  cat > "$DA_HOME/config.toml" <<TOML
[defaults]
checklist_template = "standard"
${1:-}

[project.volk]
source_dir = "$DA_HOME/fake-src"
devdoc_dir = "$DA_HOME/fake-devdoc"
default_baseline = "origin/main"
${2:-}

[project.volk.issue_source]
backend    = "github"
repo       = "gnuradio/volk"
dir_prefix = "Issue-"

[project.volk.code_source]
backend  = "github"
upstream = "gnuradio/volk"
fork     = "mtibbits/volk"
${3:-}
TOML
}

# lim <bash text> — run it under -euo pipefail with the libs sourced; the text
# ends by echoing what the test reads. stdout only: the library prints nothing.
lim() {
  run --separate-stderr bash -euo pipefail -c '
    source "$1/scripts/lib/paths.sh"
    source "$1/scripts/lib/io.sh"
    source "$1/scripts/lib/config.sh"
    source "$1/scripts/lib/watchdog-limits.sh"
    eval "$2"
  ' _ "$PLUGIN_ROOT" "$1"
}

# limit <key> [<project>] [<timeout>] — one "rc=<rc> <value> <source>" line.
limit() {
  lim "rc=0; watchdog_limit $* || rc=\$?; echo \"rc=\$rc \${WATCHDOG_LIMIT:--} \${WATCHDOG_LIMIT_SRC:--}\""
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# window <text> [<project>] [<maximum>] — "rc=<rc> <secs>" then the refusal text.
window() {
  lim "rc=0; watchdog_window '$1' ${2:-''} ${3:-''} || rc=\$?; echo \"rc=\$rc \${WATCHDOG_WINDOW_SECS:--}\"; echo \"\$WATCHDOG_WINDOW_ERR\""
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# since <text> — "rc=<rc> <epoch>".
since() {
  lim "rc=0; watchdog_parse_since '$1' || rc=\$?; echo \"rc=\$rc \${WATCHDOG_SINCE_EPOCH:--}\""
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

doctor() { run "$PLUGIN_ROOT/scripts/doctor.sh" "$@"; }

@test "shipped defaults are 1200, 180 and 3600 seconds" {
  # The pin for 20 min no-progress, 3 min telemetry, 60 min silent-window maximum.
  lim 'echo "$WATCHDOG_DEFAULT_NO_PROGRESS_SECS $WATCHDOG_DEFAULT_TELEMETRY_SECS $WATCHDOG_DEFAULT_SILENT_MAX_SECS"'
  [ "$output" = "1200 180 3600" ]
  [ "$((20 * 60)) $((3 * 60)) $((60 * 60))" = "1200 180 3600" ]
  limit watchdog_no_progress_secs volk; [ "$output" = "rc=0 1200 constant" ]
  limit watchdog_telemetry_secs volk;   [ "$output" = "rc=0 180 constant" ]
  limit watchdog_silent_max_secs volk;  [ "$output" = "rc=0 3600 constant" ]
  limit watchdog_no_progress_secs;      [ "$output" = "rc=0 1200 constant" ]
}

@test "[defaults] overrides each constant" {
  write_cfg $'watchdog_no_progress_secs = 900\nwatchdog_telemetry_secs = 60\nwatchdog_silent_max_secs = 7200'
  limit watchdog_no_progress_secs volk; [ "$output" = "rc=0 900 defaults" ]
  limit watchdog_telemetry_secs volk;   [ "$output" = "rc=0 60 defaults" ]
  limit watchdog_silent_max_secs volk;  [ "$output" = "rc=0 7200 defaults" ]
  limit watchdog_telemetry_secs;        [ "$output" = "rc=0 60 defaults" ]
}

@test "a project overrides the limit, the interval and analyze_silent_secs" {
  write_cfg $'watchdog_no_progress_secs = 900\nwatchdog_telemetry_secs = 60\nanalyze_silent_secs = 300' \
            $'watchdog_no_progress_secs = 2400\nwatchdog_telemetry_secs = 30\nanalyze_silent_secs = 600'
  limit watchdog_no_progress_secs volk; [ "$output" = "rc=0 2400 project" ]
  limit watchdog_telemetry_secs volk;   [ "$output" = "rc=0 30 project" ]
  limit analyze_silent_secs volk;       [ "$output" = "rc=0 600 project" ]
  # Another project, and no project, read [defaults].
  limit watchdog_no_progress_secs other; [ "$output" = "rc=0 900 defaults" ]
  limit analyze_silent_secs;             [ "$output" = "rc=0 300 defaults" ]
}

@test "a quoted integer and the range ends 1 and 604800 resolve" {
  write_cfg $'watchdog_no_progress_secs = "900"\nwatchdog_telemetry_secs = 1\nwatchdog_silent_max_secs = 604800'
  limit watchdog_no_progress_secs; [ "$output" = "rc=0 900 defaults" ]
  limit watchdog_telemetry_secs;   [ "$output" = "rc=0 1 defaults" ]
  limit watchdog_silent_max_secs;  [ "$output" = "rc=0 604800 defaults" ]
}

@test "a project-level maximum is ignored by the resolver and failed by doctor" {
  write_cfg '' 'watchdog_silent_max_secs = 86400'
  limit watchdog_silent_max_secs volk
  [ "$output" = "rc=0 3600 constant" ]
  window 61 volk
  [ "${lines[0]}" = "rc=2 3660" ]
  doctor volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL project.volk.watchdog_silent_max_secs"*"[defaults] only"* ]]
  # The control: the same key in [defaults] is read and passes.
  write_cfg 'watchdog_silent_max_secs = 86400'
  limit watchdog_silent_max_secs volk
  [ "$output" = "rc=0 86400 defaults" ]
  doctor volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK   defaults.watchdog_silent_max_secs"* ]]
}

@test "an unparseable config returns 3, not a default" {
  limit watchdog_no_progress_secs volk
  [ "$output" = "rc=0 1200 constant" ]
  printf '[defaults\nwatchdog_no_progress_secs = = 5\n' > "$DA_HOME/config.toml"
  local key
  for key in watchdog_no_progress_secs watchdog_telemetry_secs watchdog_silent_max_secs analyze_silent_secs; do
    limit "$key" volk
    [ "$output" = "rc=3 - project" ] || [ "$output" = "rc=3 - defaults" ]
  done
  window 1
  [ "${lines[0]}" = "rc=3 60" ]
  [[ "${lines[1]}" == *watchdog_silent_max_secs* ]]
  # A config that is not there is unreadable too.
  rm "$DA_HOME/config.toml"
  limit watchdog_no_progress_secs
  [ "$output" = "rc=3 - defaults" ]
}

@test "a malformed value returns 2, not a default or the next scope" {
  local bad
  for bad in 0 -5 1.5 '"abc"' 604801 1234567890123456789 true '[60]' '""'; do
    write_cfg "watchdog_no_progress_secs = $bad"
    limit watchdog_no_progress_secs volk
    [ "$output" = "rc=2 - defaults" ]
    write_cfg 'watchdog_no_progress_secs = 900' "watchdog_no_progress_secs = $bad"
    limit watchdog_no_progress_secs volk
    [ "$output" = "rc=2 - project" ]
  done
  # A table where a value belongs is malformed, not absent.
  write_cfg '' '' $'[defaults.watchdog_telemetry_secs]\nvalue = 60'
  limit watchdog_telemetry_secs volk
  [ "$output" = "rc=2 - defaults" ]
  write_cfg '' '' $'[project.volk.analyze_silent_secs]\nvalue = 60'
  limit analyze_silent_secs volk
  [ "$output" = "rc=2 - project" ]
}

@test "a key that is not a watchdog key returns 1" {
  write_cfg 'watchdog_no_progres_secs = 900'
  limit watchdog_no_progres_secs volk
  [ "$output" = "rc=1 - -" ]
  limit ''
  [ "$output" = "rc=1 - -" ]
}

@test "unset analyze_silent_secs derives min(analyze_timeout, maximum)" {
  # No analyze_timeout: the legs' own 1800 default, under the 3600 maximum.
  limit analyze_silent_secs volk
  [ "$output" = "rc=0 1800 derived" ]
  limit analyze_silent_secs
  [ "$output" = "rc=0 1800 derived" ]
  # The project's analyze_timeout, below and above the maximum.
  write_cfg '' 'analyze_timeout = 900'
  limit analyze_silent_secs volk
  [ "$output" = "rc=0 900 derived" ]
  write_cfg '' 'analyze_timeout = 7200'
  limit analyze_silent_secs volk
  [ "$output" = "rc=0 3600 derived" ]
  write_cfg 'watchdog_silent_max_secs = 600' 'analyze_timeout = 900'
  limit analyze_silent_secs volk
  [ "$output" = "rc=0 600 derived" ]
  # A timeout the caller has already resolved wins over the config's.
  limit analyze_silent_secs volk 45
  [ "$output" = "rc=0 45 derived" ]
  # A timeout that is not seconds in range leaves the maximum.
  limit analyze_silent_secs volk 0
  [ "$output" = "rc=0 600 derived" ]
  # A set key is never derived, and a maximum that cannot be read is not guessed.
  write_cfg 'analyze_silent_secs = 120' 'analyze_timeout = 900'
  limit analyze_silent_secs volk
  [ "$output" = "rc=0 120 defaults" ]
  write_cfg 'watchdog_silent_max_secs = 0'
  limit analyze_silent_secs volk
  [ "$output" = "rc=2 - defaults" ]
}

@test "doctor fails 0, -5, 1.5, \"abc\", 604801 and a 19-digit value for each key" {
  local bad shown key
  for bad in 0 -5 1.5 '"abc"' 604801 1234567890123456789; do
    shown="${bad//\"/}"
    write_cfg "watchdog_no_progress_secs = $bad"$'\n'"watchdog_telemetry_secs = $bad"$'\n'"watchdog_silent_max_secs = $bad"$'\n'"analyze_silent_secs = $bad"
    doctor volk
    [ "$status" -eq 1 ]
    for key in watchdog_no_progress_secs watchdog_telemetry_secs watchdog_silent_max_secs analyze_silent_secs; do
      [[ "$output" == *"FAIL defaults.$key — must be an integer number of seconds from 1 to 604800, got '$shown'"* ]]
    done
    write_cfg '' "watchdog_no_progress_secs = $bad"$'\n'"watchdog_telemetry_secs = $bad"$'\n'"analyze_silent_secs = $bad"
    doctor volk
    [ "$status" -eq 1 ]
    for key in watchdog_no_progress_secs watchdog_telemetry_secs analyze_silent_secs; do
      [[ "$output" == *"FAIL project.volk.$key — must be an integer number of seconds from 1 to 604800, got '$shown'"* ]]
    done
  done
}

@test "doctor passes each key in range, quoted or bare" {
  write_cfg $'watchdog_no_progress_secs = 1\nwatchdog_telemetry_secs = "60"\nwatchdog_silent_max_secs = 604800\nanalyze_silent_secs = 604800' \
            $'watchdog_no_progress_secs = 604800\nwatchdog_telemetry_secs = 30\nanalyze_silent_secs = "90"'
  doctor volk
  [ "$status" -eq 0 ]
  local key
  for key in watchdog_no_progress_secs watchdog_telemetry_secs watchdog_silent_max_secs analyze_silent_secs; do
    [[ "$output" == *"OK   defaults.$key"* ]]
  done
  for key in watchdog_no_progress_secs watchdog_telemetry_secs analyze_silent_secs; do
    [[ "$output" == *"OK   project.volk.$key"* ]]
  done
  [[ "$output" != *FAIL* ]]
}

@test "doctor fails analyze_silent_secs above the maximum and passes it equal" {
  write_cfg 'watchdog_silent_max_secs = 3590' 'analyze_silent_secs = 3590'
  doctor volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK   project.volk.analyze_silent_secs"* ]]
  write_cfg 'watchdog_silent_max_secs = 3590' 'analyze_silent_secs = 3591'
  doctor volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL project.volk.analyze_silent_secs — 3591 s exceeds the silent-window maximum of 3590 s"* ]]
  # [defaults], against the shipped maximum.
  write_cfg 'analyze_silent_secs = 3601'
  doctor volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL defaults.analyze_silent_secs — 3601 s exceeds the silent-window maximum of 3600 s"* ]]
}

@test "doctor fails a misspelt watchdog_ key" {
  write_cfg 'watchdog_no_progres_secs = 900'
  doctor volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL defaults.watchdog_no_progres_secs — unknown key"* ]]
  write_cfg '' 'watchdog_telemetry = 60'
  doctor volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL project.volk.watchdog_telemetry — unknown key"* ]]
}

@test "doctor fails a table where a limit belongs" {
  write_cfg '' '' $'[defaults.watchdog_telemetry_secs]\nvalue = 60'
  doctor volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL defaults.watchdog_telemetry_secs — must be an integer number of seconds from 1 to 604800, got a table"* ]]
  write_cfg '' '' $'[project.volk.watchdog_extra]\nvalue = 60'
  doctor volk
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL project.volk.watchdog_extra — unknown key"* ]]
}

@test "doctor passes a config with none of the keys" {
  doctor volk
  [ "$status" -eq 0 ]
  [[ "$output" != *watchdog_* ]]
  [[ "$output" != *analyze_silent_secs* ]]
}

@test "window grammar: 1 is 60, 2m is 120, 90s is 90; 0, 1h, 1.5 and seven digits are refused" {
  window 1;   [ "${lines[0]}" = "rc=0 60" ]
  window 2m;  [ "${lines[0]}" = "rc=0 120" ]
  window 90s; [ "${lines[0]}" = "rc=0 90" ]
  window 60;  [ "${lines[0]}" = "rc=0 3600" ]
  local bad
  for bad in 0 0s 1h 1.5 1234567 1234567s 01 -1 '' m s ' 1' 1ms 1M; do
    window "$bad"
    [ "${lines[0]}" = "rc=2 -" ]
    [ "${lines[1]}" = "--silent $bad is not a window; write <N> or <N>m for minutes or <N>s for seconds, N from 1 to 999999" ]
  done
  # Six digits is grammar; the maximum refuses it, in the contract's words.
  window 999999s
  [ "${lines[0]}" = "rc=2 999999" ]
  [ "${lines[1]}" = "--silent 999999s exceeds the silent-window maximum of 3600 s; declare a shorter window (the maximum is operator-set and is not changed from a session)" ]
}

@test "a window equal to a maximum of 3590 passes and 3591s is refused" {
  write_cfg 'watchdog_silent_max_secs = 3590'
  window 3590s
  [ "${lines[0]}" = "rc=0 3590" ]
  [ "${#lines[@]}" -eq 1 ]
  window 3591s
  [ "${lines[0]}" = "rc=2 3591" ]
  [ "${lines[1]}" = "--silent 3591s exceeds the silent-window maximum of 3590 s; declare a shorter window (the maximum is operator-set and is not changed from a session)" ]
  window 59;  [ "${lines[0]}" = "rc=0 3540" ]
  window 60;  [ "${lines[0]}" = "rc=2 3600" ]
  # A maximum the caller passes is used as given, and no config is read.
  printf '[defaults\n' > "$DA_HOME/config.toml"
  window 1 '' 60;  [ "${lines[0]}" = "rc=0 60" ]
  window 61s '' 60; [ "${lines[0]}" = "rc=2 61" ]
  window 1 '' abc; [ "${lines[0]}" = "rc=3 60" ]
}

@test "--since converts a zoned ISO time and refuses anything else" {
  since 2026-11-20T10:00:00Z;          [ "$output" = "rc=0 1795168800" ]
  since 2026-11-20T10:00:00+00:00;     [ "$output" = "rc=0 1795168800" ]
  since 2026-11-20T11:00:00+01:00;     [ "$output" = "rc=0 1795168800" ]
  since 2026-11-20T05:00:00.25-05:00;  [ "$output" = "rc=0 1795168800" ]
  since 2026-11-20T10:00:00.123456789Z; [ "$output" = "rc=0 1795168800" ]
  since 1970-01-01T00:00:00Z;          [ "$output" = "rc=0 0" ]
  local bad
  for bad in 2026-11-20T10:00:00 '2026-11-20 10:00:00Z' 2026-11-20T10:00Z 2026-11-20T10:00:00z \
             2026-13-01T00:00:00Z 2026-02-30T00:00:00Z 2026-11-20T25:00:00Z 2026-11-20T10:00:60Z \
             2026-11-20T10:00:00+99:00 1969-12-31T23:59:59Z 1795168800 ''; do
    since "$bad"
    [ "$output" = "rc=2 -" ]
  done
}

@test "sourcing watchdog-limits.sh leaves set +o and shopt -p unchanged and prints nothing" {
  lim 'echo start' # control: lim runs
  [ "$output" = start ]
  run --separate-stderr bash -euo pipefail -c '
    source "$1/scripts/lib/paths.sh"
    source "$1/scripts/lib/io.sh"
    source "$1/scripts/lib/config.sh"
    before="$(set +o; shopt -p)"
    source "$1/scripts/lib/watchdog-limits.sh"
    after="$(set +o; shopt -p)"
    [ "$before" = "$after" ] && echo same
  ' _ "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = same ]
  [ -z "$stderr" ]
}
