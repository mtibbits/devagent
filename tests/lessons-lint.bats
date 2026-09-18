#!/usr/bin/env bats

. "${BATS_TEST_DIRNAME}/lib/hermetic-env.bash"

setup() {
  LINT="$BATS_TEST_DIRNAME/../scripts/lessons-lint.sh"
  TPL="$BATS_TEST_DIRNAME/../templates/lessonsLearned_template.md"
}

@test "lessons-lint: passes a file using only closed-taxonomy tags" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### claim one
- Tags: [actionable]
### claim two
- Tags: [norm, pattern]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: fails an off-taxonomy tag (#232, the Issue-78 case)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
- [process] A wide-blast change is de-risked by enumerating callers.
- [test-isolation] Found, not fixed: DEVAGENT_CONFIG_OVERRIDE wired to nothing.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *process* ]]
  [[ "$output" == *test-isolation* ]]
}

@test "lessons-lint: fails a structured entry with no tag line" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### untagged claim
- Evidence: something
- Consequence: something
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
}

@test "lessons-lint: ignores tags inside a comment block" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### real claim
- Tags: [reference]
<!--
### example to delete
- Tags: [bogus-tag]
-->
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: the canonical template passes (lint agrees with the format)" {
  run bash "$LINT" "$TPL"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: missing file is a usage error (exit 2)" {
  run bash "$LINT" "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 2 ]
}

@test "lessons-lint: an empty bracket [] does not satisfy the tag requirement (#232 review L1)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### claim
- []
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
}

@test "lessons-lint: a multi-tag line flags only the off-taxonomy token (#232)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
## Entries
### claim
- Tags: [norm, bogus]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag [bogus]"* ]]
  [[ "$output" != *"tag [norm]"* ]]
}

@test "lessons-lint: fails an untagged flat-bullet file, naming it (#525)" {
  # Batch-11 shape: top-level bold bullets, no '### ' heading, zero tags. The
  # entry floor used to key only off '### ', so these passed vacuously (exit 0).
  cat > "$BATS_TEST_TMPDIR/batch11.md" <<'LL'
# Lessons learned — Issue-440

- **`user-invocable:false` gates the operator MENU only** — not model
  reachability. State it precisely.
- **Blast radius of a which-files-carry-X change:** grep the file-set BEFORE
  the edit; the guard update is Step 0.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/batch11.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *batch11.md* ]]
}

@test "lessons-lint: a flat-bullet entry tagged by a following Tags line passes (#525)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X

