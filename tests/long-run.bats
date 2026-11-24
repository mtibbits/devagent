#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/long-run.bats — #932: libexec/long-run.sh, the wrapper that makes a
# long command's output count as progress, and scripts/lib/_longrun_pump.py,
# the byte pump it puts in the data path.
#
# Waits synchronise on an observable event (a file appears, a log shows a line)
# and are bounded by elapsed time; none asserts a real-clock upper bound. The
# passthrough loops run 20 times on Linux and 3 on Git Bash, where a wrapper
# start costs about a second (the 100-run measurements are Issue-932 R2-U1).
# `check` is asked at an injected --now except where the subject is a run that
# is live at the real time.

bats_require_minimum_version 1.5.0   # run --separate-stderr: stdout and stderr are both pinned

load 'lib/bats-helpers'

ID=0f8fad5b-d9cb-469f-a165-70867728950e
OTHER=7c9e6679-7425-40de-944b-e07fc1f90ae7
LIMIT=1200
DAY=86400

setup() {
  setup_tmp_devagent_home
  L="$PLUGIN_ROOT/libexec/long-run.sh"
  W="$PLUGIN_ROOT/scripts/watchdog.sh"
  PUMP="$PLUGIN_ROOT/scripts/lib/_longrun_pump.py"
  FX="$PLUGIN_ROOT/tests/fixtures/watchdog"
  WD="$DA_HOME/state/watchdog"
  LOGS="$WD/logs"
  TMP="$BATS_TEST_TMPDIR"
  GO="$TMP/go"
  PROJ="$TMP/projects/C--src-volk"
  TR="$PROJ/$ID.jsonl"
  mkdir -p "$PROJ" "$DA_HOME/fake-devdoc/Issue-7"
  : > "$DA_HOME/fake-devdoc/Issue-7/imPlan.md"
  write_cfg
  RUNS=20
  case "$(uname -s)" in MINGW*|MSYS*) RUNS=3 ;; esac
  BG_PIDS=()
}

teardown() {
  # Release and reap anything a failed test left held.
  : > "$GO" 2>/dev/null || true
  : > "$GO.2" 2>/dev/null || true
  local p
  for p in "${BG_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
  teardown_tmp_devagent_home
}

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

[project.good]
source_dir = "$DA_HOME/fake-src"
devdoc_dir = "$DA_HOME/fake-devdoc"
TOML
}

