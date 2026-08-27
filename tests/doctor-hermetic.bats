#!/usr/bin/env bats
# #585: doctor.sh shells out to `claude plugin list`. Every bats file that invokes
# it must therefore install the harness's PATH-shadowed stub, or the test takes a
# live dependency on the developer's real plugin state (measured: +0.28 s per
# invocation x19 invocations = ~5.0 s per suite run — analysis/2026-08-27-draft-probes.md
# P3; a HUNG CLI costs `timeout 5` x19 = 95 s).
REPO="${BATS_TEST_DIRNAME}/.."

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

# Files that INVOKE the doctor script — i.e. name it as a command to run, not merely
# mention it. A bare `grep -l` for the script name matches THIS file, whose header and
# test names both contain it, so the canary would demand that the policing file load
# the harness it exists to police and could never go green. Key on the invocation
# shape, and exclude self by name rather than by accident.
#
# Tracked set, NUL-delimited, with :(glob) magic so `*` cannot cross `/` (#566).
_doctor_invokers() {
  local f
  while IFS= read -r -d '' f; do
    [ "${f##*/}" = "${BATS_TEST_FILENAME##*/}" ] && continue      # never self (see below)
    # Match the PATH, on any non-comment line — deliberately the broadest possible
    # predicate, after two narrower ones each missed real invocation shapes:
    #   `\b(run|bash|exec)\b.*/doctor\.sh`  missed  out=$(…) and `if …; then`
    #   the regex that replaced it            missed  "$SCRIPTS"/doctor.sh
    #                                                 "${SCRIPTS}"/doctor.sh
    # The second was committed AS a widening and was in fact a narrowing, because
    # `[^"]*` cannot cross a closing quote. Both misses are the same failure: a file
    # takes a live `claude plugin list` dependency and the canary stays green.
    #
    # So: stop trying to describe an invocation. Any non-comment line naming the path
    # enrols the file. Over-matching costs one spurious `load` line in a file that
    # only mentions the script; under-matching costs a silent machine-dependent test,
    # which is the defect class this whole issue exists to close. The `_shape_probe`
    # test below pins the seven shapes, so the next person to "improve" this regex
    # finds out immediately.
    #
    # Self-exclusion IS required here, and that is a consequence of the broad
    # predicate: this file carries the path on non-comment lines, in the _SHAPES
    # fixtures below. An earlier narrow selector excluded this file by construction,
    # and the assertion that pinned that is gone — the shape probe replaces it and is
    # a stronger guard, because it fails on a narrowing rather than only on a
    # name-grep regression.
    grep -vE '^[[:space:]]*#' "$REPO/$f" \
      | grep -qE '/doctor\.sh' \
      && printf '%s\n' "$f"
  done < <(git -C "$REPO" ls-files -z -- ':(glob)tests/*.bats')
  return 0
}

# The shapes a contributor might plausibly write. Every one must enrol the file.
# Kept beside the selector so a future rewrite is measured against them, not eyeballed.
_SHAPES=(
  'run "$SCRIPTS/doctor.sh" volk'
  'run "$SCRIPTS"/doctor.sh volk'
  'run "${SCRIPTS}"/doctor.sh volk'
  'run bash -c "$SCRIPTS/doctor.sh volk"'
  'out=$("$SCRIPTS/doctor.sh" volk)'
  'if "$SCRIPTS/doctor.sh" volk; then :; fi'
  'cd "$REPO/scripts" && run ./doctor.sh volk'
)

@test "the invoker selector matches every plausible invocation shape (#585)" {
  # A selector that under-matches lets a file take a live `claude plugin list`
  # dependency invisibly. Two successive regexes each missed shapes in this list.
  local shape missed=() tmp="$BATS_TEST_TMPDIR/shape.txt"
  for shape in "${_SHAPES[@]}"; do
    # The fixture only has to carry the LINE — the selector greps lines, it does not
    # parse bats. Writing a real test file here would also put the literal test-case
    # token inside this file, which bats' own parser scans for.
    printf '%s\n' "$shape" > "$tmp"
    grep -vE '^[[:space:]]*#' "$tmp" | grep -qE '/doctor\.sh' || missed+=("$shape")
  done
  [ ${#missed[@]} -eq 0 ] || {
    echo 'selector MISSES these invocation shapes:' >&2
    printf '%s\n' "${missed[@]}" >&2
    false
  }
  # And it must still reject a file that merely NAMES the script in a comment.
  printf '%s\n' '# see scripts/doctor.sh for details' > "$tmp"
  run bash -c "grep -vE '^[[:space:]]*#' '$tmp' | grep -qE '/doctor\.sh'"
  [ "$status" -ne 0 ]
}

@test "every bats file invoking doctor.sh loads the doctor harness (#585)" {
  local missing=() f
  while read -r f; do
    grep -qE '^[[:space:]]*(load|\.|source)[[:space:]].*doctor-harness' "$REPO/$f" || missing+=("$f")
  done < <(_doctor_invokers)
  [ ${#missing[@]} -eq 0 ] || {
    echo 'doctor.sh invoked without the hermetic harness:' >&2
    printf '%s\n' "${missing[@]}" >&2
    false
  }
}

@test "the doctor.sh-invoker enumeration is not vacuously empty (#151)" {
  # If this selector ever stops matching, the canary above passes silently (#439).
  # #572: a negative assertion is vacuously satisfied by a missing function, so
  # prove the function exists before asserting anything about its output.
  run type -t _doctor_invokers
  [ "$output" = function ]

  _doctor_invokers > "$BATS_TEST_TMPDIR/invokers.txt"
  # `-ge 3` plus membership, not `-eq 3`: an exact pin would redden on a legitimate
  # FOURTH file that invokes doctor.sh AND loads the harness, which is the state this
  # canary is trying to produce.
  local n; n="$(wc -l < "$BATS_TEST_TMPDIR/invokers.txt")"
  [ "$n" -ge 3 ]
  grep -qx 'tests/doctor.bats'             "$BATS_TEST_TMPDIR/invokers.txt"
  grep -qx 'tests/doctor-recommended.bats' "$BATS_TEST_TMPDIR/invokers.txt"
  grep -qx 'tests/revise.bats'             "$BATS_TEST_TMPDIR/invokers.txt"
  # The selector excludes this file explicitly, so assert that held.
  grep -qx "tests/${BATS_TEST_FILENAME##*/}" "$BATS_TEST_TMPDIR/invokers.txt" && {
    echo 'self-exclusion failed' >&2
    false
  }
  true
}
