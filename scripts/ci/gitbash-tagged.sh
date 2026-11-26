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
#   gitbash-tagged.sh run [--jobs N] <outdir> <file>...
#       For each file: bats --formatter tap <file>, its output to
#       <outdir>/<basename>.tap and its rc to <outdir>/<basename>.rc; print the
#       TAP and "time: <file> <s>s". Never stops at a failing file. Then print
#       "time: total <s>s" and summarize. rc is summarize's. With --jobs N (N > 1)
#       the files run N at a time (xargs -P N, one bats per file), each printing
#       "done: <file> rc=<rc> <s>s" as it finishes (so a hung run shows which file
#       never did), and the TAP and time lines print afterwards, still in list order.
#       Records are keyed by basename: the files passed to run and summarize must
#       have distinct basenames.
#   gitbash-tagged.sh summarize <outdir> <file>...
#       One line per file, in order, then the verdict line:
#         gitbash-tagged: <file> ran=R passed=P skipped=S failed=F rc=RC OK
#         gitbash-tagged: <file> ran=R passed=P skipped=S failed=F rc=RC FAIL (<reason>; ...)
#         gitbash-tagged: <n> file(s), <k> failed
#       Each failed file is also annotated "::error file=<file>::<reasons>".
#       rc 0 when every file is OK, 1 otherwise, 2 on usage.
#   gitbash-tagged.sh shard <index> <count> <timings> <file>...
#       (#1197) Print shard <index> of <count> (1-based) of <file>..., one per line,
#       heaviest first (ties: list order). Weights: <timings> rows by basename; a
#       file with no row weighs 60 and is named on stderr ("gitbash-tagged: untimed
#       <file> (weighted 60s)"). Files are taken largest first (ties: list order),
#       each onto the least-loaded shard (ties: lowest index). stderr ends
#       "gitbash-tagged: shard <i> of <k>: <n> file(s), weight <w>s".
#       rc 0 listed; 2 usage, unreadable or bad timings; 3 the shard is empty.
#       A <timings> row is "<basename> <seconds>"; blank and '#' lines are skipped.
#       The weights only balance the shards: a missing or stale row never drops a
#       file from the union of the <count> shards.
#   gitbash-tagged.sh gate <count> <interval-secs> <run-secs> <start-secs>
#       (#1197) The body of the `Git Bash tagged files` job. In a workflow run
#       (GITHUB_REPOSITORY, GITHUB_RUN_ID; gh reads GH_TOKEN), poll
#         gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?filter=latest&per_page=100"
#       every <interval-secs> until the shard jobs, named "Git Bash shard <i> of
#       <count>" for i = 1..<count>, are each completed with conclusion success
#       (rc 0, last line "gitbash-tagged: gate: <count> of <count> shards succeeded"), or:
#       rc 1  a shard completed with any other conclusion, or none (at once; the
#             other shards are not waited for and nothing is cancelled);
#             a job named "Git Bash shard <i> of <m>" with m != <count> or i outside
#             1..<count>, or one named twice;
#             a shard in_progress for more than <run-secs> since its started_at
#             (the shard's own clock; a queued shard's started_at is never read);
#             a shard missing, not yet in_progress, or in_progress with no
#             started_at when the gate has waited <start-secs> ($SECONDS since the
#             gate began, never poll turns);
#             5 consecutive reads failed (gh rc != 0, or jq could not read .jobs).
#       rc 2  usage: <count> as shard's; <interval-secs> 0..9999; <run-secs> and
#             <start-secs> 1..99999; GITHUB_REPOSITORY and GITHUB_RUN_ID set.
#       Each poll prints "gitbash-tagged: gate: <d> of <count> shards done (<name>=
#       <status, conclusion or in_progress <age>s>, ...)". A failure prints
#       "::error::<reason>", "gitbash-tagged: gate: FAIL (<reason>)", the failing
#       shard's job URL, and the remedy: re-run failed jobs (not a single shard) to
#       refresh Git Bash tagged files. A single-shard re-run does not re-run this
#       job, so it would keep its old verdict.
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
skip_re='^ok [0-9]+ .* # skip( |$)'
bare_skip_re='^ok ([0-9]+) .* # skip[[:space:]]*$'

