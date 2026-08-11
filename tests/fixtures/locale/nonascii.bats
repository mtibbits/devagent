#!/usr/bin/env bats
# #565 FIXTURE — not part of the suite. `bats <dir>` does not recurse, so
# neither `bats tests/`, run-suite's `compgen -G "tests/*.bats"`, nor the
# SC2314 CI gate's `tests/*.bats` glob selects this file. It exists only to be
# executed BY tests/locale-registration.bats, which runs it under different
# locales. Its @test names deliberately carry non-ASCII characters — do not
# "fix" them to ASCII; that is the property under test.

@test "fixture — em dash in the name" {
  true
}

@test "fixture §6.3 section sign and ⇒ arrow" {
  true
}
