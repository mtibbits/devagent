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

@test "prune.md exists, invokes devagent-prune, parses \$NOTE, logs" {
  F="$CMD_DIR/prune.md"
  [ -f "$F" ]
  grep -q 'devagent-prune' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "tighten.md exists, invokes devagent-tighten, parses \$NOTE, logs" {
  F="$CMD_DIR/tighten.md"
  [ -f "$F" ]
  grep -q 'devagent-tighten' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "implement.md exists, invokes superpowers:executing-plans, parses \$NOTE, logs" {
  F="$CMD_DIR/implement.md"
  [ -f "$F" ]
  grep -q 'superpowers:executing-plans' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "quality.md exists, invokes simplify, references coding_standards.md, logs" {
  F="$CMD_DIR/quality.md"
  [ -f "$F" ]
  grep -q 'simplify' "$F"
  grep -q 'coding_standards' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "document.md exists, invokes devagent-document-actual-work, parses \$NOTE, logs" {
  F="$CMD_DIR/document.md"
  [ -f "$F" ]
  grep -q 'devagent-document-actual-work' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "draftmr.md exists, invokes devagent-draft-mr, parses \$NOTE, logs" {
  F="$CMD_DIR/draftmr.md"
  [ -f "$F" ]
  grep -q 'devagent-draft-mr' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "review.md exists, invokes superpowers:requesting-code-review, logs" {
  F="$CMD_DIR/review.md"
  [ -f "$F" ]
  grep -q 'superpowers:requesting-code-review' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "redmr.md exists, invokes devagent-redmr, parses \$NOTE, logs" {
  F="$CMD_DIR/redmr.md"
  [ -f "$F" ]
  grep -q 'devagent-redmr' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "impact.md exists, invokes devagent-impact, parses \$NOTE, logs" {
  F="$CMD_DIR/impact.md"
  [ -f "$F" ]
  grep -q 'devagent-impact' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}
