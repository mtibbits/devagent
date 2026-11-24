# shellcheck shell=bash
# shellcheck disable=SC2034
# (SC2034: PREREQ_* below are the return channel — doctor.sh reads them after the
# setters run, so shellcheck sees them assigned here and never read.)
#
# scripts/lib/prereqs.sh — #986: doctor's [prerequisites] rows (bash, git, python3)
# and the shared `check` printer.
#
# NO DEPENDENCIES: doctor sources this before every other library, so the bash
# gate runs before any 4.4-only library can fail to load (trust-locate.sh is built
# the same way). It must therefore parse and run under bash 3.2: no `declare -A`
# or `-g`, no `mapfile`, no `${v,,}`, no `local -n`, no `[[ -v ]]`, no `;&`, and
# no expansion of a possibly-empty array under `set -u` (`${#a[@]}` is fine).
#
# The 4.4 floor also lives in the guard at the top of scripts/lib/potholes.sh,
# which stays for its other callers (#986); tests/doctor-prereqs.bats pins the two
# literals together.
#
# Setters write globals; call them bare, never inside $( … ).

PREREQ_BASH_MIN='4.4'
PREREQ_LABEL_BASH='bash 4.4 or later'
PREREQ_LABEL_GIT='git'
PREREQ_LABEL_PY='python3 3.11+, or 3.8-3.10 with tomli'
PREREQ_LABEL_JQ='jq'
PREREQ_STOP_BASH="doctor: stopped — devagent's libraries need bash 4.4 or later, so no other check ran"
PREREQ_STOP_PYTHON3='doctor: stopped — the remaining checks need python3'
# A python3 under WindowsApps that did not run (or printed no version) is most
# likely the Store's App execution alias, not a Python.
PREREQ_ALIAS_REMEDY='this python3 is probably the Windows Store alias: turn off its App execution alias under Settings > Apps > Advanced app settings > App execution aliases, then install Python 3.11 or later and open a new Git Bash window'

# The rows, as three parallel arrays (no TSV: `IFS=$'\t' read` collapses an
# empty field). PREREQ_PY is the python3 path that resolved; PREREQ_PY_OK is 1
# when it is usable.
PREREQ_ST=()
PREREQ_LABEL=()
PREREQ_DETAIL=()
PREREQ_PY=''
PREREQ_PY_OK=0

check() {
  local label="$1" status="$2" detail="${3:-}"
  case "$status" in
    ok)   echo "  OK   $label" ;;
    # skip: a check that does not apply on this platform (e.g. a POSIX
    # mode audit on a filesystem that can't represent modes). Visible and
    # non-fatal — never report a skipped 644/755 as a bare OK (#289).
    skip) echo "  SKIP $label${detail:+ — $detail}" ;;
    # warn: advisory only (#541 recommend-not-require) — visible, never
    # counted in ERRORS, never flips doctor's exit code. NOT the auth-hook
    # protocol's WARN (doctor_auth.sh), which deliberately maps to fail.
    warn) echo "  WARN $label${detail:+ — $detail}" ;;
    *)    echo "  FAIL $label${detail:+ — $detail}"; ERRORS=$((ERRORS + 1)) ;;
  esac
}

# prereq_version_ge <have> <want>: both M.m, each component 1-6 digits (so it
# stays within bash arithmetic). 0 when have >= want, 1 when lower, 2 malformed.
prereq_version_ge() {
  local re='^([0-9]{1,6})\.([0-9]{1,6})$' hM hm wM wm
  [[ "$1" =~ $re ]] || return 2
  hM="${BASH_REMATCH[1]}" hm="${BASH_REMATCH[2]}"
  [[ "$2" =~ $re ]] || return 2
  wM="${BASH_REMATCH[1]}" wm="${BASH_REMATCH[2]}"
  # 10#: a leading zero must not read as octal.
  if (( 10#$hM != 10#$wM )); then
    (( 10#$hM > 10#$wM )) && return 0
    return 1
  fi
  (( 10#$hm >= 10#$wm )) && return 0
  return 1
}

prereq_on_git_bash() {
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*) return 0 ;; esac
  return 1
}

# prereq_remedy <bash|git|python3|jq>: the one-line fix, the Windows way on Git Bash.
prereq_remedy() {
  if prereq_on_git_bash; then
    case "$1" in
      bash)    echo 'install a current Git for Windows (winget install --id Git.Git -e), whose Git Bash ships bash 5' ;;
      git)     echo 'winget install --id Git.Git -e, then open a new Git Bash window' ;;
      python3) echo 'install Python 3.11 or later, then check that python3 runs in a new Git Bash window' ;;
      jq)      echo 'winget install jqlang.jq, then open a new Git Bash window' ;;
    esac
  else
    case "$1" in
      bash)    echo 'install bash 4.4 or later and run devagent with it' ;;
      git)     echo 'install git 2.29 or later with your package manager' ;;
      python3) echo 'install Python 3.11 or later so that python3 runs it' ;;
      jq)      echo 'install jq with your package manager' ;;
    esac
  fi
}

