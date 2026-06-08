#!/usr/bin/env bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TMPROOT="$(mktemp -d)"
  TMPDEV="$TMPROOT/devdoc"
  mkdir -p "$TMPDEV"
  export HOME="$TMPROOT/home"
  mkdir -p "$HOME/.claude/devagent/state" "$HOME/.claude/devagent/secrets"

  # Minimum config: testproj points devdoc at $TMPDEV.
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
}

teardown() {
  rm -rf "$TMPROOT"
}

# Helper: write an arbitrary scalar to the project state via the
# production toml helper (the script reads via state_get).
_state_set() {
  local key="$1" value="$2"
  python3 "$REPO/scripts/lib/_toml.py" set \
    "$HOME/.claude/devagent/state/testproj.toml" "$key" "\"$value\""
}
_state_set_int() {
  local key="$1" value="$2"
  python3 "$REPO/scripts/lib/_toml.py" set-int \
    "$HOME/.claude/devagent/state/testproj.toml" "$key" "$value"
}
_init_state() {
  # state_init from lib/state.sh handles the touch + initial keys.
  bash -c "source $REPO/scripts/lib/paths.sh; \
           source $REPO/scripts/lib/io.sh; \
           source $REPO/scripts/lib/state.sh; \
           state_init testproj"
}

@test "wbs init scaffolds WBS.md from template" {
  run bash "$REPO/scripts/wbs.sh" init testproj
  [ "$status" -eq 0 ]
  [ -f "$TMPDEV/WBS.md" ]
  grep -q "# testproj WBS" "$TMPDEV/WBS.md"
  grep -q "Recognized keys" "$TMPDEV/WBS.md"
}

@test "wbs init resolves project from single-project config when no arg" {
  run bash "$REPO/scripts/wbs.sh" init
  [ "$status" -eq 0 ]
  [ -f "$TMPDEV/WBS.md" ]
  grep -q "# testproj WBS" "$TMPDEV/WBS.md"
}

@test "wbs init is idempotent (refuses to overwrite without --force)" {
  bash "$REPO/scripts/wbs.sh" init testproj
  echo "hand-edited content" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init testproj
  [ "$status" -ne 0 ]
  grep -q "hand-edited content" "$TMPDEV/WBS.md"
}

@test "wbs init --force overwrites existing file" {
  bash "$REPO/scripts/wbs.sh" init testproj
  echo "hand-edited" >> "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" init testproj --force
  [ "$status" -eq 0 ]
  run grep -q "hand-edited" "$TMPDEV/WBS.md"
  [ "$status" -ne 0 ]
}

@test "wbs show prints WBS.md contents" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj
  [ "$status" -eq 0 ]
  [[ "$output" == *"Top"* ]]
  [[ "$output" == *"Leaf A"* ]]
  [[ "$output" == *"Leaf B"* ]]
}

@test "wbs show --depth 1 hides children below depth 1" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj --depth 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
  [[ "$output" == *"Subgoal A"* ]]
  [[ "$output" != *"Subsubgoal A1"* ]]
}

@test "wbs show --milestone M2 filters to that milestone subtree" {
  cp "$REPO/tests/fixtures/wbs/nested.md" "$TMPDEV/WBS.md"
  run bash "$REPO/scripts/wbs.sh" show testproj --milestone M2
  [ "$status" -eq 0 ]
  [[ "$output" == *"Root"* ]]
}

@test "wbs show errors when WBS.md missing" {
  run bash "$REPO/scripts/wbs.sh" show testproj
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "wbs update appends a new entry for an active issue not yet in WBS" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Existing milestone {est: 2w, milestone: M1}
  - [x] Old leaf {issue: Issue-1, est: 1w}
EOF
  _init_state
  _state_set active_issue "Issue-2"
  _state_set issue_dir "$TMPDEV/Issue-2"
  _state_set_int last_step 3
  _state_set last_step_name "improve"
  mkdir -p "$TMPDEV/Issue-2"
  cat > "$TMPDEV/Issue-2/checklist.md" <<'EOF'
# Issue-2 — Workflow checklist
Template: standard

## Revision 1
- [x] 0. pull
- [~] 3. improve

## Log
- 2026-05-19 10:00  pull: fetched
EOF
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  grep -q "Issue-2" "$TMPDEV/WBS.md"
}

@test "wbs update is idempotent (running twice produces same file)" {
  cp "$REPO/tests/fixtures/wbs/simple.md" "$TMPDEV/WBS.md"
  _init_state
  _state_set active_issue "Issue-1"
  _state_set issue_dir "$TMPDEV/Issue-1"
  _state_set_int last_step 0
  _state_set last_step_name "pull"
  mkdir -p "$TMPDEV/Issue-1"
  echo "# Issue-1 — Workflow checklist" > "$TMPDEV/Issue-1/checklist.md"
  bash "$REPO/scripts/wbs.sh" update testproj
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
  bash "$REPO/scripts/wbs.sh" update testproj
  diff "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
}

@test "updatewbs.md command file exists and references wbs.sh update" {
  [ -f "$REPO/commands/updatewbs.md" ]
  grep -q "scripts/wbs.sh update" "$REPO/commands/updatewbs.md"
}

@test "wbs update reconciles in-progress leaf from checklist truth" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [ ] Working leaf {issue: Issue-9, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-9"
  cat > "$TMPDEV/Issue-9/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [~]  7. implement
- [ ] 11. analyze
EOF
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  grep -q "\[~\] Working leaf" "$TMPDEV/WBS.md"
}

@test "wbs update reconciles done leaf when all steps complete (works AFTER active_issue cleared)" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [~] Working leaf {issue: Issue-9, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-9"
  cat > "$TMPDEV/Issue-9/checklist.md" <<'EOF'
- [x]  0. pull
- [x]  1. draft
- [x]  7. implement
- [x] 11. analyze
- [x] 20. cleanup
EOF
  # Note: NO active_issue set. Mimics the post-cleanup state where the
  # operator runs wbs update and the issue's leaf must still flip to [x].
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -eq 0 ]
  grep -q "\[x\] Working leaf" "$TMPDEV/WBS.md"
}

@test "wbs update is idempotent (no spurious diff on a fully-reconciled WBS)" {
  cat > "$TMPDEV/WBS.md" <<EOF
# testproj WBS

- [ ] Plan {est: 1w}
  - [x] Done leaf {issue: Issue-3, est: 1w}
EOF
  mkdir -p "$TMPDEV/Issue-3"
  cat > "$TMPDEV/Issue-3/checklist.md" <<'EOF'
- [x]  0. pull
- [x] 20. cleanup
EOF
  bash "$REPO/scripts/wbs.sh" update testproj
  cp "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
  bash "$REPO/scripts/wbs.sh" update testproj
  diff "$TMPDEV/WBS.md" "$TMPDEV/WBS.md.first"
}

@test "wbs update --if-exists silently no-ops when WBS.md missing" {
  # No WBS.md created.
  run bash "$REPO/scripts/wbs.sh" update testproj --if-exists
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wbs update (no --if-exists) errors when WBS.md missing" {
  run bash "$REPO/scripts/wbs.sh" update testproj
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"* ]]
}
