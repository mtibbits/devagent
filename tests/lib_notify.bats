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

# ---- Task 3: refusals, field formats, framing and --check -------------------

# refusal_rows: one refused input per line, `id|arg|arg...`, shared by R1 and R4.
# Each row is the fault-free twin (event=hold project=toy issue=Issue-7 detail=d)
# with exactly one fault. Capture values carry `zz` so a test can see whether
# stderr repeats them.
refusal_rows() {
  local b='event=hold|project=toy' i='issue=Issue-7' d='detail=d' l65
  l65="$(printf 'a%.0s' $(seq 65))"
  printf '%s\n' \
    "event|event=bogus|project=toy|$i|$d" \
    "event|project=toy|$i|$d" \
    "project|event=hold|project=|$i|$d" \
    "project|event=hold|project=nope|$i|$d" \
    "project|event=hold|project=volk.issue_source|$i|$d" \
    "issue-capture|$b|$i|capture=zzboth|$d" \
    "issue-capture|$b|$d" \
    "unknown-field|v=1|$b|$i|$d" \
    "question|$b|$i|question=rel/STUCK|$d" \
    "question|$b|$i|question=|$d" \
    "issue|$b|issue=-x|$d" \
    "issue|$b|issue=a b|$d" \
    "issue|$b|issue=a/b|$d" \
    "issue|$b|issue=$l65|$d" \
    "issue|$b|issue=|$d" \
    "capture|$b|capture=.zzdot|$d" \
    "capture|$b|capture=zz/yy|$d" \
    "capture|$b|capture=zz yy|$d" \
    "capture|$b|capture=|$d" \
    "step|$b|$i|step=9x|$d" \
    "step|$b|$i|step=a.b|$d" \
    "step|$b|$i|step=$l65|$d" \
    "step|$b|$i|step=|$d" \
    "detail|$b|$i|detail=" \
    "detail|$b|$i"
  printf 'capture|%s|capture=zz\tyy|%s\n' "$b" "$d"
  printf 'capture|%s|capture=zz\001yy|%s\n' "$b" "$d"
  is_git_bash || printf 'question|%s|%s|question=C:/x|%s\n' "$b" "$i" "$d"
}

# run_rows <door...>: run every refusal row through the door; each must exit 2
# with its id, leave $NF byte-identical to $SEED (or absent when SEED is empty),
# and, for capture rows, keep the slug out of stderr. Sets ROWS.
run_rows() {
  local id rest a n=0
  local -a args
  while IFS='|' read -r id rest; do
    IFS='|' read -r -a args <<< "$rest"
    n=$((n + 1))
    run --separate-stderr "$@" "${args[@]}"
    [ "$status" -eq 2 ] || { echo "row $n ($id): status $status: $stderr" >&2; return 1; }
    [[ "$stderr" == *"($id)"* ]] || { echo "row $n ($id): stderr $stderr" >&2; return 1; }
    [ -z "$output" ] || { echo "row $n ($id): stdout $output" >&2; return 1; }
    if [ -n "$SEED" ]; then
      cmp -s "$SEED" "$NF" || { echo "row $n ($id): the file changed" >&2; return 1; }
    else
      [ ! -e "$NF" ] || { echo "row $n ($id): the file was written" >&2; return 1; }
    fi
    if [ "$id" = capture ]; then
      for a in "${args[@]}"; do
        case "$a" in capture=?*)
          [[ "$stderr" != *"${a#capture=}"* ]] || { echo "row $n: stderr repeats the slug" >&2; return 1; } ;;
        esac
      done
    fi
  done < <(refusal_rows)
  ROWS="$n"
}