# unatt <command>... — run it as the unattended session $ID would.
unatt() { env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" "$@"; }

# bg <stdout file> <wrapper arguments>... — the wrapper in the background, as
# session $ID. Its stderr goes to <stdout file>.err; fd 3 is closed so bats
# never waits on it.
bg() {
  local out="$1"
  shift
  env DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" bash "$L" "$@" \
    > "$out" 2> "$out.err" 3>&- < /dev/null &
  BG_PID=$!
  BG_PIDS+=("$BG_PID")
}

# wait_for <command>... — poll until it succeeds; give up after 60 s.
wait_for() {
  local end=$((SECONDS + 60))
  until "$@"; do
    [ "$SECONDS" -lt "$end" ] || { echo "timed out waiting for: $*" >&2; return 1; }
    sleep 0.1
  done
}

# wraps — sets WRAPS to this session's wrap files, windows excluded.
wraps() {
  local f
  WRAPS=()
  for f in "$WD/$ID"/wrap.*; do
    [[ -f "$f" && "$f" != *.window ]] || continue
    WRAPS+=("$f")
  done
}
have_wraps() { wraps; [ "${#WRAPS[@]}" -ge "${1:-1}" ]; }
have_window() { compgen -G "$WD/$ID/wrap.*.window" > /dev/null; }
no_window() { if have_window; then return 1; fi; }
log_shows() { grep -qs -- "$1" "$LOGS"/*.log; }
newer_than() { [ "$(stat -c %Y "$1")" -gt "$2" ]; }

# at <epoch> <file>... — give each file (created if absent) that mtime.
at() {
  local t="$1" f
  shift
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    [ -e "$f" ] || : > "$f"
    touch -d "@$t" "$f"
  done
}

# chk <now> — `check volk Issue-7` on the fixture transcript at an injected time.
chk() {
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$TR" --now "$1"
}

is_ok() {
  [ "$status" -eq 0 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ "$output" = ok ]
}

# native <path> — the path as a native python reads it.
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s\n' "$1"; fi
}

# pump <stream> <log> <cap> <heartbeat> <every> <threshold> <run> — the pump
# alone, as the wrapper starts it. Empty <log> or <heartbeat> stay empty.
pump() {
  local log="$2" hb="$4"
  [ -z "$log" ] || log="$(native "$log")"
  [ -z "$hb" ] || hb="$(native "$hb")"
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' python3 -I -B "$(native "$PUMP")" "$1" "$log" "$3" "$hb" "$5" "$6" "$7"
}

# bulk <lines> — that many 100-byte lines on stdout.
bulk() {
  python3 -c 'import sys
w = sys.stdout.buffer.write
for i in range(int(sys.argv[1])):
    w(b"%099d\n" % i)' "$1"
}

size_of() { stat -c %s "$1"; }

# ---------------------------------------------------------------- Passthrough

@test "--merge output is byte-identical to the command run directly with 2>&1" {
  local r rc mode
  rc=0
  bash "$FX/interleave.sh" > "$TMP/g.merged" 2>&1 || rc=$?
  [ "$rc" -eq 3 ]
  [ "$(wc -l < "$TMP/g.merged")" -eq 80 ]
  for mode in attended unattended; do
    for r in $(seq 1 "$RUNS"); do
      rc=0
      if [ "$mode" = unattended ]; then
        unatt bash "$L" --merge -- bash "$FX/interleave.sh" > "$TMP/m.out" 2> "$TMP/m.err" || rc=$?
      else
        bash "$L" --merge -- bash "$FX/interleave.sh" > "$TMP/m.out" 2> "$TMP/m.err" || rc=$?
      fi
      [ "$rc" -eq 3 ] || { echo "$mode run $r: rc=$rc err=$(cat "$TMP/m.err")" >&2; return 1; }
      cmp "$TMP/m.out" "$TMP/g.merged" || { echo "$mode run $r: stdout differs" >&2; return 1; }
      [ ! -s "$TMP/m.err" ] || { echo "$mode run $r: stderr: $(cat "$TMP/m.err")" >&2; return 1; }
    done
  done
  # every run kept its own complete log: the same bytes between the wrapper's lines
  local f n=0
  for f in "$LOGS"/*.log; do
    n=$((n + 1))
    grep -v '^\[long-run\] ' "$f" | cmp - "$TMP/g.merged" || { echo "log $f differs" >&2; return 1; }
  done
  [ "$n" -eq "$((2 * RUNS))" ]
}

@test "separate streams are each byte-identical" {
  local r rc mode
  rc=0
  bash "$FX/interleave.sh" > "$TMP/g.out" 2> "$TMP/g.err" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$(wc -l < "$TMP/g.out")" -eq 40 ]
  [ "$(wc -l < "$TMP/g.err")" -eq 40 ]
  for mode in attended unattended; do
    for r in $(seq 1 "$RUNS"); do
      rc=0
      if [ "$mode" = unattended ]; then
        unatt bash "$L" bash "$FX/interleave.sh" > "$TMP/s.out" 2> "$TMP/s.err" || rc=$?
      else
        bash "$L" bash "$FX/interleave.sh" > "$TMP/s.out" 2> "$TMP/s.err" || rc=$?
      fi
      [ "$rc" -eq 3 ] || { echo "$mode run $r: rc=$rc" >&2; return 1; }
      cmp "$TMP/s.out" "$TMP/g.out" || { echo "$mode run $r: stdout differs" >&2; return 1; }
      cmp "$TMP/s.err" "$TMP/g.err" || { echo "$mode run $r: stderr differs" >&2; return 1; }
    done
  done
  # one writer per file: each stream's log is complete on its own
  local f n=0
  for f in "$LOGS"/*.out.log; do
    n=$((n + 1))
    grep -v '^\[long-run\] ' "$f" | cmp - "$TMP/g.out" || { echo "log $f differs" >&2; return 1; }
    grep -v '^\[long-run\] ' "${f%.out.log}.err.log" | cmp - "$TMP/g.err" || { echo "err log of $f differs" >&2; return 1; }
  done
  [ "$n" -eq "$((2 * RUNS))" ]
}

@test "binary bytes without a final newline pass unchanged" {
  python3 -c 'import sys
sys.stdout.buffer.write(bytes(range(256)) * 50 + b"a\r\nb\rc\n\x00tail")' > "$TMP/bin.gold"
  [ "$(size_of "$TMP/bin.gold")" -eq 12812 ]
  unatt bash "$L" --merge -- cat "$TMP/bin.gold" > "$TMP/bin.m"
  cmp "$TMP/bin.m" "$TMP/bin.gold"
  unatt bash "$L" -- cat "$TMP/bin.gold" > "$TMP/bin.s" 2> "$TMP/bin.e"
  cmp "$TMP/bin.s" "$TMP/bin.gold"
  [ ! -s "$TMP/bin.e" ]
  # the wrapper's own lines start on a line of their own in the log
  local f
  for f in "$LOGS/$ID".*.out.log; do
    [ "$(grep -ac '^\[long-run\] closed stdout ' "$f")" -eq 1 ]
    [ "$(grep -ac '^\[long-run\] end ' "$f")" -eq 1 ]
  done
}

@test "stdin reaches the command" {
  run --separate-stderr bash -c 'printf "one\ntwo" | bash "$1" bash "$2"' _ "$L" "$FX/echo-stdin.sh"
  [ "$status" -eq 0 ]
  [ "$output" = $'probe=unset\none\ntwo' ]
  run --separate-stderr bash -c 'printf "one\ntwo" | bash "$1" --merge bash "$2"' _ "$L" "$FX/echo-stdin.sh"
  [ "$status" -eq 0 ]
  [ "$output" = $'probe=unset\none\ntwo' ]
}

@test "exit codes 0, 3 and 127 pass through" {
  run bash "$L" -- bash -c 'exit 0'
  [ "$status" -eq 0 ]
  run bash "$L" -- bash -c 'exit 3'
  [ "$status" -eq 3 ]
  run -127 bash "$L" -- bash -c 'exit 127'
  [ "$status" -eq 127 ]
  run bash "$L" --merge -- bash -c 'exit 3'
  [ "$status" -eq 3 ]
  # a command that does not exist is 127 too, and says so on stderr
  run --separate-stderr -127 bash "$L" -- no-such-command-932
  [ "$status" -eq 127 ]
  [ -z "$output" ]
  [[ "$stderr" == *no-such-command-932* ]]
}

@test "NAME=value words reach the command" {
  run --separate-stderr bash "$L" LR_PROBE=7 bash "$FX/echo-stdin.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "probe=7" ]
  # control: without the word the variable is unset
  run --separate-stderr bash "$L" bash "$FX/echo-stdin.sh" < /dev/null
  [ "$output" = "probe=unset" ]
  # the log names the command, not the assignment
  grep -q '^\[long-run\] start [0-9T:Z-]* run=[0-9]*-[0-9]* cmd=bash$' "$LOGS"/no-session.*.out.log
}

@test "the command runs without --" {
  run --separate-stderr bash "$L" --merge echo plain
  [ "$status" -eq 0 ]
  [ "$output" = plain ]
  # and an option-looking word after the command belongs to the command
  run --separate-stderr bash "$L" echo --merge -- x
  [ "$status" -eq 0 ]
  [ "$output" = "--merge -- x" ]
}

@test "a reader that closes early ends the run, and the caller's other descriptors reach the command" {
  # `yes` never ends by itself: the pump stops reading when its output closes,
  # so the command sees the closed pipe as it would without the wrapper.
  local shape
  for shape in "" --merge; do
    run --separate-stderr bash -c 'timeout 60 bash "$1" $2 yes | head -n 1' _ "$L" "$shape"
    [ "$status" -eq 0 ] || { echo "shape='$shape' rc=$status" >&2; return 1; }
    [ "$output" = y ]
  done
  # the wrapper keeps the caller's stdout and stderr on descriptors of its own
  # choosing, so a low one the caller opened is still the caller's
  bash "$L" bash -c 'echo through >&4' 4> "$TMP/fd4"
  [ "$(cat "$TMP/fd4")" = through ]
}

# ---------------------------------------------------------------- Telemetry

@test "a running wrapped command keeps check ok beside a two-hour-old transcript" {
  local now
  now="$(date +%s)"
  at "$((now - 7200))" "$TR"
  # control: before the run this session is stalled
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$TR"
  [ "$status" -eq 3 ]
  [[ "$output" == "stalled no-progress limit=1200s "*" last=transcript "* ]]
  bg "$TMP/bg.out" -- bash "$FX/hold.sh" "$GO"
  wait_for have_wraps
  run --separate-stderr bash "$W" check volk Issue-7 --transcript "$TR"
  is_ok
  : > "$GO"
  wait "$BG_PID"
  [ "$(cat "$TMP/bg.out")" = $'up\nafter go' ]
}

@test "a wrap file the real wrapper left is a progress source for check" {
  at 1600000000 "$TR"
  [ ! -e "$WD" ]
  run --separate-stderr unatt bash "$L" echo hi
  [ "$status" -eq 0 ]
  [ "$output" = hi ]
  wraps
  [ "${#WRAPS[@]}" -eq 1 ]
  local s
  s="$(stat -c %Y "${WRAPS[0]}")"
  chk "$((s + LIMIT - 1))"
  is_ok
  chk "$((s + LIMIT + 5))"
  [ "$status" -eq 3 ]
  [[ "$output" == "stalled no-progress limit=1200s age=1205s last=wrap at="* ]]
}

@test "a gap longer than the interval logs exactly one quiet line and the run finishes" {
  # the project's interval (2) is the threshold, not the [defaults] one
  write_cfg "watchdog_telemetry_secs = 100" "watchdog_telemetry_secs = 2"
  run --separate-stderr unatt bash "$L" --merge --project volk --every 0 -- bash "$FX/gappy.sh" "$LOGS" 4
  [ "$status" -eq 0 ]
  [ "$output" = $'first\nsecond' ]
  local log
  log="$(echo "$LOGS/$ID".*.log)"
  [ -f "$log" ]
  run grep -c '^\[long-run\] quiet ' "$log"
  [ "$output" = 1 ]
  run grep -E '^\[long-run\] quiet [0-9]+s > 2s ended [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z run=[0-9]+-[0-9]+$' "$log"
  [ "$status" -eq 0 ]
  local gap="${output#*quiet }"
  gap="${gap%%s *}"
  [ "$gap" -ge 3 ]
  run grep -E '^\[long-run\] closed merged .* longest-gap=[0-9]+s refreshes=2$' "$log"
  [ "$status" -eq 0 ]
  # the quiet line sits between the two lines it separates
  [ "$(grep -n -e '^first$' -e '^\[long-run\] quiet ' -e '^second$' "$log" | cut -d: -f2 | cut -c1-6 | tr '\n' ' ')" = "first [long- second " ]
}

@test "the interval's project is --project, else DEVAGENT_ACTIVE_PROJECT, else [defaults]" {
  # a malformed project value is the observable: it warns, and never fails the run
  write_cfg "" "watchdog_telemetry_secs = 0"
  run --separate-stderr unatt env DEVAGENT_ACTIVE_PROJECT=volk bash "$L" echo hi
  [ "$status" -eq 0 ]
  [ "$output" = hi ]
  [[ "$stderr" == "long-run: warning: watchdog_telemetry_secs"*"180 s"* ]]
  [ "$(wc -l <<<"$stderr")" -eq 1 ]
  run --separate-stderr unatt env DEVAGENT_ACTIVE_PROJECT=volk bash "$L" --project good echo hi
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run --separate-stderr unatt bash "$L" echo hi
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "chunks.sh reports refreshes=3 under --every 0 and refreshes=2 under --every 3600" {
  # The rule: a refresh is counted each time the pump moves the file's mtime
  # forward. Every chunk does under --every 0, and the final refresh then has
  # nothing to move. Under --every 3600 the first chunk does, the next two are
  # inside the hour, and the final refresh moves the file to the last chunk.
  run --separate-stderr unatt bash "$L" --merge --every 0 -- bash "$FX/chunks.sh" "$LOGS"
  [ "$status" -eq 0 ]
  [ "$output" = $'chunk 1\nchunk 2\nchunk 3' ]
  run grep -h '^\[long-run\] closed ' "$LOGS/$ID".*.log
  [[ "$output" == "[long-run] closed merged "*" refreshes=3" ]]
  rm -f "$LOGS"/*.log
  run --separate-stderr unatt bash "$L" --merge --every 3600 -- bash "$FX/chunks.sh" "$LOGS"
  [ "$status" -eq 0 ]
  run grep -h '^\[long-run\] closed ' "$LOGS/$ID".*.log
  [[ "$output" == "[long-run] closed merged "*" refreshes=2" ]]
}

@test "two streams ending at different times leave the later stream's time" {
  # stdout: one chunk that refreshes and one inside --every that waits for the
  # final refresh. stderr speaks 2 s later, and the command ends only once that
  # line is carried. The stdout pump's final refresh must not move the file
  # back to its own last chunk.
  run --separate-stderr unatt bash "$L" --every 3600 -- bash -c '
    carried() { local e=$((SECONDS + 30)); until grep -qs "^$1\$" "$2"/*."$3".log || [ "$SECONDS" -ge "$e" ]; do sleep 0.1; done; }
    echo o1; carried o1 "$1" out
    echo o2; carried o2 "$1" out
    sleep 2; date +%s > "$2"; echo late >&2; carried late "$1" err' _ "$LOGS" "$TMP/late"
  [ "$status" -eq 0 ]
  [ "$output" = $'o1\no2' ]
  [ "$stderr" = late ]
  wraps
  [ "$(stat -c %Y "${WRAPS[0]}")" -ge "$(cat "$TMP/late")" ]
}

@test "the pump never moves a heartbeat file earlier: two hours ahead stays" {
  local now ahead
  now="$(date +%s)"
  ahead="$((now + 7200))"
  at "$ahead" "$TMP/hb"
  printf 'a\nb\n' | pump stdout "$TMP/p.log" 5242880 "$TMP/hb" 0 180 r1 > "$TMP/p.out"
  [ "$(cat "$TMP/p.out")" = $'a\nb' ]
  [ "$(stat -c %Y "$TMP/hb")" -eq "$ahead" ]
  grep -q '^\[long-run\] closed stdout .* run=r1 longest-gap=[0-9]*s refreshes=0$' "$TMP/p.log"
  # control: a file behind the clock is moved, once
  at "$((now - 7200))" "$TMP/hb2"
  printf 'a\n' | pump stdout "$TMP/p2.log" 5242880 "$TMP/hb2" 0 180 r2 > /dev/null
  [ "$(stat -c %Y "$TMP/hb2")" -ge "$now" ]
  grep -q '^\[long-run\] closed stdout .* run=r2 longest-gap=[0-9]*s refreshes=1$' "$TMP/p2.log"
}

@test "a heartbeat file removed mid-run is put back by the next chunk; a missing directory only skips it" {
  [ ! -e "$TMP/gone" ]
  printf 'a\n' | pump stdout "$TMP/g.log" 5242880 "$TMP/gone" 0 180 r1 > "$TMP/g.out"
  [ "$(cat "$TMP/g.out")" = a ]
  [ -f "$TMP/gone" ]
  # no directory to put it in: the bytes still pass and nothing is created
  printf 'b\n' | pump stdout "$TMP/g2.log" 5242880 "$TMP/nodir/hb" 0 180 r2 > "$TMP/g2.out"
  [ "$(cat "$TMP/g2.out")" = b ]
  [ ! -e "$TMP/nodir" ]
}

@test "the wrapper's own lines and another run's output do not move this run's file" {
  local t=1600000000 a
  bg "$TMP/a.out" --every 0 -- bash "$FX/hold.sh" --quiet "$GO"
  wait_for have_wraps
  a="${WRAPS[0]}"
  at "$t" "$a"
  # another run of the same session, with output
  run --separate-stderr unatt bash "$L" --every 0 echo other
  [ "$status" -eq 0 ]
  wraps
  [ "${#WRAPS[@]}" -eq 2 ]
  [ "$(stat -c %Y "$a")" -eq "$t" ]
  : > "$GO"
  wait "$BG_PID"
  # the first run has ended: its start, closed and end lines moved nothing
  grep -q '^\[long-run\] end ' "$LOGS/$ID.${a##*/wrap.}.out.log"
  [ "$(stat -c %Y "$a")" -eq "$t" ]
  # control: the run that printed moved its own file
  local b
  for b in "${WRAPS[@]}"; do [ "$b" = "$a" ] || break; done
  [ "$(stat -c %Y "$b")" -gt "$t" ]
}

