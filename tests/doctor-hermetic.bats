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
    [ "${f##*/}" = "${BATS_TEST_FILENAME##*/}" ] && continue      # never self
    # Strip comment lines FIRST, then look for a runner ahead of the script path on
    # the same line. The measured call shapes are `run "$PLUGIN_ROOT/scripts/doctor.sh"`,
    # `run bash "$SCRIPTS/doctor.sh"` and `run "$DEVAGENT_ROOT/scripts/doctor.sh"`, so the
    # variable is NOT adjacent to the filename — an intervening path segment is the norm.
    grep -vE '^[[:space:]]*#' "$REPO/$f" \
      | grep -qE '\b(run|bash|exec)\b.*/doctor\.sh' \
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
  local n; n="$(_doctor_invokers | wc -l)"
  [ "$n" -eq 3 ]
  _doctor_invokers | grep -qx 'tests/doctor.bats'
  _doctor_invokers | grep -qx 'tests/doctor-recommended.bats'
  _doctor_invokers | grep -qx 'tests/revise.bats'
  # And it must NOT select this file, whose text names doctor.sh repeatedly without
  # ever running it. A regression to a naive name grep reddens here.
  run bash -c '_doctor_invokers | grep -qx "tests/${BATS_TEST_FILENAME##*/}"'
  [ "$status" -ne 0 ]
}
