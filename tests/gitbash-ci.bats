#!/usr/bin/env bats
# tests/gitbash-ci.bats — #1096: scripts/ci/gitbash-tagged.sh, the helper behind the
# `Git Bash tagged files` check in .github/workflows/gitbash.yml. Selection, the
# malformed-tag detector, the per-file run loop, the TAP rules, the `shard` split and
# the `gate` that is the check job (#1197) are each driven against planted fixtures
# here, so every fail-closed rule has a control that runs on
# every PR (the Linux shards). This file is NOT itself tagged.
#
# Invariant: no line of this file may hold both the tag key and the tag value, or
# the live-tree test below fails with rc 4 on this very file. Every such string is
# composed from K and T (and the mixed-case spelling from G and B).
bats_require_minimum_version 1.5.0   # run --separate-stderr wherever stderr is pinned

load 'lib/bats-helpers'

K=file_tags
T=gitbash
G=Git
B=Bash

setup() {
  H="$PLUGIN_ROOT/scripts/ci/gitbash-tagged.sh"
  D="$BATS_TEST_TMPDIR/t"
  O="$BATS_TEST_TMPDIR/out"
  mkdir -p "$D" "$O"
}

# tagfile <name> <line>: a fixture .bats whose line 2 is <line>.
tagfile() {
  printf '%s\n%s\n%s\n' '#!/usr/bin/env bats' "$2" '@test "x" { true; }' > "$D/$1"
}
# tagline <value>: the well-formed tag line carrying <value>.
tagline() { printf '# bats %s=%s' "$K" "$1"; }
# mktap <name> <rc> <tap line>...: a recorded per-file result in $O.
mktap() {
  local n="$1" rc="$2"; shift 2
  printf '%s\n' "$@" > "$O/$n.tap"
  printf '%s\n' "$rc" > "$O/$n.rc"
}
# fileline <name>: the summarize line for <name> from the last run.
fileline() {
  local l
  for l in "${lines[@]}"; do
    [[ "$l" == "gitbash-tagged: $1 "* ]] && { printf '%s\n' "$l"; return 0; }
  done
  return 1
}

# ------------------------------------------------------------------- select

@test "select: lists a file tagged gitbash alone, first, last, and space-padded" {
  tagfile a.bats "$(tagline "$T")"
  tagfile b.bats "$(tagline "slow,$T")"
  tagfile c.bats "$(tagline "$T,slow")"
  tagfile d.bats "$(tagline "a, $T ,b")"
  run --separate-stderr "$H" select "$D"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$D/a.bats" "$D/b.bats" "$D/c.bats" "$D/d.bats")" ]
}

@test "select: ignores untagged files and files with other tags only" {
  tagfile a.bats "$(tagline "$T")"
  tagfile b.bats "$(tagline slow)"
  tagfile c.bats '# just a comment'
  run --separate-stderr "$H" select "$D"
  [ "$status" -eq 0 ]
  [ "$output" = "$D/a.bats" ]
}

@test "select: exit 3 when no file is tagged" {
  tagfile b.bats "$(tagline slow)"
  tagfile c.bats '# just a comment'
  run --separate-stderr "$H" select "$D"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"NO TAGGED FILES"* ]]
}

@test "select: exit 2 when the directory does not exist" {
  run --separate-stderr "$H" select "$BATS_TEST_TMPDIR/no-such-dir"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not a directory"* ]]
}

@test "select: a code line naming the tag is neither a tag nor malformed" {
  tagfile a.bats "$(tagline "$T")"
  tagfile c.bats "run grep -c \"$K=$T\" README.md"
  run --separate-stderr "$H" select "$D"
  [ "$status" -eq 0 ]
  [ "$output" = "$D/a.bats" ]
}

@test "select: exit 4 on every malformed spelling, naming file and line" {
  local s i=0
  local -a bad=(
    " $(tagline "$T")"
    "#bats $K=$T"
    "# bats  $K=$T"
    "$(tagline "$G$B")"
    "$(tagline "${T}2")"
    "$(tagline "x,$T-slow")"
  )
  [ "${#bad[@]}" -eq 6 ]
  for s in "${bad[@]}"; do
    i=$((i + 1))
    rm -rf "$D"; mkdir -p "$D"
    tagfile "m$i.bats" "$s"
    run --separate-stderr "$H" select "$D"
    [ "$status" -eq 4 ] || { echo "spelling $i: rc $status for [$s]"; return 1; }
    [[ "$stderr" == *"$D/m$i.bats:2:"* ]] || { echo "spelling $i: stderr [$stderr]"; return 1; }
  done
  # A file that ALSO carries a valid line still fails: the malformed check runs first.
  rm -rf "$D"; mkdir -p "$D"
  printf '%s\n%s\n%s\n' '#!/usr/bin/env bats' "$(tagline "$T")" "#bats $K=$T" > "$D/both.bats"
  run --separate-stderr "$H" select "$D"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"$D/both.bats:3:"* ]]
}