@test "refused: each refused input exits 2 with its id and leaves the file unchanged" {
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  SEED="$BATS_TEST_TMPDIR/seed"
  cp "$NF" "$SEED"
  run_rows notify_append
  [ "$ROWS" -eq "$(refusal_rows | wc -l)" ]
  [ "$ROWS" -ge 27 ]
  run --separate-stderr notify_append
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(framing)'* ]]
  cmp "$SEED" "$NF"
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=d
  [ "$status" -eq 0 ]
  [ "$(lines "$NF")" -eq 2 ]
}

@test "refused: a value with a newline or CR is refused before the helper runs" {
  local stub="$BATS_TEST_TMPDIR/stub" mark="$BATS_TEST_TMPDIR/python-ran"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$mark" > "$stub/python3"
  chmod +x "$stub/python3"
  PATH="$stub:$PATH" run --separate-stderr notify_append event=hold project=toy issue=Issue-7 "detail=$(printf 'x\nstep=crrf')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(newline)'* ]]
  [ ! -e "$mark" ]
  PATH="$stub:$PATH" run --separate-stderr notify_append event=hold project=toy issue=Issue-7 "detail=$(printf 'x\rcr')"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(newline)'* ]]
  [ ! -e "$mark" ]
  PATH="$stub:$PATH" run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=x
  [ "$status" -eq 0 ]
  [ -e "$mark" ]
}

@test "refused: the helper fed directly refuses a duplicate key, a line without =, invalid UTF-8 and a CR" {
  local f="$BATS_TEST_TMPDIR/in" ok='event=hold\nproject=toy\nissue=Issue-7\n'
  printf "${ok}detail=d\ndetail=e\n" > "$f"
  run --separate-stderr _notify_helper check < "$f"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(duplicate)'* ]]
  printf "${ok}detail=d\nnokey\n" > "$f"
  run --separate-stderr _notify_helper check < "$f"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(framing)'* ]]
  printf "${ok}detail=\xff\n" > "$f"
  run --separate-stderr _notify_helper check < "$f"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(encoding)'* ]]
  printf "${ok}detail=x\r\n" > "$f"
  run --separate-stderr _notify_helper check < "$f"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(newline)'* ]]
  printf "${ok}detail=d\n" > "$f"
  run --separate-stderr _notify_helper check < "$f"
  [ "$status" -eq 0 ]
}

@test "refused: --check refuses every refused input with the same id and writes nothing" {
  rm -rf "$DA_HOME/state"
  SEED=
  run_rows bash "$NOTIFY" --check
  [ "$ROWS" -eq "$(refusal_rows | wc -l)" ]
  run_rows notify_check
  [ "$ROWS" -eq "$(refusal_rows | wc -l)" ]
  run --separate-stderr bash "$NOTIFY" --check event=hold project=toy issue=Issue-7 detail=d
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr notify_check event=notify project=volk capture=2026-11-09-some-capture step=crrf question=/x/STUCK detail=d
  [ "$status" -eq 0 ]
  [ ! -e "$DA_HOME/state" ]
}

@test "refused: configured projects and capture slugs follow their real producers" {
  . "$PLUGIN_ROOT/scripts/lib/io.sh"
  . "$PLUGIN_ROOT/scripts/lib/config.sh"
  local p c n=0 refused=0
  local -a names
  mapfile -t names < <(config_list_projects)
  [ "${#names[@]}" -eq 2 ]
  for p in "${names[@]}"; do
    run --separate-stderr notify_check event=hold "project=$p" issue=Issue-7 detail=d
    [ "$status" -eq 0 ] || { echo "configured $p refused: $stderr" >&2; return 1; }
  done
  for p in defaults project volk.issue_source toy.code_source Volk 'toy '; do
    run --separate-stderr notify_check event=hold "project=$p" issue=Issue-7 detail=d
    [ "$status" -eq 2 ] || { echo "unconfigured <$p> gave $status" >&2; return 1; }
    [[ "$stderr" == *'(project)'* ]]
    n=$((n + 1))
  done
  [ "$n" -eq 6 ]
  for c in .x .. a/b /abs .hidden-slug 'x/' ok-slug 2026-11-09-some-capture; do
    if devagent_validate_slug "$c" 2>/dev/null; then continue; fi
    refused=$((refused + 1))
    run --separate-stderr notify_check event=notify project=toy "capture=$c" detail=d
    [ "$status" -eq 2 ] || { echo "slug <$c> gave $status" >&2; return 1; }
    [[ "$stderr" == *'(capture)'* ]]
  done
  [ "$refused" -ge 3 ]
  run --separate-stderr notify_check event=notify project=toy capture=ok-slug detail=d
  [ "$status" -eq 0 ]
}

