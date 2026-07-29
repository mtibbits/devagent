#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() { setup_tmp_devagent_home; }
teardown() { teardown_tmp_devagent_home; }

@test "checklist-init.sh creates a checklist with default template" {
  ISSUE_DIR="$DA_HOME/Issue-1"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  [ -f "$ISSUE_DIR/checklist.md" ]
  run grep -q '23. cleanup' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist-init.sh accepts --template flag" {
  ISSUE_DIR="$DA_HOME/Issue-2"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" --template research "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  run grep -q 'Template: research' "$ISSUE_DIR/checklist.md"
  [ "$status" -eq 0 ]
}

@test "checklist-init.sh fails on bad template" {
  ISSUE_DIR="$DA_HOME/Issue-3"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" --template foo "$ISSUE_DIR"
  [ "$status" -ne 0 ]
}

@test "standard template carries preship (17) between redmr and ship in file order (#149)" {
  ISSUE_DIR="$DA_HOME/Issue-149t"
  run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  awk '/16\. redmr/{r=NR} /17\. preship/{p=NR} /18\. ship/{s=NR} END{exit !(r<p && p<s)}' "$ISSUE_DIR/checklist.md"
}

# --- #120: registry-routed templates ----------------------------------------

@test "devdoc override wins for checklist template when a project resolves (#120)" {
  cat > "$DA_HOME/config.toml" <<EOC
[project.tp]
source_dir = "$BATS_TEST_TMPDIR/src"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc"
EOC
  mkdir -p "$BATS_TEST_TMPDIR/devdoc/templates"
  printf '# OVERRIDE MARKER #120\n- [ ]  0. pull\n- [ ] 23. cleanup\n\n## Log\n' \
    > "$BATS_TEST_TMPDIR/devdoc/templates/checklist-standard.md"
  ISSUE_DIR="$DA_HOME/Issue-120a"
  DEVAGENT_ACTIVE_PROJECT=tp run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  grep -q 'OVERRIDE MARKER #120' "$ISSUE_DIR/checklist.md"
}

@test "no project context falls back to the plugin default (#120)" {
  ISSUE_DIR="$DA_HOME/Issue-120b"
  run env -u DEVAGENT_ACTIVE_PROJECT "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  grep -q '17\. preship' "$ISSUE_DIR/checklist.md"
}

# --- mergetoall ships pre-skipped; all_prs_branch opts it back in ------------

@test "mergetoall ships pre-skipped [-] when no project resolves" {
  ISSUE_DIR="$DA_HOME/Issue-m1"
  run env -u DEVAGENT_ACTIVE_PROJECT "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  grep -qE '^- \[-\] 19\. mergetoall$' "$ISSUE_DIR/checklist.md"
}

@test "checklist-init flips mergetoall to pending when the project sets all_prs_branch" {
  cat > "$DA_HOME/config.toml" <<EOC
[project.tp]
source_dir = "$BATS_TEST_TMPDIR/src"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc"
all_prs_branch = "dev/all-prs"
EOC
  ISSUE_DIR="$DA_HOME/Issue-m2"
  DEVAGENT_ACTIVE_PROJECT=tp run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  grep -qE '^- \[ \] 19\. mergetoall$' "$ISSUE_DIR/checklist.md"
}

@test "a project without all_prs_branch keeps mergetoall pre-skipped" {
  cat > "$DA_HOME/config.toml" <<EOC
[project.tp]
source_dir = "$BATS_TEST_TMPDIR/src"
devdoc_dir = "$BATS_TEST_TMPDIR/devdoc"
EOC
  ISSUE_DIR="$DA_HOME/Issue-m3"
  DEVAGENT_ACTIVE_PROJECT=tp run "$PLUGIN_ROOT/scripts/checklist-init.sh" "$ISSUE_DIR"
  [ "$status" -eq 0 ]
  grep -qE '^- \[-\] 19\. mergetoall$' "$ISSUE_DIR/checklist.md"
}
