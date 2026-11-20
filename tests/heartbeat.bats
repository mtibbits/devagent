#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/heartbeat.bats — #932: scripts/lib/heartbeat.sh, the per-session progress
# record. Every body runs the library in a fresh `bash -euo pipefail`, the
# strictest caller it has, with the marker and the session id set per test.

bats_require_minimum_version 1.5.0   # run --separate-stderr: stdout and stderr are both pinned

load 'lib/bats-helpers'

ID=0f8fad5b-d9cb-469f-a165-70867728950e
ID_UPPER=0F8FAD5B-D9CB-469F-A165-70867728950E

setup() {
  setup_tmp_devagent_home
  WD="$DA_HOME/state/watchdog"
}
teardown() { teardown_tmp_devagent_home; }

# hb <marker> <session id> <bash text> — source paths.sh and heartbeat.sh under
# -euo pipefail, then run the text. An empty marker or id leaves it unset.
hb() {
  local marker="$1" id="$2" body="$3"
  local -a envv=(env -u DEVAGENT_UNATTENDED -u CLAUDE_CODE_SESSION_ID)
  [ -z "$marker" ] || envv+=("DEVAGENT_UNATTENDED=$marker")
  [ -z "$id" ] || envv+=("CLAUDE_CODE_SESSION_ID=$id")
  run --separate-stderr "${envv[@]}" bash -euo pipefail -c '
    source "$1/scripts/lib/paths.sh"
    source "$1/scripts/lib/heartbeat.sh"
    eval "$2"
    echo "END rc=$?"
  ' _ "$PLUGIN_ROOT" "$body"
}

# The body ran to its last line, printed nothing of its own, and stderr is empty.
quiet_ok() {
  [ "$status" -eq 0 ]
  [ "$output" = "END rc=0" ]
  [ -z "$stderr" ]
}

mtime() { stat -c %Y "$1"; }

@test "heartbeat_touch creates <id>/script and moves a pre-dated mtime" {
  [ ! -e "$WD" ]
  hb 1 "$ID" 'heartbeat_touch script'
  quiet_ok
  [ -f "$WD/$ID/script" ]
  [ ! -s "$WD/$ID/script" ]
  touch -d '2020-01-01 00:00:00' "$WD/$ID/script"
  local old now
  old="$(mtime "$WD/$ID/script")"
  now="$(date +%s)"
  hb 1 "$ID" 'heartbeat_touch script'
  quiet_ok
  [ "$(mtime "$WD/$ID/script")" -gt "$old" ]
  [ "$(mtime "$WD/$ID/script")" -ge "$((now - 5))" ]
}

@test "heartbeat_note writes the dispatch line" {
  hb 1 "$ID" 'heartbeat_note dispatch "v1 volk Issue-7 9 implement"'
  quiet_ok
  [ "$(cat "$WD/$ID/dispatch")" = "v1 volk Issue-7 9 implement" ]
  hb 1 "$ID" 'heartbeat_note dispatch "v1 volk Issue-7 10 quality"'
  quiet_ok
  [ "$(cat "$WD/$ID/dispatch")" = "v1 volk Issue-7 10 quality" ]
}

@test "heartbeat_drop removes one file and an absent one is fine" {
  hb 1 "$ID" 'heartbeat_note beat.window 60; heartbeat_touch beat'
  quiet_ok
  [ -f "$WD/$ID/beat.window" ]
  hb 1 "$ID" 'heartbeat_drop beat.window; heartbeat_drop beat.window'
  quiet_ok
  [ ! -e "$WD/$ID/beat.window" ]
  [ -f "$WD/$ID/beat" ]
}

@test "forty concurrent touches of distinct names all land" {
  hb 1 "$ID" 'for i in $(seq 1 40); do ( heartbeat_touch "wrap.$i" ) & done; wait'
  quiet_ok
  local n
  n="$(find "$WD/$ID" -type f -name 'wrap.*' | wc -l)"
  [ "$n" -eq 40 ]
}

@test "a touch leaves dispatch and a .window alone" {
  hb 1 "$ID" 'heartbeat_note dispatch "v1 volk Issue-7 9 implement"; heartbeat_note beat.window 120'
  quiet_ok
  touch -d '2020-01-01 00:00:00' "$WD/$ID/dispatch" "$WD/$ID/beat.window"
  local d w
  d="$(mtime "$WD/$ID/dispatch")"
  w="$(mtime "$WD/$ID/beat.window")"
  hb 1 "$ID" 'heartbeat_touch script; heartbeat_touch beat'
  quiet_ok
  [ -f "$WD/$ID/script" ]
  [ "$(cat "$WD/$ID/dispatch")" = "v1 volk Issue-7 9 implement" ]
  [ "$(cat "$WD/$ID/beat.window")" = 120 ]
  [ "$(mtime "$WD/$ID/dispatch")" -eq "$d" ]
  [ "$(mtime "$WD/$ID/beat.window")" -eq "$w" ]
}

