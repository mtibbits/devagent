#!/usr/bin/env bats
# #713 task 7: gates under trust. In scope (TRUST_IN_SCOPE=1, set by
# trust_entry_check), a gate reads the policy alone: config, DA_YES, a tty,
# DEVAGENT_PERMISSION_PUSH_MR and --yes never open a policy-closed gate, and
# nothing prompts. merge_mr and merge_to_all_prs are separate gates.

bats_require_minimum_version 1.5.0   # run --separate-stderr
load 'lib/bats-helpers'
load 'lib/trust-fixture'

setup() {
  setup_tmp_devagent_home
  cat > "$DA_HOME/config.toml" <<'EOF'
[project.wid.permissions]
push_mr = true
merge_to_all_prs = true
merge_mr = true
commit_devdoc = true
EOF
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
  source "$PLUGIN_ROOT/scripts/lib/permission.sh"
}

teardown() { teardown_tmp_devagent_home; }

# _in_scope <gate=bool>…: the state trust_entry_check leaves in scope.
_in_scope() {
  local kv
  TRUST_IN_SCOPE=1
  declare -gA TRUST_VAL=([push_mr]=false [merge_to_all_prs]=false [merge_mr]=false [commit_devdoc]=false [file]=false)
  for kv in "$@"; do TRUST_VAL["${kv%%=*}"]="${kv#*=}"; done
}

@test "gates: config push_mr=true does not open a policy-closed gate" {
  type permission_value
  _in_scope
  run permission_value wid push_mr
  [ "$output" = false ]
  run --separate-stderr permission_gate wid push_mr "ship plan"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"permission_gate: push_mr denied (trust policy)"* ]]
  # out of scope the config still decides.
  TRUST_IN_SCOPE=0
  run permission_value wid push_mr
  [ "$output" = true ]
}

@test "gates: DA_YES=1 does not open a policy-closed gate" {
  _in_scope
  DA_YES=1 run --separate-stderr permission_gate wid push_mr "ship plan"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"denied (trust policy)"* ]]
  [[ "$stderr" != *"Proceed with"* ]]
  # positive control: open when the policy says true.
  _in_scope push_mr=true
  DA_YES= run --separate-stderr permission_gate wid push_mr "ship plan"
  [ "$status" -eq 0 ]
}

@test "gates: policy merge_to_all_prs=true leaves merge_mr closed, and the reverse" {
  _in_scope merge_to_all_prs=true
  [ "$(permission_value wid merge_to_all_prs)" = true ]
  [ "$(permission_value wid merge_mr)" = false ]
  _in_scope merge_mr=true
  [ "$(permission_value wid merge_mr)" = true ]
  [ "$(permission_value wid merge_to_all_prs)" = false ]
}

@test "gates: no direct permissions.<gate> config read outside permission.sh" {
  local re='config_get_project_field[^|]*permissions\.(push_mr|commit_devdoc|merge_to_all_prs|merge_mr|file)'
  # positive control: the predicate sees a planted direct read (the shape
  # cleanup.sh:220 had before #713).
  printf '%s\n' 'x="$(config_get_project_field "$project" "permissions.commit_devdoc" 2>/dev/null || echo false)"' \
    > "$BATS_TEST_TMPDIR/planted.sh"
  run grep -nE "$re" "$BATS_TEST_TMPDIR/planted.sh"
  [ "$status" -eq 0 ]
  # every code line elsewhere; doctor's advisory merge_mr/merge_to_all_prs
  # migration hint (never a gate) is the one allow-listed reader.
  run bash -c "grep -rnE '$re' '$PLUGIN_ROOT/scripts' | grep -v '/scripts/lib/permission.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' | grep -v '/scripts/doctor.sh:'"
  [ "$output" = "" ] || { echo "direct gate reads: $output" >&2; false; }
}

# --- capture/file.sh under trust (the policy's `file` gate; backend and repo
# from config, never DEVAGENT_ISSUE_BACKEND / DEVAGENT_REPO_*)

# _file_fixture <file-gate>: project wid (origin acme/widgets) with one capture
# draft, a policy in scope whose worker is the stub's whoami (github:1001).
_file_fixture() {
  trust_fixture_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_EVENTS_DIR="$BATS_TEST_TMPDIR/ev" GH_STUB_ARGS_LOG="$BATS_TEST_TMPDIR/args"
  mkdir -p "$GH_STUB_EVENTS_DIR"
  echo '{"login":"worker","id":1001,"type":"User"}' > "$GH_STUB_EVENTS_DIR/user.json"
  DEVDOC="$BATS_TEST_TMPDIR/devDoc/wid"
  SLUG=2026-11-01-x
  mkdir -p "$DEVDOC/Captures/$SLUG"
  printf '# A title\n\nbody\n' > "$DEVDOC/Captures/$SLUG/draft.md"
  cat > "$DA_HOME/config.toml" <<EOF2
[project.wid]
source_dir = "$BATS_TEST_TMPDIR/wid"
devdoc_dir = "$DEVDOC"

[project.wid.permissions]
transition_issue = true
push_mr = true

[project.wid.issue_source]
backend = "github"
repo = "acme/widgets"
dir_prefix = "Issue-"
EOF2
  trust_fixture_policy "$HOME/.config/devagent/trust" 'scopes = ["github:github.com/acme/widgets"]' \
    'worker_identities = ["github:1001"]' "file = $1"
  export DEVAGENT_DEVDOC_DIR="$DEVDOC" DEVAGENT_ISSUE_BACKEND_DIR="$PLUGIN_ROOT/scripts/issue"
  export DEVAGENT_ISSUE_BACKEND=gitlab DEVAGENT_REPO_ORIGIN=evil/repo
}

@test "gates: file.sh exits 4 with DEVAGENT_PERMISSION_PUSH_MR=true and policy file=false, and its text has no --yes" {
  _file_fixture false
  export DEVAGENT_PERMISSION_PUSH_MR=true
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug "$SLUG" --target origin
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"Permission gate: file=false (trust policy)"* ]]
  [[ "$stderr" == *"repo:    acme/widgets"* ]]
  [[ "$stderr" != *"--yes"* ]]
  [ ! -e "$GH_STUB_ARGS_LOG" ]
}

@test "gates: file.sh --yes under trust exits 9" {
  _file_fixture true
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug "$SLUG" --target origin --yes
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"trust: --yes is refused under a trust policy"* ]]
  [ ! -e "$GH_STUB_ARGS_LOG" ]
}

@test "gates: file.sh under trust files to the config repo through the config backend" {
  _file_fixture true
  run --separate-stderr "$PLUGIN_ROOT/scripts/capture/file.sh" --slug "$SLUG" --target origin
  [ "$status" -eq 0 ] || { echo "$stderr" >&2; false; }
  grep -q -- '--repo acme/widgets' "$GH_STUB_ARGS_LOG"
  run grep -c 'evil/repo' "$GH_STUB_ARGS_LOG"
  [ "$output" = 0 ]
}
