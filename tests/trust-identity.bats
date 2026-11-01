#!/usr/bin/env bats
# #713 task 5: locate and load the trust policy, the predicate, the identity
# checks and the hardenings. Entry-point cases run the real pull.sh against a
# policy in a tmp HOME and the gh-stub (whoami answers from
# $GH_STUB_EVENTS_DIR/user.json); system-location cases call trust_locate /
# trust_entry_check from a sourced lib, so the candidates are arguments.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/doctor-harness'
load 'helpers/common'
load 'lib/trust-golden'
load 'lib/trust-fixture'

SCOPE='scopes = ["github:github.com/acme/widgets"]'

setup() {
  trust_fixture_home
  unset GH_HOST
  POL="$HOME/.config/devagent/trust"
}

teardown() {
  teardown_tmp_devagent_home
  devagent_test_teardown
}

# _wid [transition_issue]: project `wid` (origin acme/widgets, fork
# mtibbits/widgets), the gh-stub on PATH, whoami = github:1001.
_wid() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE=standard GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export GH_STUB_EVENTS_DIR="$BATS_TEST_TMPDIR/ev"
  mkdir -p "$GH_STUB_EVENTS_DIR"
  echo '{"login":"worker","id":1001,"type":"User"}' > "$GH_STUB_EVENTS_DIR/user.json"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/wid"
  mkdir -p "$DEVDOC"
  cat > "$DA_HOME/config.toml" <<EOF
[project.wid]
source_dir = "$BATS_TEST_TMPDIR/wid"
devdoc_dir = "$DEVDOC"

[project.wid.permissions]
transition_issue = ${1:-true}

[project.wid.issue_source]
backend = "github"
repo = "acme/widgets"
dir_prefix = "Issue-"

[project.wid.issue_source_fork]
backend = "github"
repo = "mtibbits/widgets"
dir_prefix = "Issue-Fork-"
EOF
}

_pull() { run --separate-stderr "$PLUGIN_ROOT/scripts/pull.sh" "${1:-wid}" origin 7; }

# _refused <rc> <token>: pull refused with <rc> naming <token>, made no call but
# whoami, and scaffolded nothing.
_refused() {
  [ "$status" -eq "$1" ] || { echo "rc=$status stderr=$stderr" >&2; return 1; }
  [[ "$stderr" == *"trust: "*"$2"* ]] || { echo "stderr: $stderr" >&2; return 1; }
  [ ! -d "$DEVDOC/Issue-7" ]
  if [ -f "$GH_STUB_ARGV_LOG" ]; then
    run grep -v '^\[api\] \[-i\] \[--hostname\] \[github.com\] \[user\]' "$GH_STUB_ARGV_LOG"
    [ "$output" = "" ] || { echo "unexpected calls: $output" >&2; return 1; }
  fi
}

# _lib: source trust.sh as an entry point would.
_lib() {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
}

# --- the predicate

@test "predicate: trust_grants table" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]' \
    'trusted_approvers = ["github:2002", "github:3003"]'
  _lib
  type trust_grants
  trust_locate --system "$BATS_TEST_TMPDIR/nosys" --user "$POL"
  trust_load
  TRUST_WHOAMI=github:1001
  run trust_grants trusted_approvers github '?' User;     [ "$status" -eq 1 ]
  run trust_grants trusted_approvers github whoami User;  [ "$status" -eq 1 ]
  run trust_grants trusted_approvers github 1001 User;    [ "$status" -eq 1 ]
  run trust_grants trusted_approvers github 4004 Bot;     [ "$status" -eq 1 ]
  run trust_grants trusted_approvers github 5005 Customer; [ "$status" -eq 1 ]
  run trust_grants trusted_approvers github 2002 User;    [ "$status" -eq 0 ]
  run trust_grants trusted_approvers github 3003 Bot;     [ "$status" -eq 0 ]
  run trust_grants trusted_approvers gitlab 2002 User;    [ "$status" -eq 1 ]
}

@test "predicate: under single_identity, whoami in the set grants only with [] or --signed" {
  _wid
  _lib
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]' \
    'trusted_approvers = ["github:1001"]' 'single_identity = true'
  trust_locate --system "$BATS_TEST_TMPDIR/nosys" --user "$POL"
  trust_load
  TRUST_WHOAMI=github:1001
  run trust_grants trusted_approvers github whoami User;  [ "$status" -eq 0 ]
  run trust_grants trusted_reviewers github whoami User;  [ "$status" -eq 1 ]
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]' \
    'trusted_approvers = ["github:1001"]' 'single_identity = true' 'required_hardening = ["separate_identity"]'
  trust_load
  run trust_grants trusted_approvers github whoami User;  [ "$status" -eq 1 ]
  run trust_grants trusted_approvers github 1001 User;    [ "$status" -eq 1 ]
  run trust_grants trusted_approvers github whoami User --signed; [ "$status" -eq 0 ]
}