@test "refused: usage errors exit 2" {
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  local n=0 form
  local -a args
  for form in '' 'event=hold' '--rotate=x' '--check|--rotate|x' '--check|event=hold|--rotate|x' \
              '--bogus' '--check' '--check|' '--rotate' '--rotate|a|b' 'event=hold|--check' \
              '--rotate|--check' '--rotate|-x'; do
    if [ -z "$form" ]; then args=(); else IFS='|' read -r -a args <<< "$form|"; fi
    [ "$form" != '--check|' ] || args=(--check '')
    n=$((n + 1))
    run --separate-stderr bash "$NOTIFY" "${args[@]}"
    [ "$status" -eq 2 ] || { echo "form <$form>: $status $stderr" >&2; return 1; }
    [[ "$stderr" == *'(usage)'* ]] || { echo "form <$form>: $stderr" >&2; return 1; }
    [ -z "$output" ]
  done
  [ "$n" -eq 13 ]
  run --separate-stderr bash "$NOTIFY" --rotate ''
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(rotate-name)'* ]]
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
  [ "$(find "$DA_HOME/state" -name '-*' | wc -l)" -eq 0 ]
}

@test "refused: an unreadable helper is io, not 2" {
  _NOTIFY_PY="$BATS_TEST_TMPDIR/missing/_notify.py"
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=d
  [ "$status" -eq 4 ]
  [[ "$stderr" == *'notify: io:'* ]]
  [ ! -e "$NF" ]
}

# ---- Task 4: long detail ---------------------------------------------------

ELL="$(printf '\xe2\x80\xa6')"   # U+2026, the shortening mark

@test "notify: a 5,000-character ASCII detail is shortened to fit 4096 bytes" {
  local in d
  in="$(head -c 5000 /dev/zero | tr '\0' x)"
  [ "${#in}" -eq 5000 ]
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 "detail=$in"
  [ "$status" -eq 0 ]
  run probe bytes "$NF" 1
  [ "$output" -eq 4096 ]
  d="$(probe field "$NF" 1 detail)"
  [[ "$d" == *"$ELL" ]]
  [ "${#d}" -lt 5000 ]
  [[ "$in" == "${d%"$ELL"}"* ]]
  notify_append event=hold project=toy issue=Issue-7 detail=short
  run probe field "$NF" 2 detail
  [ "$output" = short ]
}

@test "notify: a 5,000-character multi-byte detail is shortened on a character boundary" {
  local in d
  in="$(printf '\xe6\x97\xa5%.0s' $(seq 5000))"
  [ "${#in}" -eq 5000 ]
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 "detail=$in"
  [ "$status" -eq 0 ]
  run probe bytes "$NF" 1
  [ "$output" -ge 4093 ]
  [ "$output" -le 4096 ]
  run probe count "$NF"
  [ "$output" = 1 ]
  d="$(probe field "$NF" 1 detail)"
  [[ "$d" == *"$ELL" ]]
  [ "${#d}" -lt 5000 ]
  [[ "$in" == "${d%"$ELL"}"* ]]
}

@test "notify: a line too long with an empty detail is refused" {
  local cap
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  cap="$(head -c 4200 /dev/zero | tr '\0' c)"
  run --separate-stderr notify_append event=notify project=toy "capture=$cap" detail=d
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(too-long)'* ]]
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
}