_prereq_row() {   # _prereq_row <status> <label> [detail]
  local n=${#PREREQ_ST[@]}
  PREREQ_ST[n]="$1"
  PREREQ_LABEL[n]="$2"
  PREREQ_DETAIL[n]="${3:-}"
}

# prereq_bash_gate <M.m>: on >= 4.4 record an OK row silently; otherwise print the
# block header, the FAIL row and the stop line, and exit 1 — the libraries doctor
# sources next cannot load. A malformed version fails too.
prereq_bash_gate() {
  if prereq_version_ge "$1" "$PREREQ_BASH_MIN"; then
    _prereq_row ok "$PREREQ_LABEL_BASH"
    return 0
  fi
  echo
  echo "[prerequisites]"
  check "$PREREQ_LABEL_BASH" fail "found $1; $(prereq_remedy bash)"
  echo "$PREREQ_STOP_BASH"
  exit 1
}

prereq_git() {
  if type -P git >/dev/null 2>&1; then
    _prereq_row ok "$PREREQ_LABEL_GIT"
    return 0
  fi
  _prereq_row fail "$PREREQ_LABEL_GIT" "not found on PATH; $(prereq_remedy git)"
  return 1
}

# prereq_python3: sets PREREQ_PY / PREREQ_PY_OK and records one row. The probe runs
# the way devagent's scripts run python3 — without -I, so user-site packages
# (pip install --user tomli) count — from an empty temporary directory, so no file
# in the current folder can be imported instead.
prereq_python3() {
  local py d out err rc first re remedy tomli_fix mm
  PREREQ_PY='' PREREQ_PY_OK=0
  py="$(type -P python3 2>/dev/null)"
  if [ -z "$py" ]; then
    _prereq_row fail "$PREREQ_LABEL_PY" "not found on PATH; $(prereq_remedy python3)"
    return 1
  fi
  # A relative PATH entry would resolve again after the cd below.
  case "$py" in /*|[A-Za-z]:*) ;; *) py="$PWD/$py" ;; esac
  PREREQ_PY="$py"
  case "$py" in
    */[Ww]indows[Aa]pps/*) remedy="$PREREQ_ALIAS_REMEDY" ;;
    *)                     remedy="$(prereq_remedy python3)" ;;
  esac
  d="$(mktemp -d 2>/dev/null)"
  if [ -z "$d" ] || [ ! -d "$d" ] || ! mkdir "$d/run" 2>/dev/null; then
    _prereq_row fail "$PREREQ_LABEL_PY" "could not create a temporary directory to run $py from; check that TMPDIR names a writable directory"
    [ -n "$d" ] && rm -rf -- "$d"
    return 1
  fi
  # stdout and stderr apart: a .pth warning on stderr must not hide the version.
  out="$(cd "$d/run" && "$py" -c 'import sys; print(sys.version_info[:2])' 2>"$d/err")"
  rc=$?
  out="${out//$'\r'/}"   # Windows Python prints (3, 13)\r\n
  if [ "$rc" -ne 0 ]; then
    err="$(cat "$d/err" 2>/dev/null)"
    err="${err//$'\r'/}"
    first="${err%%$'\n'*}"
    [ -n "$first" ] || first="${out%%$'\n'*}"
    [ -n "$first" ] || first='(no output)'
    _prereq_row fail "$PREREQ_LABEL_PY" "$py exited $rc: $first; $remedy"
    rm -rf -- "$d"
    return 1
  fi
  first="${out%%$'\n'*}"
  [ -n "$first" ] || first='(no output)'
  re='^\(([0-9]{1,6}), ([0-9]{1,6})\)$'
  if ! [[ "$first" =~ $re ]]; then
    _prereq_row fail "$PREREQ_LABEL_PY" "$py printed \"$first\", not a version; $remedy"
    rm -rf -- "$d"
    return 1
  fi
  mm="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  if prereq_version_ge "$mm" 3.11; then
    _prereq_row ok "$PREREQ_LABEL_PY"
    PREREQ_PY_OK=1
  elif prereq_version_ge "$mm" 3.8; then
    if (cd "$d/run" && "$py" -c 'import tomli' >/dev/null 2>&1); then
      _prereq_row ok "$PREREQ_LABEL_PY"
      PREREQ_PY_OK=1
    else
      if prereq_on_git_bash; then
        tomli_fix="run \"$py\" -m pip install --user tomli"
      else
        tomli_fix="install tomli for it (apt install python3-tomli, or \"$py\" -m pip install --user tomli)"
      fi
      _prereq_row fail "$PREREQ_LABEL_PY" "$py is Python $mm without tomli; $tomli_fix, or install Python 3.11 or later"
    fi
  else
    _prereq_row fail "$PREREQ_LABEL_PY" "$py is Python $mm; $(prereq_remedy python3)"
  fi
  rm -rf -- "$d"
  [ "$PREREQ_PY_OK" -eq 1 ]
}

# prereq_print: replay the recorded rows through check (ok rows carry no detail).
prereq_print() {
  local i=0
  while [ "$i" -lt "${#PREREQ_ST[@]}" ]; do
    if [ "${PREREQ_ST[i]}" = ok ]; then
      check "${PREREQ_LABEL[i]}" ok
    else
      check "${PREREQ_LABEL[i]}" "${PREREQ_ST[i]}" "${PREREQ_DETAIL[i]}"
    fi
    i=$((i + 1))
  done
}