# --- AC3: refusals before any fetch

@test "identity: refuses before any fetch when whoami is in <set>" {
  local set
  for set in trusted_approvers trusted_reporters trusted_reviewers; do
    _wid
    trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:2002"]' "$set = [\"github:1001\"]"
    rm -f "$GH_STUB_ARGV_LOG"
    _pull
    _refused 9 "account github:1001 is in $set"
  done
}

@test "identity: refuses before any fetch when whoami is missing from worker_identities" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:2002"]'
  _pull
  _refused 9 "account github:1001 is not in worker_identities"
  grep -q '\[user\]' "$GH_STUB_ARGV_LOG"
}

@test "identity: refuses before any fetch when whoami fails definitively" {
  _wid
  printf '401 Unauthorized\n' > "$GH_STUB_EVENTS_DIR/user.status"
  echo 1 > "$GH_STUB_EVENTS_DIR/user.rc"
  trust_fixture_policy "$POL"
  _pull
  _refused 9 "whoami failed for github.com/acme/widgets (backend exit 3)"
}

@test "identity: refuses before any fetch when the backend has no whoami" {
  _wid
  mkdir -p "$BATS_TEST_TMPDIR/be"
  printf '#!/usr/bin/env bash\n[ "$1" = whoami ] && exec "%s" whoami "$2"\nexec "%s" "$@"\n' \
    "$PLUGIN_ROOT/scripts/issue/custom.sh" "$PLUGIN_ROOT/scripts/issue/github.sh" > "$BATS_TEST_TMPDIR/be/github.sh"
  chmod +x "$BATS_TEST_TMPDIR/be/github.sh"
  export DEVAGENT_ISSUE_BACKEND_DIR="$BATS_TEST_TMPDIR/be"
  trust_fixture_policy "$POL"
  _pull
  _refused 9 "the github backend has no whoami verb (exit 78)"
}

@test "identity: refuses before any fetch when transition_issue is off" {
  _wid false
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]'
  _pull
  _refused 9 "permissions.transition_issue is not true for project wid"
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

@test "identity: refuses required_hardening [separate_identity] with single_identity true" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]' \
    'trusted_approvers = ["github:1001"]' 'single_identity = true' 'required_hardening = ["separate_identity"]'
  _pull
  _refused 9 "required_hardening lists separate_identity, which is not met"
}

@test "identity: refuses required_hardening [signatures]" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]' 'required_hardening = ["signatures"]'
  _pull
  _refused 9 "required_hardening lists signatures, which is not met"
}

@test "identity: whoami could-not-run exits 10" {
  _wid
  printf 'none\n' > "$GH_STUB_EVENTS_DIR/user.status"
  echo 1 > "$GH_STUB_EVENTS_DIR/user.rc"
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]'
  _pull
  _refused 10 "whoami could not reach github.com (backend exit 75) — try later (exit 10)"
}

@test "identity: GH_HOST with a bare repo refuses" {
  _wid
  export GH_HOST=ghe.corp
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]'
  _pull
  _refused 9 "GH_HOST is set and acme/widgets is a bare OWNER/REPO"
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

# --- defects

@test "defect: an unreadable / dangling / invalid-TOML policy refuses pull with 9" {
  _wid
  trust_fixture_policy "$POL" 'scopes = [' 'worker'
  _pull
  _refused 9 "policy $POL/policy.toml: invalid TOML"
  rm -f "$POL/policy.toml"
  if ln -s "$BATS_TEST_TMPDIR/nowhere" "$POL/policy.toml" 2>/dev/null && [ -L "$POL/policy.toml" ]; then
    _pull
    _refused 9 "dangling link"
  fi
  rm -f "$POL/policy.toml"
  trust_fixture_policy "$POL"
  chmod 000 "$POL/policy.toml"
  if [ ! -r "$POL/policy.toml" ]; then
    _pull
    _refused 9 "cannot read"
  fi
}

@test "defect: a CR in load output refuses" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]'
  local real
  real="$(command -v python3)"
  cat > "$STUB_BIN/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *trust_policy.py*) "$real" "\$@" | sed 's/\$/\r/' ;;
  *) exec "$real" "\$@" ;;
esac
EOF
  chmod +x "$STUB_BIN/python3"
  _pull
  _refused 9 "carriage return"
}

# --- location

@test "location: an empty location dir is no policy" {
  mkdir -p "$POL"
  _scenario_pull
  _golden_check pull "$GOLDEN_ARGV"
}

