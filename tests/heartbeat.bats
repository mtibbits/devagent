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
# _DEVAGENT_NO_ENTRY_BEAT keeps paths.sh's own entry refresh out of the library's
# tests: what is written here is written by the text. The entry refresh has its
# own tests at the end of this file, which do not set it.
hb() {
  local marker="$1" id="$2" body="$3"
  local -a envv=(env -u DEVAGENT_UNATTENDED -u CLAUDE_CODE_SESSION_ID _DEVAGENT_NO_ENTRY_BEAT=1)
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
    run --separate-stderr env DEVAGENT_UNATTENDED=1 CLAUDE_CODE_SESSION_ID="$ID" _DEVAGENT_NO_ENTRY_BEAT=1 bash $flags -c '
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

# ---------------------------------------------------------------------------
# The script-entry refresh: the tail of scripts/lib/paths.sh (#932 Task 4).
# Every script that sources paths.sh moves <id>/script in an unattended
# session. None of these sets _DEVAGENT_NO_ENTRY_BEAT.

# seed_where: a one-project config, enough for where.sh to report "no active issue".
seed_where() {
  cat > "$DA_HOME/config.toml" <<TOML
[defaults]
checklist_template = "standard"

[project.volk]
source_dir = "$DA_HOME/fake-src"
devdoc_dir = "$DA_HOME/fake-devdoc"
TOML
}

# strict <text> [<arg>...] — a fresh `bash -euo pipefail -c <text>` in an
# unattended session with the id set; the text sees the arguments as $1...
strict() {
  local text="$1"
  shift
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" \
    bash -euo pipefail -c "$text" _ "$@"
}

# The sourcing script ran on past the source: exit 0, nothing on stdout, and the
# sentinel its next statement writes.
ran_on() {
  [ "$status" -eq 0 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ -z "$output" ]
  [ -f "$BATS_TEST_TMPDIR/after" ]
}

# copy_lib: paths.sh alone in a directory of its own. Sets COPY.
copy_lib() {
  COPY="$BATS_TEST_TMPDIR/copy/lib"
  mkdir -p "$COPY"
  cp "$PLUGIN_ROOT/scripts/lib/paths.sh" "$COPY/paths.sh"
}

@test "a devagent script call moves script in an unattended session" {
  seed_where
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$output" == *"Active issue: (none)"* ]]
  [ -f "$WD/$ID/script" ]
  [ ! -s "$WD/$ID/script" ]
  run find "$WD" -type f
  [ "$output" = "$WD/$ID/script" ]     # and nothing else

  # A second call moves a pre-dated mtime and leaves the session's other records.
  hb 1 "$ID" 'heartbeat_note dispatch "v1 volk Issue-7 9 implement"; heartbeat_note beat.window 120'
  quiet_ok
  touch -d '2020-01-01 00:00:00' "$WD/$ID/script" "$WD/$ID/dispatch" "$WD/$ID/beat.window"
  local old now d w
  old="$(mtime "$WD/$ID/script")"
  d="$(mtime "$WD/$ID/dispatch")"
  w="$(mtime "$WD/$ID/beat.window")"
  now="$(date +%s)"
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(mtime "$WD/$ID/script")" -gt "$old" ]
  [ "$(mtime "$WD/$ID/script")" -ge "$((now - 5))" ]
  [ "$(cat "$WD/$ID/dispatch")" = "v1 volk Issue-7 9 implement" ]
  [ "$(cat "$WD/$ID/beat.window")" = 120 ]
  [ "$(mtime "$WD/$ID/dispatch")" -eq "$d" ]
  [ "$(mtime "$WD/$ID/beat.window")" -eq "$w" ]
}

@test "the same call with no marker creates no state/watchdog directory" {
  seed_where
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  local unattended="$output"
  [ -d "$WD/$ID" ]
  rm -rf "$WD"
  run --separate-stderr env "CLAUDE_CODE_SESSION_ID=$ID" bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "$unattended" ]        # the report itself does not depend on the marker
  [ ! -e "$WD" ]
  # the opt-out is the other way to write nothing
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" _DEVAGENT_NO_ENTRY_BEAT=1 bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [ ! -e "$WD" ]
}

@test "broken tail: heartbeat.sh missing beside a copied paths.sh exits 0 with empty stdout" {
  copy_lib
  # control: with the library beside it, the copy writes
  cp "$PLUGIN_ROOT/scripts/lib/heartbeat.sh" "$COPY/heartbeat.sh"
  strict 'source "$1/paths.sh"; : > "$2"' "$COPY" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  [ -f "$WD/$ID/script" ]
  rm -rf "$WD" "$BATS_TEST_TMPDIR/after" "$COPY/heartbeat.sh"
  strict 'source "$1/paths.sh"; : > "$2"' "$COPY" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  [ ! -e "$WD" ]
}

