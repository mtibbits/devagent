#!/usr/bin/env bash
# scripts/ci/gitbash-tagged.sh — #1096: the logic behind the `Git Bash tagged files`
# job in .github/workflows/gitbash.yml. The workflow is a thin caller; every rule
# that can fail the job lives here, where tests/gitbash-ci.bats drives it against
# planted fixtures on every PR.
#
# Usage:
#   gitbash-tagged.sh select <dir>
#       Print the tagged <dir>/*.bats files, one per line, in glob order.
#       rc 0  listed
#       rc 2  usage, or a grep error
#       rc 3  no file tagged ("NO TAGGED FILES in <dir>" on stderr)
#       rc 4  malformed tag line(s), each on stderr as "<file>:<line>: <text>"
#       The malformed check runs before the empty check, and before selection:
#       a typo in one file fails the job even when other files are tagged.
#   gitbash-tagged.sh run <outdir> <file>...
#       For each file in order: bats --formatter tap <file>, its output to
#       <outdir>/<basename>.tap and its rc to <outdir>/<basename>.rc; print the
#       TAP and "time: <file> <s>s". Never stops at a failing file. Then print
#       "time: total <s>s" and summarize. rc is summarize's.
#   gitbash-tagged.sh summarize <outdir> <file>...
#       One line per file, in order, then the verdict line:
#         gitbash-tagged: <file> ran=R passed=P skipped=S failed=F rc=RC OK
#         gitbash-tagged: <file> ran=R passed=P skipped=S failed=F rc=RC FAIL (<reason>; ...)
#         gitbash-tagged: <n> file(s), <k> failed
#       Each failed file is also annotated "::error file=<file>::<reasons>".
#       rc 0 when every file is OK, 1 otherwise, 2 on usage.
#
# A file FAILS on any of: bats rc != 0, no rc recorded, no TAP output, a "not ok"
# line, no plan line, plan != ran, zero tests ran, every test skipped, or a skip
# with no reason. A skip is only allowed with a stated reason.
#
# One bats invocation per file, so each file's TAP has its own 1..N plan and the
# counts above need no junit parsing.

set -uo pipefail

# The tag line: column 0, the acceptance criterion's regex verbatim. Selection and
# the malformed detector both read this ONE variable. No regex in this file has a
# /-leading segment, so MSYS path conversion under Git Bash cannot rewrite one.
SELECT_RE='^# bats file_tags=(.*,)? *gitbash *(,|$)'

plan_re='^1\.\.([0-9]+)$'
result_re='^(ok|not ok) [0-9]+( |$)'
fail_re='^not ok [0-9]+( |$)'
skip_re='^ok [0-9]+ .* # skip( |$)'
bare_skip_re='^ok ([0-9]+) .* # skip[[:space:]]*$'

die() { local rc="$1"; shift; printf 'gitbash-tagged: %s\n' "$*" >&2; exit "$rc"; }
usage() {
  die 2 "usage: gitbash-tagged.sh select <dir> | run <outdir> <file>... | summarize <outdir> <file>..."
}

