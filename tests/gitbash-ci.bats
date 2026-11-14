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

@test "run: invokes bats once per file in list order with the TAP formatter, and carries on past a failure" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  export STUB_LOG="$BATS_TEST_TMPDIR/bats-argv.log"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$STUB_LOG"' \
    'case "${!#}" in' \
    '  *a.bats) printf "1..1\nnot ok 1 planted\n"; exit 1 ;;' \
    '  *) printf "1..1\nok 1 fine\n" ;;' \
    'esac' > "$bin/bats"
  chmod +x "$bin/bats"
  tagfile a.bats "$(tagline "$T")"
  tagfile b.bats "$(tagline "$T")"
  PATH="$bin:$PATH" run "$H" run "$O" "$D/a.bats" "$D/b.bats"
  [ "$status" -eq 1 ]
  [ "$(cat "$STUB_LOG")" = "$(printf '%s\n' "--formatter tap $D/a.bats" "--formatter tap $D/b.bats")" ]
  [[ "$output" == *"not ok 1 planted"* ]]
  [[ "$output" == *"ok 1 fine"* ]]
  [[ "$output" =~ time:\ "$D/a.bats"\ [0-9]+s ]]
  [[ "$output" =~ time:\ "$D/b.bats"\ [0-9]+s ]]
  [[ "$output" =~ time:\ total\ [0-9]+s ]]
  [[ "$(fileline "$D/a.bats")" == *" FAIL ("* ]]
  [[ "$(fileline "$D/b.bats")" == *" OK" ]]
  [ "${lines[${#lines[@]}-1]}" = "gitbash-tagged: 2 file(s), 1 failed" ]
}
