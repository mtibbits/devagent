#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/watchdog-check.bats — #932: scripts/watchdog.sh, the launcher's one-shot
# progress question (`check`) and the session's explicit progress mark
# (`heartbeat`). Time is injected: every `check` takes --now and every progress
# file is dated with `touch -d`, so no test waits or reads the clock. Limits are
# the shipped ones (1200 s, maximum 3600 s) unless a test writes a config value.
# Each `stalled` follows an `ok` control on the same fixture.

bats_require_minimum_version 1.5.0   # run --separate-stderr: stdout and stderr are both pinned

load 'lib/bats-helpers'

ID=0f8fad5b-d9cb-469f-a165-70867728950e
ID_UPPER=0F8FAD5B-D9CB-469F-A165-70867728950E
OTHER=7c9e6679-7425-40de-944b-e07fc1f90ae7
T=1700000000          # 2023-11-14T22:13:20Z
T_ISO=2023-11-14T22:13:20Z
LIMIT=1200

setup() {
  setup_tmp_devagent_home
  W="$PLUGIN_ROOT/scripts/watchdog.sh"
  WD="$DA_HOME/state/watchdog"
  # The layout tests/fixtures/watchdog/README describes.
  PROJ="$BATS_TEST_TMPDIR/projects/C--src-volk"
  TR="$PROJ/$ID.jsonl"
  mkdir -p "$PROJ"
  write_cfg
}
teardown() { teardown_tmp_devagent_home; }

# write_cfg [<[defaults] lines>] [<[project.volk] lines>]
write_cfg() {
  cat > "$DA_HOME/config.toml" <<TOML
[defaults]
checklist_template = "standard"
${1:-}

[project.volk]
source_dir = "$DA_HOME/fake-src"
devdoc_dir = "$DA_HOME/fake-devdoc"
${2:-}
TOML
}

# at <epoch> <file>... — create each file (and its directory) with that mtime.
at() {
  local t="$1" f
  shift
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    [ -e "$f" ] || : > "$f"
    touch -d "@$t" "$f"
  done
}

# chk <now> [<check arguments>...] — `check volk Issue-7` on the fixture
# transcript at an injected time.
chk() {
  local now="$1"
  shift
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$TR" --now "$now" "$@"
}

# beat [<heartbeat arguments>...] — the real `watchdog.sh heartbeat`, as the
# unattended session $ID would call it.
beat() {
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash "$W" heartbeat "$@"
}

is_ok() {
  [ "$status" -eq 0 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ "$output" = ok ]
  [ -z "$stderr" ]
}

# is_stalled <source> <at epoch> <age> [<tail>] — exit 3 and the whole line.
is_stalled() {
  local iso
  iso="$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)"
  [ "$status" -eq 3 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ "$output" = "stalled no-progress limit=${LIMIT}s age=${3}s last=$1 at=${iso}${4:-}" ] || { echo "out=$output" >&2; return 1; }
  [ -z "$stderr" ]
}

# refused <exit> <stderr fragment> — nothing on stdout, every stderr line prefixed.
refused() {
  [ "$status" -eq "$1" ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ -z "$output" ]
  [ -n "$stderr" ]
  local line
  while IFS= read -r line; do
    [[ "$line" == "watchdog: "* ]] || { echo "unprefixed: $line" >&2; return 1; }
  done <<<"$stderr"
  [[ "$stderr" == *"$2"* ]] || { echo "err=$stderr" >&2; return 1; }
}

# ---------------------------------------------------------------- Stall