@test "long-run.sh does not move script" {
  run --separate-stderr unatt bash "$L" echo hi
  [ "$status" -eq 0 ]
  have_wraps
  [ ! -e "$WD/$ID/script" ]
  # control: a devagent script run under the wrapper moves it itself
  run --separate-stderr unatt bash "$L" bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ -f "$WD/$ID/script" ]
}

# ---------------------------------------------------------------- Logs

@test "the log is under \$DA_HOME/state/watchdog/logs, nothing under the devDoc fixture" {
  local before after
  before="$(cd "$DA_HOME" && find fake-devdoc config.toml | sort)"
  run --separate-stderr unatt bash "$L" --merge --project volk echo hi
  [ "$status" -eq 0 ]
  wraps
  local run_id="${WRAPS[0]##*/wrap.}"
  [[ "$run_id" =~ ^[0-9]+-[0-9]+$ ]]
  [ -f "$LOGS/$ID.$run_id.log" ]
  [ "$(ls "$LOGS")" = "$ID.$run_id.log" ]
  after="$(cd "$DA_HOME" && find fake-devdoc config.toml | sort)"
  [ "$before" = "$after" ]
  # everything the run wrote is under state/watchdog
  [ "$(cd "$DA_HOME/state" && find . -type f | grep -vc '^\./watchdog/')" -eq 0 ]
}

