#!/usr/bin/env bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

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
  sed -i "s|^commit_devdoc *=.*|commit_devdoc      = true|" \
    "$HOME/.claude/devagent/config.toml"
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
