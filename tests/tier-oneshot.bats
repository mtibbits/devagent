#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cp "$PLUGIN_ROOT/tests/fixtures/gh-stub" "$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_CASE="standard"

  DEVDOC="$BATS_TEST_TMPDIR/devDoc/volk"
  mkdir -p "$DEVDOC" "$BATS_TEST_TMPDIR/volk"
  cat > "$DA_HOME/config.toml" <<EOF
[project.volk]
source_dir = "$BATS_TEST_TMPDIR/volk"
devdoc_dir = "$DEVDOC"

[project.volk.issue_source]
backend = "github"
repo = "gnuradio/volk"
dir_prefix = "Issue-"
EOF
}

teardown() { teardown_tmp_devagent_home; }

# --- Task 1: template fixture + §12 resolution -------------------------------

@test "checklist-oneshot carries exactly rows 0/7/9/19/20 (#537)" {
  tpl="$PLUGIN_ROOT/templates/checklist-oneshot.md"
  [ -f "$tpl" ]
  [ "$(grep -cE '^\- \[ \] +[0-9]+\.' "$tpl")" -eq 5 ]
  grep -qE '^\- \[ \] +0\. pull' "$tpl"
  grep -qE '^\- \[ \] +7\. implement' "$tpl"
  grep -qE '^\- \[ \] +9\. document' "$tpl"
  grep -qE '^\- \[ \] 19\. lessonslearned' "$tpl"
  grep -qE '^\- \[ \] 20\. cleanup' "$tpl"
}

@test "checklist-oneshot carries the evidence note and the no-repo-change boundary (#537)" {
  tpl="$PLUGIN_ROOT/templates/checklist-oneshot.md"
  grep -q "execution evidence" "$tpl"
  grep -q "not a repo change" "$tpl"
}

@test "oneshot is §12-resolvable through checklist_init (#537)" {
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/checklist.sh"
  d="$BATS_TEST_TMPDIR/issue"
  mkdir -p "$d"
  ISSUE_ID="Issue-999" checklist_init "$d" oneshot
  grep -q '^Template: oneshot$' "$d/checklist.md"
}