@test "logs are private to the user" {
  run --separate-stderr unatt bash "$L" -- bash -c 'echo out; echo err >&2'
  [ "$status" -eq 0 ]
  run --separate-stderr unatt bash "$L" --merge echo merged
  [ "$status" -eq 0 ]
  # Git Bash has no POSIX file modes (stat reports what the ACL maps to), so
  # there the run only has to leave its three logs; the modes are checked
  # where they are real.
  local f n=0 modes=1
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) modes=0 ;; esac
  (( ! modes )) || [ "$(stat -c %a "$LOGS")" = 700 ] || { echo "dir mode $(stat -c %a "$LOGS")" >&2; return 1; }
  for f in "$LOGS"/*.log; do
    (( ! modes )) || [ "$(stat -c %a "$f")" = 600 ] || { echo "$f: $(stat -c %a "$f")" >&2; return 1; }
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]
}

@test "each run's log starts with its start line and ends with its end line" {
  run --separate-stderr unatt bash "$L" --merge -- bash -c 'echo body; exit 4'
  [ "$status" -eq 4 ]
  wraps
  local run_id="${WRAPS[0]##*/wrap.}" log
  log="$LOGS/$ID.$run_id.log"
  local iso='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  [ "$(wc -l < "$log")" -eq 4 ]
  sed -n 1p "$log" | grep -Eq "^\[long-run\] start $iso run=$run_id cmd=bash\$"
  [ "$(sed -n 2p "$log")" = body ]
  sed -n 3p "$log" | grep -Eq "^\[long-run\] closed merged $iso run=$run_id longest-gap=[0-9]+s refreshes=1\$"
  sed -n 4p "$log" | grep -Eq "^\[long-run\] end $iso run=$run_id rc=4\$"
  # two streams: each file carries the run's start and end around its own stream
  rm -rf "$WD"
  run --separate-stderr unatt bash "$L" -- bash -c 'echo body; echo oops >&2; exit 5'
  [ "$status" -eq 5 ]
  wraps
  run_id="${WRAPS[0]##*/wrap.}"
  local s
  for s in out err; do
    log="$LOGS/$ID.$run_id.$s.log"
    [ "$(wc -l < "$log")" -eq 4 ]
    sed -n 1p "$log" | grep -Eq "^\[long-run\] start $iso run=$run_id cmd=bash\$"
    sed -n 4p "$log" | grep -Eq "^\[long-run\] end $iso run=$run_id rc=5\$"
  done
  [ "$(sed -n 2p "$LOGS/$ID.$run_id.out.log")" = body ]
  [ "$(sed -n 2p "$LOGS/$ID.$run_id.err.log")" = oops ]
  sed -n 3p "$LOGS/$ID.$run_id.out.log" | grep -q '^\[long-run\] closed stdout '
  sed -n 3p "$LOGS/$ID.$run_id.err.log" | grep -q '^\[long-run\] closed stderr '
  [ ! -e "$LOGS/$ID.$run_id.log" ]
}