@test "location: system beats user" {
  _wid
  _lib
  local sys="$BATS_TEST_TMPDIR/sys"
  trust_fixture_policy "$sys" "$SCOPE" 'worker_identities = ["github:1001"]' 'merge_mr = true'
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]'
  trust_locate --system "$BATS_TEST_TMPDIR/absent" "$sys" --user "$POL"
  [ "$TRUST_SOURCE" = system ]
  [ "$TRUST_DIR" = "$sys" ]
  [ "$TRUST_USER_IGNORED" = "$POL" ]
  trust_load
  [ "$TRUST_DIGEST" = "$(trust_py load "$sys" | awk -F'\t' '$1 == "digest" { print $3 }')" ]
  [ "$TRUST_DIGEST" != "$(trust_py load "$POL" | awk -F'\t' '$1 == "digest" { print $3 }')" ]
  TRUST_SYSTEM_DIRS=("$sys")
  run --separate-stderr trust_entry_check pull wid origin
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"ignored"* ]]
}

@test "location: a defective location refuses (dangling, non-directory)" {
  _lib
  run trust_locate --system "$BATS_TEST_TMPDIR/nosys" --user "$POL"
  [ "$status" -eq 0 ]
  : > "$BATS_TEST_TMPDIR/file"
  trust_locate --system "$BATS_TEST_TMPDIR/file" --user "$POL" || true
  [ "$TRUST_HOST" = 1 ]
  [[ "$TRUST_DEFECT" == *"not a directory"* ]]
}

@test "hardening: required_hardening [system_policy] refuses at either location" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]' 'required_hardening = ["system_policy"]'
  _pull
  _refused 9 "required_hardening lists system_policy, which is not met (unverified: not met"
  rm -rf "$POL"
  _lib
  local sys="$BATS_TEST_TMPDIR/sys"
  trust_fixture_policy "$sys" "$SCOPE" 'worker_identities = ["github:1001"]' 'required_hardening = ["system_policy"]'
  TRUST_SYSTEM_DIRS=("$sys")
  run --separate-stderr trust_entry_check pull wid origin
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"required_hardening lists system_policy"* ]]
}

@test "baseline: a user-level single_identity policy with the operator id as worker and approver turns trust on" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:1001"]' \
    'trusted_approvers = ["github:1001"]' 'single_identity = true'
  _pull
  [ "$status" -eq 0 ]
  [ -d "$DEVDOC/Issue-7" ]
  grep -q '^\[api\] \[-i\] \[--hostname\] \[github.com\] \[user\]' "$GH_STUB_ARGV_LOG"
  grep -q '^\[issue\] \[view\]' "$GH_STUB_ARGV_LOG"
}

# --- stays on: no config edit turns trust off

@test "scope: trust stays on with a NEW DA_HOME holding a fresh config.toml naming the same repo, no trust keys" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:2002"]'
  local cfg
  cfg="$(cat "$DA_HOME/config.toml")"
  export DA_HOME="$BATS_TEST_TMPDIR/fresh-home"
  mkdir -p "$DA_HOME/state"
  printf '%s\n' "$cfg" > "$DA_HOME/config.toml"
  _pull
  _refused 9 "not in worker_identities"
}

@test "scope: trust stays on when a [project.alias] copies the covered repo" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:2002"]'
  cat >> "$DA_HOME/config.toml" <<EOF

[project.alias]
source_dir = "$BATS_TEST_TMPDIR/alias"
devdoc_dir = "$DEVDOC"

[project.alias.permissions]
transition_issue = true

[project.alias.issue_source]
backend = "github"
repo = "ACME/Widgets.git"
dir_prefix = "Issue-"
EOF
  _pull alias
  _refused 9 "not in worker_identities"
}

@test "scope: trust stays on when config.toml gains trust-shaped keys" {
  _wid
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:2002"]'
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set-bool "$DA_HOME/config.toml" project.wid.trust false
  python3 "$PLUGIN_ROOT/scripts/lib/_toml.py" set "$DA_HOME/config.toml" project.wid.trust_policy /dev/null
  grep -q 'trust_policy' "$DA_HOME/config.toml"
  _pull
  _refused 9 "not in worker_identities"
}

@test "scope: an out-of-scope project replays the pull golden unchanged" {
  trust_fixture_policy "$POL" "$SCOPE" 'worker_identities = ["github:2002"]'
  _scenario_pull
  _golden_check pull "$GOLDEN_ARGV"
}

@test "hermetic: a policy on the suite host fails the guard" {
  local h="$BATS_TEST_TMPDIR/hosthome"
  trust_fixture_policy "$h/.config/devagent/trust"
  run bash -c "HOME='$h'; . '$PLUGIN_ROOT/tests/lib/hermetic-env.bash'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"suite host carries a trust policy at $h/.config/devagent/trust/policy.toml; run the suite where none exists"* ]]
  run bash -c "HOME='$BATS_TEST_TMPDIR/clean'; . '$PLUGIN_ROOT/tests/lib/hermetic-env.bash'"
  [ "$status" -eq 0 ]
}
