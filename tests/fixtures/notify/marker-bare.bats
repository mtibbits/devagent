#!/usr/bin/env bats
# #961 FIXTURE — not part of the suite: `bats <dir>` does not recurse, so no
# suite run selects this file. tests/lib_notify.bats runs it in a fresh bats
# started with DEVAGENT_UNATTENDED set. It is a committed file, not one a test
# writes, because bats 1.10 rewrites every `@test` line in the file that holds
# it, a heredoc's included, so a generated inner file gathered no tests.
. "$BATS_TEST_DIRNAME/../../lib/hermetic-env.bash"
. "$BATS_TEST_DIRNAME/../../../scripts/lib/paths.sh"

@test "inner: the marker is unset" {
  run devagent_unattended
  [ "$status" -eq 1 ]
}
