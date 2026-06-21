#!/usr/bin/env bats
# #250: the opt-in pre-push hook mirrors the CI SC2314 bats gate
# (.github/workflows/shellcheck.yml) so a vacuous `! cmd` bats assertion is
# caught locally before a push, not after.
#
# Fixtures are written with printf (NOT heredocs and NOT literal leading `@test`
# lines) so bats' own preprocessor does not mistake the fixture bodies for real
# tests in this file. Every real assertion here uses `run …; [ "$status" -ne 0 ]`,
# so tests/git-hooks.bats is itself SC2314-clean.

load 'lib/bats-helpers'

setup() {
  HOOK="$PLUGIN_ROOT/.githooks/pre-push"
  INSTALLER="$PLUGIN_ROOT/scripts/install-git-hooks.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/tests"
  git -C "$REPO" init -q
}

@test "#250: pre-push hook blocks a new vacuous '!' bats assertion (SC2314)" {
  printf '#!/usr/bin/env bats\n@test "x" { ! grep -q nope /dev/null; }\n' \
    > "$REPO/tests/bad.bats"
  run bash -c "cd '$REPO' && '$HOOK' origin file:///dev/null < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SC2314"* ]]
}

@test "#250: pre-push hook passes a clean tests/*.bats tree" {
  printf '#!/usr/bin/env bats\n@test "x" { run grep -q nope /dev/null; [ "$status" -ne 0 ]; }\n' \
    > "$REPO/tests/good.bats"
  run bash -c "cd '$REPO' && '$HOOK' origin file:///dev/null < /dev/null"
  [ "$status" -eq 0 ]
}

@test "#250: pre-push hook is SC2314-specific (a non-SC2314 finding does not block)" {
  # Unquoted $foo trips SC2086, NOT SC2314 — the gate must ignore it.
  printf '#!/usr/bin/env bats\n@test "x" { foo=bar; echo $foo; }\n' \
    > "$REPO/tests/other.bats"
  run bash -c "cd '$REPO' && '$HOOK' origin file:///dev/null < /dev/null"
  [ "$status" -eq 0 ]
}

@test "#250: pre-push hook refuses to pass when shellcheck cannot emit SC2314 (too old)" {
  printf '#!/usr/bin/env bats\n@test "x" { run true; [ "$status" -eq 0 ]; }\n' \
    > "$REPO/tests/good.bats"
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\necho "ShellCheck 0.8.0"\nexit 0\n' > "$stub/shellcheck"
  chmod +x "$stub/shellcheck"
  run bash -c "cd '$REPO' && PATH='$stub:$PATH' '$HOOK' origin file:///dev/null < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SC2314"* ]]
}

@test "#250: pre-push hook exits 0 when there are no tests/*.bats files" {
  rm -rf "$REPO/tests"
  run bash -c "cd '$REPO' && '$HOOK' origin file:///dev/null < /dev/null"
  [ "$status" -eq 0 ]
}

@test "#250: install-git-hooks.sh points core.hooksPath at .githooks" {
  cp -r "$PLUGIN_ROOT/.githooks" "$REPO/.githooks"
  cp "$INSTALLER" "$REPO/install-git-hooks.sh"
  run bash -c "cd '$REPO' && bash install-git-hooks.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" config core.hooksPath)" = ".githooks" ]
}
