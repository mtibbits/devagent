#!/usr/bin/env bats
# #541: doctor's recommended-plugin check — WARN when superpowers is absent
# or disabled, silent when enabled, silent (no false WARN) when the CLI
# errors or is missing. Never flips doctor's exit code (recommend, not
# require — Issue-242: no new die in a chain).

load 'lib/bats-helpers'
load 'lib/doctor-harness'

setup() {
  setup_tmp_devagent_home
  seed_doctor_project
  # No default stub here: each @test names the state it is exercising.
}
teardown() { teardown_tmp_devagent_home; }

# Strip every PATH dir that carries a `claude` executable (the CI case:
# no claude CLI at all).
remove_claude_from_path() {
  local newpath="" d
  local IFS=:
  for d in $PATH; do
    [ -x "$d/claude" ] && continue
    newpath="${newpath:+$newpath:}$d"
  done
  export PATH="$newpath"
}

@test "doctor WARNs when superpowers is not installed (recommend, never die)" {
  stub_claude_cli absent      # list carries OTHER plugins but no superpowers (poison control)
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]          # WARN must not flip doctor's exit
  [[ "$output" == *"recommended: claude plugin install superpowers@claude-plugins-official"* ]]
}

@test "doctor WARNs when superpowers is installed but DISABLED" {
  stub_claude_cli disabled    # superpowers block present, Status: disabled (Cell C's state)
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  # redmr finding: the disabled state's copy-pasteable fix is ENABLE (with the
  # stanza's own marketplace-qualified name), not a second install
  [[ "$output" == *"recommended: claude plugin enable superpowers@claude-plugins-official"* ]]
}

@test "doctor stays silent about superpowers when installed+enabled" {
  stub_claude_cli enabled
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
}

@test "doctor stays silent (no false WARN) when the claude CLI itself errors" {
  stub_claude_cli failing     # stub exits 1 with no output — the Issue-314/243 case
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
}

@test "doctor skips the check silently when no claude CLI on PATH (CI)" {
  remove_claude_from_path
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
}

@test "the stub SHADOWS the real claude CLI — doctor reports the stub's state, not the machine's (#585)" {
  # The enrollment canary in doctor-hermetic.bats is a source grep, and a source grep
  # passes on disabled code (#565). This is its runtime twin: the `absent` stub's
  # answer DIFFERS from a developer machine where superpowers is genuinely installed
  # and enabled, so a shim that failed to shadow shows up as a silent doctor here
  # rather than as a passing test.
  stub_claude_cli absent
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" == *"recommended: claude plugin install superpowers@claude-plugins-official"* ]]

  # And the converse, so this is not a one-way pin: same harness, same test process,
  # flipped to `enabled`, must go silent.
  stub_claude_cli enabled
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
  [[ "$output" != *"recommended: claude plugin enable"* ]]
}
