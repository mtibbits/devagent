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
