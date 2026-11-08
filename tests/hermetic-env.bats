#!/usr/bin/env bats
# #322: the hermetic-env guard must be sourced by every setup layer and must
# neutralize the #240 pins + hostile git config, so one developer-shell export
# (DEVAGENT_ACTIVE_PROJECT/ISSUE) or a hostile global gitconfig can't fail the
# suite. Regression guard for the 44+-test exposure (measured 68 here).

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
# #585: bare-setup file, so the guard is sourced at FILE scope like every other one.
# This file also sources it INSIDE test 2 on purpose — that is the assertion under
# test, not the file's own hermeticity. Until the enrollment grep was anchored to
# column 0, that in-test line was what made this file look guarded.
. "$REPO/tests/lib/hermetic-env.bash"

@test "every setup layer sources the hermetic-env guard (#322)" {
  local layer
  for layer in helpers/common.bash lib/bats-helpers.bash helpers.bash \
               helpers/auth_setup.bash helpers/fixtures.bash wbs.bats; do
    grep -q 'hermetic-env' "$REPO/tests/$layer" \
      || { echo "$layer does not source lib/hermetic-env.bash" >&2; false; }
  done
}

@test "hermetic-env neutralizes the #240 pins and hostile git config (#322)" {
  unset _DEVAGENT_HERMETIC_HOMES   # this test is the FIRST source of the guard in a fresh shell
  export DEVAGENT_ACTIVE_PROJECT=volk DEVAGENT_ACTIVE_ISSUE=Issue-99 DEVAGENT_SUITE_JOBS=9 DEVAGENT_FETCH_TIMEOUT=9 DEVAGENT_BC_MAX_PAGES=2 BC_MAX_PAGES=2 CLAUDE_CONFIG_DIR=/x/claude DA_HOME=/x/da
  . "$REPO/tests/lib/hermetic-env.bash"
  [ -z "${DEVAGENT_ACTIVE_PROJECT:-}" ]
  [ -z "${DEVAGENT_ACTIVE_ISSUE:-}" ]
  [ -z "${DEVAGENT_SUITE_JOBS:-}" ]                       # #593: the one-run jobs override
  [ -z "${DEVAGENT_FETCH_TIMEOUT:-}" ]   # #660: the one-run fetch bound
  [ -z "${DEVAGENT_BC_MAX_PAGES:-}" ]   # #774: the paging cap
  [ -z "${BC_MAX_PAGES:-}" ]
  [ -z "${CLAUDE_CONFIG_DIR:-}" ]   # #731: the operator's transcripts
  [ -z "${DA_HOME:-}" ]             # #731: the operator's archive config
  [ "$GIT_CONFIG_GLOBAL" = /dev/null ]
  [ "$GIT_CONFIG_SYSTEM" = /dev/null ]
}

@test "a re-source of hermetic-env keeps the DA_HOME and CLAUDE_CONFIG_DIR a setup exported (#731)" {
  # First source in a shell clears the operator's inherited values; a test body that
  # loads a harness (which re-sources this guard) after setup exported its own tmp
  # DA_HOME / CLAUDE_CONFIG_DIR must keep them, else the test writes to /config.toml.
  export DA_HOME="$BATS_TEST_TMPDIR/da" CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  . "$REPO/tests/lib/hermetic-env.bash"
  [ "$DA_HOME" = "$BATS_TEST_TMPDIR/da" ]
  [ "$CLAUDE_CONFIG_DIR" = "$BATS_TEST_TMPDIR/claude" ]
}
