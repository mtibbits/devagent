#!/usr/bin/env bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# #322: hermetic env (pins / git config / TZ / locale)
. "$(dirname "$BATS_TEST_FILENAME")/lib/hermetic-env.bash"
# #335: pull in the shared _toml.py-backed config helpers. This file keeps its
# own hermetic setup(); `load` only defines the helper functions (and re-sources
# the idempotent hermetic-env guard).
load 'helpers/common'

setup() {
  TMPROOT="$(mktemp -d)"
  TMPDEV="$TMPROOT/devdoc"
  mkdir -p "$TMPDEV"
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets"

  cat > "$HOME/.claude/devagent/config.toml" <<EOF
[defaults]
checklist_template = "standard"

[project.testproj]
source_dir = "$TMPROOT/src"
devdoc_dir = "$TMPDEV"

[project.testproj.issue_source]
backend = "github"
repo    = "acme/testproj"

[project.testproj.code_source]
backend  = "github"
upstream = "acme/testproj"

[project.testproj.permissions]
push_mr            = true
merge_to_all_prs   = true
commit_devdoc      = false
transition_issue   = true
cleanup_on_merge   = false
EOF
  mkdir -p "$TMPROOT/src"

  mkdir -p "$TMPDEV/Issue-100" "$TMPDEV/Issue-101" "$TMPDEV/Issue-103" "$TMPDEV/Issue-104"
  cp "$REPO/tests/fixtures/issues/Issue-100/checklist.md" "$TMPDEV/Issue-100/"
  cp "$REPO/tests/fixtures/issues/Issue-100/STUCK"        "$TMPDEV/Issue-100/"
  cp "$REPO/tests/fixtures/issues/Issue-101/checklist.md" "$TMPDEV/Issue-101/"
  cp "$REPO/tests/fixtures/issues/Issue-103/checklist.md" "$TMPDEV/Issue-103/"
  cp "$REPO/tests/fixtures/issues/Issue-104/checklist.md" "$TMPDEV/Issue-104/"

  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Milestone {est: 5w, milestone: M1}
  - [x] Done leaf {issue: Issue-104, est: 1w}
  - [~] Stuck leaf {issue: Issue-100, est: 1w}
  - [ ] Idle leaf {issue: Issue-103, est: 1w}
  - [ ] Future leaf {est: 1w}
EOF
}

teardown() {
  rm -rf "$TMPROOT"
}

_flip_commit_devdoc_true() {
  devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.testproj.permissions.commit_devdoc" true
}

@test "statusreport writes a dated report to <devdoc>/StatusReports/" {
  run bash "$REPO/scripts/statusreport.sh" testproj
  [ "$status" -eq 0 ]
  found="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  [ -n "$found" ]
}

@test "statusreport detects stuck, failed-redteam, and idle issues" {
  bash "$REPO/scripts/statusreport.sh" testproj
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "Issue-100" "$report"
  grep -q "Issue-101" "$report"
  grep -q "Issue-103" "$report"
}

@test "statusreport advances pin in project state by default" {
  bash "$REPO/scripts/statusreport.sh" testproj
  pin="$(python3 "$REPO/scripts/lib/_toml.py" get \
    "$HOME/.claude/devagent/state/testproj.toml" statusreport_last_pin 2>/dev/null)"
  [ -n "$pin" ]
}

@test "statusreport --no-pin leaves pin unchanged" {
  bash -c "source $REPO/scripts/lib/paths.sh; \
           source $REPO/scripts/lib/io.sh; \
           source $REPO/scripts/lib/state.sh; \
           state_init testproj; \
           state_set testproj statusreport_last_pin '2026-05-01T00:00:00+00:00'"
  bash "$REPO/scripts/statusreport.sh" testproj --no-pin
  pin="$(python3 "$REPO/scripts/lib/_toml.py" get \
    "$HOME/.claude/devagent/state/testproj.toml" statusreport_last_pin)"
  [ "$pin" = "2026-05-01T00:00:00+00:00" ]
}

