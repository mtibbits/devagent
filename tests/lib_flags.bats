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

# --- #561: per-issue model steering keys, the tier shim, and the label channel

@test "flags_known_keys gains the two model keys and keeps the shipped three (#561)" {
  run flags_known_keys
  [ "$status" -eq 0 ]
  [[ " $output " == *" implementation-model "* ]]
  [[ " $output " == *" checking-model "* ]]
  [[ " $output " == *" tier "* ]]
  [[ " $output " == *" research "* ]]
  [[ " $output " == *" spike "* ]]
}

@test "model_token_allowlist is the Agent enum plus reserved inherit (#561)" {
  run model_token_allowlist
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet opus haiku fable inherit" ]
}

@test "model_token_is_legal accepts every token, rejects bogus/empty/prose/path (#561)" {
  model_token_is_legal sonnet
  model_token_is_legal opus
  model_token_is_legal haiku
  model_token_is_legal fable
  model_token_is_legal inherit
  run model_token_is_legal bogus
  [ "$status" -ne 0 ]
  run model_token_is_legal ""
  [ "$status" -ne 0 ]
  # trailing inline prose is part of the value (bare-value grammar) -> illegal
  run model_token_is_legal "opus trailing prose"
  [ "$status" -ne 0 ]
  run model_token_is_legal "../evil"
  [ "$status" -ne 0 ]
}

@test "model_token_require_legal dies with the single-sourced token list (#561)" {
  # the helper uses whatever die() is in the caller's scope (tier_require_legal
  # contract), so the test supplies one and asserts the message names every token
  die() { echo "$*" >&2; return 1; }
  run model_token_require_legal bogus " in ## Workflow flags"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown model token 'bogus'"* ]]
  [[ "$output" == *"in ## Workflow flags"* ]]
  [[ "$output" == *"sonnet opus haiku fable inherit"* ]]
  # a legal token is silent and succeeds
  run model_token_require_legal fable
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tier_shim_model maps <model>-checking, rejects everything else (#561)" {
  run tier_shim_model opus-checking
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
  run tier_shim_model fable-checking
  [ "$status" -eq 0 ]
  [ "$output" = "fable" ]
  # NOT a shim -> rc 1 so the caller falls through to tier_require_legal
  run tier_shim_model bogus-checking
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run tier_shim_model oneshot
  [ "$status" -eq 1 ]
  run tier_shim_model -checking
  [ "$status" -eq 1 ]
  run tier_shim_model ""
  [ "$status" -eq 1 ]
}

@test "issue_labels reads the header - Labels: line, both backend separators (#561)" {
  local f="$BATS_TEST_TMPDIR/labels-gh.md"
  # scripts/issue/github.sh joins on ', '
  printf -- '# repo#1 — demo\n\n- State: open\n- Labels: tier:impl-opus, tier:check-fable\n\n---\n\nBody.\n' > "$f"
  run issue_labels "$f"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tier:impl-opus" ]
  [ "${lines[1]}" = "tier:check-fable" ]
  [ "${#lines[@]}" -eq 2 ]
  # scripts/issue/gitlab.sh and jira.sh join on bare ','
  local g="$BATS_TEST_TMPDIR/labels-gl.md"
  printf -- '- Labels: bug,tier:check-opus\n\n---\nBody.\n' > "$g"
  run issue_labels "$g"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "bug" ]
  [ "${lines[1]}" = "tier:check-opus" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "issue_labels: an empty label line and a missing file both yield nothing (#561)" {
  local f="$BATS_TEST_TMPDIR/labels-empty.md"
  printf -- '- Labels: \n\n---\nBody.\n' > "$f"
  run issue_labels "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run issue_labels "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "issue_labels is HEADER-SEGMENT ONLY — body, comment, and second lines cannot steer (#561)" {
  # Each case asserts the header label IS still read, so a function that simply
  # returned nothing would fail: the negative is paired with a positive.
  local body="$BATS_TEST_TMPDIR/labels-body.md"
  printf -- '- Labels: bug\n\n---\n\nProse.\n- Labels: tier:check-opus\n' > "$body"
  run issue_labels "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "bug" ]

  local cmt="$BATS_TEST_TMPDIR/labels-comment.md"
  printf -- '- Labels: bug\n\n---\n\n## Comments (1)\n\n### @bob\n- Labels: tier:check-opus\n' > "$cmt"
  run issue_labels "$cmt"
  [ "$status" -eq 0 ]
  [ "$output" = "bug" ]

  # a SECOND - Labels: line inside the header: first wins, second is dead
  local two="$BATS_TEST_TMPDIR/labels-second.md"
  printf -- '- Labels: bug\n- Labels: tier:check-opus\n\n---\nBody.\n' > "$two"
  run issue_labels "$two"
  [ "$status" -eq 0 ]
  [ "$output" = "bug" ]
}

@test "duplicate tier: lines are FIRST-match-wins — AC10 pin of existing behavior (#561)" {
  # PIN, not a born-red claim: flags_get exits on the first match, so this is
  # green at HEAD by construction. A body combining a template tier with a model
  # annotation must use tier: + checking-model:, one line each.
  local f="$BATS_TEST_TMPDIR/dup-tier.md"
  printf -- '## Workflow flags\ntier: opus-checking\ntier: oneshot\n\n## Motivation\nx\n' > "$f"
  run flags_get "$f" tier
  [ "$status" -eq 0 ]
  [ "$output" = "opus-checking" ]
}
