# tests/lib/trust-fixture.bash — shared trust-policy fixtures (#713).
# Load after lib/bats-helpers.

. "$(dirname "${BASH_SOURCE[0]}")/hermetic-env.bash"   # idempotent (#322)

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

# The quarantine label line an in-scope success-path policy needs (#714: a
# scope with no quarantine label refuses, exit 9).
TRUST_FIXTURE_QUARANTINE='quarantine = "devagent:quarantine"'

# trust_fixture_quarantine_shim: a backend dir whose github.sh answers the
# #714 quarantine reads itself (events: no records; state-exists: the label
# is there) and hands every other verb to the real backend, so a success-path
# test under a policy keeps its gh-stub argv log as it was.
trust_fixture_quarantine_shim() {
  local d="$BATS_TEST_TMPDIR/qshim"
  mkdir -p "$d"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "${1:-}" in events|state-exists) exit 0 ;; esac' \
    "exec \"$PLUGIN_ROOT/scripts/issue/github.sh\" \"\$@\"" > "$d/github.sh"
  chmod +x "$d/github.sh"
  export DEVAGENT_ISSUE_BACKEND_DIR="$d"
}