@test "notify: a 200,000-character detail is shortened within 5 seconds" {
  local in start
  in="$(head -c 200000 /dev/zero | tr '\0' y)"
  start=$SECONDS
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 "detail=$in"
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -le 5 ]
  run probe bytes "$NF" 1
  [ "$output" -eq 4096 ]
}

# ---- Task 5: the lock, concurrency, the torn line and I/O failure ------------

# hold_lock <name>: start a holder of the module's own lock; sets HOLDER (pid) and
# RELEASE (the file that ends it). The holder ends on RELEASE or after 30 s.
hold_lock() {
  local ready="$BATS_TEST_TMPDIR/$1.ready" i
  RELEASE="$BATS_TEST_TMPDIR/$1.release"
  probe hold-lock "$DA_HOME/state" "$ready" "$RELEASE" 3>&- >/dev/null 2>&1 &
  HOLDER=$!
  for i in $(seq 200); do [ -e "$ready" ] && return 0; sleep 0.05; done
  echo "the holder never became ready" >&2
  return 1
}

# release: end the holder and wait for it, so teardown never races a handle.
release() { touch "$RELEASE"; wait "$HOLDER"; }

@test "notify: with the lock held by another process an append exits 3 after the bounded wait" {
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  hold_lock c1
  local start end
  start=$(date +%s)
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=late
  end=$(date +%s)
  release
  [ "$status" -eq 3 ]
  [[ "$stderr" == *'notify: lock-timeout:'* ]]
  [ $((end - start)) -ge 9 ]
  [ $((end - start)) -le 25 ]
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
}

@test "notify: an append started while the lock is held completes when it is released" {
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  hold_lock c2
  ( notify_append event=hold project=toy issue=Issue-7 detail=waited; echo $? > "$BATS_TEST_TMPDIR/c2.rc" ) 3>&- >/dev/null 2>&1 &
  local writer=$!
  sleep 1
  kill -0 "$writer"
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
  release
  wait "$writer"
  [ "$(cat "$BATS_TEST_TMPDIR/c2.rc")" = 0 ]
  [ "$(lines "$NF")" -eq 2 ]
  run probe field "$NF" 2 detail
  [ "$output" = waited ]
}

