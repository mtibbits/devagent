#!/usr/bin/env bats
# #961 FIXTURE — not part of the suite (see marker-bare.bats). A file that
# loads the shared fixtures, run by tests/lib_notify.bats in a fresh bats
# started with DEVAGENT_UNATTENDED set.
load '../../helpers/fixtures'

setup() {
  fixture_init toy Issue-1
  . "$BATS_TEST_DIRNAME/../../../scripts/lib/paths.sh"
}

@test "inner: the marker is unset after the fixtures" {
  run devagent_unattended
  [ "$status" -eq 1 ]
}

@test "inner: a marker exported after the fixtures survives" {
  export DEVAGENT_UNATTENDED=1
  run devagent_unattended
  [ "$status" -eq 0 ]
}
