#!/usr/bin/env bats
# #986: doctor's [prerequisites] block — bash, git, python3 and jq, each with a
# one-line remedy (the Windows fix on Git Bash). Unit tests source the real
# scripts/lib/prereqs.sh; the integration tests drive scripts/doctor.sh end to
# end with tools hidden or stubbed on PATH.

bats_require_minimum_version 1.5.0   # run --separate-stderr, run -N
load 'lib/bats-helpers'
load 'lib/doctor-harness'

setup() {
  setup_tmp_devagent_home
  seed_doctor_project
  # seed_doctor_project reassigns STUBBIN without touching PATH; re-calling the
  # stub puts the reassigned dir on PATH (doctor.bats does the same).
  stub_claude_cli enabled
}
teardown() { teardown_tmp_devagent_home; }

# _uname_stub <sysname>: `uname -s` prints <sysname>; any other call runs the
# real uname. Goes first on PATH, so prereq_on_git_bash sees the stubbed host.
_uname_stub() {
  local real_uname d="$BATS_TEST_TMPDIR/unamebin"
  real_uname="$(type -P uname)"
  [ -n "$real_uname" ]
  mkdir -p "$d"
  cat > "$d/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -s ]; then echo '$1'; exit 0; fi
exec "$real_uname" "\$@"
EOF
  chmod +x "$d/uname"
  export PATH="$d:$PATH"
  [ "$(uname -s)" = "$1" ]
}

_src_prereqs() {
  # shellcheck disable=SC2034  # check() in prereqs.sh increments the caller's ERRORS
  ERRORS=0
  # shellcheck source=scripts/lib/prereqs.sh
  source "$PLUGIN_ROOT/scripts/lib/prereqs.sh"
}

# ---- unit: scripts/lib/prereqs.sh ---------------------------------------------

@test "prereqs: version compare is numeric per component" {
  _src_prereqs
  run type -t prereq_version_ge
  [ "$output" = function ]
  local pair
  for pair in '4.4 4.4' '4.10 4.4' '5.0 4.4' '10.0 4.4' '3.11 3.11'; do
    # shellcheck disable=SC2086  # the pair splits into <have> <want> on purpose
    run prereq_version_ge $pair
    [ "$status" -eq 0 ] || { echo "want 0 for $pair, got $status" >&2; false; }
  done
  for pair in '4.3 4.4' '3.2 4.4' '3.9 3.11'; do
    # shellcheck disable=SC2086
    run prereq_version_ge $pair
    [ "$status" -eq 1 ] || { echo "want 1 for $pair, got $status" >&2; false; }
  done
  for pair in '4 4.4' '4.x 4.4' '1234567.0 4.4' '4.4 4'; do
    # shellcheck disable=SC2086
    run prereq_version_ge $pair
    [ "$status" -eq 2 ] || { echo "want 2 for $pair, got $status" >&2; false; }
  done
}

@test "prereqs: bash 4.3 prints the FAIL row and the stop line and exits 1" {
  _uname_stub Linux
  _src_prereqs
  run type -t prereq_bash_gate
  [ "$output" = function ]
  run prereq_bash_gate 4.3
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 3 ]
  local want
  want="$(printf '\n%s\n%s\n%s' '[prerequisites]' \
    '  FAIL bash 4.4 or later — found 4.3; install bash 4.4 or later and run devagent with it' \
    "doctor: stopped — devagent's libraries need bash 4.4 or later, so no other check ran")"
  [ "$output" = "$want" ] || { printf 'got:\n%s\n' "$output" >&2; false; }
}

@test "prereqs: a malformed bash version fails the gate too" {
  _uname_stub Linux
  _src_prereqs
  run type -t prereq_bash_gate
  [ "$output" = function ]
  run prereq_bash_gate 4.x
  [ "$status" -eq 1 ]
  [[ "$output" == *"  FAIL bash 4.4 or later — found 4.x; "* ]]
}

@test "prereqs: bash 4.4 passes silently and records an OK row" {
  _src_prereqs
  run prereq_bash_gate 4.4
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  prereq_bash_gate 4.4
  [ "${PREREQ_ST[0]}" = ok ]
  [ "${PREREQ_LABEL[0]}" = 'bash 4.4 or later' ]
  [ "${#PREREQ_ST[@]}" -eq 1 ]
}

