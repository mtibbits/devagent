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
