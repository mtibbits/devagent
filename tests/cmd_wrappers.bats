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

@test "draft.md instructs the pothole-register read + Potholes considered section (#286)" {
  grep -q 'potholes' "$CMD_DIR/draft.md"
  grep -q '## Potholes considered' "$CMD_DIR/draft.md"
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
@test "capture skill documents the env-derivation sources, not a phantom loader (#114)" {
  F="$BATS_TEST_DIRNAME/../skills/capture/SKILL.md"
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

# #133: a prerequisite whose producing step is absent from the issue's checklist
# must be treated as N/A, not halted on (docs-only omits analyze → draftmr; research
# omits branch → document).
@test "draftmr.md treats absent analyze step as N/A, not a halt (#133)" {
  F="$CMD_DIR/draftmr.md"
  grep -q 'absent from the issue' "$F"
  grep -q 'N/A' "$F"
  grep -qi 'docs-only' "$F"
}

@test "document.md treats absent branch step as N/A, not a halt (#133)" {
  F="$CMD_DIR/document.md"
  grep -q 'absent from the issue' "$F"
  grep -q 'N/A' "$F"
  grep -qi 'research' "$F"
}

@test "core-draft-mr and core-document-actual-work mirror the N/A carve-out (#133)" {
  grep -q 'absent from the issue' "$BATS_TEST_DIRNAME/../skills/core-draft-mr/SKILL.md"
  grep -q 'absent from the issue' "$BATS_TEST_DIRNAME/../skills/core-document-actual-work/SKILL.md"
}

@test "preship.md exists, invokes core-preship, documents stuck + tier resolution (#149)" {
  F="$CMD_DIR/preship.md"
  [ -s "$F" ]
  grep -q 'core-preship' "$F"
  grep -q 'checklist-stuck.sh' "$F"
  grep -q 'step-model.sh' "$F"
  # Must NOT be a full dispatch-contract carrier (that lives in the skill);
  # the sweep filters carriers by this heading.
  run grep -q '^## Dispatch contract' "$F"
  [ "$status" -ne 0 ]
}

@test "command count matches the documented totals (#149)" {
  # Derived count — a new command that forgets the README/marketplace sweep
  # fails here instead of drifting silently (the '53 commands' class).
  # #452: next/capture/ship live as user-invocable skills; the skill half is
  # derived from the user-invocable frontmatter marker (core-* are pinned
  # `user-invocable: false`), so an unmarked core skill fails here too.
  # Assert the SPLIT, not just the sum: a 4th command->skill conversion keeps
  # the sum at 55 (51+4) and would slip through a sum-only check — while
  # falsifying README's explicit "52 commands + 3 user-invocable skills".
  n="$(ls "$CMD_DIR"/*.md | wc -l)"
  s="$(grep -L '^user-invocable: false' "$BATS_TEST_DIRNAME"/../skills/*/SKILL.md | wc -l)"
  [ "$n" -eq 52 ]
  [ "$s" -eq 3 ]
  [ $((n + s)) -eq 55 ]
  grep -q "55 slash commands" "$CMD_DIR/../README.md"
  # BOTH manifests carry the claim (#439 plan's enumeration); plugin.json was
  # unpinned while marketplace.json was, so the two could drift apart.
  grep -q "55 slash commands" "$CMD_DIR/../.claude-plugin/marketplace.json"
  grep -q "55 slash commands" "$CMD_DIR/../.claude-plugin/plugin.json"
}