@test "notify: two different callers appending 200 lines each leave 400 whole valid lines" {
  local fx="$PLUGIN_ROOT/tests/fixtures/notify" a b ra=0 rb=0
  bash "$fx/caller-hold.sh" 200 3>&- >"$BATS_TEST_TMPDIR/a.out" 2>&1 &
  a=$!
  bash "$fx/caller-notice.sh" 200 3>&- >"$BATS_TEST_TMPDIR/b.out" 2>&1 &
  b=$!
  wait "$a" || ra=$?
  wait "$b" || rb=$?
  [ "$ra" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/a.out" >&2; return 1; }
  [ "$rb" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/b.out" >&2; return 1; }
  run probe count "$NF"
  [ "$status" -eq 0 ]
  [ "$output" = 400 ]
  run probe prefix-count "$NF" 'hold '
  [ "$output" = 200 ]
  run probe prefix-count "$NF" 'notice '
  [ "$output" = 200 ]
}

@test "notify: after a torn last line the next append starts on a new line" {
  notify_append event=hold project=toy issue=Issue-7 detail=whole
  head -n1 "$NF" > "$BATS_TEST_TMPDIR/line1"
  printf '{"v":1,"ts":"torn' >> "$NF"
  local s
  s=$(wc -c < "$NF")
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=after
  [ "$status" -eq 0 ]
  cmp -n "$s" "$BATS_TEST_TMPDIR/seed" "$NF"
  [ "$(lines "$NF")" -eq 3 ]
  head -n1 "$NF" | cmp - "$BATS_TEST_TMPDIR/line1"
  [ "$(sed -n 2p "$NF")" = '{"v":1,"ts":"torn' ]
  run probe field "$NF" 3 detail
  [ "$output" = after ]
  run probe field "$NF" 1 detail
  [ "$status" -eq 0 ]
  run probe field "$NF" 2 detail
  [ "$status" -ne 0 ]
}

@test "notify: existing bytes never change and a byte-offset cursor reads exactly the new line" {
  notify_append event=hold project=toy issue=Issue-7 detail=one
  notify_append event=notify project=volk capture=c-1 detail=two
  local s
  s=$(wc -c < "$NF")
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  notify_append event=answered project=toy issue=Issue-7 question=/x/q-03 'detail=answered; resume'
  cmp -n "$s" "$BATS_TEST_TMPDIR/seed" "$NF"
  tail -c +"$((s + 1))" "$NF" > "$BATS_TEST_TMPDIR/new"
  run probe count "$BATS_TEST_TMPDIR/new"
  [ "$output" = 1 ]
  run probe field "$BATS_TEST_TMPDIR/new" 1 detail
  [ "$output" = 'answered; resume' ]
}

@test "notify: an unwritable file exits 4 and is unchanged" {
  is_git_bash && skip "Git Bash has no POSIX file modes"
  [ "$(id -u)" -ne 0 ] || skip "root writes a mode-400 file"
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  chmod 400 "$NF"
  run --separate-stderr notify_append event=hold project=toy issue=Issue-7 detail=more
  [ "$status" -eq 4 ]
  [[ "$stderr" == *'notify: io:'* ]]
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
}

@test "notify: an open refused for sharing is retried until the holder closes" {
  is_git_bash || skip "Windows only: POSIX has no sharing violation"
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  local ready="$BATS_TEST_TMPDIR/c7.ready" i
  RELEASE="$BATS_TEST_TMPDIR/c7.release"
  probe deny-share "$NF" "$ready" "$RELEASE" 3>&- >/dev/null 2>&1 &
  HOLDER=$!
  for i in $(seq 200); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ]
  # The control: a plain open fails while the holder has the file.
  run python3 -c 'import sys; open(sys.argv[1], "ab")' "$NF"
  [ "$status" -ne 0 ]
  ( notify_append event=hold project=toy issue=Issue-7 detail=shared; echo $? > "$BATS_TEST_TMPDIR/c7.rc" ) 3>&- >/dev/null 2>&1 &
  local writer=$!
  sleep 1
  release
  wait "$writer"
  [ "$(cat "$BATS_TEST_TMPDIR/c7.rc")" = 0 ]
  [ "$(lines "$NF")" -eq 2 ]
  run probe field "$NF" 2 detail
  [ "$output" = shared ]
}

# ---- Task 6: --rotate ------------------------------------------------------

@test "rotate: --rotate renames the file in the same directory" {
  notify_append event=hold project=toy issue=Issue-7 detail=one
  notify_append event=hold project=toy issue=Issue-7 detail=two
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  run --separate-stderr bash "$NOTIFY" --rotate notifications-1.jsonl
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$BATS_TEST_TMPDIR/seed" "$DA_HOME/state/notifications-1.jsonl"
  [ ! -e "$NF" ]
  notify_append event=hold project=toy issue=Issue-7 detail=three
  [ "$(lines "$NF")" -eq 1 ]
}

@test "rotate: --rotate waits for the lock and a writer started during it writes one whole line" {
  notify_append event=hold project=toy issue=Issue-7 detail=seed-1
  notify_append event=hold project=toy issue=Issue-7 detail=seed-2
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  local target="$DA_HOME/state/rotated.jsonl" rot app
  hold_lock t2
  bash "$NOTIFY" --rotate rotated.jsonl 3>&- >"$BATS_TEST_TMPDIR/rot.out" 2>&1 &
  rot=$!
  ( notify_append event=hold project=toy issue=Issue-7 detail=during; echo $? > "$BATS_TEST_TMPDIR/app.rc" ) 3>&- >/dev/null 2>&1 &
  app=$!
  sleep 1
  [ ! -e "$target" ]
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
  release
  wait "$rot" || { cat "$BATS_TEST_TMPDIR/rot.out" >&2; return 1; }
  wait "$app"
  [ "$(cat "$BATS_TEST_TMPDIR/app.rc")" = 0 ]
  [ -e "$target" ]
  cat "$target" > "$BATS_TEST_TMPDIR/both"
  [ ! -e "$NF" ] || cat "$NF" >> "$BATS_TEST_TMPDIR/both"
  run probe count "$BATS_TEST_TMPDIR/both"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  run probe prefix-count "$BATS_TEST_TMPDIR/both" seed-
  [ "$output" = 2 ]
  run probe prefix-count "$BATS_TEST_TMPDIR/both" during
  [ "$output" = 1 ]
}

@test "rotate: --rotate refuses a bad name or an existing target" {
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  local name n=0
  for name in a/b 'a\b' a:b . .. ''; do
    n=$((n + 1))
    run --separate-stderr bash "$NOTIFY" --rotate "$name"
    [ "$status" -eq 2 ] || { echo "name <$name>: $status $stderr" >&2; return 1; }
    [[ "$stderr" == *'(rotate-name)'* ]] || { echo "name <$name>: $stderr" >&2; return 1; }
  done
  [ "$n" -eq 6 ]
  printf 'kept\n' > "$DA_HOME/state/taken.jsonl"
  run --separate-stderr bash "$NOTIFY" --rotate taken.jsonl
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'(rotate-exists)'* ]]
  [ "$(cat "$DA_HOME/state/taken.jsonl")" = kept ]
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
}