@test "select: a malformed tag beside a valid file still fails" {
  tagfile a.bats "$(tagline "$T")"
  tagfile b.bats "$(tagline "${T}2")"
  run --separate-stderr "$H" select "$D"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"$D/b.bats:2:"* ]]
}

@test "select: SELECT_RE is the acceptance criterion's regex verbatim" {
  local want
  want="SELECT_RE='^# bats $K=(.*,)? *$T *(,|\$)'"
  run grep -cF -- "$want" "$H"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
}

@test "helper: committed executable" {
  [ -x "$H" ]
  run git -C "$PLUGIN_ROOT" ls-files -s scripts/ci/gitbash-tagged.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755\ * ]]
}

@test "select: the live tests/ tree has at least one tagged file and no malformed tag" {
  run --separate-stderr "$H" select "$PLUGIN_ROOT/tests"
  [ "$status" -eq 0 ] || { echo "rc $status: $stderr"; return 1; }
  [ -n "$output" ]
}

# #1097 (U5): tests/preship-deferred.bats checks the Git Bash criterion's static half
# with git and this selector, so the Windows job must run it.
@test "#1097 select tests lists tests/preship-deferred.bats" {
  run --separate-stderr "$H" select "$PLUGIN_ROOT/tests"
  [ "$status" -eq 0 ] || { echo "rc $status: $stderr"; return 1; }
  grep -qxF "$PLUGIN_ROOT/tests/preship-deferred.bats" <<<"$output"
}

@test "select: the README's documented tag line selects" {
  local sect tagl
  sect="$(sed -n '/^## Running the test suite$/,/^## /p' "$PLUGIN_ROOT/README.md")"
  tagl="$(printf '%s\n' "$sect" | grep -oE '`# bats [^`]*`' | head -n 1)"
  tagl="${tagl//\`/}"
  [ -n "$tagl" ] || { echo "no backticked tag line in README's Running the test suite"; return 1; }
  tagfile r.bats "$tagl"
  run --separate-stderr "$H" select "$D"
  [ "$status" -eq 0 ]
  [ "$output" = "$D/r.bats" ]
}

# ---------------------------------------------------------------- summarize

@test "summarize: a passing file reports its counts and OK" {
  mktap x.bats 0 '1..3' 'ok 1 a' 'ok 2 b # skip needs modes' 'ok 3 c'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 0 ]
  [ "$(fileline x.bats)" = "gitbash-tagged: x.bats ran=3 passed=2 skipped=1 failed=0 rc=0 OK" ]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: 1 file(s), 0 failed" ]
}

@test "summarize: not ok fails the file" {
  mktap x.bats 1 '1..2' 'ok 1 a' 'not ok 2 b'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  local l; l="$(fileline x.bats)"
  [[ "$l" == *" failed=1 rc=1 FAIL ("* ]]
  [[ "${l#* FAIL }" == *"failed=1"* ]]
  [[ "$output" == *"::error file=x.bats::"* ]]
}

@test "summarize: a skip with no reason fails, naming the test number" {
  local tail
  for tail in '' '   '; do
    mktap x.bats 0 '1..2' 'ok 1 a' "ok 2 b # skip$tail"
    run "$H" summarize "$O" x.bats
    [ "$status" -eq 1 ]
    [[ "$(fileline x.bats)" == *"FAIL ("*"skip without a reason: 2"* ]]
  done
}

@test "summarize: every test skipped fails" {
  mktap x.bats 0 '1..2' 'ok 1 a # skip r1' 'ok 2 b # skip r2'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *"FAIL ("*"every test skipped"* ]]
}

@test "summarize: zero tests, missing plan, plan mismatch, missing TAP each fail" {
  mktap x.bats 0 '1..0'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *"FAIL ("*"no tests ran"* ]]

  mktap x.bats 0 'ok 1 a'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *"FAIL ("*"no plan line"* ]]

  mktap x.bats 0 '1..3' 'ok 1 a' 'ok 2 b'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *"FAIL ("*"plan 3 != ran 2"* ]]

  rm -f "$O/x.bats.tap"
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *"FAIL ("*"no TAP output"* ]]
}

@test "summarize: a non-zero bats rc fails even when every line is ok" {
  mktap x.bats 1 '1..2' 'ok 1 a' 'ok 2 b'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *"FAIL ("*"bats rc=1"* ]]
}

@test "summarize: a missing or empty rc record fails as no rc recorded" {
  mktap x.bats 0 '1..1' 'ok 1 a'
  rm -f "$O/x.bats.rc"
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *" rc=? FAIL ("*"no rc recorded"* ]]

  : > "$O/x.bats.rc"
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *" rc=? FAIL ("*"no rc recorded"* ]]
}

