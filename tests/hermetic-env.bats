#!/usr/bin/env bats
# #322: the hermetic-env guard must be sourced by every setup layer and must
# neutralize the #240 pins + hostile git config, so one developer-shell export
# (DEVAGENT_ACTIVE_PROJECT/ISSUE) or a hostile global gitconfig can't fail the
# suite. Regression guard for the 44+-test exposure (measured 68 here).

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "every setup layer sources the hermetic-env guard (#322)" {
  local layer
  for layer in helpers/common.bash lib/bats-helpers.bash helpers.bash \
               helpers/auth_setup.bash helpers/fixtures.bash wbs.bats; do
    grep -q 'hermetic-env' "$REPO/tests/$layer" \
      || { echo "$layer does not source lib/hermetic-env.bash" >&2; false; }
  done
}

@test "hermetic-env neutralizes the #240 pins and hostile git config (#322)" {
  export DEVAGENT_ACTIVE_PROJECT=volk DEVAGENT_ACTIVE_ISSUE=Issue-99
  . "$REPO/tests/lib/hermetic-env.bash"
  [ -z "${DEVAGENT_ACTIVE_PROJECT:-}" ]
  [ -z "${DEVAGENT_ACTIVE_ISSUE:-}" ]
  [ "$GIT_CONFIG_GLOBAL" = /dev/null ]
  [ "$GIT_CONFIG_SYSTEM" = /dev/null ]
}
