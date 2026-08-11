#!/usr/bin/env bats
# #565: on this project's Windows box /etc/fstab mounts are `noacl`, so chmod is
# a no-op and the auth/secrets mode tests can never pass there — BY DESIGN.
# run-suite.sh's only product is a provenance artifact consumed by
# preship-evidence.sh, so producing one from such a filesystem manufactures
# authoritative-looking evidence for a gate it cannot pass (Issue-550's lesson).

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # shellcheck source=../scripts/lib/fs-probe.sh
  . "$REPO/scripts/lib/fs-probe.sh"
}

# #572: a negative assertion is vacuously satisfied by a missing function's 127.
@test "#565: fs_chmod_is_effective is defined by scripts/lib/fs-probe.sh" {
  run type -t fs_chmod_is_effective
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "#565: fs_chmod_is_effective reports 0 on a filesystem where chmod sticks" {
  if ! _chmod_sticks_here; then
    skip "this filesystem is chmod-ineffective (noacl) — the negative case is covered below"
  fi
  run fs_chmod_is_effective "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "#565: fs_chmod_is_effective reports 1 on a filesystem where chmod is a no-op" {
  if _chmod_sticks_here; then
    skip "this filesystem honours chmod — the positive case is covered above"
  fi
  run fs_chmod_is_effective "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}

@test "#565: fs_chmod_is_effective reports 2 when the probe file cannot be created" {
  run fs_chmod_is_effective "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}

@test "#565: fs_chmod_is_effective leaves no probe file behind" {
  fs_chmod_is_effective "$BATS_TEST_TMPDIR" || true
  run bash -c "ls -A '$BATS_TEST_TMPDIR' | wc -l"
  [ "$output" = "0" ]
}

@test "#565: the preflight's die message points at a README section that exists" {
  # Two-sided constant (#106): the message names a heading, so a rename must
  # redden here instead of silently misdirecting the reader.
  run grep -q '^## Running the test suite$' "$REPO/README.md"
  [ "$status" -eq 0 ]
  run grep -q 'Running the test suite' "$REPO/scripts/run-suite.sh"
  [ "$status" -eq 0 ]
  run grep -q 'WSL' "$REPO/scripts/run-suite.sh"
  [ "$status" -eq 0 ]
}

@test "#565: the preflight only fires when the tree actually has a suite to run" {
  # run-suite.sh serves EVERY configured project; a tests-less tree legitimately
  # records (none)/(none) and must not die on a filesystem property it never
  # exercises. Pin the guard's condition rather than its wording.
  run grep -n 'compgen -G "tests/\*\.bats"' "$REPO/scripts/run-suite.sh"
  [ "$status" -eq 0 ]
  run bash -c "grep -c 'fs_chmod_is_effective' '$REPO/scripts/run-suite.sh'"
  [ "$output" != "0" ]
  # the preflight loop must sit inside a suite-presence guard, not at top level
  run bash -c "awk '/^if compgen -G \"tests\/\\*\\.bats\" .*\\|\\| compgen/,/^fi\$/' '$REPO/scripts/run-suite.sh' | grep -c fs_chmod_is_effective"
  [ "$output" = "1" ]
}

# Is chmod effective on THIS filesystem? Used only to route the two verdict
# branches above, so neither platform gets a silently skipped assertion.
_chmod_sticks_here() {
  local probe perms
  probe="$(mktemp "$BATS_TEST_TMPDIR/.sticks.XXXXXX")" || return 1
  chmod 600 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
  perms="$(ls -l "$probe" | cut -c1-10)"
  rm -f "$probe"
  [ "$perms" = "-rw-------" ]
}
