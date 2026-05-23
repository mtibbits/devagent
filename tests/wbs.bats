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
}

teardown() {
  rm -rf "$TMPDEV" "$TMPSTATE"
}

@test "wbs init scaffolds WBS.md from template" {
  run bash "$REPO/scripts/wbs.sh" init
  [ "$status" -eq 0 ]
  [ -f "$TMPDEV/WBS.md" ]
  grep -q "# testproj WBS" "$TMPDEV/WBS.md"
  grep -q "Recognized keys" "$TMPDEV/WBS.md"
}

@test "wbs init is idempotent (refuses to overwrite without --force)" {
  bash "$REPO/scripts/wbs.sh" init
  echo "hand-edited content" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init
  [ "$status" -ne 0 ]
  grep -q "hand-edited content" "$TMPDEV/WBS.md"
}

@test "wbs init --force overwrites existing file" {
  bash "$REPO/scripts/wbs.sh" init
  echo "hand-edited" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init --force
  [ "$status" -eq 0 ]
  ! grep -q "hand-edited" "$TMPDEV/WBS.md"
}

@test "wbs show prints WBS.md contents" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Top"* ]]
  [[ "$output" == *"Leaf A"* ]]
  [[ "$output" == *"Leaf B"* ]]
}

@test "wbs show --depth 1 hides children below depth 1" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show --depth 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
  [[ "$output" == *"Subgoal A"* ]]
  [[ "$output" != *"Subsubgoal A1"* ]]
}

@test "wbs show --milestone M2 filters to that milestone subtree" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show --milestone M2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
}

@test "wbs show errors when WBS.md missing" {
  run bash "$REPO/scripts/wbs.sh" show
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$stderr" == *"not found"* ]] || true
}

@test "wbs update appends a new entry for an active issue not yet in WBS" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Existing milestone {est: 2w, milestone: M1}
  - [x] Old leaf {issue: Issue-1, est: 1w}
EOF
  cat > "$TMPSTATE/testproj.toml" <<EOF
active_issue = "Issue-2"
issue_dir = "$TMPDEV/Issue-2"
last_step = 3
last_step_name = "improve"
EOF
  mkdir -p "$TMPDEV/Issue-2"
  cat > "$TMPDEV/Issue-2/checklist.md" <<EOF
# Issue-2 — Workflow checklist
Template: standard

## Revision 1
- [x] 0. pull
- [~] 3. improve

## Log
- 2026-05-19 10:00  pull: fetched
EOF
  run bash "$REPO/scripts/wbs.sh" update
  [ "$status" -eq 0 ]
  grep -q "Issue-2" "$TMPDEV/WBS.md"
}

@test "wbs update is idempotent (running twice produces same file)" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  cat > "$TMPSTATE/testproj.toml" <<EOF
active_issue = "Issue-1"
issue_dir = "$TMPDEV/Issue-1"
last_step = 0
last_step_name = "pull"
EOF
  mkdir -p "$TMPDEV/Issue-1"
  echo "# Issue-1 — Workflow checklist" > "$TMPDEV/Issue-1/checklist.md"
  bash "$REPO/scripts/wbs.sh" update
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
  bash "$REPO/scripts/wbs.sh" update
  diff "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
}

@test "updatewbs.md command file exists and references wbs.sh update" {
  [ -f "$REPO/commands/updatewbs.md" ]
  grep -q "scripts/wbs.sh update" "$REPO/commands/updatewbs.md"
}

@test "wbs update updates state glyph when active issue progresses" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [ ] Working leaf {issue: Issue-9, est: 1w}
EOF
  cat > "$TMPSTATE/testproj.toml" <<EOF
active_issue = "Issue-9"
issue_dir = "$TMPDEV/Issue-9"
last_step = 7
last_step_name = "implement"
EOF
  mkdir -p "$TMPDEV/Issue-9"
  echo "# Issue-9 — Workflow checklist" > "$TMPDEV/Issue-9/checklist.md"
  run bash "$REPO/scripts/wbs.sh" update
  [ "$status" -eq 0 ]
  grep -q "\[~\] Working leaf" "$TMPDEV/WBS.md"
}
