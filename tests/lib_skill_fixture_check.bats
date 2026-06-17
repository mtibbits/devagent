#!/usr/bin/env bats

setup() {
  HARNESS="$BATS_TEST_DIRNAME/lib/skill-fixture-check.sh"
  TMP="$(mktemp -d)"
  export TMP
}

teardown() {
  rm -rf "$TMP"
}

@test "harness rejects missing SKILL.md" {
  run bash "$HARNESS" "$TMP/no-such-skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SKILL.md not found"* ]]
}

@test "harness rejects SKILL.md missing frontmatter name field" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
description: stub
---
# Skill
## Checklist
1. step
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"frontmatter missing: name"* ]]
}

@test "harness rejects SKILL.md missing Checklist section" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: x
description: Use when y
---
# Skill
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Checklist section missing"* ]]
}

@test "harness rejects SKILL.md missing checklist-log invocation" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: x
description: Use when y
---
# Skill
## Checklist
1. do thing
## Halt
If unsure ask the operator.
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing checklist-log invocation"* ]]
}

@test "harness accepts a valid SKILL.md" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: x
description: Use when y
---
# Skill
## Checklist
1. do thing
## Halt
If unsure, halt and ask the operator.
## Logging
Run ${CLAUDE_PLUGIN_ROOT}/scripts/checklist-log.sh "$ISSUE_DIR" stepname "msg"
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -eq 0 ]
}

@test "harness rejects an unprefixed checklist-log invocation (#131)" {
  mkdir -p "$TMP/skill" "$TMP/fixture"
  cat > "$TMP/skill/SKILL.md" <<'EOF'
---
name: x
description: Use when y
---
# Skill
## Checklist
1. do thing
## Halt
If unsure, halt and ask the operator.
## Logging
Run scripts/checklist-log.sh "$ISSUE_DIR" stepname "msg"
EOF
  run bash "$HARNESS" "$TMP/skill" "$TMP/fixture"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_PLUGIN_ROOT"* ]]
}