@test "the fixture launcher sees exit 3 no later than the limit plus one poll" {
  at "$T" "$TR"
  local poll=300 at_s
  run --separate-stderr bash "$PLUGIN_ROOT/tests/fixtures/watchdog/launcher.sh" \
    "$W" volk Issue-7 "$TR" "$((T + 7))" "$poll" 12
  [ "$status" -eq 3 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  at_s="$(sed -n 's/^stalled-at=\([0-9]*\) .*/\1/p' <<<"$output")"
  [ -n "$at_s" ]
  [ "$at_s" -gt "$((T + LIMIT))" ]
  [ "$at_s" -le "$((T + LIMIT + poll))" ]
  # every earlier poll was ok: the stall is the fifth answer, not the first
  [[ "$output" == "stalled-at=$((T + 1207)) polls=5"* ]]
  [[ "${lines[1]}" == "stalled no-progress limit=1200s age=1207s last=transcript at=$T_ISO" ]]
}

@test "the stalled line names the limit, the source and its time" {
  write_cfg "" "watchdog_no_progress_secs = 900"
  at "$T" "$TR"
  chk "$((T + 900))"
  is_ok
  chk "$((T + 901))"
  [ "$status" -eq 3 ]
  [ "$output" = "stalled no-progress limit=900s age=901s last=transcript at=$T_ISO" ]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------- Early stall

@test "a session with no state directory is stalled after the limit" {
  at "$T" "$TR"
  [ ! -e "$WD" ]
  chk "$((T + LIMIT))"
  is_ok
  chk "$((T + LIMIT + 1))"
  is_stalled transcript "$T" "$((LIMIT + 1))"
  [ ! -e "$WD" ]          # check writes nothing
}

# ---------------------------------------------------------------- Startup

@test "no transcript, old --since: stalled" {
  [ ! -e "$TR" ]
  chk "$((T + LIMIT))" --since "$T_ISO"
  is_ok
  chk "$((T + LIMIT + 1))" --since "$T_ISO"
  is_stalled since "$T" "$((LIMIT + 1))"
}

@test "no transcript, no --since: exit 1" {
  chk "$((T + 5))"
  refused 1 "watchdog: error: "
  [[ "$stderr" == *"--since"* ]]
  # the same call with a transcript is judged
  at "$T" "$TR"
  chk "$((T + 5))"
  is_ok
}

@test "a fresh --since is ok" {
  at "$((T - 7200))" "$TR"
  chk "$T"
  is_stalled transcript "$((T - 7200))" 7200
  chk "$T" --since 2023-11-14T22:13:00Z
  is_ok
  # an offset and a fraction name the same instant
  chk "$T" --since 2023-11-15T00:13:00.250+02:00
  is_ok
}

@test "--since without a zone exits 2" {
  at "$T" "$TR"
  chk "$((T + 5))" --since 2023-11-14T22:13:20
  refused 2 "watchdog: usage: "
  chk "$((T + 5))" --since 2023-13-45T22:13:20Z
  refused 2 "watchdog: usage: "
  chk "$((T + 5))" --since "$T_ISO"
  is_ok
}

# ---------------------------------------------------------------- Subagent progress

@test "a newer file under <id>/subagents keeps a silent parent ok" {
  at "$((T - 7200))" "$TR"
  at "$T" "$PROJ/$ID/subagents/agent-a497e3b75296f1039.jsonl"
  at "$((T - 7000))" "$PROJ/$ID/subagents/agent-a497e3b75296f1039.meta.json"
  chk "$((T + LIMIT))"
  is_ok
}

@test "both silent is stalled" {
  at "$((T - 7200))" "$TR"
  at "$T" "$PROJ/$ID/subagents/agent-a497e3b75296f1039.jsonl"
  chk "$((T + LIMIT))"
  is_ok
  chk "$((T + LIMIT + 5))"
  is_stalled subagent-transcript "$T" "$((LIMIT + 5))"
}

@test "a subagent listing that fails is cannot-determine (exit 1), never stalled" {
  at "$((T - 7200))" "$TR"
  at "$T" "$PROJ/$ID/subagents/agent-a497e3b75296f1039.jsonl"
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  printf '#!/bin/sh\nexit 2\n' > "$BATS_TEST_TMPDIR/shim/find"
  chmod +x "$BATS_TEST_TMPDIR/shim/find"
  # control: the same fixture with the real find is stalled
  chk "$((T + LIMIT + 5))"
  is_stalled subagent-transcript "$T" "$((LIMIT + 5))"
  run --separate-stderr env "PATH=$BATS_TEST_TMPDIR/shim:$PATH" \
    bash "$W" check volk Issue-7 --transcript "$TR" --now "$((T + LIMIT + 5))"
  [ "$status" -eq 1 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ -z "$output" ]
  [[ "$stderr" == *"cannot determine progress"* ]]
}

# ---------------------------------------------------------------- Progress sources

@test "transcript growth alone is ok at T+limit-1 and stalled at T+limit+5" {
  at "$((T - 9000))" "$WD/$ID/script" "$WD/$ID/dispatch" "$WD/$ID/beat" "$WD/$ID/wrap.1699990000-4242"
  at "$T" "$TR"
  chk "$((T + LIMIT - 1))" --since 2023-11-14T19:00:00Z
  is_ok
  chk "$((T + LIMIT + 5))" --since 2023-11-14T19:00:00Z
  is_stalled transcript "$T" "$((LIMIT + 5))"
}

@test "a real heartbeat alone is ok at T+limit-1 and stalled at T+limit+5" {
  at "$((T - 9000))" "$TR" "$WD/$ID/script" "$WD/$ID/dispatch" "$WD/$ID/wrap.1699990000-4242"
  local before
  before="$(date +%s)"
  beat
  is_ok
  [ -f "$WD/$ID/beat" ]
  [ "$(stat -c %Y "$WD/$ID/beat")" -ge "$before" ]
  local b
  b="$(stat -c %Y "$WD/$ID/beat")"
  chk "$((b + LIMIT - 1))"
  is_ok
  chk "$((b + LIMIT + 5))"
  is_stalled beat "$b" "$((LIMIT + 5))"
}

@test "a planted script, dispatch and wrap file each count, and only for their own time" {
  local src f
  for src in script dispatch wrap; do
    rm -rf "$WD"
    f="$WD/$ID/$src"
    [ "$src" != wrap ] || f="$WD/$ID/wrap.1699990000-4242"
    at "$((T - 9000))" "$TR"
    at "$T" "$f"
    chk "$((T + LIMIT - 1))"
    is_ok
    chk "$((T + LIMIT + 5))"
    is_stalled "$src" "$T" "$((LIMIT + 5))"
  done
}

@test "on equal times the earlier source in the list is named" {
  at "$T" "$TR" "$WD/$ID/beat" "$WD/$ID/script"
  chk "$((T + LIMIT + 5))"
  is_stalled transcript "$T" "$((LIMIT + 5))"
  at "$((T - 10))" "$TR"
  chk "$((T + LIMIT + 5))"
  is_stalled beat "$T" "$((LIMIT + 5))"
}

# ---------------------------------------------------------------- Foreign progress

@test "another session's directory does not keep this one ok" {
  at "$T" "$TR"
  at "$((T + 1000))" "$WD/$OTHER/beat" "$WD/$OTHER/script" "$WD/$OTHER/wrap.1700000900-77"
  at "$((T + 1000))" "$PROJ/$OTHER.jsonl" "$PROJ/$OTHER/subagents/agent-1.jsonl"
  # control: the same files in this session's directory do
  chk "$((T + LIMIT + 5))"
  is_stalled transcript "$T" "$((LIMIT + 5))"
  at "$((T + 1000))" "$WD/$ID/beat"
  chk "$((T + LIMIT + 5))"
  is_ok
}

@test "a malformed id writes nothing" {
  run --separate-stderr env DEVAGENT_UNATTENDED=1 CLAUDE_CODE_SESSION_ID=../../escape bash "$W" heartbeat
  is_ok
  [ ! -e "$WD" ]
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=${ID}x" bash "$W" heartbeat --silent 1
  is_ok
  [ ! -e "$WD" ]
  # the same call with the id writes
  beat
  is_ok
  [ -f "$WD/$ID/beat" ]
}

@test "heartbeat with no marker exits 0 and writes nothing" {
  run --separate-stderr env "CLAUDE_CODE_SESSION_ID=$ID" bash "$W" heartbeat
  is_ok
  run --separate-stderr env "CLAUDE_CODE_SESSION_ID=$ID" bash "$W" heartbeat --silent 2
  is_ok
  [ ! -e "$WD" ]
  beat --silent 2
  is_ok
  [ "$(cat "$WD/$ID/beat.window")" = 120 ]
}

@test "a script call keeps the dispatch line and a declared window" {
  beat --silent 2
  is_ok
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash -euo pipefail -c '
    source "$1/scripts/lib/paths.sh"
    source "$1/scripts/lib/heartbeat.sh"
    heartbeat_note dispatch "v1 volk Issue-7 9 implement"
    heartbeat_touch script
  ' _ "$PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$WD/$ID/script" ]
  [ "$(cat "$WD/$ID/dispatch")" = "v1 volk Issue-7 9 implement" ]
  [ "$(cat "$WD/$ID/beat.window")" = 120 ]
  # and check still reads both: the window stretches beat's allowance
  write_cfg "watchdog_no_progress_secs = 30"
  at "$((T - 9000))" "$TR" "$WD/$ID/script" "$WD/$ID/dispatch"
  at "$T" "$WD/$ID/beat"
  chk "$((T + 120))"
  is_ok
}

@test "a future-dated file is ignored" {
  at "$T" "$TR"
  at "$((T + LIMIT + 5000))" "$WD/$ID/beat"
  chk "$((T + LIMIT))"
  is_ok
  chk "$((T + LIMIT + 5))"
  is_stalled transcript "$T" "$((LIMIT + 5))"
  # sixty seconds of clock skew is not the future
  at "$((T + LIMIT + 65))" "$WD/$ID/beat"
  chk "$((T + LIMIT + 5))"
  is_ok
}

@test "every candidate in the future exits 1" {
  at "$((T + 5000))" "$TR" "$WD/$ID/beat"
  chk "$T"
  refused 1 "watchdog: error: "
  chk "$((T + 5000))"
  is_ok
}

# ---------------------------------------------------------------- Silent window

@test "heartbeat --silent 1 (limit 30 by config) is ok at T+59 and stalled, silent-window=expired, at T+61" {
  write_cfg "watchdog_no_progress_secs = 30"
  LIMIT=30
  at "$((T - 9000))" "$TR"
  beat --silent 1
  is_ok
  [ "$(cat "$WD/$ID/beat.window")" = 60 ]
  at "$T" "$WD/$ID/beat"
  chk "$((T + 59))"
  is_ok
  chk "$((T + 61))"
  is_stalled beat "$T" 61 " silent-window=expired"
}

@test "--silent above the maximum exits 2 and writes no window" {
  beat --silent 61
  refused 2 "watchdog: usage: --silent 61 exceeds the silent-window maximum of 3600 s; declare a shorter window (the maximum is operator-set and is not changed from a session)"
  [ ! -e "$WD" ]
  beat --silent 3601s
  refused 2 "watchdog: usage: --silent 3601s exceeds the silent-window maximum of 3600 s"
  local bad
  for bad in 0 1h 1.5 1234567 ""; do
    beat --silent "$bad"
    refused 2 "watchdog: usage: "
  done
  [ ! -e "$WD" ]
  # no marker: still refused, still nothing written
  run --separate-stderr bash "$W" heartbeat --silent 61
  refused 2 "exceeds the silent-window maximum of 3600 s"
  # the maximum itself passes, in both spellings
  beat --silent 60
  is_ok
  [ "$(cat "$WD/$ID/beat.window")" = 3600 ]
  beat --silent 3600s
  is_ok
  [ "$(cat "$WD/$ID/beat.window")" = 3600 ]
}

@test "a plain heartbeat ends the window" {
  write_cfg "watchdog_no_progress_secs = 30"
  LIMIT=30
  at "$((T - 9000))" "$TR"
  beat --silent 1
  is_ok
  [ -f "$WD/$ID/beat.window" ]
  beat
  is_ok
  [ ! -e "$WD/$ID/beat.window" ]
  [ -f "$WD/$ID/beat" ]
  at "$T" "$WD/$ID/beat"
  chk "$((T + 30))"
  is_ok
  chk "$((T + 31))"
  is_stalled beat "$T" 31
}

@test "an over-maximum window planted in the file is ignored" {
  at "$((T - 9000))" "$TR"
  at "$T" "$WD/$ID/beat"
  local planted
  for planted in 3601 7200 0 -5 abc 1e3 ""; do
    printf '%s\n' "$planted" > "$WD/$ID/beat.window"
    chk "$((T + LIMIT))"
    is_ok
    chk "$((T + LIMIT + 1))"
    is_stalled beat "$T" "$((LIMIT + 1))"
  done
  # control: the maximum itself is honoured
  printf '3600\n' > "$WD/$ID/beat.window"
  chk "$((T + 3600))"
  is_ok
  chk "$((T + 3601))"
  is_stalled beat "$T" 3601 " silent-window=expired"
}

@test "a wrap file's own window stretches that run only" {
  at "$((T - 9000))" "$TR"
  at "$T" "$WD/$ID/wrap.1699999990-11" "$WD/$ID/wrap.1699999990-12"
  printf '1800\n' > "$WD/$ID/wrap.1699999990-11.window"
  at "$((T - 100))" "$WD/$ID/wrap.1699999990-12"
  chk "$((T + 1800))"
  is_ok
  chk "$((T + 1801))"
  is_stalled wrap "$T" 1801 " silent-window=expired"
}

@test "a stale window on another source does not tag the stalled line" {
  at "$((T - 5000))" "$WD/$ID/beat"
  printf '60\n' > "$WD/$ID/beat.window"
  at "$T" "$TR"
  chk "$((T + LIMIT))"
  is_ok
  chk "$((T + LIMIT + 1))"
  is_stalled transcript "$T" "$((LIMIT + 1))"
}

# ---------------------------------------------------------------- Dispatch record

@test "a dispatch record for another issue exits 1" {
  at "$T" "$TR"
  mkdir -p "$WD/$ID"
  printf 'v1 volk Issue-7 9 implement\n' > "$WD/$ID/dispatch"
  touch -d "@$((T - 9000))" "$WD/$ID/dispatch"
  chk "$((T + 5))"
  is_ok
  printf 'v1 volk Issue-8 9 implement\n' > "$WD/$ID/dispatch"
  chk "$((T + 5))"
  refused 1 "watchdog: error: "
  [[ "$stderr" == *"volk Issue-8"* && "$stderr" == *"volk Issue-7"* ]]
  printf 'v1 other Issue-7 9 implement\n' > "$WD/$ID/dispatch"
  chk "$((T + 5))"
  refused 1 "other Issue-7"
  # an empty record (a writer between its truncate and its line) is not a mismatch
  : > "$WD/$ID/dispatch"
  chk "$((T + 5))"
  is_ok
}

# ---------------------------------------------------------------- Grammar and paths

@test "a name that is not <uuid>.jsonl, an unknown flag and an empty --transcript value each exit 2" {
  at "$T" "$TR" "$PROJ/notes.jsonl" "$PROJ/$ID.json" "$PROJ/${ID}0.jsonl"
  local bad
  for bad in "$PROJ/notes.jsonl" "$PROJ/$ID.json" "$PROJ/${ID}0.jsonl" "$PROJ"; do
    run --separate-stderr bash "$W" check volk Issue-7 --transcript "$bad" --now "$T"
    refused 2 "watchdog: usage: "
  done
  chk "$T" --frobnicate
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "" --now "$T"
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" check volk Issue-7 --now "$T" --transcript
  refused 2 "watchdog: usage: "
  chk "$T"
  is_ok
}

@test "wrong arity, a bad project or issue name and a bad --now each exit 2" {
  at "$T" "$TR"
  run --separate-stderr bash "$W" check volk --transcript "$TR" --now "$T"
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" check volk Issue-7 extra --transcript "$TR" --now "$T"
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" check 'vo/lk' Issue-7 --transcript "$TR" --now "$T"
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" check volk 'Issue 7' --transcript "$TR" --now "$T"
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" check volk "" --transcript "$TR" --now "$T"
  refused 2 "watchdog: usage: "
  local bad
  for bad in -5 1.5 abc 1234567890123 ""; do
    run --separate-stderr bash "$W" check volk Issue-7 --transcript "$TR" --now "$bad"
    refused 2 "watchdog: usage: "
  done
  run --separate-stderr bash "$W"
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" fire volk Issue-7
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" heartbeat --loud
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" heartbeat extra
  refused 2 "watchdog: usage: "
}

@test "the env variable supplies the transcript and the flag wins" {
  at "$T" "$TR"
  at "$((T - 9000))" "$PROJ/$OTHER.jsonl"
  run --separate-stderr bash "$W" check volk Issue-7 --now "$((T + 5))"
  refused 2 "watchdog: usage: "
  run --separate-stderr env "DEVAGENT_WATCHDOG_TRANSCRIPT=$TR" bash "$W" check volk Issue-7 --now "$((T + 5))"
  is_ok
  run --separate-stderr env "DEVAGENT_WATCHDOG_TRANSCRIPT=$PROJ/$OTHER.jsonl" bash "$W" check volk Issue-7 --now "$((T + 5))"
  is_stalled transcript "$((T - 9000))" 9005
  run --separate-stderr env "DEVAGENT_WATCHDOG_TRANSCRIPT=$PROJ/$OTHER.jsonl" bash "$W" check volk Issue-7 --transcript "$TR" --now "$((T + 5))"
  is_ok
  # a flag naming a bad file is not rescued by a good variable
  run --separate-stderr env "DEVAGENT_WATCHDOG_TRANSCRIPT=$TR" bash "$W" check volk Issue-7 --transcript "$PROJ/notes.jsonl" --now "$((T + 5))"
  refused 2 "watchdog: usage: "
}

@test "a path with a space is judged" {
  local dir="$BATS_TEST_TMPDIR/my projects/C--src volk"
  at "$T" "$dir/$ID.jsonl"
  at "$((T + 600))" "$dir/$ID/subagents/agent 1.jsonl"
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$dir/$ID.jsonl" --now "$((T + 600 + LIMIT))"
  is_ok
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$dir/$ID.jsonl" --now "$((T + 600 + LIMIT + 1))"
  is_stalled subagent-transcript "$((T + 600))" "$((LIMIT + 1))"
}

@test "a C:\\…\\<uuid>.jsonl path is judged" {
  command -v cygpath >/dev/null 2>&1 || skip "no cygpath: not a Windows bash"
  at "$T" "$TR"
  local win
  win="$(cygpath -w "$TR")"
  [[ "$win" == *\\* ]]
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$win" --now "$((T + LIMIT))"
  is_ok
  run --separate-stderr env "DEVAGENT_WATCHDOG_TRANSCRIPT=$win" bash "$W" check volk Issue-7 --now "$((T + LIMIT + 1))"
  is_stalled transcript "$T" "$((LIMIT + 1))"
}

@test "an upper-case uuid reads the lower-case directory" {
  local up="$PROJ/$ID_UPPER.jsonl"
  at "$((T - 9000))" "$up"
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$up" --now "$((T + LIMIT))"
  is_stalled transcript "$((T - 9000))" "$((LIMIT + 9000))"
  at "$T" "$WD/$ID/beat"
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$up" --now "$((T + LIMIT))"
  is_ok
}

@test "stdout is empty and every stderr line starts \"watchdog: \" on exits 1 and 2" {
  # exit 1, four ways
  chk "$T"                                           # no transcript, no --since
  refused 1 "watchdog: error: "
  at "$T" "$TR"
  run --separate-stderr bash "$W" check nobody Issue-7 --transcript "$TR" --now "$T"
  refused 1 "watchdog: error: "
  printf 'this is = not [toml\n' > "$DA_HOME/config.toml"
  chk "$T"
  refused 1 "watchdog: error: "
  rm -f "$DA_HOME/config.toml"
  chk "$T"
  refused 1 "watchdog: error: "
  # exit 2, three ways
  write_cfg
  chk "$T" --frobnicate
  refused 2 "watchdog: usage: "
  chk "$T" --since yesterday
  refused 2 "watchdog: usage: "
  run --separate-stderr bash "$W" check volk
  refused 2 "watchdog: usage: "
}

@test "an unknown project exits 1" {
  at "$T" "$TR"
  run --separate-stderr bash "$W" check nobody Issue-7 --transcript "$TR" --now "$T"
  refused 1 "watchdog: error: "
  [[ "$stderr" == *nobody* ]]
  chk "$T"
  is_ok
}

@test "an unparseable config exits 1" {
  at "$T" "$TR"
  chk "$T"
  is_ok
  printf 'this is = not [toml\n' > "$DA_HOME/config.toml"
  chk "$T"
  refused 1 "watchdog: error: "
  # stalled by age, and still not called stalled
  chk "$((T + 99999))"
  refused 1 "watchdog: error: "
}

@test "a malformed or table-typed limit exits 1, never a default" {
  at "$T" "$TR"
  local bad
  for bad in 'watchdog_no_progress_secs = 0' 'watchdog_no_progress_secs = "abc"' \
             'watchdog_no_progress_secs = 604801' 'watchdog_silent_max_secs = 1.5'; do
    write_cfg "$bad"
    chk "$T"
    refused 1 "watchdog: error: "
  done
  write_cfg "" "watchdog_no_progress_secs = -5"
  chk "$T"
  refused 1 "watchdog_no_progress_secs"
  write_cfg
  printf '\n[defaults.watchdog_silent_max_secs]\nx = 1\n' >> "$DA_HOME/config.toml"
  chk "$T"
  refused 1 "watchdog_silent_max_secs"
  write_cfg
  chk "$T"
  is_ok
}

@test "a project limit overrides [defaults] for that project's check" {
  write_cfg "watchdog_no_progress_secs = 600" "watchdog_no_progress_secs = 60"
  LIMIT=60
  at "$T" "$TR"
  chk "$((T + 60))"
  is_ok
  chk "$((T + 61))"
  is_stalled transcript "$T" 61
}

# ---------------------------------------------------------------- Shape

@test "check and heartbeat do not move script, and check writes nothing" {
  at "$T" "$TR"
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash "$W" check volk Issue-7 --transcript "$TR" --now "$T"
  is_ok
  [ ! -e "$WD" ]
  beat
  is_ok
  [ -f "$WD/$ID/beat" ]
  [ ! -e "$WD/$ID/script" ]
}

@test "watchdog.sh and the launcher fixture are committed 100755" {
  local f
  for f in scripts/watchdog.sh tests/fixtures/watchdog/launcher.sh; do
    run git -C "$PLUGIN_ROOT" ls-files -s "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == 100755\ * ]] || { echo "$f: $output" >&2; return 1; }
  done
}

# ---------------------------------------------------------------- Script entry (Task 4)

@test "a real where.sh call is a progress source for check" {
  at "$((T - 9000))" "$TR"
  [ ! -e "$WD" ]
  run --separate-stderr env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [ -f "$WD/$ID/script" ]
  local s
  s="$(stat -c %Y "$WD/$ID/script")"
  chk "$((s + LIMIT - 1))"
  is_ok
  chk "$((s + LIMIT + 5))"
  is_stalled script "$s" "$((LIMIT + 5))"
}
