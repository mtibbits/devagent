#!/usr/bin/env bats
# Issue-570: skills/capture/SKILL.md's env contract must not derive
# DEVAGENT_PROJECT from the mutable global pointer. AC1/AC2/AC4/AC5 canaries.
# The pointer FILENAME is spelled literally below only because the guard greps
# for it; that is the assertion, not prose (register: Issue-561).
#
# One claim per test (register: Issue-123): a multi-assertion guard reddens only
# at its FIRST failing assert, which would leave the later legs' born-red status
# unproven. Each pinned literal is the SHORTEST claim-bearing token that still
# discriminates (register: Issue-561 — pin the CLAIM, not one phrasing), so
# improving the doc's wording around them does not red the guard.

load 'helpers'

F="${BATS_TEST_DIRNAME}/../skills/capture/SKILL.md"

# Cleanup lives in bats' teardown(), NOT inline at the end of each test: an
# inline call never runs on failure, and during the born-red phase all three AC2
# legs fail by design — which would leak two mktemp trees per leg. Safe to scope
# to the whole file: teardown_tmp_devdoc is a no-op when TMP_DEVDOC/TMP_HOME are
# unset (tests/helpers.bash), which is the case for every doc canary below.
teardown() {
  teardown_tmp_devdoc
}

# --- AC1: the pointer derivation is gone -----------------------------------

@test "AC1 subject exists (anti-vacuous, glob-drop guard)" {
  [ -f "$F" ]
}

@test "AC1 the pointer file is named exactly once in the capture skill" {
  # Issue-337: a presence canary asserts an exact count, never -ne 0.
  run grep -c '_active\.toml' "$F"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "AC1 the single pointer mention sits inside the do-not-derive warning" {
  run grep -n '_active\.toml' "$F"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Do not derive"* ]]
}

@test "AC1 no sed derivation of the env vars survives in the capture skill" {
  # Issue-337 / Issue-Fork-132: assert the PRECISE no-match code (1). `-ne 0`
  # would also be satisfied by grep's error code (2), so a vanished subject or a
  # broken pattern would read as a pass.
  run grep -F 'sed -n' "$F"
  [ "$status" -eq 1 ]
}

# --- AC4: the doc distinguishes the two variables' roles, per script --------

@test "AC4 the table names DEVAGENT_DEVDOC_DIR as the write destination" {
  grep -qF 'governs WHERE' "$F"
}

@test "AC4 the table names reap.sh's ledger key" {
  grep -qF 'reaped.toml' "$F"
}

@test "AC4 the table marks DEVAGENT_PROJECT required for reap.sh" {
  grep -qF 'reap.sh`: **required**' "$F"
}

@test "AC4 the table keeps capture.sh's template-substitution use" {
  grep -qF '{{project}}' "$F"
}

@test "AC4 the table keeps capture.sh's paths-override use" {
  grep -qF '[project.<name>.paths]' "$F"
}

# --- AC5: no regex interpolation in the devdoc lookup ----------------------

@test "AC5 the devdoc lookup goes through the TOML reader" {
  grep -qF '_toml.py' "$F"
}

@test "AC5 no interpolated sed address-range survives" {
  # Issue-337 / Issue-Fork-132: precise no-match (1), never `-ne 0`.
  # shellcheck disable=SC2016  # the single quotes are the point: we grep for the
  # LITERAL ${DEVAGENT_PROJECT} text in the doc, so expanding it would defeat the test.
  run grep -F '/^\[project.${DEVAGENT_PROJECT}\]/' "$F"
  [ "$status" -eq 1 ]
}

# --- AC2: the documented recipe, EXECUTED ----------------------------------
# The block is read from the doc's bytes, never retyped: running a VARIANT of a
# published command is not running it (register: Issue-106/Issue-566).
#
# The per-test DEVAGENT_PROJECT export below is MEANT to be test-local — each
# @test is its own subshell, and that isolation is what lets the three legs
# assert different halves of the same recipe. Hence the SC2030/SC2031 waivers.

ac2_fixture() {
  setup_tmp_devdoc
  freeze_date 2026-05-19
  ALPHA_DEVDOC="${TMP_HOME}/devdoc/alpha"
  BETA_DEVDOC="${TMP_HOME}/devdoc/beta"
  mkdir -p "$ALPHA_DEVDOC/Captures" "$BETA_DEVDOC/Captures" \
           "$HOME/.claude/devagent/state"
  cat > "$HOME/.claude/devagent/config.toml" <<TOML
[project.alpha]
devdoc_dir = "${ALPHA_DEVDOC}"

[project.beta]
devdoc_dir = "${BETA_DEVDOC}"
TOML
  printf 'active_project = "beta"\n' \
    > "$HOME/.claude/devagent/state/_active.toml"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  BLOCK="$(awk '/^## Env contract/{s=1} s&&/^```bash$/{f=1;next} f&&/^```$/{exit} f' \
    "$REPO_ROOT/skills/capture/SKILL.md")"
  [ -n "$BLOCK" ]          # anti-vacuous: an empty extraction must red, not pass
}

@test "AC2 the documented block does not overwrite the operator's project" {
  ac2_fixture
  # shellcheck disable=SC2030,SC2031  # test-local by design (see block note above)
  export DEVAGENT_PROJECT=alpha
  eval "$BLOCK"
  [ "$DEVAGENT_PROJECT" = "alpha" ]
}

@test "AC2 the documented block resolves the named project's devdoc" {
  ac2_fixture
  # shellcheck disable=SC2030,SC2031  # test-local by design (see block note above)
  export DEVAGENT_PROJECT=alpha
  eval "$BLOCK"
  [ "$DEVAGENT_DEVDOC_DIR" = "$ALPHA_DEVDOC" ]
}

@test "AC2 capture.sh writes under the named project, not the pointer's" {
  ac2_fixture
  # shellcheck disable=SC2030,SC2031  # test-local by design (see block note above)
  export DEVAGENT_PROJECT=alpha
  eval "$BLOCK"
  run "$REPO_ROOT/scripts/capture/capture.sh" \
    --type issue --subtype bug --title "Scope probe"
  [ "$status" -eq 0 ]
  [ -f "$ALPHA_DEVDOC/Captures/2026-05-19-scope-probe/draft.md" ]
  [ ! -d "$BETA_DEVDOC/Captures/2026-05-19-scope-probe" ]
}