@test "no marker writes no state/watchdog/<id>/ directory" {
  hb '' "$ID" 'heartbeat_touch script; heartbeat_note dispatch x; heartbeat_drop beat.window'
  quiet_ok
  [ ! -e "$WD" ]
  hb '' "$ID" 'heartbeat_dir'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "marker set writes" {
  hb 1 "$ID" 'heartbeat_dir; echo "$HEARTBEAT_ID|$HEARTBEAT_DIR"; heartbeat_touch script'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$ID|$WD/$ID" ]
  [ -z "$stderr" ]
  [ -f "$WD/$ID/script" ]
}

@test "absent and malformed ids write and print nothing" {
  local bad
  for bad in '' 'not-a-uuid' "${ID}x" "${ID%?}" "../$ID" "$ID/.." "${ID//-/_}" "g${ID#?}" " $ID"; do
    hb 1 "$bad" 'heartbeat_touch script; heartbeat_note dispatch x; heartbeat_drop beat'
    quiet_ok
    [ ! -e "$WD" ]
    hb 1 "$bad" 'heartbeat_dir'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
  done
  # The control: the same calls with a well-formed id write.
  hb 1 "$ID" 'heartbeat_touch script'
  quiet_ok
  [ -f "$WD/$ID/script" ]
}

@test "a name with a slash, a leading dot or no text writes nothing" {
  hb 1 "$ID" 'heartbeat_touch ../escape; heartbeat_touch .hidden; heartbeat_touch ""; heartbeat_note a/b x; heartbeat_drop ../x'
  quiet_ok
  [ ! -e "$WD" ]
}

@test "an upper-case id writes under the lower-case directory" {
  hb 1 "$ID_UPPER" 'heartbeat_touch script; heartbeat_dir; echo "$HEARTBEAT_ID"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$ID" ]
  [ -z "$stderr" ]
  [ -f "$WD/$ID/script" ]
  run find "$WD" -mindepth 1 -maxdepth 1
  [ "$output" = "$WD/$ID" ]
}

@test "an unwritable state root warns once and returns 0" {
  # The root's parent is a regular file, so no mkdir can make it (no chmod).
  rm -rf "$DA_HOME/state"
  : > "$DA_HOME/state"
  hb 1 "$ID" 'heartbeat_touch script'
  [ "$status" -eq 0 ]
  [ "$output" = "END rc=0" ]
  [ "$stderr" = "heartbeat: warning: cannot write $WD/$ID/script" ]
  hb 1 "$ID" 'heartbeat_note dispatch x'
  [ "$status" -eq 0 ]
  [ "$output" = "END rc=0" ]
  [ "$stderr" = "heartbeat: warning: cannot write $WD/$ID/dispatch" ]
  hb 1 "$ID" 'heartbeat_drop beat.window'
  quiet_ok
  [ -f "$DA_HOME/state" ]
}

@test "DA_HOME moves the state under \$DA_HOME/state/watchdog" {
  local other="$BATS_TEST_TMPDIR/other home"
  mkdir -p "$other"
  DA_HOME="$other" hb 1 "$ID" 'heartbeat_touch script; heartbeat_log_dir; echo "$HEARTBEAT_LOG_DIR"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$other/state/watchdog/logs" ]
  [ -z "$stderr" ]
  [ -f "$other/state/watchdog/$ID/script" ]
  [ ! -e "$WD" ]
}

@test "heartbeat_dir_for names another session's directory without the marker" {
  hb '' '' "heartbeat_dir_for $ID_UPPER; echo \"\$HEARTBEAT_ID|\$HEARTBEAT_DIR\""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$ID|$WD/$ID" ]
  [ ! -e "$WD" ]
  hb '' '' 'heartbeat_dir_for nope'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "sourced without paths.sh every call is a silent no-op" {
  run --separate-stderr env DEVAGENT_UNATTENDED=1 CLAUDE_CODE_SESSION_ID="$ID" bash -euo pipefail -c '
    source "$1/scripts/lib/heartbeat.sh"
    heartbeat_touch script; heartbeat_note dispatch x; heartbeat_drop beat
    heartbeat_dir || echo "dir rc=$?"
    heartbeat_log_dir || echo "log rc=$?"
    echo END
  ' _ "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "dir rc=1"$'\n'"log rc=1"$'\n'"END" ]
  [ -z "$stderr" ]
  [ ! -e "$WD" ]
}

@test "sourcing heartbeat.sh leaves set +o and shopt -p unchanged" {
  local flags
  for flags in '-euo pipefail' '+e'; do
    # shellcheck disable=SC2086  # $flags is a word list on purpose
    run --separate-stderr env DEVAGENT_UNATTENDED=1 CLAUDE_CODE_SESSION_ID="$ID" bash $flags -c '
      source "$1/scripts/lib/paths.sh"
      before="$(set +o; shopt -p)"
      source "$1/scripts/lib/heartbeat.sh"
      heartbeat_touch script
      after="$(set +o; shopt -p)"
      [ "$before" = "$after" ] && echo same
    ' _ "$PLUGIN_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = same ]
    [ -z "$stderr" ]
  done
  [ -f "$WD/$ID/script" ]
}