@test "concurrent runs of one session write separate logs" {
  bg "$TMP/a.out" --merge -- bash -c 'echo run-a; exec bash "$2" --quiet "$1"' _ "$GO" "$FX/hold.sh"
  local pa="$BG_PID"
  bg "$TMP/b.out" --merge -- bash -c 'echo run-b; exec bash "$2" --quiet "$1"' _ "$GO" "$FX/hold.sh"
  local pb="$BG_PID"
  wait_for have_wraps 2
  : > "$GO"
  wait "$pa"
  wait "$pb"
  local -a logs=("$LOGS/$ID".*.log)
  [ "${#logs[@]}" -eq 2 ]
  [ "$(grep -l '^run-a$' "${logs[@]}" | wc -l)" -eq 1 ]
  [ "$(grep -l '^run-b$' "${logs[@]}" | wc -l)" -eq 1 ]
  [ "$(grep -l '^run-a$' "${logs[@]}")" != "$(grep -l '^run-b$' "${logs[@]}")" ]
  local f
  for f in "${logs[@]}"; do
    [ "$(grep -c '^\[long-run\] start ' "$f")" -eq 1 ]
    [ "$(grep -c '^\[long-run\] end .* rc=0$' "$f")" -eq 1 ]
  done
}

@test "the log and .log.1 each stay within the cap" {
  bulk 25000 > "$TMP/gold"
  [ "$(size_of "$TMP/gold")" -eq 2500000 ]
  unatt bash "$L" --merge --log-cap 1000000 -- cat "$TMP/gold" > "$TMP/out"
  cmp "$TMP/out" "$TMP/gold"
  local log
  log="$(echo "$LOGS/$ID".*.log)"
  [ -f "$log" ] && [ -f "$log.1" ]
  [ "$(size_of "$log")" -le 1000000 ]
  [ "$(size_of "$log.1")" -le 1000000 ]
  [ "$(size_of "$log.1")" -gt 800000 ]         # the cap is used, not a fraction of it
  tail -n 1 "$log" | grep -q '^\[long-run\] end .* rc=0$'
  # the newest bytes are the ones kept
  [ "$(grep -v '^\[long-run\] ' "$log" | tail -n 1)" = "$(tail -n 1 "$TMP/gold")" ]
  # two streams: each file is capped by its own writer
  rm -rf "$WD"
  unatt bash "$L" --log-cap 1000000 -- bash -c 'cat "$1"; cat "$1" >&2' _ "$TMP/gold" > "$TMP/out" 2> "$TMP/err"
  cmp "$TMP/out" "$TMP/gold"
  cmp "$TMP/err" "$TMP/gold"
  local f
  for f in "$LOGS/$ID".*.out.log "$LOGS/$ID".*.out.log.1 "$LOGS/$ID".*.err.log "$LOGS/$ID".*.err.log.1; do
    [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
    [ "$(size_of "$f")" -le 1000000 ] || { echo "$f is $(size_of "$f")" >&2; return 1; }
  done
}

@test "a failed rotation keeps the log within the cap" {
  # A non-empty directory where .log.1 goes: the rename fails on every host.
  mkdir -p "$TMP/p.log.1/keep"
  bulk 25000 > "$TMP/gold"
  pump merged "$TMP/p.log" 1000000 "" 0 0 r1 < "$TMP/gold" > "$TMP/out"
  cmp "$TMP/out" "$TMP/gold"                    # the copy never stops
  [ -d "$TMP/p.log.1/keep" ]
  [ "$(size_of "$TMP/p.log")" -le 1000000 ]
  [ "$(size_of "$TMP/p.log")" -gt 0 ]
  [ "$(grep -v '^\[long-run\] ' "$TMP/p.log" | tail -n 1)" = "$(tail -n 1 "$TMP/gold")" ]
  grep -q '^\[long-run\] closed merged ' "$TMP/p.log"
  # control: with the rename free, the same input rotates
  pump merged "$TMP/q.log" 1000000 "" 0 0 r2 < "$TMP/gold" > /dev/null
  [ -f "$TMP/q.log.1" ]
  [ "$(size_of "$TMP/q.log.1")" -gt 800000 ]
}

@test "the pump leaves room under the cap for the wrapper's end line" {
  # 300 bytes under the cap plus 100 more would end 200 under it: no room for
  # the end line, so the log rotates first.
  head -c 999700 /dev/zero > "$TMP/p.log"
  head -c 100 /dev/zero | pump merged "$TMP/p.log" 1000000 "" 0 0 r1 > /dev/null
  [ "$(size_of "$TMP/p.log.1")" -eq 999700 ]
  [ "$(size_of "$TMP/p.log")" -le 999744 ]
  # control: 500 under the cap, the same 100 bytes and the closed line fit
  head -c 999500 /dev/zero > "$TMP/q.log"
  head -c 100 /dev/zero | pump merged "$TMP/q.log" 1000000 "" 0 0 r2 > /dev/null
  [ ! -e "$TMP/q.log.1" ]
  [ "$(size_of "$TMP/q.log")" -gt 999600 ]
  [ "$(size_of "$TMP/q.log")" -le 999744 ]
}

@test "logs and session directories older than 14 days are pruned at start" {
  local now old young
  now="$(date +%s)"
  old="$((now - 15 * DAY))"
  young="$((now - 13 * DAY))"
  at "$old" "$LOGS/$OTHER.1-1.log" "$LOGS/no-session.1-1.out.log.1"
  at "$young" "$LOGS/$OTHER.2-2.log"
  # a session whose every file is old; one with a single young file; a
  # directory this feature did not make
  local dead=11111111-1111-4111-8111-111111111111 live=22222222-2222-4222-8222-222222222222
  at "$old" "$WD/$dead/script" "$WD/$dead/wrap.1-1" "$WD/$dead"
  at "$old" "$WD/$live/script"
  at "$young" "$WD/$live/beat"
  at "$old" "$WD/$live"
  at "$old" "$WD/not-a-session/file" "$WD/not-a-session"
  run --separate-stderr bash "$L" echo hi
  [ "$status" -eq 0 ]
  [ "$output" = hi ]
  [ -z "$stderr" ]
  [ ! -e "$LOGS/$OTHER.1-1.log" ]
  [ ! -e "$LOGS/no-session.1-1.out.log.1" ]
  [ -f "$LOGS/$OTHER.2-2.log" ]
  [ ! -e "$WD/$dead" ]
  [ -f "$WD/$live/script" ] && [ -f "$WD/$live/beat" ]
  [ -f "$WD/not-a-session/file" ]
}

# ---------------------------------------------------------------- Attended

@test "no marker: no state/watchdog/<id>/ directory, identical bytes and exit code, the log exists" {
  local rc=0
  bash "$FX/interleave.sh" > "$TMP/g.out" 2> "$TMP/g.err" || true
  env "CLAUDE_CODE_SESSION_ID=$ID" bash "$L" bash "$FX/interleave.sh" > "$TMP/s.out" 2> "$TMP/s.err" || rc=$?
  [ "$rc" -eq 3 ]
  cmp "$TMP/s.out" "$TMP/g.out"
  cmp "$TMP/s.err" "$TMP/g.err"
  [ ! -e "$WD/$ID" ]
  [ "$(ls "$WD")" = logs ]
  local -a logs=("$LOGS"/no-session.*.out.log)
  [ "${#logs[@]}" -eq 1 ] && [ -f "${logs[0]}" ]
  [[ "${logs[0]##*/}" =~ ^no-session\.[0-9]+-[0-9]+\.out\.log$ ]]
  [ -f "${logs[0]%.out.log}.err.log" ]
  # an attended run writes no quiet note, whatever the gap
  run grep -l '^\[long-run\] quiet ' "$LOGS"/*.log
  [ "$status" -eq 1 ]
  # control: the same call with the marker makes the directory
  unatt bash "$L" echo hi > /dev/null
  [ -d "$WD/$ID" ]
}

@test "no valid id: the log is no-session.<run>.log" {
  run --separate-stderr env DEVAGENT_UNATTENDED=1 CLAUDE_CODE_SESSION_ID=not-a-uuid bash "$L" --merge echo hi
  [ "$status" -eq 0 ]
  [ "$output" = hi ]
  [ -z "$stderr" ]
  local -a logs=("$LOGS"/*)
  [ "${#logs[@]}" -eq 1 ]
  [[ "${logs[0]##*/}" =~ ^no-session\.[0-9]+-[0-9]+\.log$ ]]
  [ "$(ls "$WD")" = logs ]
  grep -q '^hi$' "${logs[0]}"
}