@test "summarize: CRLF TAP counts the same as LF" {
  local lf
  mktap x.bats 0 '1..3' 'ok 1 a' 'ok 2 b # skip needs modes' 'ok 3 c'
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 0 ]
  lf="$(fileline x.bats)"
  printf '%s\r\n' '1..3' 'ok 1 a' 'ok 2 b # skip needs modes' 'ok 3 c' > "$O/x.bats.tap"
  printf '0\r\n' > "$O/x.bats.rc"
  run "$H" summarize "$O" x.bats
  [ "$status" -eq 0 ]
  [ "$(fileline x.bats)" = "$lf" ]
}

@test "summarize: every file is reported before the verdict" {
  mktap x.bats 1 '1..1' 'not ok 1 a'
  mktap y.bats 0 '1..1' 'ok 1 a'
  run "$H" summarize "$O" x.bats y.bats
  [ "$status" -eq 1 ]
  [[ "$(fileline x.bats)" == *" FAIL ("* ]]
  [[ "$(fileline y.bats)" == *" OK" ]]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: 2 file(s), 1 failed" ]
}

# ---------------------------------------------------------------------- run

# stub_bats: a binstub bats on STUB_BIN that logs its argv, sleeps 2s on a.bats (so
# under --jobs the first file finishes last), and fails any *fail*.bats.
stub_bats() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  export STUB_LOG="$BATS_TEST_TMPDIR/bats-argv.log"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$STUB_LOG"' \
    'f="${!#}"' \
    'case "$f" in *a.bats) sleep 2 ;; esac' \
    'case "$f" in' \
    '  *fail*.bats) printf "1..1\nnot ok 1 planted\n"; exit 1 ;;' \
    '  *) printf "1..1\nok 1 %s\n" "${f##*/}" ;;' \
    'esac' > "$STUB_BIN/bats"
  chmod +x "$STUB_BIN/bats"
}

@test "run: invokes bats once per file in list order with the TAP formatter, and carries on past a failure" {
  stub_bats
  tagfile fail.bats "$(tagline "$T")"
  tagfile b.bats "$(tagline "$T")"
  PATH="$STUB_BIN:$PATH" run "$H" run "$O" "$D/fail.bats" "$D/b.bats"
  [ "$status" -eq 1 ]
  [ "$(cat "$STUB_LOG")" = "$(printf '%s\n' "--formatter tap $D/fail.bats" "--formatter tap $D/b.bats")" ]
  [[ "$output" == *"not ok 1 planted"* ]]
  [[ "$output" == *"ok 1 b.bats"* ]]
  [[ "$output" =~ time:\ "$D/fail.bats"\ [0-9]+s ]]
  [[ "$output" =~ time:\ "$D/b.bats"\ [0-9]+s ]]
  [[ "$output" =~ time:\ total\ [0-9]+s ]]
  [[ "$(fileline "$D/fail.bats")" == *" FAIL ("* ]]
  [[ "$(fileline "$D/b.bats")" == *" OK" ]]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: 2 file(s), 1 failed" ]
}

@test "run --jobs 2: every file runs once and output is in list order" {
  local n
  stub_bats
  for n in a b c; do tagfile "$n.bats" "$(tagline "$T")"; done
  PATH="$STUB_BIN:$PATH" run "$H" run --jobs 2 "$O" "$D/a.bats" "$D/b.bats" "$D/c.bats"
  [ "$status" -eq 0 ]
  [ "$(sort "$STUB_LOG")" = "$(printf '%s\n' "--formatter tap $D/a.bats" "--formatter tap $D/b.bats" "--formatter tap $D/c.bats")" ]
  # a.bats finished last, yet its TAP and time line come first: output follows the list.
  [ "$(printf '%s\n' "${lines[@]}" | grep -E '^(ok 1 |time: )' | sed -E 's/ [0-9]+s$/ Ns/')" = \
    "$(printf '%s\n' 'ok 1 a.bats' "time: $D/a.bats Ns" 'ok 1 b.bats' "time: $D/b.bats Ns" \
                     'ok 1 c.bats' "time: $D/c.bats Ns" 'time: total Ns')" ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -E '^gitbash-tagged: ' | cut -d' ' -f2)" = \
    "$(printf '%s\n' "$D/a.bats" "$D/b.bats" "$D/c.bats" '3')" ]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: 3 file(s), 0 failed" ]
  # Each file prints a done line as it finishes; the slow a.bats finishes last.
  [ "$(printf '%s\n' "${lines[@]}" | grep -c '^done: ')" -eq 3 ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep '^done: ' | tail -n 1)" =~ ^done:\ "$D/a.bats"\ rc=0\ [0-9]+s$ ]]
}

@test "run: --jobs must be a positive integer" {
  tagfile a.bats "$(tagline "$T")"
  run --separate-stderr "$H" run --jobs 0 "$O" "$D/a.bats"
  [ "$status" -eq 2 ]
  run --separate-stderr "$H" run --jobs x "$O" "$D/a.bats"
  [ "$status" -eq 2 ]
}

