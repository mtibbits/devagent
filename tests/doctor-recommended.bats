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

@test "curated_path_without_claude hides claude WITHOUT stripping its neighbours (#585)" {
  # Issue-541 review minor 9. The predecessor stripped every PATH DIRECTORY holding a
  # `claude`; on this author's machine that took pytest, py.test, uv, uvx and
  # git-filter-repo with it. Build a dir holding `claude` plus a bystander, put it on
  # PATH, and require that only `claude` disappears.
  local shared="$BATS_TEST_TMPDIR/shared"; mkdir -p "$shared"
  printf '#!/usr/bin/env bash\necho REAL_CLAUDE\n'  > "$shared/claude"
  printf '#!/usr/bin/env bash\necho BYSTANDER\n'    > "$shared/bystander-585"
  chmod +x "$shared/claude" "$shared/bystander-585"
  export PATH="$shared:$PATH"

  # Control: both resolvable BEFORE (#Fork-149 — without this the post-assertion is
  # satisfied just as well by a fixture that never worked).
  command -v claude >/dev/null
  command -v bystander-585 >/dev/null

  curated_path_without_claude

  run command -v claude
  [ "$status" -ne 0 ]                      # gone
  run command -v bystander-585
  [ "$status" -eq 0 ]                      # survived
  # And the ordinary toolchain doctor.sh needs is still reachable.
  command -v git >/dev/null
  command -v grep >/dev/null
}

@test "doctor skips the check silently when no claude CLI on PATH (CI)" {
  # Must work on BOTH kinds of machine: one where claude is installed (the helper
  # hides it) and a CI runner where it never was (the helper no-ops). A helper that
  # hard-failed on the second would make this test's verdict a function of the
  # machine — the very thing this issue removes.
  curated_path_without_claude
  run command -v claude
  [ "$status" -ne 0 ]                      # the postcondition, however it was reached
  run bash "$SCRIPTS/doctor.sh" volk
  [ "$status" -eq 0 ]
  [[ "$output" != *"recommended: claude plugin install"* ]]
}

@test "curated_path_without_claude is a safe no-op when claude was never there (#585)" {
  # The CI shape, forced, so it is pinned on a developer machine too.
  curated_path_without_claude            # first call hides the real one
  run curated_path_without_claude        # second call has nothing left to hide
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
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