@test "statusreport --window-weeks with no value fails with a clear message (A22)" {
  run bash "$REPO/scripts/statusreport.sh" testproj --window-weeks
  [ "$status" -ne 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"--window-weeks"* ]]
}

@test "statusreport reports velocity and estimate sections" {
  bash "$REPO/scripts/statusreport.sh" testproj
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "Velocity & estimate" "$report"
  grep -q "Remaining WBS leaves" "$report"
}

@test "statusreport prints summary to stdout" {
  run bash "$REPO/scripts/statusreport.sh" testproj
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status Report"* ]]
}

@test "statusreport commits to devdoc git repo iff commit_devdoc=true" {
  ( cd "$TMPDEV" && git init -q && git config user.email "t@x" && git config user.name "t" )
  _flip_commit_devdoc_true
  bash "$REPO/scripts/statusreport.sh" testproj
  run git -C "$TMPDEV" log --oneline -n1
  [ "$status" -eq 0 ]
  [[ "$output" == *"statusreport(testproj)"* ]]
}

@test "statusreport does not commit when commit_devdoc=false" {
  ( cd "$TMPDEV" && git init -q && git config user.email "t@x" && git config user.name "t" )
  # commit_devdoc default is already false in setup().
  bash "$REPO/scripts/statusreport.sh" testproj
  run git -C "$TMPDEV" log --oneline -n1
  [ "$status" -ne 0 ]
}

# --- #423: template resolves through the §12 registry (layers 1-3) -----------
# Helper: point [project.testproj.paths].statusreport_template at PATH.
_set_statusreport_template_override() {
  cat >> "$HOME/.claude/devagent/config.toml" <<EOF

[project.testproj.paths]
statusreport_template = "$1"
EOF
}

@test "statusreport honors [project.X.paths].statusreport_template (layer 1 wins over devdoc)" {
  # Seed a devdoc template (layer 2) that would win under the pre-fix loop...
  mkdir -p "$TMPDEV/templates"
  printf '# %s — DEVDOC_MARKER_423\nStuck: {{STUCK_COUNT}}\n' '{{PROJECT}}' \
    > "$TMPDEV/templates/statusreport_template.md"
  # ...and a config-paths override (layer 1) carrying a UNIQUE sentinel.
  printf '# %s — SENTINEL_OVERRIDE_423\nStuck: {{STUCK_COUNT}}\n' '{{PROJECT}}' \
    > "$TMPROOT/custom_sr_template.md"
  _set_statusreport_template_override "$TMPROOT/custom_sr_template.md"

  run bash "$REPO/scripts/statusreport.sh" testproj
  [ "$status" -eq 0 ]
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "SENTINEL_OVERRIDE_423" "$report"   # layer 1 rendered
  run grep -q "DEVDOC_MARKER_423" "$report"
  [ "$status" -ne 0 ]                          # layer 2 did NOT win
}

@test "statusreport warns and falls through when the configured override file is missing" {
  _set_statusreport_template_override "$TMPROOT/does_not_exist_sr_template.md"
  run bash "$REPO/scripts/statusreport.sh" testproj
  [ "$status" -eq 0 ]                                  # falls through to plugin layer
  [[ "$output" == *"configured override for 'statusreport_template' not found"* ]]
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  [ -n "$report" ]                                     # report still rendered
}

@test "statusreport resolves a devdoc-layer template with no config override (regression)" {
  mkdir -p "$TMPDEV/templates"
  printf '# %s — DEVDOC_ONLY_423\nStuck: {{STUCK_COUNT}}\n' '{{PROJECT}}' \
    > "$TMPDEV/templates/statusreport_template.md"
  run bash "$REPO/scripts/statusreport.sh" testproj
  [ "$status" -eq 0 ]
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "DEVDOC_ONLY_423" "$report"
}