@test "run --jobs 2: a stale record never stands in for a child that recorded nothing" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  # The stub kills its parent (the per-file worker) before it can record an rc.
  printf '%s\n' '#!/usr/bin/env bash' 'kill -9 "$PPID"' > "$bin/bats"
  chmod +x "$bin/bats"
  tagfile dies.bats "$(tagline "$T")"
  mktap dies.bats 0 '1..1' 'ok 1 stale'
  PATH="$bin:$PATH" run "$H" run --jobs 2 "$O" "$D/dies.bats"
  [ "$status" -eq 1 ]
  [[ "$(fileline "$D/dies.bats")" == *" rc=? FAIL ("*"no rc recorded"* ]]
}

@test "run --jobs 2: a failing file still fails the verdict" {
  stub_bats
  tagfile ok.bats "$(tagline "$T")"
  tagfile fail.bats "$(tagline "$T")"
  PATH="$STUB_BIN:$PATH" run "$H" run --jobs 2 "$O" "$D/ok.bats" "$D/fail.bats"
  [ "$status" -eq 1 ]
  [[ "$(fileline "$D/ok.bats")" == *" OK" ]]
  [[ "$(fileline "$D/fail.bats")" == *" FAIL ("*"failed=1"* ]]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: 2 file(s), 1 failed" ]
}

# -------------------------------------------------------------------- shard
# #1197: `shard <index> <count> <timings> <file>...` splits select's list across the
# shard jobs. Every partition check is an EQUALITY of sorted lists plus a count.

# mktimes <name=secs>...: $TIMES, one "<name>.bats <secs>" row per argument.
mktimes() {
  TIMES="$BATS_TEST_TMPDIR/times.txt"
  local r
  : > "$TIMES"
  for r in "$@"; do printf '%s.bats %s\n' "${r%%=*}" "${r#*=}" >> "$TIMES"; done
}
# mkfiles <name>...: tagged fixtures $D/<name>.bats; FILES holds their paths.
mkfiles() {
  local n
  FILES=()
  for n in "$@"; do tagfile "$n.bats" "$(tagline "$T")"; FILES+=("$D/$n.bats"); done
}
# shard_union <count> <timings> <file>...: every shard's stdout, sorted; fails on a
# shard whose rc is not 0 or whose stdout is empty. The loop is never on the left of
# a pipe: bats sets no pipefail, so a failing shard there would be lost.
shard_union() {
  local k="$1" t="$2" i out rc all=""
  shift 2
  for i in $(seq 1 "$k"); do
    out="$("$H" shard "$i" "$k" "$t" "$@" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "shard $i of $k: rc $rc" >&2; return 1; }
    [ -n "$out" ] || { echo "shard $i of $k: empty" >&2; return 1; }
    all+="$out"$'\n'
  done
  printf '%s' "$all" | LC_ALL=C sort
}
# count_lines <fixed string> <text>: how many lines of <text> equal <fixed string>.
count_lines() { printf '%s\n' "$2" | grep -cxF -- "$1"; }

@test "shard: every file lands in exactly one shard, K = 1 to 4" {
  local k got want
  mktimes a=50 b=40 c=30 d=20 e=10
  mkfiles a b c d e f g
  want="$(printf '%s\n' "${FILES[@]}" | LC_ALL=C sort)"
  for k in 1 2 3 4; do
    got="$(shard_union "$k" "$TIMES" "${FILES[@]}")" || { echo "K=$k: a shard failed"; return 1; }
    [ "$got" = "$want" ] || { echo "K=$k: got [$got]"; return 1; }
    [ "$(printf '%s\n' "$got" | wc -l)" -eq 7 ] || { echo "K=$k: count"; return 1; }
  done
}

@test "shard: largest first onto the least-loaded shard, ties to the lower shard" {
  mktimes a=50 b=40 c=30 d=20 e=10
  mkfiles a b c d e
  run --separate-stderr "$H" shard 1 2 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$D/a.bats" "$D/d.bats" "$D/e.bats")" ]
  run --separate-stderr "$H" shard 2 2 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$D/b.bats" "$D/c.bats")" ]
}

@test "shard: equal weights keep list order" {
  mktimes c=7 a=7 b=7
  mkfiles c a b
  run --separate-stderr "$H" shard 1 1 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$D/c.bats" "$D/a.bats" "$D/b.bats")" ]
}

@test "shard: the split is stable" {
  local i a b r="$BATS_TEST_TMPDIR/rev.txt"
  mktimes a=50 b=40 c=30 d=20 e=10 f=40 g=5
  mkfiles a b c d e f g
  tac "$TIMES" > "$r"
  run cmp -s "$r" "$TIMES"
  [ "$status" -eq 1 ]
  for i in 1 2 3; do
    a="$("$H" shard "$i" 3 "$TIMES" "${FILES[@]}" 2>&1)"
    b="$("$H" shard "$i" 3 "$TIMES" "${FILES[@]}" 2>&1)"
    [ "$a" = "$b" ] || { echo "shard $i: two runs differ"; return 1; }
    b="$("$H" shard "$i" 3 "$r" "${FILES[@]}" 2>&1)"
    [ "$a" = "$b" ] || { echo "shard $i: reversed table differs"; return 1; }
  done
}

