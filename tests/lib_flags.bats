#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  source "$PLUGIN_ROOT/scripts/lib/flags.sh"
  MD="$BATS_TEST_TMPDIR/issue.md"
  cat > "$MD" <<'EOF'
# repo#1 — demo

- State: open

---

Intro prose.

## Workflow flags
tier: oneshot
future-key: something

## Motivation
tier: bogus-in-prose

---

## Comments (1)

### @bob
quoting a block:
## Workflow flags
tier: research
EOF
}

@test "flags_get reads tier from the body flags block (#537)" {
  run flags_get "$MD" tier
  [ "$status" -eq 0 ]
  [ "$output" = "oneshot" ]
}

@test "flags_get ignores a flags block quoted in comments (#537)" {
  MD2="$BATS_TEST_TMPDIR/comment-only.md"
  cat > "$MD2" <<'EOF'
# repo#2 — demo

---

Body with no flags block.

---

## Comments (1)

### @bob
quoting a block:
## Workflow flags
tier: research
EOF
  run flags_get "$MD2" tier
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "flags_get is key-scoped: unknown keys ride along untouched (#537)" {
  run flags_get "$MD" future-key
  [ "$status" -eq 0 ]
  [ "$output" = "something" ]
}

@test "flags_get returns 1 on missing file or absent block (#537)" {
  run flags_get "$BATS_TEST_TMPDIR/nope.md" tier
  [ "$status" -ne 0 ]
}

@test "tier_is_legal accepts registered tiers, rejects reserved and bogus (#537)" {
  tier_is_legal oneshot
  tier_is_legal docs-only
  run tier_is_legal simple
  [ "$status" -ne 0 ]
  run tier_is_legal ultra
  [ "$status" -ne 0 ]
  run tier_is_legal ../evil
  [ "$status" -ne 0 ]
}

@test "flags_get ignores a Workflow-flags block inside an HTML comment (#537 redmr)" {
  MD3="$BATS_TEST_TMPDIR/commented.md"
  cat > "$MD3" <<'FIXTURE'
# repo#3 — demo

---

Body text.

<!-- Optional per-issue workflow tier (spec §6.3 tier table; delete if unused):
## Workflow flags
tier: oneshot
-->

More body.

---

## Comments (0)
FIXTURE
  run flags_get "$MD3" tier
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "flags_get returns a trailing-annotated value verbatim (bare-value grammar, downstream fail-closed) (#537 redmr)" {
  MD4="$BATS_TEST_TMPDIR/annotated.md"
  cat > "$MD4" <<'FIXTURE'
## Workflow flags
tier: oneshot   # run the Q3 release
FIXTURE
  run flags_get "$MD4" tier
  [ "$status" -eq 0 ]
  [ "$output" = "oneshot   # run the Q3 release" ]
}

# --- #535: flags_validate (block-level unknown-key WARN, deferred from #537) ---

@test "flags_known_keys is the single source: tier + research + spike (#535/#536)" {
  run flags_known_keys
  [ "$output" = "tier research spike" ]
}

@test "flags_validate is silent when only known keys are present (#535)" {
  local f="$BATS_TEST_TMPDIR/known.md"
  printf '## Workflow flags\ntier: perf\nresearch: required\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "flags_validate warns (stderr) on an unknown key, naming it (#535)" {
  local f="$BATS_TEST_TMPDIR/unk.md"
  printf '## Workflow flags\nresearch: required\nboguskey: x\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]                       # non-fatal (forward-compat)
  [[ "$output" == *"boguskey"* ]]           # named
  [[ "$output" != *"research"* ]]           # known key NOT warned (exact negative)
}

@test "flags_validate is silent when the flags block is absent (#535)" {
  local f="$BATS_TEST_TMPDIR/noblock.md"
  printf '# Title\n\nOrdinary body, no flags.\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "flags_validate does not enumerate keys inside an HTML comment or below Comments (#535)" {
  local f="$BATS_TEST_TMPDIR/comment.md"
  # The SECOND flags block sits below `## Comments (` — without the Comments exit it
  # would re-open the block and `belowkey` WOULD warn, so this half is falsifiable.
  printf '<!--\n## Workflow flags\ncommentedkey: x\n-->\n## Workflow flags\nresearch: required\n## Comments (1)\n## Workflow flags\nbelowkey: y\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"commentedkey"* ]]       # HTML-comment key not enumerated
  [[ "$output" != *"belowkey"* ]]           # below `## Comments (` not enumerated
}

@test "flags_validate does not treat a value-continuation/indented line as a key (#535)" {
  local f="$BATS_TEST_TMPDIR/cont.md"
  printf '## Workflow flags\nresearch: required\n  indented: notakey\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"indented"* ]]           # col>1, not a key (exact negative)
}

@test "the flags block is contiguous: col-1 prose after a blank line is NOT a flag (#535 review)" {
  local f="$BATS_TEST_TMPDIR/contig.md"
  printf '## Workflow flags\ntier: standard\n\nSome prose paragraph.\nresearch: required\ndepends: 536\n' > "$f"
  # flags_get must NOT read the post-blank prose line as a flag (this MIS-FLIPPED row 22)
  run flags_get "$f" research
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # and the enumerator must not spuriously warn about the prose key
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"depends"* ]]
  # the real in-block key still reads
  run flags_get "$f" tier
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "markdown-conventional block (heading, BLANK line, keys) still parses — tier regression guard (#535 redmr)" {
  local f="$BATS_TEST_TMPDIR/blankafter.md"
  printf '## Workflow flags\n\ntier: oneshot\nresearch: required\n\nBody prose.\ndepends: 536\n' > "$f"
  # #537's shipped tier flag MUST survive (this form is what GitHub's editor produces)
  run flags_get "$f" tier
  [ "$status" -eq 0 ]
  [ "$output" = "oneshot" ]
  run flags_get "$f" research
  [ "$status" -eq 0 ]
  [ "$output" = "required" ]
  # ...and post-block prose is still not enumerated
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"depends"* ]]
}