@test "rotate: --rotate with no file exits 5" {
  run --separate-stderr bash "$NOTIFY" --rotate old.jsonl
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'notify: nothing-to-rotate'* ]]
  [ ! -e "$DA_HOME/state/old.jsonl" ]
  rm -rf "$DA_HOME/state"
  run --separate-stderr bash "$NOTIFY" --rotate old.jsonl
  [ "$status" -eq 5 ]
  [ ! -e "$DA_HOME/state" ]
}

@test "rotate: a failed rename is io and leaves the file" {
  is_git_bash && skip "Git Bash has no POSIX directory modes"
  [ "$(id -u)" -ne 0 ] || skip "root renames in a read-only directory"
  notify_append event=hold project=toy issue=Issue-7 detail=seed
  cp "$NF" "$BATS_TEST_TMPDIR/seed"
  chmod 500 "$DA_HOME/state"
  run --separate-stderr bash "$NOTIFY" --rotate old.jsonl
  chmod 700 "$DA_HOME/state"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *'notify: io:'* ]]
  cmp "$BATS_TEST_TMPDIR/seed" "$NF"
  [ ! -e "$DA_HOME/state/old.jsonl" ]
}

# ---- Task 7: documentation ---------------------------------------------------

@test "spec 7.3 states that only answered lines are merged" {
  local spec="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md" text
  text="$(awk '/^### 7\.3 /{on=1; print; next} on && /^### /{exit} on{print}' "$spec" | tr '\n' ' ')"
  [ -n "$text" ]
  [[ "$text" =~ Only\ \`answered\`\ lines\ are\ merged[^.]*project[^.]*issue\ or\ capture[^.]*\`question\`\ path ]]
}

@test "spec 7.3 says the capture slug check runs in bash before the helper's ordered checks" {
  local spec="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md" text
  text="$(awk '/^### 7\.3 /{on=1; print; next} on && /^### /{exit} on{print}' "$spec" | tr '\n' ' ')"
  [[ "$text" =~ a\ \`capture\`\ that\ \`devagent_validate_slug\`\ refuses[^.]*before\ the\ helper ]]
  [[ "$text" != *'or that holds a space or a control character, a `step`'* ]]
}