@test "shard: an untimed file lands in exactly one shard, weighted 60s, and is named on stderr" {
  local u="gitbash-tagged: untimed $D/u.bats (weighted 60s)"
  mktimes a=100 b=59
  mkfiles a b u
  run --separate-stderr "$H" shard 2 2 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$D/u.bats" "$D/b.bats")" ]
  [ "$(count_lines "$u" "$stderr")" -eq 1 ]
  # The shard that does not hold u.bats does not name it.
  run --separate-stderr "$H" shard 1 2 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$D/a.bats" ]
  [[ "$stderr" != *untimed* ]]

  mktimes a=100 b=61
  run --separate-stderr "$H" shard 2 2 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$D/b.bats" "$D/u.bats")" ]
  [ "$(count_lines "$u" "$stderr")" -eq 1 ]
}

@test "shard: prints its size and weight on stderr" {
  mktimes a=50 b=40 c=30 d=20 e=10
  mkfiles a b c d e
  run --separate-stderr "$H" shard 2 2 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "${stderr##*$'\n'}" = "gitbash-tagged: shard 2 of 2: 2 file(s), weight 70s" ]
  run --separate-stderr "$H" shard 1 2 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "${stderr##*$'\n'}" = "gitbash-tagged: shard 1 of 2: 3 file(s), weight 80s" ]
}

@test "shard: refuses bad arguments, rc 2" {
  local row i=0
  mktimes a=50 b=40
  mkfiles a b
  # chk <stderr substring> <args...>
  chk() {
    local want="$1"; shift
    run --separate-stderr "$H" shard "$@"
    [ "$status" -eq 2 ] || { echo "[$*]: rc $status"; return 1; }
    [[ "$stderr" == *"$want"* ]] || { echo "[$*]: stderr [$stderr]"; return 1; }
  }
  chk 'bad shard index: 0' 0 2 "$TIMES" "${FILES[@]}"
  chk 'shard index 3 > count 2' 3 2 "$TIMES" "${FILES[@]}"
  chk 'bad shard count: 0' 1 0 "$TIMES" "${FILES[@]}"
  chk 'bad shard index: x' x 2 "$TIMES" "${FILES[@]}"
  chk 'bad shard count: 1000' 1 1000 "$TIMES" "${FILES[@]}"
  chk "cannot read timings: $BATS_TEST_TMPDIR/none.txt" 1 2 "$BATS_TEST_TMPDIR/none.txt" "${FILES[@]}"
  for row in 'x.bats 1.5' 'x.bats' 'tests/x.bats 3' 'x.bats  3' 'x.bats 123456'; do
    i=$((i + 1))
    printf '# header\n\na.bats 50\n%s\n' "$row" > "$BATS_TEST_TMPDIR/bad$i.txt"
    chk "bad timings line 4: $row" 1 2 "$BATS_TEST_TMPDIR/bad$i.txt" "${FILES[@]}"
  done
  printf 'a.bats 50\nb.bats 40\na.bats 9\n' > "$BATS_TEST_TMPDIR/dup.txt"
  chk 'duplicate timings row: a.bats' 1 2 "$BATS_TEST_TMPDIR/dup.txt" "${FILES[@]}"
  chk 'usage:' 1 2 "$TIMES"
  mkdir -p "$D/sub"
  tagfile sub/a.bats "$(tagline "$T")"
  chk "duplicate file basename: a.bats" 1 2 "$TIMES" "$D/a.bats" "$D/sub/a.bats"
}

@test "shard: an empty shard is rc 3" {
  mktimes a=50 b=40
  mkfiles a b
  run --separate-stderr "$H" shard 3 3 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"shard 3 of 3 is empty (2 file(s) for 3 shards)"* ]]
  run --separate-stderr "$H" shard 1 3 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$D/a.bats" ]
  run --separate-stderr "$H" shard 2 3 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$D/b.bats" ]
}

@test "shard: a leading-zero weight is decimal, never octal" {
  mktimes a=010 b=9
  mkfiles a b
  run --separate-stderr "$H" shard 1 1 "$TIMES" "${FILES[@]}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$D/a.bats" "$D/b.bats")" ]
  [ "${stderr##*$'\n'}" = "gitbash-tagged: shard 1 of 1: 2 file(s), weight 19s" ]
}