@test "prereqs: remedies are generic off Git Bash and name winget on Git Bash" {
  _uname_stub Linux
  _src_prereqs
  run type -t prereq_remedy
  [ "$output" = function ]
  run prereq_remedy bash;    [ "$output" = 'install bash 4.4 or later and run devagent with it' ]
  run prereq_remedy git;     [ "$output" = 'install git 2.29 or later with your package manager' ]
  run prereq_remedy python3; [ "$output" = 'install Python 3.11 or later so that python3 runs it' ]
  run prereq_remedy jq;      [ "$output" = 'install jq with your package manager' ]
  _uname_stub MINGW64_NT-10.0-26100
  run prereq_remedy bash;    [ "$output" = 'install a current Git for Windows (winget install --id Git.Git -e), whose Git Bash ships bash 5' ]
  run prereq_remedy git;     [ "$output" = 'winget install --id Git.Git -e, then open a new Git Bash window' ]
  run prereq_remedy python3; [ "$output" = 'install Python 3.11 or later, then check that python3 runs in a new Git Bash window' ]
  run prereq_remedy jq;      [ "$output" = 'winget install jqlang.jq, then open a new Git Bash window' ]
}

@test "prereqs: the 4.4 floor in prereqs.sh matches the potholes.sh guard" {
  _src_prereqs
  [ "$PREREQ_BASH_MIN" = 4.4 ]
  # Extract the guard's literals: -lt <M> … -eq <M> … BASH_VERSINFO[1] -lt <m>.
  local guard re major minor
  guard="$(grep -m1 'BASH_VERSINFO\[0\]' "$PLUGIN_ROOT/scripts/lib/potholes.sh")"
  re='-eq ([0-9]+) \] && \[ "\$\{BASH_VERSINFO\[1\]\}" -lt ([0-9]+)'
  [[ "$guard" =~ $re ]] || { echo "guard shape changed: $guard" >&2; false; }
  major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}"
  [ "$major.$minor" = "$PREREQ_BASH_MIN" ]
  [[ "$guard" == *"-lt $major ]"* ]]
  # Both sides decide 4.3 and 4.4 the same way.
  run prereq_version_ge 4.3 "$major.$minor"; [ "$status" -eq 1 ]
  run prereq_version_ge 4.4 "$major.$minor"; [ "$status" -eq 0 ]
}

@test "prereqs: no bash 4.x-only construct before the gate (prereqs.sh, doctor.sh up to its first other library)" {
  # The suite runs on bash 5, so a 4.x-only construct here would stay green while
  # an old-bash host got a parse error instead of the FAIL row. Comments are skipped:
  # prereqs.sh's header names the banned constructs.
  local pre banned hits
  pre="$(awk '/^source "\$PLUGIN_ROOT\/scripts\/lib\/paths.sh"/ { exit } { print }' "$PLUGIN_ROOT/scripts/doctor.sh")"
  grep -q 'prereq_bash_gate' <<<"$pre"   # positive control: the cut kept the gate
  banned='declare -[A-Za-z]*[Agn]|local -[A-Za-z]*n|\b(mapfile|readarray)\b|[,^]{1,2}\}|\[\[ -v |;;?&'
  hits="$( { cat "$PLUGIN_ROOT/scripts/lib/prereqs.sh"; printf '%s\n' "$pre"; } \
    | grep -v '^[[:space:]]*#' | grep -nE -- "$banned" || true)"
  [ -z "$hits" ] || { printf 'bash 4.x-only construct before the gate:\n%s\n' "$hits" >&2; false; }
  run grep -cE -- "$banned" <<<'x="${v,,}"'   # the pattern does catch a known construct
  [ "$output" = 1 ]
}

# ---- integration: scripts/doctor.sh -------------------------------------------

_doctor() { run --separate-stderr "$PLUGIN_ROOT/scripts/doctor.sh" "$@"; }

PY_LABEL='python3 3.11+, or 3.8-3.10 with tomli'
STOP_PY='doctor: stopped — the remaining checks need python3'
ALIAS_REMEDY='this python3 is probably the Windows Store alias: turn off its App execution alias under Settings > Apps > Advanced app settings > App execution aliases, then install Python 3.11 or later and open a new Git Bash window'

