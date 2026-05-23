#!/usr/bin/env bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TMPDEV="$(mktemp -d)"
  TMPSTATE="$(mktemp -d)"
  export DEVAGENT_PROJECT="testproj"
  export DEVAGENT_DEVDOC_DIR="$TMPDEV"
  export DEVAGENT_STATE_DIR="$TMPSTATE"
  export DEVAGENT_PERM_COMMIT_DEVDOC="false"
  export DEVAGENT_STUB_LIB="$REPO/tests/fixtures/devagent_stubs"

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
  rm -rf "$TMPDEV" "$TMPSTATE"
}

@test "statusreport writes a dated report to <devdoc>/StatusReports/" {
  run bash "$REPO/scripts/statusreport.sh"
  [ "$status" -eq 0 ]
  found="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  [ -n "$found" ]
}

@test "statusreport detects stuck, failed-redteam, and idle issues" {
  bash "$REPO/scripts/statusreport.sh"
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "Issue-100" "$report"
  grep -q "Issue-101" "$report"
  grep -q "Issue-103" "$report"
}

@test "statusreport advances pin by default" {
  bash "$REPO/scripts/statusreport.sh"
  pin_file="$TMPSTATE/testproj.statusreport.toml"
  [ -f "$pin_file" ]
  grep -q '^last_pin' "$pin_file"
}

@test "statusreport --no-pin leaves pin unchanged" {
  pin_file="$TMPSTATE/testproj.statusreport.toml"
  echo 'last_pin = "2026-05-01T00:00:00+00:00"' > "$pin_file"
  bash "$REPO/scripts/statusreport.sh" --no-pin
  grep -q '2026-05-01T00:00:00' "$pin_file"
}

@test "statusreport reports velocity and estimate sections" {
  bash "$REPO/scripts/statusreport.sh"
  report="$(find "$TMPDEV/StatusReports" -name '*.md' | head -n1)"
  grep -q "Velocity & estimate" "$report"
  grep -q "Remaining WBS leaves" "$report"
}

@test "statusreport prints summary to stdout" {
  run bash "$REPO/scripts/statusreport.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status Report"* ]] || [[ "$output" == *"testproj"* ]]
}