@test "shard: a CRLF table splits the same as LF" {
  local i lf crlf
  mktimes a=50 b=40 c=30 d=20 e=10
  mkfiles a b c d e
  printf '%s\r\n' '# weights' 'a.bats 50' 'b.bats 40' 'c.bats 30' 'd.bats 20' 'e.bats 10' \
    > "$BATS_TEST_TMPDIR/crlf.txt"
  [ "$(od -An -c "$BATS_TEST_TMPDIR/crlf.txt" | grep -o '\\r' | wc -l)" -eq 6 ]
  for i in 1 2; do
    lf="$("$H" shard "$i" 2 "$TIMES" "${FILES[@]}" 2>&1)" || return 1
    crlf="$("$H" shard "$i" 2 "$BATS_TEST_TMPDIR/crlf.txt" "${FILES[@]}" 2>&1)" || return 1
    [ "$lf" = "$crlf" ] || { echo "shard $i: [$lf] vs [$crlf]"; return 1; }
  done
}

@test "shard: the live list and checked-in table split into K non-empty shards covering select" {
  local k got want n
  run --separate-stderr "$H" select "$PLUGIN_ROOT/tests"
  [ "$status" -eq 0 ] || { echo "select rc $status: $stderr"; return 1; }
  mapfile -t FILES <<<"$output"
  n="${#FILES[@]}"
  [ "$n" -ge 4 ]
  want="$(printf '%s\n' "${FILES[@]}" | LC_ALL=C sort)"
  for k in 2 3 4; do
    got="$(shard_union "$k" "$PLUGIN_ROOT/scripts/ci/gitbash-times.txt" "${FILES[@]}")" \
      || { echo "K=$k: a shard failed"; return 1; }
    [ "$got" = "$want" ] || { echo "K=$k: partition differs"; return 1; }
    [ "$(printf '%s\n' "$got" | wc -l)" -eq "$n" ]
  done
}

# --------------------------------------------------------------------- gate
# #1197: `gate <count> <interval-secs> <run-secs> <start-secs>` is the body of the
# `Git Bash tagged files` job: it polls the run's own jobs and passes only when every
# shard job completed with success. gh is a PATH binstub; the gate reads the real
# clock (jq `now`), so ages are written as real UTC timestamps.

# stub_gh: a binstub gh PREPENDED to PATH. On call n it prints $STUB_DIR/resp.<n>
# (repeating the last response it has), logs its argv to $STUB_DIR/argv.log, and
# exits $STUB_DIR/rc.<n> (0 if absent).
stub_gh() {
  STUB_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$STUB_DIR/bin"
  export STUB_DIR
  cat > "$STUB_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
d="$STUB_DIR"
n=1
[ -f "$d/calls" ] && n=$(( $(cat "$d/calls") + 1 ))
printf '%s\n' "$n" > "$d/calls"
printf '%s\n' "$*" >> "$d/argv.log"
r="$n"
while [ "$r" -gt 1 ] && [ ! -f "$d/resp.$r" ]; do r=$((r - 1)); done
[ -f "$d/resp.$r" ] && cat "$d/resp.$r"
rc=0
[ -f "$d/rc.$n" ] && rc="$(cat "$d/rc.$n")"
exit "$rc"
STUB
  chmod +x "$STUB_DIR/bin/gh"
  PATH="$STUB_DIR/bin:$PATH"
}
calls() { cat "$STUB_DIR/calls" 2>/dev/null || echo 0; }

# ts <age>: the UTC timestamp <age> seconds before now.
ts() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
# jobs_json "<name>|<status>|<conclusion>|<age>"...: the jobs API's response shape.
# An empty conclusion is null; an age of '-' or none is a null started_at. Job k's
# html_url is https://github.com/o/r/actions/runs/123/job/<k>.
jobs_json() {
  local j k=0 name status concl age sep='' out='{"total_count":'"$#"',"jobs":['
  for j in "$@"; do
    k=$((k + 1))
    IFS='|' read -r name status concl age <<<"$j"
    [ -n "$concl" ] && concl="\"$concl\"" || concl=null
    if [ -n "$age" ] && [ "$age" != - ]; then age="\"$(ts "$age")\""; else age=null; fi
    out+="$sep{\"name\":\"$name\",\"status\":\"$status\",\"conclusion\":$concl,\"started_at\":$age,\"html_url\":\"https://github.com/o/r/actions/runs/123/job/$k\"}"
    sep=,
  done
  printf '%s]}\n' "$out"
}
# resp <n> <job>...: response n of the stub.
resp() { local n="$1"; shift; jobs_json "$@" > "$STUB_DIR/resp.$n"; }
# gate [args...]: run the gate in a run; default arguments 3 0 3600 3600.
gate() {
  [ $# -gt 0 ] || set -- 3 0 3600 3600
  GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=123 run --separate-stderr "$H" gate "$@"
}
S1='Git Bash shard 1 of 3'
S2='Git Bash shard 2 of 3'
S3='Git Bash shard 3 of 3'
NAMED='Git Bash tagged files'
REMEDY='re-run failed jobs (not a single shard) to refresh Git Bash tagged files'

@test "gate: passes when every shard of K completed with success" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300" "$NAMED|in_progress||300"
  gate
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: gate: 3 of 3 shards succeeded" ]
  [ "$(cat "$STUB_DIR/argv.log")" = 'api repos/o/r/actions/runs/123/jobs?filter=latest&per_page=100' ]
}

