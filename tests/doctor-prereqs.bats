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
