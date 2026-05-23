#!/usr/bin/env bats

CMD_DIR="$BATS_TEST_DIRNAME/../commands"

@test "draft.md exists and is non-empty" {
  [ -f "$CMD_DIR/draft.md" ]
  [ -s "$CMD_DIR/draft.md" ]
}

@test "draft.md documents \$NOTE parsing per spec §6.1" {
  grep -qE '\$NOTE' "$CMD_DIR/draft.md"
  grep -qE 'project|issue' "$CMD_DIR/draft.md"
}

@test "draft.md references the wrapped skill (superpowers:writing-plans)" {
  grep -q 'superpowers:writing-plans' "$CMD_DIR/draft.md"
}

@test "draft.md instructs the model to append a checklist log entry" {
  grep -q 'checklist-log.sh' "$CMD_DIR/draft.md"
}

@test "scope.md exists, invokes devagent-scope, parses \$NOTE, logs" {
  F="$CMD_DIR/scope.md"
  [ -f "$F" ]
  grep -q 'devagent-scope' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "improve.md exists, invokes devagent-improve, parses \$NOTE, logs" {
  F="$CMD_DIR/improve.md"
  [ -f "$F" ]
  grep -q 'devagent-improve' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
