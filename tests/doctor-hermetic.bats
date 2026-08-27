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
    # Deliberately NO self-exclusion by filename. Keying on the invocation SHAPE is
    # what keeps this file out of its own result set, and the assertion below pins
    # that. An `[ "$f" = "$BATS_TEST_FILENAME" ] && continue` line would make the
    # assertion unfalsifiable — it would pass even if the selector regressed to a
    # bare name grep, which is the regression it exists to catch.
    #
    # Strip comment lines FIRST, then look for the script path used as a COMMAND.
    # `run "$X/doctor.sh"`, `run bash "$X/doctor.sh"`, `out=$("$X/doctor.sh" …)` and
    # `if "$X/doctor.sh" …; then` are all invocations; a bare mention in prose is not.
    # Keying on run/bash/exec alone missed the last two shapes, so a future file in
    # either would have taken a live `claude plugin list` dependency invisibly.
    grep -vE '^[[:space:]]*#' "$REPO/$f" \
      | grep -qE '(\b(run|bash|exec)\b[^|]*|\$\(|`|^[[:space:]]*(if|while|until)\b[^|]*|^[[:space:]]*)"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[^"]*/doctor\.sh' \
      && printf '%s\n' "$f"
  done < <(git -C "$REPO" ls-files -z -- ':(glob)tests/*.bats')
  return 0
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
  # And it must NOT select this file, whose text names doctor.sh repeatedly without
  # ever running it. Asserted IN-PROCESS: `run bash -c '_doctor_invokers | …'` cannot
  # see this file's functions, so it would pass on an empty pipeline regardless.
  grep -qx "tests/${BATS_TEST_FILENAME##*/}" "$BATS_TEST_TMPDIR/invokers.txt" && {
    echo 'selector self-matched — it is keying on the name, not the invocation shape' >&2
    false
  }
  true
}
