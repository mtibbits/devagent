#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/lib_notify.bats — #961: the launcher contracts. The DEVAGENT_UNATTENDED
# marker (read only through devagent_unattended, scripts/lib/paths.sh) and the
# suite guard that unsets it; the notifications file and its one appender
# (scripts/lib/notify.sh, scripts/lib/_notify.py). Spec §7.3.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-twoproject.toml
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  NOTIFY="$PLUGIN_ROOT/scripts/lib/notify.sh"
  . "$NOTIFY"
  NF="$DA_HOME/state/notifications.jsonl"
}

teardown() { teardown_tmp_devagent_home; }

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# probe <verb> <args...>: tests/helpers/notify_probe.py. A native reader gets file
# paths only; every expected value is compared here, in bash.
probe() { python3 -X utf8 "$PLUGIN_ROOT/tests/helpers/notify_probe.py" "$@"; }

# lines <file>: the number of \n-ended lines (0 for a missing file).
lines() { if [ -e "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# A detail with quotes, backslashes, a tab, an equals sign and non-ASCII text,
# built from printf escapes (never literal control bytes).
special() { printf 'say \x22hi\x22 a\\b c\\\\d\tk=v caf\xc3\xa9 \xe6\x97\xa5 \xe2\x80\xa6'; }

# ---- Task 1: the marker and the suite guard ---------------------------------

@test "marker: devagent_unattended succeeds for any non-empty value, including 0" {
  . "$PLUGIN_ROOT/scripts/lib/paths.sh"
  run type -t devagent_unattended
  [ "$output" = function ]
  local v
  for v in 1 0 false ' '; do
    DEVAGENT_UNATTENDED="$v" run devagent_unattended
    [ "$status" -eq 0 ] || { echo "value <$v> gave $status" >&2; return 1; }
  done
}

@test "marker: devagent_unattended fails when the variable is unset or empty" {
  . "$PLUGIN_ROOT/scripts/lib/paths.sh"
  run type -t devagent_unattended
  [ "$output" = function ]
  unset DEVAGENT_UNATTENDED
  run devagent_unattended
  [ "$status" -eq 1 ]
  DEVAGENT_UNATTENDED='' run devagent_unattended
  [ "$status" -eq 1 ]
  run env -u DEVAGENT_UNATTENDED bash -uc '. "$1"; devagent_unattended' _ "$PLUGIN_ROOT/scripts/lib/paths.sh"
  [ "$status" -eq 1 ]
  run env DEVAGENT_UNATTENDED= bash -uc '. "$1"; devagent_unattended' _ "$PLUGIN_ROOT/scripts/lib/paths.sh"
  [ "$status" -eq 1 ]
}

@test "suite: a bare-setup file started with the marker set sees it unset" {
  local inner="$BATS_TEST_TMPDIR/inner_bare.bats"
  cat > "$inner" <<EOF
#!/usr/bin/env bats
. "$PLUGIN_ROOT/tests/lib/hermetic-env.bash"
. "$PLUGIN_ROOT/scripts/lib/paths.sh"
@test "inner: the marker is unset" {
  run devagent_unattended
  [ "\$status" -eq 1 ]
}
EOF
  run env DEVAGENT_UNATTENDED=1 bats --tap "$inner"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^ok ')" -eq 1 ]
  printf '%s\n' "$output" | grep -qx '1\.\.1'
}

@test "suite: a fixtures-loading file started with the marker set sees it unset" {
  local inner="$BATS_TEST_TMPDIR/inner_fixtures.bats"
  cat > "$inner" <<EOF
#!/usr/bin/env bats
load '$PLUGIN_ROOT/tests/helpers/fixtures'
setup() {
  fixture_init toy Issue-1
  . "$PLUGIN_ROOT/scripts/lib/paths.sh"
}
@test "inner: the marker is unset after the fixtures" {
  run devagent_unattended
  [ "\$status" -eq 1 ]
}
@test "inner: a marker exported after the fixtures survives" {
  export DEVAGENT_UNATTENDED=1
  run devagent_unattended
  [ "\$status" -eq 0 ]
}
EOF
  run env DEVAGENT_UNATTENDED=1 bats --tap "$inner"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^ok ')" -eq 2 ]
  printf '%s\n' "$output" | grep -qx '1\.\.2'
}

# ---- Task 2: one line, written where it belongs -----------------------------

@test "notify: notify_append writes exactly one version-1 line" {
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=first
  [ "$status" -eq 0 ]
  [ "$(lines "$NF")" -eq 1 ]
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail='operator question 03 at improve; parked'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(lines "$NF")" -eq 2 ]
  run probe count "$NF"
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  run probe keys "$NF" 2
  [ "$output" = "v ts event project issue step question detail" ]
  run probe type "$NF" 2 v
  [ "$output" = int ]
  run probe type "$NF" 2 step
  [ "$output" = null ]
  run probe type "$NF" 2 question
  [ "$output" = null ]
  run probe field "$NF" 2 detail
  [ "$output" = 'operator question 03 at improve; parked' ]
  [ "$(tail -c1 "$NF" | od -An -tx1 | tr -d ' \n')" = 0a ]
  run grep -c $'\r' "$NF"
  [ "$output" = 0 ]
}

@test "notify: a capture line has capture and no issue key" {
  run --separate-stderr notify_append event=notify project=toy capture=2026-11-09-some-capture detail=notice
  [ "$status" -eq 0 ]
  run probe keys "$NF" 1
  [ "$output" = "v ts event project capture step question detail" ]
  run probe type "$NF" 1 issue
  [ "$output" = absent ]
}

@test "notify: ts is ISO 8601 with a numeric zone offset" {
  notify_append event=hold project=toy issue=Issue-7 step=improve detail=d
  run probe field "$NF" 1 ts
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]
  run probe field "$NF" 1 step
  [ "$output" = improve ]
}

@test "notify: a detail with quotes, backslashes, a tab, an equals sign and non-ASCII text round-trips" {
  local d
  d="$(special)"
  [[ "$d" == *$'\t'* ]]
  run --separate-stderr notify_append event=notify project=volk issue=Issue-12 "detail=$d"
  [ "$status" -eq 0 ]
  run probe field "$NF" 1 detail
  [ "$output" = "$d" ]
}

@test "notify: a question with the same characters is recorded unchanged on Linux" {
  is_git_bash && skip "Git Bash converts the question with cygpath -m (P3 checks that form)"
  local q
  q="/q/$(special)/STUCK"
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 "question=$q" detail=d
  [ "$status" -eq 0 ]
  run probe field "$NF" 1 question
  [ "$output" = "$q" ]
  notify_append event=hold project=toy issue=Issue-7 question=/c/Users/x/STUCK detail=d
  run probe field "$NF" 2 question
  [ "$output" = /c/Users/x/STUCK ]
}

@test "notify: the file is written under DA_HOME/state, which is created when missing" {
  rm -rf "$DA_HOME"
  export DA_HOME="$BATS_TEST_TMPDIR/da home"
  mkdir -p "$DA_HOME"
  install_fixture_config config-twoproject.toml
  export DEVAGENT_STATE_DIR="$BATS_TEST_TMPDIR/decoy"
  [ ! -e "$DA_HOME/state" ]
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=d
  [ "$status" -eq 0 ]
  [ "$(lines "$DA_HOME/state/notifications.jsonl")" -eq 1 ]
  [ ! -e "$HOME/.claude" ]
  [ ! -e "$DEVAGENT_STATE_DIR" ]
}

@test "notify: the file and its lock are created 0600 under umask 022" {
  is_git_bash && skip "Git Bash has no POSIX file modes"
  umask 022
  notify_append event=hold project=toy issue=Issue-7 detail=d
  assert_file_mode "$NF" 600
  assert_file_mode "$NF.lock" 600
}

@test "notify: notify.sh is tracked 100755 and sourcing it is silent" {
  run git -C "$PLUGIN_ROOT" ls-files -s scripts/lib/notify.sh
  [[ "$output" == 100755\ * ]]
  local out="$BATS_TEST_TMPDIR/source.out"
  run bash -c 'b="$(set +o; shopt -p)"; . "$1" >"$2" 2>&1; a="$(set +o; shopt -p)"; [ "$b" = "$a" ]' _ "$NOTIFY" "$out"
  [ "$status" -eq 0 ]
  [ ! -s "$out" ]
  run bash -euo pipefail -c 'b="$(set +o; shopt -p)"; . "$1" >"$2" 2>&1; a="$(set +o; shopt -p)"; [ "$b" = "$a" ]' _ "$NOTIFY" "$out"
  [ "$status" -eq 0 ]
  [ ! -s "$out" ]
}

@test "notify: a detail of /c/x refused and of /devagent/foo is recorded unchanged" {
  notify_append event=notify project=toy issue=Issue-7 'detail=/c/x refused'
  notify_append event=notify project=toy issue=Issue-7 detail=/devagent/foo
  run probe field "$NF" 1 detail
  [ "$output" = '/c/x refused' ]
  run probe field "$NF" 2 detail
  [ "$output" = /devagent/foo ]
}

@test "notify: a question of /c/Users/x/STUCK is recorded as C:/Users/x/STUCK" {
  is_git_bash || skip "Git Bash only: Linux records the question unchanged (W5)"
  notify_append event=hold project=toy issue=Issue-7 question=/c/Users/x/STUCK detail=d
  run probe field "$NF" 1 question
  [ "$output" = C:/Users/x/STUCK ]
}

@test "notify: a question with special characters is recorded as cygpath -m prints it" {
  is_git_bash || skip "Git Bash only: Linux records the question unchanged (W5)"
  local q want
  q="/c/q/$(special)/STUCK"
  want="$(cygpath -m "$q")"
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 "question=$q" detail=d
  [ "$status" -eq 0 ]
  run probe field "$NF" 1 question
  [ "$output" = "$want" ]
}

@test "notify: a failing cygpath under errexit returns 4 and writes nothing" {
  # The shim stands in for Git Bash: notify.sh converts paths whenever cygpath exists.
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$BATS_TEST_TMPDIR/shim/cygpath"
  chmod +x "$BATS_TEST_TMPDIR/shim/cygpath"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/shim:$PATH" bash -euo pipefail -c \
    '. "$1"; notify_append event=hold project=toy issue=Issue-7 question=/x/STUCK detail=d; echo reached' _ "$NOTIFY"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  [[ "$stderr" == *'notify: io:'* ]]
  [ ! -e "$NF" ]
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/shim:$PATH" bash -euo pipefail -c \
    '. "$1"; notify_append event=hold project=toy issue=Issue-7 detail=d; echo reached' _ "$NOTIFY"
  [ "$status" -eq 4 ]
  [ ! -e "$NF" ]
}
