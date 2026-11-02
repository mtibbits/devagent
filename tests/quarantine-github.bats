#!/usr/bin/env bats
# #714 Task 4: `github.sh transition <repo> <num> quarantine` adds the policy's
# quarantine label and nothing else: no --remove-label, the name from the
# trust policy alone (never an env override or config), exit set 0/2/4/1.

load 'lib/bats-helpers'
load 'lib/trust-fixture'
load 'lib/quarantine-fixture'

setup() {
  trust_fixture_home
  setup_tmp_devagent_home
  unset GH_HOST DEVAGENT_PROJECT
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE=standard GH_STUB_ARGV_LOG="$BATS_TEST_TMPDIR/gh-argv"
  : > "$GH_STUB_ARGV_LOG"
  export GH_STUB_REPO_LABELS='[{"name":"In Progress"},{"name":"devagent:quarantine"},{"name":"bug"}]'
  export GH_STUB_LABELS_JSON='[{"name":"In Progress"},{"name":"bug"}]'
  printf '[project.wid]\nsource_dir = "%s"\ndevdoc_dir = "%s"\n' "$BATS_TEST_TMPDIR/wid" "$BATS_TEST_TMPDIR/dd" \
    > "$DA_HOME/config.toml"
  GH="$PLUGIN_ROOT/scripts/issue/github.sh"
}

teardown() { teardown_tmp_devagent_home; }

EDIT='[issue] [edit] [7] [--repo] [acme/widgets] [--add-label] [devagent:quarantine]'

@test "transition quarantine adds only the policy label (argv has no --remove-label)" {
  qf_policy separate
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 0 ]
  grep -qxF "$EDIT" "$GH_STUB_ARGV_LOG"
  run grep -F -- '--remove-label' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition quarantine ignores DEVAGENT_GITHUB_LABEL_QUARANTINE" {
  qf_policy separate
  DEVAGENT_GITHUB_LABEL_QUARANTINE=WRONG run "$GH" transition acme/widgets 7 quarantine --project wid
  [ "$status" -eq 0 ]
  grep -qxF "$EDIT" "$GH_STUB_ARGV_LOG"
  run grep -F WRONG "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition quarantine without a policy exits 2" {
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 2 ]
  [ "$output" = "github.sh: transition quarantine needs a trust policy with a quarantine label" ]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

@test "transition quarantine with a policy that sets no quarantine label exits 2" {
  trust_fixture_policy "$HOME/.config/devagent/trust"
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 2 ]
  [ "$output" = "github.sh: transition quarantine needs a trust policy with a quarantine label" ]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

@test "transition quarantine on a repo without the label exits 4, no edit call" {
  qf_policy separate
  export GH_STUB_REPO_LABELS='[{"name":"devagent:quarantine (old)"}]'
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 4 ]
  [[ "$output" == *"label 'devagent:quarantine' (quarantine) not found on acme/widgets"* ]]
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition quarantine with a failed label lookup exits 1, no edit call" {
  qf_policy separate
  export GH_STUB_LABEL_LIST_FAIL=1
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 1 ]
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition quarantine is a no-op when the issue already carries it" {
  qf_policy separate
  export GH_STUB_LABELS_JSON='[{"name":"DevAgent:Quarantine"}]'
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 0 ]
  grep -qxF '[issue] [view] [7] [--repo] [acme/widgets] [--json] [labels]' "$GH_STUB_ARGV_LOG"
  run grep -F '[issue] [edit]' "$GH_STUB_ARGV_LOG"
  [ "$status" -eq 1 ]
}

@test "transition quarantine with a defective policy exits 1" {
  trust_fixture_policy "$HOME/.config/devagent/trust" 'scopes = ['
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 1 ]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}

@test "transition quarantine refuses a label with a comma before any gh call" {
  QF_LABEL='hold,me' qf_policy separate
  run "$GH" transition acme/widgets 7 quarantine
  [ "$status" -eq 1 ]
  [[ "$output" == *"contains a comma"* ]]
  [ ! -s "$GH_STUB_ARGV_LOG" ]
}
