#!/usr/bin/env bats
# #713 task 8: doctor's trust block (trust_report) and pull's run record.
# Doctor runs the seeded volk project (gnuradio/volk) with a policy in a tmp
# HOME and the gh-stub: whoami answers $GH_STUB_EVENTS_DIR/user.json (1001),
# `gh auth status` lists $GH_STUB_EVENTS_DIR/accounts accounts.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/doctor-harness'
load 'lib/trust-fixture'

VOLK='scopes = ["github:github.com/gnuradio/volk"]'

setup() {
  trust_fixture_home
  unset GH_HOST GITLAB_HOST GH_TOKEN GITHUB_TOKEN
  setup_tmp_devagent_home
  seed_doctor_project
  stub_claude_cli enabled
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUBBIN/gh"
  chmod +x "$STUBBIN/gh"
  export PATH="$STUBBIN:$PATH"
  export GH_STUB_EVENTS_DIR="$BATS_TEST_TMPDIR/ev" GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  mkdir -p "$GH_STUB_EVENTS_DIR"
  echo '{"login":"worker","id":1001,"type":"User"}' > "$GH_STUB_EVENTS_DIR/user.json"
  POL="$HOME/.config/devagent/trust"
}

teardown() { teardown_tmp_devagent_home; }

_doctor() { run --separate-stderr "$PLUGIN_ROOT/scripts/doctor.sh" volk; }

@test "doctor: user-level baseline names system_policy (unverified) and separate_identity not met" {
  trust_fixture_policy "$POL" "$VOLK" 'worker_identities = ["github:1001"]' \
    'trusted_approvers = ["github:1001"]' 'single_identity = true'
  _doctor
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  [[ "$output" == *"WARN trust hardening — met: none; not met: separate_identity, signatures, system_policy (unverified)"* ]]
  [[ "$output" == *"OK   trust whoami github:1001 on github:github.com/gnuradio/volk — in worker_identities; single_identity=true"* ]]
}

@test "doctor: reports digest and whoami" {
  trust_fixture_policy "$POL" "$VOLK" 'worker_identities = ["github:1001"]'
  _doctor
  [ "$status" -eq 0 ] || { echo "$output $stderr" >&2; false; }
  [[ "$output" == *"OK   trust policy — user $POL/policy.toml sha256:"* ]]
  [[ "$output" == *"OK   trust whoami github:1001 on github:github.com/gnuradio/volk — in worker_identities; single_identity=false"* ]]
  [[ "$output" == *"WARN trust hardening — met: separate_identity; not met: signatures, system_policy (unverified)"* ]]
  # the trust block comes first, before the global checks.
  [ "$(grep -n 'trust policy' <<<"$output" | cut -d: -f1)" -lt "$(grep -n 'config exists' <<<"$output" | cut -d: -f1)" ]
}

@test "doctor: GH_TOKEN warns" {
  trust_fixture_policy "$POL" "$VOLK" 'worker_identities = ["github:1001"]'
  export GH_TOKEN=x
  _doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN trust credentials — GH_TOKEN is set"* ]]
}

@test "doctor: two gh accounts warn" {
  trust_fixture_policy "$POL" "$VOLK" 'worker_identities = ["github:1001"]'
  echo 2 > "$GH_STUB_EVENTS_DIR/accounts"
  _doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN trust gh accounts — 2 accounts on github.com"* ]]
  grep -q '^\[auth\] \[status\] \[--hostname\] \[github.com\]' "$GH_STUB_ARGV_LOG"
}

@test "doctor: whoami not a worker exits 9 after the block" {
  trust_fixture_policy "$POL" "$VOLK" 'worker_identities = ["github:2002"]'
  _doctor
  [ "$status" -eq 9 ]
  [[ "$output" == *"FAIL trust whoami github:1001 on github:github.com/gnuradio/volk — account github:1001 is not in worker_identities"* ]]
  [[ "$output" == *"WARN trust hardening"* ]]
  [[ "$output" != *"[project: volk]"* ]]
  [[ "$stderr" == *"doctor.sh: trust: account github:1001 is not in worker_identities — host-level refusal (exit 9)"* ]]
}

@test "doctor: no policy prints no trust block" {
  _doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"trust"* ]]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

# --- pull's run record

_wid_pull() {
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/wid"
  mkdir -p "$DEVDOC"
  cat > "$DA_HOME/config.toml" <<EOF
[project.wid]
source_dir = "$BATS_TEST_TMPDIR/wid"
devdoc_dir = "$DEVDOC"

[project.wid.permissions]
transition_issue = true

[project.wid.issue_source]
backend = "github"
repo = "acme/widgets"
dir_prefix = "Issue-"
EOF
  export GH_STUB_CASE=standard
  run --separate-stderr "$PLUGIN_ROOT/scripts/pull.sh" wid origin 7
}

@test "pull: run record carries digest, hardenings and user-ignored" {
  trust_fixture_policy "$POL" 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = ["github:1001"]' \
    'trusted_approvers = ["github:1001"]' 'single_identity = true'
  _wid_pull
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  local digest
  digest="$(trust_py load "$POL" | awk -F'\t' '$1 == "digest" { print $3 }')"
  local want="trust: policy $digest key github:github.com/acme/widgets#7 hardening met=none missing=separate_identity,signatures,system_policy(unverified)"
  [[ "$stderr" == *"pull.sh: $want"* ]]
  grep -qF "pull: $want" "$DEVDOC/Issue-7/checklist.md"
  # user-ignored: the record names a shadowed user policy (sourced lib, so the
  # system candidate is an argument).
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/trust.sh"
  trust_fixture_policy "$BATS_TEST_TMPDIR/sys" 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = ["github:1001"]'
  trust_locate --system "$BATS_TEST_TMPDIR/sys" --user "$POL"
  trust_load
  TRUST_WHOAMI=github:1001
  trust_hardening
  run trust_run_record github acme/widgets 7
  [[ "$output" == *"hardening met=separate_identity missing=signatures,system_policy(unverified) user-ignored=$POL" ]]
}

@test "pull: argv log never holds auth status" {
  trust_fixture_policy "$POL" 'scopes = ["github:github.com/acme/widgets"]' 'worker_identities = ["github:1001"]'
  echo 2 > "$GH_STUB_EVENTS_DIR/accounts"
  _wid_pull
  [ "$status" -eq 0 ]
  grep -q '\[user\]' "$GH_STUB_ARGV_LOG"
  run grep -c '\[auth\]' "$GH_STUB_ARGV_LOG"
  [ "$output" = 0 ]
}
