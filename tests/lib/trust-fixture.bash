# tests/lib/trust-fixture.bash — shared trust-policy fixtures (#713).
# Load after lib/bats-helpers.

TRUST_PY="$PLUGIN_ROOT/scripts/lib/trust_policy.py"

# The smallest valid policy: one exact repo scope and one worker id.
TRUST_FIXTURE_MIN=(
  'scopes = ["github:github.com/acme/widgets"]'
  'worker_identities = ["github:1001"]'
)

# trust_fixture_policy <dir> [toml-lines…]: write <dir>/policy.toml from the
# given lines (TRUST_FIXTURE_MIN when none are given).
trust_fixture_policy() {
  local dir="$1"
  shift
  [ $# -gt 0 ] || set -- "${TRUST_FIXTURE_MIN[@]}"
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/policy.toml"
}

# trust_fixture_home: point HOME at a fresh tmp dir, so the user-level policy
# location ($HOME/.config/devagent/trust) is the test's own.
trust_fixture_home() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}

# trust_py <verb> [args…]: run trust_policy.py exactly as trust.sh does.
trust_py() {
  python3 -I -X utf8 "$TRUST_PY" "$@"
}
