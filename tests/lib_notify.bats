#!/usr/bin/env bats
# bats file_tags=gitbash
# tests/lib_notify.bats — #961: the launcher contracts. The DEVAGENT_UNATTENDED
# marker (read only through devagent_unattended, scripts/lib/paths.sh) and the
# suite guard that unsets it; the notifications file and its one appender
# (scripts/lib/notify.sh, scripts/lib/_notify.py). Spec §7.3.
bats_require_minimum_version 1.5.0

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-twoproject.toml
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}

teardown() { teardown_tmp_devagent_home; }

is_git_bash() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# ---- Task 1: the marker and the suite guard ---------------------------------

@test "marker: devagent_unattended succeeds for any non-empty value, including 0" {
  . "$PLUGIN_ROOT/scripts/lib/paths.sh"
  run type -t devagent_unattended
  [ "$output" = function ]
  local v
  for v in 1 0 false ' '; do
    DEVAGENT_UNATTENDED="$v" run devagent_unattended
    [ "$status" -eq 0 ] || { echo "value <$v> gave $status" >&2; return 1; }
  done
}

@test "marker: devagent_unattended fails when the variable is unset or empty" {
  . "$PLUGIN_ROOT/scripts/lib/paths.sh"
  run type -t devagent_unattended
  [ "$output" = function ]
  unset DEVAGENT_UNATTENDED
  run devagent_unattended
  [ "$status" -eq 1 ]
  DEVAGENT_UNATTENDED='' run devagent_unattended
  [ "$status" -eq 1 ]
  run env -u DEVAGENT_UNATTENDED bash -uc '. "$1"; devagent_unattended' _ "$PLUGIN_ROOT/scripts/lib/paths.sh"
  [ "$status" -eq 1 ]
  run env DEVAGENT_UNATTENDED= bash -uc '. "$1"; devagent_unattended' _ "$PLUGIN_ROOT/scripts/lib/paths.sh"
  [ "$status" -eq 1 ]
}

@test "suite: a bare-setup file started with the marker set sees it unset" {
  local inner="$BATS_TEST_TMPDIR/inner_bare.bats"
  cat > "$inner" <<EOF
#!/usr/bin/env bats
. "$PLUGIN_ROOT/tests/lib/hermetic-env.bash"
. "$PLUGIN_ROOT/scripts/lib/paths.sh"
@test "inner: the marker is unset" {
  run devagent_unattended
  [ "\$status" -eq 1 ]
}
EOF
  run env DEVAGENT_UNATTENDED=1 bats --tap "$inner"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^ok ')" -eq 1 ]
  printf '%s\n' "$output" | grep -qx '1\.\.1'
}

@test "suite: a fixtures-loading file started with the marker set sees it unset" {
  local inner="$BATS_TEST_TMPDIR/inner_fixtures.bats"
  cat > "$inner" <<EOF
#!/usr/bin/env bats
load '$PLUGIN_ROOT/tests/helpers/fixtures'
setup() {
  fixture_init toy Issue-1
  . "$PLUGIN_ROOT/scripts/lib/paths.sh"
}
@test "inner: the marker is unset after the fixtures" {
  run devagent_unattended
  [ "\$status" -eq 1 ]
}
@test "inner: a marker exported after the fixtures survives" {
  export DEVAGENT_UNATTENDED=1
  run devagent_unattended
  [ "\$status" -eq 0 ]
}
EOF
  run env DEVAGENT_UNATTENDED=1 bats --tap "$inner"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^ok ')" -eq 2 ]
  printf '%s\n' "$output" | grep -qx '1\.\.2'
}
