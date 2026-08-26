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

@test "flags_known_keys is the single source: tier + research + spike + model keys (#535/#536/#561)" {
  run flags_known_keys
  # EXACT match, deliberately: this is the single-source list, and an exact
  # assertion is what forces a consumer adding a key to come here. #561 appended
  # the two model-steering keys.
  [ "$output" = "tier research spike implementation-model checking-model" ]
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

# --- #553: an EMPTY `## Workflow flags` heading must not leave the block open ------
#
# Test names in this section are deliberately ASCII-only (no em dash, no section
# sign): a locale-empty shell makes bats fail to REGISTER a test whose name carries
# non-ASCII bytes, and a guard that silently never runs is worse than no guard.

@test "flags_get: an empty flags heading followed by prose does not parse a later col-1 key (#553)" {
  local f="$BATS_TEST_TMPDIR/empty-heading-prose.md"
  printf '## Workflow flags\n\nsome prose\nresearch: required\ntier: oneshot\n' > "$f"
  # BOTH keys sit in prose position, so a pass here proves the BLOCK closed rather
  # than that one key happens to be special.
  run flags_get "$f" research
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run flags_get "$f" tier
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "flags_get: the fenced example in issue 553's own body does not parse (#553)" {
  # FENCE-BLIND ON PURPOSE. This guard must pass on the empty-block rule alone.
  # Teaching the scanner to skip ``` fences is a deliberately REJECTED alternative
  # for #553 (recorded in the issue's future-enhancements file), so do not "improve"
  # this into a fence test -- doing so would silently move a rejected alternative
  # into shipped scope and stop testing the rule this file is guarding.
  local f="$BATS_TEST_TMPDIR/fenced-example.md"
  cat > "$f" <<'FIXTURE'
## Finding

Residual: an empty flags heading followed by prose still parses a later col-1
key as a flag:

```
## Workflow flags

some prose
research: required        <- parsed as a flag today
```

## Why this is its own issue
Prose.
FIXTURE
  run flags_get "$f" research
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "flags_validate: an empty flags heading followed by prose enumerates no keys (#553)" {
  # The flags_validate half of the same defect. It exists so that reverting the
  # rule in ONE machine reddens something: G1/G3 cover flags_get, this covers
  # flags_validate, and neither can pass on the other's coverage.
  local f="$BATS_TEST_TMPDIR/validate-empty-heading.md"
  printf '## Workflow flags\n\nsome prose\nboguskey: x\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"boguskey"* ]]
}

@test "flags_get: heading plus BLANK plus keys still parses all five known keys (#553 regression PIN)" {
  # PIN, not a born-red claim: this is green at HEAD by construction. Its evidence
  # is the candidate-B mutation (M3), which drops every key in this shape -- the
  # exact #535 redmr regression the seen gate was added to prevent.
  #
  # Extends the tier-only guard above to all five shipped keys. The two model keys
  # are DIE-class in pull.sh, so a regression there is a hard pull failure rather
  # than a silently dropped flag.
  local f="$BATS_TEST_TMPDIR/conventional-five.md"
  printf '## Workflow flags\n\ntier: oneshot\nresearch: required\nspike: required\nimplementation-model: sonnet\nchecking-model: fable\n' > "$f"
  run flags_get "$f" tier
  [ "$status" -eq 0 ]
  [ "$output" = "oneshot" ]
  run flags_get "$f" research
  [ "$status" -eq 0 ]
  [ "$output" = "required" ]
  run flags_get "$f" spike
  [ "$status" -eq 0 ]
  [ "$output" = "required" ]
  run flags_get "$f" implementation-model
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
  run flags_get "$f" checking-model
  [ "$status" -eq 0 ]
  [ "$output" = "fable" ]
}

@test "flags.sh: the empty-block rule appears in BOTH state machines (#553 anti-drift)" {
  # Anti-drift sweep: flags_get and flags_validate carry the same block scanner by
  # house idiom, and the fix has to land in both. Asserts an exact count of 2
  # (never -ne 0, which conflates "clean" with "grep errored").
  #
  # BLIND SPOT, stated deliberately: this proves the rule TEXT is present twice, NOT
  # that the two awk programs are semantically identical -- G1/G3 and G2 own the
  # behavioural halves, one per machine. The pattern is whitespace-tolerant so
  # reformatting the assignment does not disarm it (see M4).
  run grep -cE 'inblock[[:space:]]*&&[[:space:]]*!seen[[:space:]]*&&' "$PLUGIN_ROOT/scripts/lib/flags.sh"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "flags_get: an INDENTED first in-block line closes the block too, not just col-1 prose (#553)" {
  # Pins the half of the rule's predicate that the other guards leave free. Every
  # other #553 block-closing fixture uses a COL-1 non-key line, so a rule narrowed
  # to `close only on col-1 non-keys` would keep them all green while making four
  # doc homes false (flags.sh header and flags_validate docblock, spec 6.3,
  # CHANGELOG all say an INDENTED line ends the block) and leaving the defect live
  # for this shape. Found by red-team: the mutation matrix proves a DELETED rule is
  # caught, not that the shipped predicate is the one documented.
  local f="$BATS_TEST_TMPDIR/indented-first.md"
  printf '## Workflow flags\n\n  indented prose\nresearch: required\ntier: oneshot\n' > "$f"
  run flags_get "$f" research
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run flags_get "$f" tier
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- #582: markdown fence awareness -------------------------------------------
#
# ASCII-only test names on purpose (see the #553 note above).

@test "flags_get: a FENCED Workflow-flags heading plus col-1 keys is documentation, not config (#582)" {
  # AC1 born-red. At HEAD this fixture parses LIVE: flags_get prints 'required' rc 0.
  # Paired with a positive so a scanner that simply returned nothing cannot pass
  # (register: Issue-318 / Issue-572).
  local f="$BATS_TEST_TMPDIR/fenced-heading-keys.md"
  cat > "$f" <<'FIXTURE'
Documented example of the grammar:

```
## Workflow flags
tier: oneshot
research: required
```

## Workflow flags
tier: perf
FIXTURE
  run flags_get "$f" research
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # the UNFENCED block below it still parses -- the negative is paired
  run flags_get "$f" tier
  [ "$status" -eq 0 ]
  [ "$output" = "perf" ]
}

@test "flags_get: a fence opened INSIDE a live block ends it; in-fence keys never parse (#582)" {
  local f="$BATS_TEST_TMPDIR/fence-inside-block.md"
  cat > "$f" <<'FIXTURE'
## Workflow flags
tier: standard
```
checking-model: opus
```
spike: required
FIXTURE
  # the pre-fence key still reads (positive half)
  run flags_get "$f" tier
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
  # the in-fence key does NOT (prints 'opus' rc 0 at HEAD)
  run flags_get "$f" checking-model
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # and the block does not resume after the closing fence
  run flags_get "$f" spike
  [ "$status" -ne 0 ]
}

@test "flags_validate: a fenced block's keys are not enumerated (#582 twin half)" {
  # The flags_validate half of the same defect, so reverting the fence rule in ONE
  # machine reddens something behavioural (the #553 M2 discipline).
  local f="$BATS_TEST_TMPDIR/fenced-validate.md"
  printf '```\n## Workflow flags\nboguskey: x\n```\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"boguskey"* ]]
}

@test "flags.sh: the fence rule appears in BOTH state machines (#582 anti-drift)" {
  # Shaped exactly like the #553 anti-drift count: asserts -eq 2, never -ne 0, which
  # would conflate "clean" with "grep errored" (register: Issue-337).
  # BLIND SPOT, stated deliberately: this proves the rule TEXT is present twice, NOT
  # that the two awk programs are semantically identical -- N1/N2 and N3 own the
  # behavioural halves, one per machine.
  run grep -cE 'fence[[:space:]]*=[[:space:]]*!fence' "$PLUGIN_ROOT/scripts/lib/flags.sh"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "flags_validate: a block closed by a MIS-CASED first key warns, naming the line (#582)" {
  local f="$BATS_TEST_TMPDIR/rulec-miscased.md"
  printf '## Workflow flags\nTier: oneshot\nresearch: required\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]                          # non-fatal, forward-compat contract
  [[ "$output" == *"Tier: oneshot"* ]]         # NAMES the closing line (AC2)
  [[ "$output" == *"flags.sh: warn:"* ]]       # is a diagnostic on the shipped channel
  # Deliberately NOT asserted: the word "closed". AC2's claim is that the closing
  # line is named and the loss is stated — not one English phrasing of it. Pinning
  # the word would redden this guard on a wording improvement ("ended at"), which is
  # the guard-weakening habit the register warns about (register: Issue-561).
}

@test "flags_validate: a block closed by an INDENTED first line warns too (#582)" {
  # The other half of Rule C's predicate. A separate @test, not another assertion in
  # the one above: a multi-assertion guard reddens only at its FIRST failing assert,
  # so each leg needs its own born-red observation (register: Issue-123).
  local f="$BATS_TEST_TMPDIR/rulec-indented.md"
  printf '## Workflow flags\n\n  indented prose\nresearch: required\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"indented prose"* ]]
}

@test "flags_validate: an inline HTML comment on a key line warns, naming the key (#582)" {
  local f="$BATS_TEST_TMPDIR/inline-comment-key.md"
  printf '## Workflow flags\ntier: oneshot <!-- why -->\nresearch: required\n' > "$f"
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier"* ]]                  # the dropped key is NAMED (AC3)
  [[ "$output" != *"research"* ]]              # the healthy key is not warned about
}

@test "flags_get: an inline comment still drops the key, and the NEXT key still parses (#582 PIN)" {
  # PIN, green at HEAD by construction: #582 adds a DIAGNOSTIC, it does not change the
  # bare-value grammar (tests/lib_flags.bats:111 pins trailing prose as part of the value).
  local f="$BATS_TEST_TMPDIR/inline-comment-get.md"
  printf '## Workflow flags\ntier: oneshot <!-- why -->\nresearch: required\n' > "$f"
  run flags_get "$f" tier
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run flags_get "$f" research
  [ "$status" -eq 0 ]
  [ "$output" = "required" ]
}

@test "flags_validate: a fence opened INSIDE a live block warns that the block closed (#582)" {
  # N10 — improve Bug 2. Task 4's `inblock = 0` on a fence line is itself a
  # block-close by a non-key line; AC2 does not carve it out.
  local f="$BATS_TEST_TMPDIR/fence-in-live-block.md"
  cat > "$f" <<'FIXTURE'
## Workflow flags
tier: standard
```
checking-model: opus
```
spike: required
FIXTURE
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fence"* ]]
  [[ "$output" == *"IGNORED"* ]]
}

@test "flags_validate: an unbalanced fence that swallowed a flags heading warns at END (#582)" {
  # N11 — improve Bug 1: a CLOSING fence inside an <!-- --> span leaves fence state
  # ON, so a downstream LIVE block is eaten. Without this the fence fix would ADD a
  # silent flag loss, which is the defect class this issue exists to remove (#535).
  local f="$BATS_TEST_TMPDIR/fence-swallowed-by-comment.md"
  cat > "$f" <<'FIXTURE'
```
<!-- an aside
```
-->

## Workflow flags
tier: oneshot
FIXTURE
  run flags_validate "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unbalanced"* ]]
  # And the loss it reports is real — the get side returns nothing for this body:
  run flags_get "$f" tier
  [ "$status" -ne 0 ]
}