die() { local rc="$1"; shift; printf 'gitbash-tagged: %s\n' "$*" >&2; exit "$rc"; }
usage() {
  die 2 "usage: gitbash-tagged.sh select <dir> | run [--jobs N] <outdir> <file>... | summarize <outdir> <file>... | shard <index> <count> <timings> <file>... | gate <count> <interval-secs> <run-secs> <start-secs>"
}

# shard: bounded widths (a digit regex alone does not bound arithmetic, #774).
shard_num_re='^[1-9][0-9]{0,2}$'
times_row_re='^([A-Za-z0-9][A-Za-z0-9._-]*\.bats) ([0-9]{1,5})$'
UNTIMED_SECS=60

cmd_shard() {
  [ $# -ge 4 ] || usage
  local idx="$1" cnt="$2" tab="$3" line n=0 name f b i j s best
  shift 3
  [[ $idx =~ $shard_num_re ]] || die 2 "bad shard index: $idx"
  [[ $cnt =~ $shard_num_re ]] || die 2 "bad shard count: $cnt"
  [ "$idx" -le "$cnt" ] || die 2 "shard index $idx > count $cnt"
  { [ -f "$tab" ] && [ -r "$tab" ]; } || die 2 "cannot read timings: $tab"

  local -A secs=() seen=()
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line//$'\r'/}"          # CRLF table: strip by expansion, never grep (#962)
    [ -z "$line" ] && continue
    [[ $line == '#'* ]] && continue
    [[ $line =~ $times_row_re ]] || die 2 "bad timings line $n: $line"
    name="${BASH_REMATCH[1]}"
    [ -z "${secs[$name]+x}" ] || die 2 "duplicate timings row: $name"
    secs[$name]=$((10#${BASH_REMATCH[2]}))   # 10#: a leading 0 is decimal, not octal
  done < "$tab"

  local -a files=("$@") wt=() untimed=() order=() load=() mine=()
  for f in "${files[@]}"; do
    b="${f##*/}"
    [ -z "${seen[$b]+x}" ] || die 2 "duplicate file basename: $b"
    seen[$b]=1
    if [ -n "${secs[$b]+x}" ]; then wt+=("${secs[$b]}"); untimed+=(""); else wt+=("$UNTIMED_SECS"); untimed+=(1); fi
  done

  # Stable insertion sort of indexes by weight, heaviest first (ties: list order).
  for ((i = 0; i < ${#files[@]}; i++)); do
    j=${#order[@]}
    order+=("$i")
    while [ "$j" -gt 0 ] && [ "${wt[${order[j-1]}]}" -lt "${wt[i]}" ]; do
      order[j]="${order[j-1]}"; j=$((j - 1))
    done
    order[j]="$i"
  done

  # LPT: each file onto the least-loaded shard (ties: lowest index).
  for ((s = 1; s <= cnt; s++)); do load[s]=0; done
  for i in "${order[@]}"; do
    best=1
    for ((s = 2; s <= cnt; s++)); do
      [ "${load[s]}" -lt "${load[best]}" ] && best="$s"
    done
    load[best]=$((load[best] + wt[i]))
    [ "$best" -eq "$idx" ] && mine+=("$i")
  done

  [ ${#mine[@]} -gt 0 ] || die 3 "shard $idx of $cnt is empty (${#files[@]} file(s) for $cnt shards)"
  for i in "${mine[@]}"; do
    printf '%s\n' "${files[i]}"
    [ -z "${untimed[i]}" ] \
      || printf 'gitbash-tagged: untimed %s (weighted %ss)\n' "${files[i]}" "$UNTIMED_SECS" >&2
  done
  printf 'gitbash-tagged: shard %s of %s: %s file(s), weight %ss\n' \
    "$idx" "$cnt" "${#mine[@]}" "${load[idx]}" >&2
}

# gate: one numeric grammar; the shard names are "Git Bash shard <i> of <count>".
gate_interval_re='^(0|[1-9][0-9]{0,3})$'
gate_secs_re='^[1-9][0-9]{0,4}$'
shard_name_re='^Git Bash shard ([0-9]{1,3}) of ([0-9]{1,3})$'
GATE_MAX_READ_FAILS=5
GATE_REMEDY='re-run failed jobs (not a single shard) to refresh Git Bash tagged files'
# One TSV row per job; no field is ever empty, so a TAB-split read cannot shift
# fields. The age is read only while the job is in_progress: a queued job's
# started_at is its created_at (spike U7), and queue time never counts. A negative
# age (clock skew) is 0.
# shellcheck disable=SC2016  # jq program, not shell
GATE_JQ='if (.jobs | type) != "array" then error("no .jobs array") else .jobs[] end
  | [ (.name // "-"), (.status // "-"), (.conclusion // "-"),
      (if .status == "in_progress" and .started_at
       then ((now - (.started_at | fromdateiso8601)) | floor | if . < 0 then 0 else . end | tostring)
       else "-" end),
      (.html_url // "-") ]
  | @tsv'

# gate_fail <reason> [<url>]: the named check's verdict line, its annotation, and
# the remedy; exit 1.
gate_fail() {
  printf '::error::%s\n' "$1"
  printf 'gitbash-tagged: gate: FAIL (%s)\n' "$1"
  [ -z "${2:-}" ] || [ "$2" = - ] || printf 'gitbash-tagged: gate: see %s\n' "$2"
  printf 'gitbash-tagged: gate: %s\n' "$GATE_REMEDY"
  exit 1
}

cmd_gate() {
  [ $# -eq 4 ] || usage
  local cnt="$1" iv="$2" runs="$3" starts="$4"
  [[ $cnt =~ $shard_num_re ]] || die 2 "bad gate count: $cnt"
  [[ $iv =~ $gate_interval_re ]] || die 2 "bad gate interval: $iv"
  [[ $runs =~ $gate_secs_re ]] || die 2 "bad gate run-secs: $runs"
  [[ $starts =~ $gate_secs_re ]] || die 2 "bad gate start-secs: $starts"
  [ -n "${GITHUB_REPOSITORY:-}" ] || die 2 "GITHUB_REPOSITORY is not set (gate runs inside a workflow run)"
  [ -n "${GITHUB_RUN_ID:-}" ] || die 2 "GITHUB_RUN_ID is not set (gate runs inside a workflow run)"
  local url="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?filter=latest&per_page=100"
  local t0="$SECONDS" fails=0 body rows rc reason errf
  local name status concl age hurl i m d n waited line failr failu
  errf="$(mktemp)" || die 2 "mktemp failed"
  # shellcheck disable=SC2064  # expand errf now
  trap "rm -f -- '$errf'" EXIT

  while :; do
    # Capture, then test the rc: never through a pipe (#314).
    body="$(gh api "$url" 2>"$errf")"; rc=$?
    reason=""
    if [ "$rc" -ne 0 ]; then
      reason="gh api rc $rc: $(head -c 300 "$errf")"
    else
      rows="$(jq -r "$GATE_JQ" 2>"$errf" <<<"$body")"; rc=$?
      [ "$rc" -eq 0 ] || reason="not a jobs response (jq rc $rc: $(head -c 300 "$errf"))"
    fi
    if [ -n "$reason" ]; then
      reason="${reason//[$'\r\n']/ }"
      fails=$((fails + 1))
      printf 'gitbash-tagged: gate: read %s of %s failed: %s\n' "$fails" "$GATE_MAX_READ_FAILS" "$reason"
      [ "$fails" -lt "$GATE_MAX_READ_FAILS" ] \
        || gate_fail "could not read the run's jobs $GATE_MAX_READ_FAILS times in a row: $reason"
      sleep "$iv"; continue
    fi
    fails=0
    rows="${rows//$'\r'/}"   # a Windows jq writes CRLF

    local -A st=() co=() ag=() hu=()
    while IFS=$'\t' read -r name status concl age hurl; do
      [[ $name =~ $shard_name_re ]] || continue
      i=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]}))
      { [ "$m" -eq "$cnt" ] && [ "$i" -ge 1 ] && [ "$i" -le "$cnt" ]; } \
        || gate_fail "unexpected shard job: $name" "$hurl"
      [ -z "${st[$i]+x}" ] || gate_fail "duplicate shard job: $name" "$hurl"
      st[$i]="$status"; co[$i]="$concl"; ag[$i]="$age"; hu[$i]="$hurl"
    done <<<"$rows"

    # Judge every shard, then print the poll line, then the first failure (if any).
    d=0; failr=""; failu=""
    local -a seen=() waiting=()
    for ((i = 1; i <= cnt; i++)); do
      n="Git Bash shard $i of $cnt"
      if [ -z "${st[$i]+x}" ]; then
        seen+=("$n=missing"); waiting+=("$n (missing)")
      elif [ "${st[$i]}" = completed ]; then
        seen+=("$n=${co[$i]}")
        if [ "${co[$i]}" = success ]; then d=$((d + 1))
        elif [ -z "$failr" ]; then
          concl="${co[$i]}"; [ "$concl" != - ] || concl="no conclusion"
          failr="$n: $concl"; failu="${hu[$i]}"
        fi
      elif [ "${st[$i]}" = in_progress ] && [ "${ag[$i]}" != - ]; then
        seen+=("$n=in_progress ${ag[$i]}s")
        if [ "${ag[$i]}" -gt "$runs" ] && [ -z "$failr" ]; then
          failr="$n in progress ${ag[$i]}s since started_at, past ${runs}s"; failu="${hu[$i]}"
        fi
      elif [ "${st[$i]}" = in_progress ]; then
        seen+=("$n=in_progress"); waiting+=("$n (in_progress, no started_at)")
      else
        seen+=("$n=${st[$i]}"); waiting+=("$n (${st[$i]})")
      fi
    done
    line="$(printf '%s, ' "${seen[@]}")"
    printf 'gitbash-tagged: gate: %s of %s shards done (%s)\n' "$d" "$cnt" "${line%, }"
    [ -z "$failr" ] || gate_fail "$failr" "$failu"
    if [ "$d" -eq "$cnt" ]; then
      printf 'gitbash-tagged: gate: %s of %s shards succeeded\n' "$cnt" "$cnt"
      return 0
    fi
    waited=$((SECONDS - t0))
    if [ ${#waiting[@]} -gt 0 ] && [ "$waited" -ge "$starts" ]; then
      line="$(printf '%s; ' "${waiting[@]}")"
      gate_fail "not started after ${starts}s: ${line%; }"
    fi
    sleep "$iv"
  done
}

cmd_select() {
  [ $# -eq 1 ] || usage
  local dir="$1" f hits h n text rc bad=0 listed
  [ -d "$dir" ] || die 2 "not a directory: $dir"
  shopt -s nullglob
  local files=("$dir"/*.bats)
  shopt -u nullglob

  # Malformed detector: any comment line naming the key and the value (any case)
  # that the selection regex rejects. bats reads tags only from comments, so a code
  # line naming both is not a tag. Per file, never -H: a drive-letter dir puts ':'
  # in a path.
  for f in "${files[@]}"; do
    hits="$(grep -niE '^[[:space:]]*#.*file_tags.*gitbash' -- "$f")"; rc=$?
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

# _one <outdir> <file>: run one file, recording <basename>.tap, .rc and .secs.
# Always returns 0: the recorded rc is the verdict's input, never this status.
# Sets ONE_RC and ONE_SECS for the _one verb's done line.
cmd_one() {
  local out="$1" f="$2" b s
  b="${f##*/}"
  s="$SECONDS"
  bats --formatter tap "$f" > "$out/$b.tap" 2>&1; ONE_RC=$?
  ONE_SECS=$((SECONDS - s))
  printf '%s\n' "$ONE_RC" > "$out/$b.rc"
  printf '%s\n' "$ONE_SECS" > "$out/$b.secs"
  return 0
}

# report <outdir> <file>: print one file's recorded TAP and time line.
report() {
  local out="$1" f="$2" b rc='?' secs='?'
  b="${f##*/}"
  [ -f "$out/$b.rc" ] && read -r rc < "$out/$b.rc"
  [ -f "$out/$b.secs" ] && read -r secs < "$out/$b.secs"
  printf -- '--- %s (bats rc=%s)\n' "$f" "$rc"
  cat -- "$out/$b.tap" 2>/dev/null || echo "(no TAP recorded)"
  printf 'time: %s %ss\n' "$f" "$secs"
}

cmd_run() {
  local jobs=1
  if [ "${1:-}" = --jobs ]; then
    [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || usage
    jobs="$2"; shift 2
  fi
  [ $# -ge 2 ] || usage
  local out="$1" f b t0="$SECONDS"
  shift
  mkdir -p -- "$out" || die 2 "cannot create $out"
  # A stale record from an earlier run must never stand in for a missing one.
  local -a stale=()
  for f in "$@"; do
    b="${f##*/}"
    stale+=("$out/$b.tap" "$out/$b.rc" "$out/$b.secs")
  done
  rm -f -- "${stale[@]}"
  if [ "$jobs" -eq 1 ]; then
    for f in "$@"; do cmd_one "$out" "$f"; report "$out" "$f"; done
  else
    # N files at a time; output is printed afterwards in LIST order. A child that
    # records nothing is caught by summarize (no rc recorded / no TAP output).
    printf '%s\0' "$@" | xargs -0 -n 1 -P "$jobs" "${BASH:-bash}" "$0" _one "$out"
    for f in "$@"; do report "$out" "$f"; done
  fi
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
    b="${f##*/}"
    tap="$out/$b.tap"
    reasons=(); bare=()
    plan=""; ran=0; failed=0; skipped=0

    rcv="?"
    [ -f "$out/$b.rc" ] && { read -r rcv < "$out/$b.rc"; rcv="${rcv//[$'\r\t ']/}"; }
    if ! [[ $rcv =~ ^[0-9]+$ ]]; then
      reasons+=("no rc recorded"); rcv="?"
    elif [ "$rcv" -ne 0 ]; then
      reasons+=("bats rc=$rcv")
    fi

    if [ ! -f "$tap" ]; then
      reasons+=("no TAP output")
    else
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        if [[ $line =~ $plan_re ]]; then
          [ -n "$plan" ] || plan="${BASH_REMATCH[1]}"
        elif [[ $line =~ $result_re ]]; then
          ran=$((ran + 1))
          if [ "${BASH_REMATCH[1]}" = "not ok" ]; then
            failed=$((failed + 1))
          elif [[ $line =~ $skip_re ]]; then
            skipped=$((skipped + 1))
            [[ $line =~ $bare_skip_re ]] && bare+=("${BASH_REMATCH[1]}")
          fi
        fi
      done < "$tap"
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
  _one)      [ $# -eq 2 ] || usage; cmd_one "$@"
             printf 'done: %s rc=%s %ss\n' "$2" "$ONE_RC" "$ONE_SECS" ;;
  summarize) cmd_summarize "$@" ;;
  shard)     cmd_shard "$@" ;;
  gate)      cmd_gate "$@" ;;
  *)         usage ;;
esac