@test "broken tail: heartbeat.sh with a syntax error exits 0 with empty stdout" {
  copy_lib
  printf 'heartbeat_touch() {\n  if then\n}\n' > "$COPY/heartbeat.sh"
  run bash -n "$COPY/heartbeat.sh"
  [ "$status" -ne 0 ]                  # it is a syntax error
  strict 'source "$1/paths.sh"; : > "$2"' "$COPY" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  [ ! -e "$WD" ]
}

@test "broken tail: heartbeat_touch reading an unbound variable exits 0 with empty stdout" {
  copy_lib
  printf 'heartbeat_touch() { : "$HEARTBEAT_NEVER_SET_932"; }\n' > "$COPY/heartbeat.sh"
  # control: called outside the tail, that function ends a set -u shell
  strict 'source "$1/heartbeat.sh"; heartbeat_touch script; : > "$2"' "$COPY" "$BATS_TEST_TMPDIR/after"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/after" ]
  strict 'source "$1/paths.sh"; : > "$2"' "$COPY" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  # and the caller's set -u is back on after the tail
  strict 'source "$1/paths.sh"; : "$HEARTBEAT_NEVER_SET_932"; echo reached' "$COPY"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "broken tail: POSIXLY_CORRECT=1 with heartbeat.sh missing exits 0 with empty stdout" {
  copy_lib
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" POSIXLY_CORRECT=1 \
    bash -euo pipefail -c 'source "$1/paths.sh"; : > "$2"' _ "$COPY" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  [ ! -e "$WD" ]
  # control: in the real tree a POSIX-mode caller writes
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" POSIXLY_CORRECT=1 \
    bash -euo pipefail -c 'source "$1/scripts/lib/paths.sh"; echo reached' _ "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = reached ]
  [ -z "$stderr" ]
  [ -f "$WD/$ID/script" ]
}

@test "broken tail: an unwritable state root exits 0 with empty stdout and one warning" {
  rm -rf "$DA_HOME/state"
  : > "$DA_HOME/state"
  strict 'source "$1/scripts/lib/paths.sh"; : > "$2"' "$PLUGIN_ROOT" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ "$stderr" = "heartbeat: warning: cannot write $WD/$ID/script" ]
  [ -f "$DA_HOME/state" ]
}

@test "broken tail: an absent id exits 0 with empty stdout" {
  run --separate-stderr env DEVAGENT_UNATTENDED=1 \
    bash -euo pipefail -c 'source "$1/scripts/lib/paths.sh"; : > "$2"' _ "$PLUGIN_ROOT" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  [ ! -e "$WD" ]
}

@test "broken tail: paths.sh sourced by bare name exits 0 with empty stdout" {
  strict 'cd "$1/scripts/lib"; source paths.sh; : > "$2"' "$PLUGIN_ROOT" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  # and by a relative path with a directory part it writes
  rm -rf "$WD"
  strict 'cd "$1/scripts"; source lib/paths.sh; : > "$2"' "$PLUGIN_ROOT" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  [ -f "$WD/$ID/script" ]
}

@test "sourcing paths.sh with the marker set leaves set +o and shopt -p unchanged" {
  local flags
  for flags in '-euo pipefail' '+e' '-u' '-e'; do
    rm -rf "$WD"
    # shellcheck disable=SC2086  # $flags is a word list on purpose
    run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash $flags -c '
      before="$(set +o; shopt -p)"
      source "$1/scripts/lib/paths.sh"
      after="$(set +o; shopt -p)"
      [ "$before" = "$after" ] && echo same
    ' _ "$PLUGIN_ROOT"
    [ "$status" -eq 0 ] || { echo "$flags: rc=$status err=$stderr" >&2; return 1; }
    [ "$output" = same ] || { echo "$flags: out=$output" >&2; return 1; }
    [ -z "$stderr" ]
    [ -f "$WD/$ID/script" ]            # and the tail did run under those flags
  done
}

@test "notify.sh sourced with the marker set prints nothing" {
  strict 'source "$1/scripts/lib/notify.sh"; : > "$2"' "$PLUGIN_ROOT" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  [ -f "$WD/$ID/script" ]
}

@test "sourcing paths.sh twice, and from a function, writes one file and prints nothing" {
  strict 'f() { source "$1/scripts/lib/paths.sh"; }; f "$1"; source "$1/scripts/lib/paths.sh"; : > "$2"' \
    "$PLUGIN_ROOT" "$BATS_TEST_TMPDIR/after"
  ran_on
  [ -z "$stderr" ]
  run find "$WD" -type f
  [ "$output" = "$WD/$ID/script" ]
}