@test "gate: waits while a shard is queued or in progress, then passes" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|queued||" "$S3|queued||"
  resp 2 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|in_progress||10"
  resp 3 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300"
  gate
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 3 ]
  [ "$(printf '%s\n' "${lines[@]}" | grep -oE '^gitbash-tagged: gate: [0-9]+ of 3 shards done ' | cut -d' ' -f3)" = "$(printf '1\n2\n3')" ]
  [[ "$output" == *"gate: 1 of 3 shards done ($S1=success, $S2=queued, $S3=queued)"* ]]
}

@test "gate: fails on every non-success conclusion, as soon as that shard completes" {
  local c
  for c in failure cancelled skipped timed_out neutral action_required stale ''; do
    rm -rf "$BATS_TEST_TMPDIR/gh"
    stub_gh
    resp 1 "$S1|in_progress||10" "$S2|completed|$c|100" "$S3|in_progress||10"
    gate
    local shown="${c:-no conclusion}"
    [ "$status" -eq 1 ] || { echo "[$c]: rc $status"; return 1; }
    [ "$(calls)" -eq 1 ] || { echo "[$c]: $(calls) calls"; return 1; }
    [[ "$output" == *"::error::$S2: $shown"* ]] || { echo "[$c]: $output"; return 1; }
    [[ "$output" == *"gitbash-tagged: gate: FAIL ($S2: $shown)"* ]] || { echo "[$c]: $output"; return 1; }
    [[ "$output" == *"https://github.com/o/r/actions/runs/123/job/2"* ]] || { echo "[$c]: no html_url"; return 1; }
    [[ "$output" == *"$REMEDY"* ]] || { echo "[$c]: no remedy"; return 1; }
  done
}

@test "gate: fails on a shard job outside 1..K or of another total, or duplicated" {
  stub_gh
  resp 1 "$S1|in_progress||10" "Git Bash shard 4 of 4|in_progress||10" "$S3|in_progress||10"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (unexpected shard job: Git Bash shard 4 of 4)"* ]]
  rm -rf "$BATS_TEST_TMPDIR/gh"; stub_gh
  resp 1 "$S1|in_progress||10" "Git Bash shard 4 of 3|in_progress||10"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (unexpected shard job: Git Bash shard 4 of 3)"* ]]
  rm -rf "$BATS_TEST_TMPDIR/gh"; stub_gh
  resp 1 "$S1|completed|success|10" "$S2|completed|success|10" "$S3|completed|success|10" "$S3|completed|success|10"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (duplicate shard job: $S3)"* ]]
}

@test "gate: other jobs never count" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300" \
    "Git Bash shard x|in_progress||10" "$NAMED|in_progress||10" "$NAMED (other)|completed|failure|10"
  gate
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: gate: 3 of 3 shards succeeded" ]
}

@test "gate: a shard in progress past <run-secs> fails, naming it and its age" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|in_progress||100"
  gate 3 0 60 3600
  [ "$status" -eq 1 ]
  [ "$(calls)" -eq 1 ]
  [[ "$output" =~ FAIL\ \(Git\ Bash\ shard\ 3\ of\ 3\ in\ progress\ 1[0-9]{2}s\ since\ started_at,\ past\ 60s\) ]]
  [[ "$output" == *"https://github.com/o/r/actions/runs/123/job/3"* ]]
}

@test "gate: a shard in progress within <run-secs> keeps it waiting" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|in_progress||10"
  resp 2 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300"
  gate 3 0 60 3600
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
}

@test "gate: a missing shard fails after <start-secs> of the gate's own wait" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300"
  gate 3 1 3600 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (not started after 2s: $S3 (missing))"* ]]
  [ "$(calls)" -ge 2 ]
}

@test "gate: a queued shard fails after <start-secs>, naming its status" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|queued||"
  gate 3 1 3600 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (not started after 2s: $S3 (queued))"* ]]
}

@test "gate: an in-progress shard with no started_at is judged by <start-secs> only" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|in_progress||-"
  gate 3 1 60 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (not started after 2s: $S3 (in_progress, no started_at))"* ]]
}

@test "gate: queue time never counts toward <run-secs>" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|queued||5000"
  resp 2 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|in_progress||5"
  resp 3 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300"
  gate 3 0 60 3600
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 3 ]
}

@test "gate: a shard that starts inside <start-secs> is no longer judged by it" {
  # Start bound 4s: the first (queued) poll may take up to ~3s on a loaded runner
  # ($SECONDS ticks whole seconds) and still be inside it; the shard then stays
  # in_progress for polls 2-6 (t of about 5s, past the bound) before it succeeds.
  local n
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|queued||"
  resp 2 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|in_progress||1"
  for n in 3 4 5 6; do cp "$STUB_DIR/resp.2" "$STUB_DIR/resp.$n"; done
  resp 7 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300"
  gate 3 1 3600 4
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 7 ]
}

