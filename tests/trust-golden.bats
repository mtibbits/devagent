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
# #714 adds park, unstuck, checklist-mark, revise, cleanup and analyze, each
# captured at 5c08ea5 (before any #714 code) on its success path, so each run
# crosses the line where quarantine_guard sits. Capture just those with
# `TRUST_GOLDEN_CAPTURE_SHA=5c08ea5 bats -f '5c08ea5' tests/trust-golden.bats`.
#
# 2026-11-14 (#1099): pull.out gained `pulled <id>` — pull now prints the
# resolved id on stdout on every success. The pull fixtures were re-captured
# with the capture script at the branch commit; only pull.out's body and the
# four captured-at lines moved (the other scenarios' fixtures were kept). The
# pull @test name carries no SHA: under a squash merge the branch SHA is
# unreachable from master.
#
# #715 adds pull-steering and pull-flagsdiag, captured at 1b24202 (before any
# #715 code): two no-policy pulls whose tickets cross every print site #715
# refactors (S1-S3, S6-S9 of its plan's table C), each asserting a floor of
# `warn:` lines so a scenario that stops crossing them reddens. The three pull
# scenarios also carry the opt-in `.tree` kind (no new files; see
# _golden_check); pull.tree alone was captured into the existing scenario with
# `TRUST_GOLDEN_CAPTURE_SHA=1b24202 TRUST_GOLDEN_CAPTURE_KINDS=tree bats -f
# 'trust-golden: pull no-policy' tests/trust-golden.bats`, so pull's other
# fixtures keep their captured-at line.
#
# Retirement: the four #713 fixtures stay until #902 merges (#902's AC reuses them).
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

@test "trust-golden: pull no-policy output is byte-identical to its golden (#713, re-captured #1099)" {
  _scenario_pull
  _golden_check pull "$GOLDEN_ARGV"
}

@test "trust-golden: pull-steering no-policy output is byte-identical to the 1b24202 golden" {
  _scenario_pull_steering
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check pull-steering "$GOLDEN_ARGV"
  # The scenario must keep crossing the print sites: S3, S6 (two), S7, S8 (two), S9.
  [ "$(grep -c 'warn:' "$GOLDEN_DIR/pull-steering.err")" -ge 6 ]
}

@test "trust-golden: pull-flagsdiag no-policy output is byte-identical to the 1b24202 golden" {
  _scenario_pull_flagsdiag
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check pull-flagsdiag "$GOLDEN_ARGV"
  # S1, S2 and the fence-close warning.
  [ "$(grep -c 'flags.sh: warn:' "$GOLDEN_DIR/pull-flagsdiag.err")" -ge 3 ]
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

@test "trust-golden: park no-policy output is byte-identical to the 5c08ea5 golden" {
  _scenario_park
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check park "$GOLDEN_ARGV"
}

@test "trust-golden: unstuck no-policy output is byte-identical to the 5c08ea5 golden" {
  _scenario_unstuck
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check unstuck "$GOLDEN_ARGV"
}

@test "trust-golden: checklist-mark no-policy output is byte-identical to the 5c08ea5 golden" {
  _scenario_checklist_mark
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check checklist-mark "$GOLDEN_ARGV"
}

@test "trust-golden: revise no-policy output is byte-identical to the 5c08ea5 golden" {
  _scenario_revise
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check revise "$GOLDEN_ARGV"
}

@test "trust-golden: cleanup no-policy output is byte-identical to the 5c08ea5 golden" {
  _scenario_cleanup
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check cleanup "$GOLDEN_ARGV"
}

@test "trust-golden: analyze no-policy output is byte-identical to the 5c08ea5 golden" {
  _scenario_analyze
  [ "$status" -eq 0 ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  _golden_check analyze "$GOLDEN_ARGV"
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