cmd_select() {
  [ $# -eq 1 ] || usage
  local dir="$1" f hits h n text rc bad=0 listed
  [ -d "$dir" ] || die 2 "not a directory: $dir"
  shopt -s nullglob
  local files=("$dir"/*.bats)
  shopt -u nullglob

  # Malformed detector: any line naming the key and the value (any case) that the
  # selection regex rejects. Per file, never -H: a drive-letter dir puts ':' in a path.
  for f in "${files[@]}"; do
    hits="$(grep -niE 'file_tags.*gitbash' -- "$f")"; rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) die 2 "grep failed (rc $rc) on $f" ;;
    esac
    while IFS= read -r h; do
      n="${h%%:*}"; text="${h#*:}"
      if ! [[ $text =~ $SELECT_RE ]]; then
        printf '%s:%s: %s\n' "$f" "$n" "$text" >&2
        bad=1
      fi
    done <<< "$hits"
  done
  [ "$bad" -eq 0 ] || exit 4

  [ ${#files[@]} -gt 0 ] || die 3 "NO TAGGED FILES in $dir (no .bats files at all)"
  listed="$(grep -lE "$SELECT_RE" -- "${files[@]}")"; rc=$?
  case "$rc" in
    0) printf '%s\n' "$listed" ;;
    1) die 3 "NO TAGGED FILES in $dir" ;;
    *) die 2 "grep failed (rc $rc) selecting in $dir" ;;
  esac
}

cmd_run() {
  [ $# -ge 2 ] || usage
  local out="$1" f b s rc t0="$SECONDS"
  shift
  mkdir -p -- "$out" || die 2 "cannot create $out"
  for f in "$@"; do
    b="$(basename -- "$f")"
    s="$SECONDS"
    bats --formatter tap "$f" > "$out/$b.tap" 2>&1; rc=$?
    printf '%s\n' "$rc" > "$out/$b.rc"
    printf -- '--- %s (bats rc=%s)\n' "$f" "$rc"
    cat -- "$out/$b.tap"
    printf 'time: %s %ss\n' "$f" "$((SECONDS - s))"
  done
  printf 'time: total %ss\n' "$((SECONDS - t0))"
  cmd_summarize "$out" "$@"
}

cmd_summarize() {
  [ $# -ge 2 ] || usage
  local out="$1" f b tap rcv line plan ran failed skipped passed reason verdict
  local nfiles=0 nfailed=0
  local -a reasons bare
  shift
  for f in "$@"; do
    nfiles=$((nfiles + 1))
    b="$(basename -- "$f")"
    tap="$out/$b.tap"
    reasons=(); bare=()
    plan=""; ran=0; failed=0; skipped=0

    rcv="?"
    [ -f "$out/$b.rc" ] && rcv="$(tr -d '\r\n\t ' < "$out/$b.rc")"
    if ! [[ $rcv =~ ^[0-9]+$ ]]; then
      reasons+=("no rc recorded"); rcv="?"
    elif [ "$rcv" -ne 0 ]; then
      reasons+=("bats rc=$rcv")
    fi

    if [ ! -f "$tap" ]; then
      reasons+=("no TAP output")
    else
      while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $plan_re ]]; then
          [ -n "$plan" ] || plan="${BASH_REMATCH[1]}"
        elif [[ $line =~ $result_re ]]; then
          ran=$((ran + 1))
          if [[ $line =~ $fail_re ]]; then
            failed=$((failed + 1))
          elif [[ $line =~ $skip_re ]]; then
            skipped=$((skipped + 1))
            [[ $line =~ $bare_skip_re ]] && bare+=("${BASH_REMATCH[1]}")
          fi
        fi
      done < <(tr -d '\r' < "$tap")
      [ "$failed" -eq 0 ] || reasons+=("failed=$failed")
      if [ -z "$plan" ]; then
        reasons+=("no plan line")
      elif [ "$plan" -ne "$ran" ]; then
        reasons+=("plan $plan != ran $ran")
      fi
      if [ "$ran" -eq 0 ]; then
        reasons+=("no tests ran")
      elif [ "$skipped" -eq "$ran" ]; then
        reasons+=("every test skipped")
      fi
      [ ${#bare[@]} -eq 0 ] \
        || reasons+=("skip without a reason: $(IFS=,; printf '%s' "${bare[*]}")")
    fi

    passed=$((ran - failed - skipped))
    if [ ${#reasons[@]} -eq 0 ]; then
      verdict="OK"
    else
      reason="$(printf '%s; ' "${reasons[@]}")"; reason="${reason%; }"
      verdict="FAIL ($reason)"
      nfailed=$((nfailed + 1))
    fi
    printf 'gitbash-tagged: %s ran=%s passed=%s skipped=%s failed=%s rc=%s %s\n' \
      "$f" "$ran" "$passed" "$skipped" "$failed" "$rcv" "$verdict"
    [ "$verdict" = OK ] || printf '::error file=%s::%s\n' "$f" "$reason"
  done
  printf 'gitbash-tagged: %s file(s), %s failed\n' "$nfiles" "$nfailed"
  [ "$nfailed" -eq 0 ]
}

[ $# -ge 1 ] || usage
verb="$1"; shift
case "$verb" in
  select)    cmd_select "$@" ;;
  run)       cmd_run "$@" ;;
  summarize) cmd_summarize "$@"; exit $? ;;
  *)         usage ;;
esac