@test "gate: a future started_at (clock skew) is age 0, never negative" {
  stub_gh
  resp 1 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|in_progress||-30"
  resp 2 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300"
  gate 3 0 60 3600
  [ "$status" -eq 0 ]
  [[ "$output" == *"$S3=in_progress 0s)"* ]]
}

@test "gate: a failed or non-JSON read is retried, and fails after 5 in a row" {
  stub_gh
  echo 1 > "$STUB_DIR/rc.1"
  resp 2 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300"
  gate
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]

  rm -rf "$BATS_TEST_TMPDIR/gh"; stub_gh
  echo '<html>' > "$STUB_DIR/resp.1"
  gate
  [ "$status" -eq 1 ]
  [ "$(calls)" -eq 5 ]
  [[ "$output" == *"FAIL (could not read the run's jobs 5 times in a row: "* ]]

  # Four failures then a good read reset the count: a fifth failure later is not fatal.
  rm -rf "$BATS_TEST_TMPDIR/gh"; stub_gh
  local n
  for n in 1 2 3 4; do echo '<html>' > "$STUB_DIR/resp.$n"; done
  resp 5 "$S1|completed|success|300" "$S2|in_progress||10" "$S3|completed|success|300"
  echo '{"message":"no jobs here"}' > "$STUB_DIR/resp.6"
  resp 7 "$S1|completed|success|300" "$S2|completed|success|300" "$S3|completed|success|300"
  gate
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 7 ]
}

@test "gate: refuses bad arguments and a missing run, rc 2" {
  local a
  stub_gh
  run --separate-stderr env -u GITHUB_RUN_ID GITHUB_REPOSITORY=o/r "$H" gate 3 0 3600 3600
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"GITHUB_RUN_ID"* ]]
  run --separate-stderr env -u GITHUB_REPOSITORY GITHUB_RUN_ID=123 "$H" gate 3 0 3600 3600
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"GITHUB_REPOSITORY"* ]]
  for a in '0 0 3600 3600' '1000 0 3600 3600' 'x 0 3600 3600' '3 x 3600 3600' \
           '3 10000 3600 3600' '3 0 0 3600' '3 0 x 3600' '3 0 3600 0' '3 0 3600 x' \
           '3 0 123456 3600' '3 0 3600' '3 0 3600 3600 9'; do
    # shellcheck disable=SC2086
    gate $a
    [ "$status" -eq 2 ] || { echo "[$a]: rc $status"; return 1; }
  done
  [ "$(calls)" -eq 0 ]
}

# The spike's real jobs-API responses (Issue-1197 spike: run 45765050697,
# attempts 1-3, and queue run 45765050676), with only the job names rewritten to this workflow's names.
@test "gate: real API responses: attempt 1 failed, attempt 2 copied the success" {
  local F="$PLUGIN_ROOT/tests/fixtures/gitbash-gate"
  stub_gh
  cp "$F/attempt1-failed.json" "$STUB_DIR/resp.1"
  gate 2 0 3600 3600
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (Git Bash shard 2 of 2: failure)"* ]]

  rm -rf "$BATS_TEST_TMPDIR/gh"; stub_gh
  cp "$F/attempt2-copied.json" "$STUB_DIR/resp.1"
  gate 2 0 3600 3600
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: gate: 2 of 2 shards succeeded" ]
}

@test "gate: real API responses: in progress, single-job re-run, queued" {
  local F="$PLUGIN_ROOT/tests/fixtures/gitbash-gate"
  # Both legs in progress since the spike: past any small run bound.
  stub_gh
  cp "$F/in-progress.json" "$STUB_DIR/resp.1"
  gate 2 0 60 3600
  [ "$status" -eq 1 ]
  [[ "$output" =~ FAIL\ \(Git\ Bash\ shard\ 1\ of\ 2\ in\ progress\ [0-9]+s\ since\ started_at,\ past\ 60s\) ]]
  # A single-shard re-run: the named job's stale success never counts.
  rm -rf "$BATS_TEST_TMPDIR/gh"; stub_gh
  cp "$F/attempt3-single-rerun.json" "$STUB_DIR/resp.1"
  gate 2 0 60 3600
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: 1 of 2 shards done"* ]]
  [[ "$output" =~ FAIL\ \(Git\ Bash\ shard\ 2\ of\ 2\ in\ progress ]]
  # A queued job's started_at is set (= created_at) yet never read.
  rm -rf "$BATS_TEST_TMPDIR/gh"; stub_gh
  cp "$F/queued.json" "$STUB_DIR/resp.1"
  gate 1 1 60 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL (not started after 1s: Git Bash shard 1 of 1 (queued))"* ]]
}
