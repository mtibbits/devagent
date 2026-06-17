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

@test "scope.md exists, invokes core-scope, parses \$NOTE, logs" {
  F="$CMD_DIR/scope.md"
  [ -f "$F" ]
  grep -q 'core-scope' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "improve.md exists, invokes core-improve, parses \$NOTE, logs" {
  F="$CMD_DIR/improve.md"
  [ -f "$F" ]
  grep -q 'core-improve' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "prune.md exists, invokes core-prune, parses \$NOTE, logs" {
  F="$CMD_DIR/prune.md"
  [ -f "$F" ]
  grep -q 'core-prune' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "tighten.md exists, invokes core-tighten, parses \$NOTE, logs" {
  F="$CMD_DIR/tighten.md"
  [ -f "$F" ]
  grep -q 'core-tighten' "$F"
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

@test "document.md exists, invokes core-document-actual-work, parses \$NOTE, logs" {
  F="$CMD_DIR/document.md"
  [ -f "$F" ]
  grep -q 'core-document-actual-work' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "draftmr.md exists, invokes core-draft-mr, parses \$NOTE, logs" {
  F="$CMD_DIR/draftmr.md"
  [ -f "$F" ]
  grep -q 'core-draft-mr' "$F"
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

@test "redmr.md exists, invokes core-redmr, parses \$NOTE, logs" {
  F="$CMD_DIR/redmr.md"
  [ -f "$F" ]
  grep -q 'core-redmr' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "impact.md exists, invokes core-impact, parses \$NOTE, logs" {
  F="$CMD_DIR/impact.md"
  [ -f "$F" ]
  grep -q 'core-impact' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

@test "lessonslearned.md exists, invokes core-lessons-learned, parses \$NOTE, logs" {
  F="$CMD_DIR/lessonslearned.md"
  [ -f "$F" ]
  grep -q 'core-lessons-learned' "$F"
  grep -q '\$NOTE' "$F"
  grep -q 'checklist-log.sh' "$F"
}

# #114: the capture family must document a REAL env-derivation path, not a
# non-existent "Phase 1 config loader".
@test "capture.md documents the env-derivation sources, not a phantom loader (#114)" {
  F="$CMD_DIR/capture.md"
  grep -q 'CLAUDE_PLUGIN_ROOT' "$F"            # DEVAGENT_PLUGIN_DIR source
  grep -q 'config\.toml' "$F"                  # DEVAGENT_DEVDOC_DIR source
  grep -q 'devdoc_dir' "$F"
  grep -q 'active_project' "$F"                # DEVAGENT_PROJECT source (state)
  run grep -q 'Phase 1' "$F"                   # the phantom loader claim is gone
  [ "$status" -ne 0 ]
}

@test "file.md names the real push_mr env gate the script reads (#114)" {
  F="$CMD_DIR/file.md"
  grep -q 'DEVAGENT_PERMISSION_PUSH_MR' "$F"
}