# ---------------------------------------------------------------- Silent window

@test "--silent 1 under maximum 60 writes a 60 window, removed when the run ends" {
  write_cfg "watchdog_silent_max_secs = 60"
  bg "$TMP/bg.out" --silent 1 -- bash "$FX/hold.sh" "$GO"
  wait_for have_window
  wraps
  [ "${#WRAPS[@]}" -eq 1 ]
  [ "$(cat "${WRAPS[0]}.window")" = 60 ]
  : > "$GO"
  wait "$BG_PID"
  no_window
  [ -f "${WRAPS[0]}" ]                         # the run's file stays as ordinary progress
  # the other spellings: 45s is 45 seconds, 1m is 60
  bg "$TMP/bg2.out" --silent 45s -- bash "$FX/hold.sh" "$GO.2"
  wait_for have_window
  [ "$(cat "$WD/$ID"/wrap.*.window)" = 45 ]
  : > "$GO.2"
  wait "$BG_PID"
  no_window
}

@test "--silent 2 under maximum 60 exits 2 and the command never runs" {
  write_cfg "watchdog_silent_max_secs = 60"
  run --separate-stderr unatt bash "$L" --silent 2 -- touch "$TMP/ran"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "long-run: usage: --silent 2 exceeds the silent-window maximum of 60 s; declare a shorter window (the maximum is operator-set and is not changed from a session)" ]
  [ ! -e "$TMP/ran" ]
  [ ! -e "$WD" ]
  # attended, the same refusal
  run --separate-stderr bash "$L" --silent 2 -- touch "$TMP/ran"
  [ "$status" -eq 2 ]
  [ ! -e "$TMP/ran" ]
  # not a window at all
  run --separate-stderr unatt bash "$L" --silent 1h -- touch "$TMP/ran"
  [ "$status" -eq 2 ]
  [[ "$stderr" == "long-run: usage: --silent 1h is not a window"* ]]
  [ ! -e "$TMP/ran" ]
  # control: the window that fits runs the command
  run --separate-stderr unatt bash "$L" --silent 1 -- touch "$TMP/ran"
  [ "$status" -eq 0 ]
  [ -e "$TMP/ran" ]
}

