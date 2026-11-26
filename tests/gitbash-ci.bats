#!/usr/bin/env bats
# tests/gitbash-ci.bats — #1096: scripts/ci/gitbash-tagged.sh, the helper behind the
# `Git Bash tagged files` job in .github/workflows/gitbash.yml. Selection, the
# malformed-tag detector, the per-file run loop and the TAP rules are each driven
# against planted fixtures here, so every fail-closed rule has a control that runs on
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
# shard whose rc is not 0.
shard_union() {
  local k="$1" t="$2" i out
  shift 2
  for i in $(seq 1 "$k"); do
    out="$("$H" shard "$i" "$k" "$t" "$@" 2>/dev/null)" || { echo "shard $i of $k: rc $?" >&2; return 1; }
    printf '%s\n' "$out"
  done | LC_ALL=C sort
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
