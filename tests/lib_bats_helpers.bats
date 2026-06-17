#!/usr/bin/env bats
# #106 (F10): teardown_tmp_devagent_home must clean a tmp home even when the system
# temp dir is not /tmp (macOS / sandboxed TMPDIR). Uses /var/tmp as a real non-/tmp
# base to prove the ${TMPDIR:-/tmp} clause.

load 'lib/bats-helpers'

@test "teardown_tmp_devagent_home removes a home under a non-/tmp TMPDIR (#106)" {
  local base; base="$(mktemp -d --tmpdir=/var/tmp da106.XXXXXX)"
  export TMPDIR="$base"
  DA_HOME="$(mktemp -d --tmpdir="$base" home.XXXXXX)"
  [ -d "$DA_HOME" ]
  [[ "$DA_HOME" != /tmp/* ]]          # genuinely outside /tmp
  teardown_tmp_devagent_home
  [ ! -d "$DA_HOME" ]                 # removed via the ${TMPDIR}/* clause
  rm -rf "$base"
}