@test "a wrap file and window left by a killed wrapper are ok at T+window-1 and stalled, silent-window=expired, at T+window+1" {
  write_cfg "watchdog_silent_max_secs = 60" "watchdog_no_progress_secs = 30"
  local t=1700000000
  at "$((t - 9000))" "$TR"
  bg "$TMP/bg.out" --silent 1 -- bash "$FX/hold.sh" "$GO"
  wait_for have_window
  wait_for log_shows '^up$'
  kill -KILL "$BG_PID"
  wait "$BG_PID" 2>/dev/null || true
  : > "$GO"
  wait_for log_shows '^\[long-run\] closed stdout '   # the command and its pumps have ended
  have_window                                         # nobody was left to remove it
  wraps
  [ "$(cat "${WRAPS[0]}.window")" = 60 ]
  run grep -l '^\[long-run\] end ' "$LOGS"/*.log
  [ "$status" -eq 1 ]
  at "$t" "${WRAPS[0]}"
  chk "$((t + 59))"
  is_ok
  chk "$((t + 61))"
  [ "$status" -eq 3 ]
  [ "$output" = "stalled no-progress limit=30s age=61s last=wrap at=2023-11-14T22:13:20Z silent-window=expired" ]
}

@test "output and a script call during the run move their own files and keep the window" {
  write_cfg "watchdog_silent_max_secs = 60"
  local t=1600000000
  bg "$TMP/bg.out" --silent 1 --every 0 -- bash "$FX/hold.sh" "$GO" "$GO.2"
  wait_for have_window
  wait_for log_shows '^up$'
  wraps
  at "$t" "${WRAPS[0]}"
  # output during the run moves the wrap file and keeps the window
  : > "$GO"
  wait_for newer_than "${WRAPS[0]}" "$t"
  [ "$(cat "${WRAPS[0]}.window")" = 60 ]
  # a script call during the run moves `script` and keeps the window
  [ ! -e "$WD/$ID/script" ]
  run --separate-stderr unatt bash "$PLUGIN_ROOT/scripts/where.sh" volk
  [ "$status" -eq 0 ]
  [ -f "$WD/$ID/script" ]
  [ "$(cat "${WRAPS[0]}.window")" = 60 ]
  : > "$GO.2"
  wait "$BG_PID"
  no_window
}

# ---------------------------------------------------------------- Grammar

# refused <stderr fragment> — exit 2, nothing on stdout, one prefixed line.
refused() {
  [ "$status" -eq 2 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ -z "$output" ]
  [[ "$stderr" == "long-run: usage: "* ]] || { echo "err=$stderr" >&2; return 1; }
  [ "$(wc -l <<<"$stderr")" -eq 1 ]
  [[ "$stderr" == *"$1"* ]] || { echo "err=$stderr" >&2; return 1; }
  [ ! -e "$TMP/ran" ]
}

@test "an unknown flag exits 2" {
  run --separate-stderr unatt bash "$L" --quiet -- touch "$TMP/ran"
  refused "unknown option --quiet"
  run --separate-stderr unatt bash "$L" --project 'a b' -- touch "$TMP/ran"
  refused "--project"
  run --separate-stderr unatt bash "$L" --project
  refused "--project needs a value"
  run --separate-stderr unatt bash "$L" --silent "" -- touch "$TMP/ran"
  refused "--silent needs a non-empty value"
  [ ! -e "$WD" ]                                # a refusal writes nothing
}

@test "no command exits 2" {
  run --separate-stderr unatt bash "$L"
  refused "no command"
  run --separate-stderr unatt bash "$L" --merge --
  refused "no command"
  run --separate-stderr unatt bash "$L" --merge LR_PROBE=7
  refused "no command"
  [ ! -e "$WD" ]
}

@test "--every and --log-cap out of range exit 2" {
  local v
  for v in 12345 x; do
    run --separate-stderr unatt bash "$L" --every "$v" -- touch "$TMP/ran"
    refused "--every"
  done
  for v in 999999 12345678901 x; do
    run --separate-stderr unatt bash "$L" --log-cap "$v" -- touch "$TMP/ran"
    refused "--log-cap"
  done
  # control: the edges run the command
  run --separate-stderr unatt bash "$L" --every 0 --log-cap 1000000 -- touch "$TMP/ran"
  [ "$status" -eq 0 ]
  [ -e "$TMP/ran" ]
  rm -f "$TMP/ran"
  run --separate-stderr unatt bash "$L" --every 9999 --log-cap 9999999999 -- touch "$TMP/ran"
  [ "$status" -eq 0 ]
  [ -e "$TMP/ran" ]
}

# shim_path <dir> — a PATH directory holding the tools the wrapper uses and no
# python3, each a shim that calls the real one by its full path.
shim_path() {
  local dir="$1" tool real
  mkdir -p "$dir"
  for tool in dirname mkdir find rm cygpath env cat sleep stat date sed grep touch uname; do
    real="$(command -v "$tool" 2>/dev/null)" || continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
}

@test "python3 absent from PATH: output and exit code unchanged, one warning" {
  shim_path "$TMP/bin"
  local bash_bin
  bash_bin="$(command -v bash)"
  # control: on this PATH python3 is not found, and the tools are
  run env "PATH=$TMP/bin" "$bash_bin" -c 'command -v python3'
  [ "$status" -ne 0 ]
  run env "PATH=$TMP/bin" "$bash_bin" -c 'command -v find'
  [ "$status" -eq 0 ]
  local shape
  for shape in "" --merge; do
    run --separate-stderr env "PATH=$TMP/bin" DEVAGENT_UNATTENDED=1 "CLAUDE_CODE_SESSION_ID=$ID" \
      "$bash_bin" "$L" $shape -- "$bash_bin" -c 'echo hi; echo oops >&2; exit 3'
    [ "$status" -eq 3 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
    [ "$(grep -c '^long-run: warning: ' <<<"$stderr")" -eq 1 ] || { echo "err=$stderr" >&2; return 1; }
    [[ "$stderr" == *"python3"* ]]
    if [ -n "$shape" ]; then
      # merged: the command's stderr joins its stdout, as when pumped
      [ "$output" = "$(printf 'hi\noops')" ] || { echo "out=$output" >&2; return 1; }
      [ -z "$(grep -v '^long-run: warning: ' <<<"$stderr")" ]
    else
      [ "$output" = hi ]
      [ "$(grep -v '^long-run: warning: ' <<<"$stderr")" = oops ]
    fi
  done
  # the run is still recorded as one, and its window would still be dropped
  have_wraps 2
  no_window
}

@test "a python3 that cannot run: the command runs unwrapped, one warning" {
  shim_path "$TMP/bin"
  printf '#!/bin/sh\nexit 9\n' > "$TMP/bin/python3"
  chmod +x "$TMP/bin/python3"
  local bash_bin
  bash_bin="$(command -v bash)"
  run --separate-stderr env "PATH=$TMP/bin" "$bash_bin" "$L" -- "$bash_bin" -c 'echo hi; exit 3'
  [ "$status" -eq 3 ] || { echo "rc=$status out=$output err=$stderr" >&2; return 1; }
  [ "$output" = hi ]
  [ "$(grep -c '^long-run: warning: ' <<<"$stderr")" -eq 1 ] || { echo "err=$stderr" >&2; return 1; }
}

# ---------------------------------------------------------------- Shipping

@test "long-run.sh and its fixtures are committed 100755" {
  [ -f "$L" ]
  local f
  for f in libexec/long-run.sh tests/fixtures/watchdog/interleave.sh tests/fixtures/watchdog/gappy.sh \
           tests/fixtures/watchdog/chunks.sh tests/fixtures/watchdog/echo-stdin.sh tests/fixtures/watchdog/hold.sh; do
    run git -C "$PLUGIN_ROOT" ls-files -s "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == 100755\ * ]] || { echo "$f: $output" >&2; return 1; }
  done
}

@test "the wrapper is outside scripts/, past the skills' grant prefix, and the CI gates still read it" {
  [ ! -e "$PLUGIN_ROOT/scripts/long-run.sh" ]
  # the two grant shapes every command and skill carries end at scripts/
  run grep -rhoE 'Bash\(bash "\$\{CLAUDE_PLUGIN_ROOT\}/[a-z]+/' "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/agents"
  [ -n "$output" ]
  [ "$(sort -u <<<"$output")" = 'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/' ]
  # the shellcheck gate and the step-number census name libexec
  grep -q 'find scripts libexec -name "\*\.sh"' "$PLUGIN_ROOT/.github/workflows/shellcheck-scripts.yml"
  grep -q "'libexec'" "$PLUGIN_ROOT/scripts/lib/check-step-pairings.py"
}

@test "a path through scripts/.. or with a . segment is refused before the command runs (the grant matches it as text)" {
  local p
  for p in "$PLUGIN_ROOT/scripts/../libexec/long-run.sh" "$PLUGIN_ROOT/libexec/./long-run.sh"; do
    run --separate-stderr bash "$p" echo SHOULD-NOT-RUN
    [ "$status" -eq 2 ] || { echo "$p: rc=$status out=$output err=$stderr" >&2; return 1; }
    [ -z "$output" ]
    [[ "$stderr" == *"long-run: refused: run this wrapper by its own path"* ]]
  done
  # control: the canonical path runs the command
  run --separate-stderr bash "$PLUGIN_ROOT/libexec/long-run.sh" echo RAN
  [ "$status" -eq 0 ]
  [ "$output" = RAN ]
}