# _py_stub <dir> <mode>: write <dir>/python3, put <dir> first on PATH and prove it
# is the python3 that resolves. Probe calls (the version and tomli probes) answer
# per <mode> and log one line each to $BATS_TEST_TMPDIR/py-probe.log; any other
# call runs the real python3, so doctor's own TOML reads still work.
_py_stub() {
  local dir="$1" mode="$2" real_py
  real_py="$(type -P python3)"
  [ -n "$real_py" ] || { echo "_py_stub: no real python3" >&2; return 1; }
  case "$real_py" in "$BATS_TEST_TMPDIR"/*) echo "_py_stub: REAL_PY is a stub: $real_py" >&2; return 1 ;; esac
  mkdir -p "$dir"
  cat > "$dir/python3" <<EOF
#!/usr/bin/env bash
REAL_PY='$real_py'
MODE='$mode'
LOG='$BATS_TEST_TMPDIR/py-probe.log'
EOF
  cat >> "$dir/python3" <<'EOF'
if [ "$MODE" = store ]; then
  echo 'Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Manage App Execution Aliases.' >&2
  exit 9009
fi
code='' flags='' prev=''
for a in "$@"; do
  [ "$prev" = -c ] && code="$a"
  case "$a" in -c) ;; -*) flags="$flags $a" ;; esac
  prev="$a"
done
VER='import sys; print(sys.version_info[:2])'
if [ "$code" != "$VER" ] && [ "$code" != 'import tomli' ]; then exec "$REAL_PY" "$@"; fi
empty=0; [ -z "$(ls -A)" ] && empty=1
echo "code=$code flags=${flags# } cwd=$PWD empty=$empty" >> "$LOG"
notomli() { echo "ModuleNotFoundError: No module named 'tomli'" >&2; exit 1; }
if [ "$code" = "$VER" ]; then
  case "$MODE" in
    v39-*) echo '(3, 9)' ;;
    v312) echo '(3, 12)' ;;
    v37) echo '(3, 7)' ;;
    garbage) echo hello ;;
    bigver) echo '(3, 1234567)' ;;
    stderr-noise) echo 'Error processing line 1 of /x/site-packages/broken.pth:' >&2; echo '(3, 12)' ;;
    stdout-noise) echo 'sitecustomize: hello from site'; echo '(3, 12)' ;;
    *) echo "_py_stub: unknown mode $MODE" >&2; exit 2 ;;
  esac
  exit 0
fi
case "$MODE" in
  v39-notomli) notomli ;;
  v39-usersite)
    case " $flags " in *' -I '*|*' -s '*) notomli ;; esac
    [ -z "${PYTHONNOUSERSITE:-}" ] || notomli
    exit 0 ;;
  *) exec "$REAL_PY" "$@" ;;
esac
EOF
  chmod +x "$dir/python3"
  export PATH="$dir:$PATH"
  [ "$(type -P python3)" = "$dir/python3" ] || { echo "_py_stub: $(type -P python3) resolves, not $dir/python3" >&2; return 1; }
}

_last_line_is() { [ "${lines[${#lines[@]}-1]}" = "$1" ] || { echo "last line: ${lines[${#lines[@]}-1]}" >&2; false; }; }
_has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: %s\n--- output:\n%s\n' "$1" "$output" >&2; false; }; }
_no_text() { if grep -qF -- "$1" <<<"$output"; then printf 'unexpected text: %s\n' "$1" >&2; false; fi; }

@test "doctor: all present prints an all-OK prerequisites block between home and the global checks" {
  type -P jq >/dev/null || { echo "this test needs jq on PATH (doctor's all-OK block reads it)" >&2; false; }
  type -P git >/dev/null
  _doctor volk
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  local got want
  got="$(awk '/^home: /{on=1; next} on && n<8 {print; n++}' <<<"$output")"
  want="$(printf '%s\n' '' '[prerequisites]' '  OK   bash 4.4 or later' '  OK   git' \
    "  OK   $PY_LABEL" '  OK   jq' '' '  OK   config exists')"
  [ "$got" = "$want" ] || { printf 'got:\n%s\n' "$got" >&2; false; }
}

@test "doctor: python3 absent fails and stops before any config line, exit 1" {
  _uname_stub Linux
  curated_path_without python3
  run -1 type -P python3
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line "  FAIL $PY_LABEL — not found on PATH; install Python 3.11 or later so that python3 runs it"
  _last_line_is "$STOP_PY"
  _no_text 'config exists'
  _no_text 'tomllib'
  [ -z "$stderr" ] || { echo "stderr: $stderr" >&2; false; }
}

@test "doctor: a Store-alias python3 under WindowsApps fails with the alias remedy" {
  local WA="$BATS_TEST_TMPDIR/AppData/Local/Microsoft/WindowsApps"
  _py_stub "$WA" store
  _doctor volk
  [ "$status" -eq 1 ]
  local row
  row="$(grep -F "  FAIL $PY_LABEL — " <<<"$output")"
  [[ "$row" == "  FAIL $PY_LABEL — $WA/python3 exited "* ]] || { echo "row: $row" >&2; false; }
  [[ "$row" == *": Python was not found; run without arguments to install from the Microsoft Store"* ]]
  [[ "$row" == *"; $ALIAS_REMEDY" ]] || { echo "row: $row" >&2; false; }
  _last_line_is "$STOP_PY"
  _no_text 'config exists'
  _no_text 'tomllib'
}

@test "doctor: Python 3.9 without tomli fails with the pip remedy" {
  _uname_stub Linux
  _py_stub "$STUBBIN" v39-notomli
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line "  FAIL $PY_LABEL — $STUBBIN/python3 is Python 3.9 without tomli; install tomli for it (apt install python3-tomli, or \"$STUBBIN/python3\" -m pip install --user tomli), or install Python 3.11 or later"
  _last_line_is "$STOP_PY"
  _no_text 'App execution aliases'
}

@test "doctor: on Git Bash the Python 3.9 without tomli remedy names only pip" {
  _uname_stub MINGW64_NT-10.0-26100
  _py_stub "$STUBBIN" v39-notomli
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line "  FAIL $PY_LABEL — $STUBBIN/python3 is Python 3.9 without tomli; run \"$STUBBIN/python3\" -m pip install --user tomli, or install Python 3.11 or later"
}

@test "doctor: a working python3 under WindowsApps is OK" {
  local WA="$BATS_TEST_TMPDIR/AppData/Local/Microsoft/WindowsApps"
  _py_stub "$WA" v312
  _doctor volk
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  _has_line "  OK   $PY_LABEL"
  _has_line '  OK   config exists'
  _no_text 'App execution aliases'
}

@test "doctor: a python3 that warns on stderr but prints its version is OK" {
  _py_stub "$STUBBIN" stderr-noise
  _doctor volk
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  _has_line "  OK   $PY_LABEL"
}

@test "doctor: a python3 whose sitecustomize prints to stdout before the version is OK" {
  _py_stub "$STUBBIN" stdout-noise
  _doctor volk
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  _has_line "  OK   $PY_LABEL"
}

@test "doctor: Python 3.9 with tomli only in the user site is OK, probed without -I from an empty directory" {
  _py_stub "$STUBBIN" v39-usersite
  _doctor volk
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  _has_line "  OK   $PY_LABEL"
  local log="$BATS_TEST_TMPDIR/py-probe.log"
  [ -s "$log" ]
  [ "$(grep -c '^code=import tomli ' "$log")" -eq 1 ]
  run ! grep -E 'flags=.*(^| )-(I|s)( |$)' "$log"
  run ! grep -F "cwd=$PWD " "$log"
  run ! grep -v ' empty=1$' "$log"
}

@test "doctor: Python 3.7, a non-version reply and an oversized version each fail and stop" {
  _uname_stub Linux
  _py_stub "$STUBBIN" v37
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line "  FAIL $PY_LABEL — $STUBBIN/python3 is Python 3.7; install Python 3.11 or later so that python3 runs it"
  _last_line_is "$STOP_PY"
  _py_stub "$STUBBIN" garbage
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line "  FAIL $PY_LABEL — $STUBBIN/python3 printed \"hello\", not a version; install Python 3.11 or later so that python3 runs it"
  _last_line_is "$STOP_PY"
  _py_stub "$STUBBIN" bigver
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line "  FAIL $PY_LABEL — $STUBBIN/python3 printed \"(3, 1234567)\", not a version; install Python 3.11 or later so that python3 runs it"
}

@test "doctor: git absent fails with a remedy, the per-project checks still run, exit 1" {
  _uname_stub Linux
  curated_path_without git
  run -1 type -P git
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line '  FAIL git — not found on PATH; install git 2.29 or later with your package manager'
  _has_line '[project: volk]'
  _no_text 'doctor: aborting per-project checks'
  [[ "${lines[${#lines[@]}-1]}" =~ ^FAIL\ \([0-9]+\ error\(s\)\)$ ]]
}

@test "doctor: jq absent with a GitHub project fails, the per-project checks still run, exit 1" {
  _uname_stub Linux
  curated_path_without jq
  run -1 type -P jq
  _doctor volk
  [ "$status" -eq 1 ]
  _has_line '  FAIL jq — not found on PATH; needed by project volk (issue_source.backend = github); install jq with your package manager'
  _has_line '[project: volk]'
  _no_text 'doctor: aborting per-project checks'
}

_cust_project() {  # _cust_project <name> [extra line]...
  local p="$1"; shift
  mkdir -p "$DA_HOME/$p-src" "$DA_HOME/$p-devdoc"
  printf '%s\n' '' "[project.$p]" "source_dir = \"$DA_HOME/$p-src\"" "devdoc_dir = \"$DA_HOME/$p-devdoc\"" \
    'default_baseline = "origin/main"' "$@" >> "$DA_HOME/config.toml"
  state_init "$p"
}

@test "doctor: jq absent with git_guard = true on a custom-backend project fails" {
  _uname_stub Linux
  printf '%s\n' '[defaults]' 'checklist_template = "standard"' > "$DA_HOME/config.toml"
  _cust_project cust 'git_guard = true' '' '[project.cust.issue_source]' 'backend = "custom"' \
    '' '[project.cust.code_source]' 'backend = "custom"'
  curated_path_without jq
  run -1 type -P jq
  _doctor cust
  [ "$status" -eq 1 ]
  _has_line '  FAIL jq — not found on PATH; needed by project cust (git_guard = true); install jq with your package manager'
}

@test "doctor: jq absent with [defaults] git_guard = true and every project off fails" {
  _uname_stub Linux
  # No active project: the hook falls back to [defaults], so the guard is on.
  printf '%s\n' '[defaults]' 'checklist_template = "standard"' 'git_guard = true' > "$DA_HOME/config.toml"
  _cust_project cust 'git_guard = false' '' '[project.cust.issue_source]' 'backend = "custom"' \
    '' '[project.cust.code_source]' 'backend = "custom"'
  unset DEVAGENT_ACTIVE_PROJECT
  curated_path_without jq
  run -1 type -P jq
  _doctor
  [ "$status" -eq 1 ]
  _has_line '  FAIL jq — not found on PATH; needed by [defaults] git_guard = true; install jq with your package manager'
}

@test "doctor: jq absent with only custom, disk and local backends and git_guard off is SKIP and leaves the exit code unchanged" {
  printf '%s\n' '[defaults]' 'checklist_template = "standard"' > "$DA_HOME/config.toml"
  _cust_project cust '' '[project.cust.issue_source]' 'backend = "custom"' \
    '' '[project.cust.code_source]' 'backend = "custom"'
  mkdir -p "$BATS_TEST_TMPDIR/issues"
  _cust_project dsk '' '[project.dsk.issue_source]' 'backend = "disk"' "repo = \"$BATS_TEST_TMPDIR/issues\"" \
    'dir_prefix = "Issue-"' '' '[project.dsk.code_source]' 'backend = "local"'
  _doctor
  local rcA="$status" lastA="${lines[${#lines[@]}-1]}"
  _has_line '  OK   jq'
  curated_path_without jq
  run -1 type -P jq
  _doctor
  [ "$status" -eq "$rcA" ]
  [ "${lines[${#lines[@]}-1]}" = "$lastA" ]
  _has_line '  SKIP jq — not found on PATH; nothing configured needs it (no GitHub, GitLab or Jira backend, git_guard off)'
}

@test "doctor: jq absent with an unreadable config warns that the need is undetermined" {
  printf '%s\n' '[project.volk' > "$DA_HOME/config.toml"
  curated_path_without jq
  run -1 type -P jq
  _doctor
  [ "$status" -eq 1 ]
  _has_line '  WARN jq — not found on PATH; could not read the config to tell whether anything needs it'
  grep -qF '  FAIL config is valid TOML — ' <<<"$output"
  grep -q '^doctor: aborting per-project checks due to ' <<<"$output"
}

@test "doctor: on Git Bash the jq remedy names winget" {
  _uname_stub MINGW64_NT-10.0-26100
  curated_path_without jq
  run -1 type -P jq
  _doctor volk
  [ "$status" -eq 1 ]
  grep -F '  FAIL jq — not found on PATH; needed by project volk' <<<"$output" | grep -q '; winget install jqlang.jq, then open a new Git Bash window$'
}