- **A flat bold-bullet claim that carries a tag.**
- Tags: [actionable]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: an entry-less present file passes (#525)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons learned — Issue-000

No entries recorded yet.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: a prose bullet before the first heading is not a flat entry (#525 redmr)" {
  # A canonical file may open with a context bullet before its first '### '
  # heading; the flat floor keys off bold-lead '- **' so that prose bullet is
  # NOT mistaken for an untagged entry.
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
- See the parent epic Issue-400 for context.
### A properly tagged lesson
- Tags: [pattern]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: a flat file of bold-lead tagged bullets passes (#588, real Issue-351 entries)" {
  # The Issue-344..352 shape: Fable-era '- **[tag] claim.**' bullets, no '### '
  # heading, wrapped onto indented continuation lines carrying backticks,
  # brackets, quotes and dollar signs. Copied VERBATIM from
  # devDoc/devagent/Issue-351/lessonsLearned.md (the one file the fix turns
  # green) so the must-not-trip case is a real entry, not an imagined one.
  cat > "$BATS_TEST_TMPDIR/issue351.md" <<'LL'
# Lessons Learned — Issue-351

- **[actionable] A blanket `sed` on a token can over-match a superset.** `s/timeout "$budget"/timeout -k 10 "$budget"/`
  also hit `ctest --timeout "$budget"`, corrupting the ctest flag into `--timeout -k 10 "$budget"`.
  The bats test caught it (the `ctest --timeout 1` grep failed). When sed-editing a token that
  appears as a substring of a longer flag, anchor the pattern (leading space / word boundary) or
  use per-line Edits — and always re-run the tests after a mechanical rewrite.
- **[pattern] Reuse an existing failure-aggregation path for a new failure mode.** The timeout
  (rc 124) rode the existing #117 per-phase rc capture with just a label tweak — no parallel
  error-handling to keep in sync. Adding a mode to a mechanism beats bolting on a second one.
- **[pattern] A hang-bounding timeout needs `-k`.** `timeout N` only SIGTERMs; a SIGTERM-ignoring
  wedged process survives it (review nit). `timeout -k <grace> N` guarantees the SIGKILL — the
  difference between "usually bounds hangs" and "always bounds hangs" for the feature's purpose.
- **[actionable] Prefix-collision in a cleanup glob:** `rm build-<key>*` would let cleaning
  `Issue-1` wipe `Issue-10`. The `-*` form (requires a dash after the key) + an exact match is
  prefix-safe; a test that seeds an `Issue-10` sibling pins it.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/issue351.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: a bold-lead OFF-TAXONOMY tag reads as off-taxonomy, not as 'no tag' (#588)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons learned — X

- **[bogus] A bold-lead claim with an off-taxonomy tag.** Evidence: x.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"off-taxonomy tag [bogus]"* ]]
  # Born-red discriminator: HEAD also exits 1 here, but with the WRONG finding
  # (the bullet reads as an untagged entry), so the bare code proves nothing.
  [[ "$output" != *"entry has no tag"* ]]
}

@test "lessons-lint: an untagged bold bullet FOLLOWED by a tagged one fails, naming only the untagged line (#588)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons learned — X

- **An untagged bold claim.** Evidence: x.
- **[pattern] A tagged bold claim.** Evidence: y.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 3: entry has no tag"* ]]
  # The tagged bullet opened its OWN entry and carries its own tag: never named.
  [[ "$output" != *"line 4:"* ]]
}

@test "lessons-lint: a tagged bold bullet FOLLOWED by an untagged one fails, naming only the untagged line (#588)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons learned — X

- **[pattern] A tagged bold claim.** Evidence: y.
- **An untagged bold claim.** Evidence: x.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"line 4: entry has no tag"* ]]
  [[ "$output" != *"line 3:"* ]]
}

@test "lessons-lint: a bold-lead tag bullet under a '### ' heading tags that entry (#588)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
### a structured claim
- **[pattern] the tag arrives on a bold body bullet.**
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: an empty bracket on a bold-lead bullet still fails (#588 keeps #232 review L1)" {
  # Behavior-PRESERVING pin, not a born-red test: identical at HEAD and after.
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X

- **[] A bold bullet with an empty bracket.**
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry has no tag"* ]]
}

@test "lessons-lint: a bold bullet whose bracket does not LEAD stays an untagged entry (#232 strictness)" {
  # Behavior-PRESERVING pin, not a born-red test: the #232 leading-bracket rule
  # must not be widened into reap's scan-anywhere behavior.
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X

- **A bold claim mentioning [something] mid-sentence.**
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry has no tag"* ]]
}

