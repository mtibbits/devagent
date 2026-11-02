#!/usr/bin/env bats
# #713 AC1 (no-policy goldens): with no trust policy on the host, four reference
# entry points print byte-identical stdout/stderr, exit the same, and make the
# same backend calls as at the captured commit. Each scenario copies its source
# test's setup verbatim:
#   pull   — pull.bats "pull origin scaffolds Issue-N dir and writes issue.md"
#   ship   — ship.bats "ship.sh pushes branch, creates MR, fires on_ship transition, stores mr_url"
#   next   — next.bats "next on a skill-backed step prints the slash command to invoke"
#   doctor — doctor.bats "doctor passes on a well-formed setup" (lib/doctor-harness)
#
# Fixtures: tests/fixtures/trust-golden/<name>.{out,err,rc,argv}. Line 1 of each
# is `captured-at <sha>`; comparison starts at line 2. Output is normalised
# (_golden_norm): ISO timestamps → <TS>, the test's tmp roots → <TMP>.
#
# Re-capture: `bash tests/tools/trust-golden-capture.sh` (in the WSL clone).
# SHA rule: it refuses unless scripts/ is clean against HEAD, and stamps HEAD.
# Re-capture only when a change is MEANT to alter no-policy output, and say so
# in the commit; the first capture is 891254c (#713, before any trust code).
#
# Retirement: the four fixtures stay until #902 merges (#902's AC reuses them).
# After that, only "no-policy runs make no whoami/events call" is the standing
# guard and the fixture comparisons may be deleted.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/doctor-harness'
load 'helpers/common'
load 'lib/trust-golden'

teardown() {
  teardown_tmp_devagent_home
  devagent_test_teardown
}

@test "trust-golden: pull no-policy output is byte-identical to the 891254c golden" {
  _scenario_pull
  _golden_check pull "$GOLDEN_ARGV"
}

@test "trust-golden: ship no-policy output is byte-identical to the 891254c golden" {
  _scenario_ship
  _golden_check ship "$GOLDEN_ARGV"
}

@test "trust-golden: next no-policy output is byte-identical to the 891254c golden" {
  _scenario_next
  _golden_check next "$GOLDEN_ARGV"
}

@test "trust-golden: doctor no-policy output is byte-identical to the 891254c golden" {
  _scenario_doctor
  _golden_check doctor "$GOLDEN_ARGV"
}

@test "trust-golden: no-policy runs make no whoami/events call" {
  local s all
  for s in pull ship next doctor; do
    # a subshell per scenario: each exports its own HOME/PATH/backend dir.
    ( "_scenario_$s"
      [ "$status" -eq 0 ] || { echo "$s exited $status" >&2; exit 1; }
      if [ -f "$GOLDEN_ARGV" ]; then cat "$GOLDEN_ARGV"; fi > "$BATS_TEST_TMPDIR/argv-$s.log"
      teardown )
  done
  all="$(cat "$BATS_TEST_TMPDIR"/argv-*.log)"
  # positive control: the pull and ship logs recorded their backend calls.
  [[ "$all" == *"[issue] [view]"* ]]
  [[ "$all" == *"gh pr create"* ]]
  run grep -E '\[api\].*\[user\]|/events\]| api .*user|/events' <<<"$all"
  [ "$status" -eq 1 ]
}