@test "lessons-lint: an INDENTED bold-lead tag bullet tags the open flat entry, it does not open a new one (#588)" {
  # Design decision (#588): the entry-opener half of the widened rule is
  # column-0 anchored (the shared boldlead predicate, same as the #525 rule), so
  # an indented bold-tagged sub-bullet is a Tags line for its parent entry,
  # exactly as an indented '- Tags: [..]' line would be.
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X

- **An untagged bold claim.**
  - **[pattern] a nested tagged sub-bullet.**
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

@test "lessons-lint: a bold-lead tag bullet BEFORE the first '### ' heading is a tagged flat entry (#588)" {
  # Before the first heading seen_heading is 0, so the bullet opens its own
  # entry and tags it (HEAD: the #525 rule opened it untagged -> exit 1).
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
- **[pattern] A bold-lead tag bullet before the first heading.**
### a structured claim
- Tags: [norm]
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
}

# --- #594: two false positives closed, both directions pinned (Issue-585) -------
# Fixtures are copied verbatim from the live corpus (Issue-586): the wikilink
# bullets from volk/Issue-Fork-58 "Carried memories", the bracket-leading
# headings from devagent/Issue-536:3 and devagent/Issue-530:32.

@test "lessons-lint: a '- [[wikilink]]' bullet is a link, not a tag: it does not flag (#594)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
### a structured claim
- Tags: [pattern]

## Carried memories

*None new.* Existing memories already cover the lessons:
- [[feedback_subagent_delegation_rubric]] — reinforced (reviews caught real bugs)
- [[feedback_inspect_generated_machine_c]] — reinforced (this PR's check formalizes the manual inspection step from that memory)
- [[feedback_verify_call_site]] — reinforced (plan-vs-reality mismatch on `generic` deps)
- [[project_dispatch_path_test_gap]] — partially closed by this PR (the check formalizes one piece of dispatch-path coverage)
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"off-taxonomy tag"* ]]
}

@test "lessons-lint: the wikilink exemption does not swallow real tag bullets (#594 must-trip half)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
### a structured claim
- [actionable] real claim
- [[feedback_verify_call_site]] — reinforced
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
  cat > "$BATS_TEST_TMPDIR/ll2.md" <<'LL'
# Lessons — X
### a structured claim
- [bogus] x
- [[feedback_verify_call_site]] — reinforced
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll2.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"off-taxonomy tag [bogus]"* ]]
  [[ "$output" != *"feedback_verify_call_site"* ]]
}

@test "lessons-lint: a '### [pattern] claim' heading tags its own entry (#594)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons learned — Issue-536

### [pattern] Before extracting a block, ADD the test that covers the line the extraction could break — an unedited green suite only proves what the suite already pinned
Tags: refactor, coverage, equivalence, actionable
"branch.bats passes unedited" was offered as refactor-equivalence, but every worktree test INJECTED
`worktree_root`.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"entry has no tag"* ]]
}

@test "lessons-lint: a '### [process] claim' heading reports off-taxonomy, not no-tag (#594 flip: do not 'fix' it back)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X

### [process] An MR claim about COMMIT STRUCTURE must match `git log` — a maintainer will check it
Tags: [process]
I wrote "Part A is a self-standing commit prefix" but committed both parts in
one commit; redmr caught it.
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"off-taxonomy tag [process]"* ]]
  [[ "$output" != *"entry has no tag"* ]]
}

@test "lessons-lint: a '### [[wikilink]] claim' heading is an untagged heading, never routed to the tag check (#594)" {
  # The hunk-2/hunk-3 drift pin: the wikilink exemption holds for headings as it
  # does for bullets. The heading stays untagged (one honest finding) and its
  # bracket is never read as a token.
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
### [[some page]] claim
- Evidence: something
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry has no tag"* ]]
  [[ "$output" != *"off-taxonomy tag"* ]]
}

@test "lessons-lint: a heading whose bracket does not LEAD stays untagged (#232 strictness, #594)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
### claim mentioning [pattern] mid-sentence
- Evidence: something
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry has no tag"* ]]
}

@test "lessons-lint: a wikilink bullet does not tag the untagged entry above it (#594, the volk/Issue-Fork-53:40 class)" {
  cat > "$BATS_TEST_TMPDIR/ll.md" <<'LL'
# Lessons — X
### an untagged structured claim
- [[page]] — note
LL
  run bash "$LINT" "$BATS_TEST_TMPDIR/ll.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry has no tag: an untagged structured claim"* ]]
  [[ "$output" != *"off-taxonomy tag"* ]]
}
