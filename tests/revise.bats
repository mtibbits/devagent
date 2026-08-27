#!/usr/bin/env bats

load 'helpers/fixtures'
# #585: this file invokes doctor.sh, which shells out to `claude plugin list`.
. "${BATS_TEST_DIRNAME}/lib/doctor-harness.bash"

setup() {
  fixture_init volk Issue-676
  # Seed a prior revision's comments.md so revise can proceed.
  mkdir -p "$FIX_ISSUE_DIR/revisions/r1"
  cat >"$FIX_ISSUE_DIR/revisions/r1/comments.md" <<'EOF'
# example/volk#842 — Comments

## Comments (3)

### @alice · 2026-05-20
nit
### @bob · 2026-05-20
nit
### @carol · 2026-05-21
nit
EOF
  stub_chain_recorder
}

run_revise() {
  run env \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" "$@"
}

@test "revise increments revision from 1 to 2 in state" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*2$' "$FIX_STATE_FILE"
}

@test "revise with no project arg resolves the active project, not 'default' (#124)" {
  # Bare revise must route through active_resolve_project, not the literal 'default'.
  run env \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    DEVAGENT_CHAIN_CMD="$DEVAGENT_CHAIN_CMD" \
    DEVAGENT_ACTIVE_PROJECT=volk \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" --no-chain
  [ "$status" -eq 0 ]
  [[ "$output" != *"project 'default'"* ]]
  grep -q '^revision[[:space:]]*=[[:space:]]*2$' "$FIX_STATE_FILE"
}

@test "revise creates revisions/r2 directory" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  [ -d "$FIX_ISSUE_DIR/revisions/r2" ]
}

@test "revise appends a new ## Revision 2 block to checklist.md" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^## Revision 2$' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \]  2\. draft' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \] 18\. ship' "$FIX_ISSUE_DIR/checklist.md"
  # #76: the appended block carries preship + the full closeout, so a revised
  # MR re-runs preship/mergetoall/updatewbs/impact/lessonslearned/cleanup.
  grep -q '\[ \] 17\. preship' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \] 19\. mergetoall' "$FIX_ISSUE_DIR/checklist.md"
  grep -q '\[ \] 23\. cleanup' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise preserves the original ## Revision 1 block" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^## Revision 1$' "$FIX_ISSUE_DIR/checklist.md"
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 2 ]
}

@test "revise records the previous revision's comments as pending_comments_file" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q "^pending_comments_file[[:space:]]*=[[:space:]]*\"$FIX_ISSUE_DIR/revisions/r1/comments.md\"$" \
    "$FIX_STATE_FILE"
}

@test "revise logs the revision start with the comment count" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q 'revise: revision 2 started, 3 comments to address' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise start entry lands inside the Log section, not after the new block (#75)" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  local logln revln
  logln="$(grep -n 'revise: revision 2 started' "$FIX_ISSUE_DIR/checklist.md" | head -1 | cut -d: -f1)"
  revln="$(grep -n '^## Revision 2' "$FIX_ISSUE_DIR/checklist.md" | head -1 | cut -d: -f1)"
  [ -n "$logln" ]
  [ "$logln" -lt "$revln" ]
}

@test "revise errors when revisions/r<N>/comments.md is missing" {
  rm -f "$FIX_ISSUE_DIR/revisions/r1/comments.md"
  run_revise volk Issue-676 --no-chain
  [ "$status" -ne 0 ]
  [[ "$output" == *"/devagent:comments"* ]]
  grep -q '^revision[[:space:]]*=[[:space:]]*1$' "$FIX_STATE_FILE"
}

@test "revise chains to /devagent:next by default" {
  run_revise volk Issue-676
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/chain.log" ]
  grep -q '/devagent:next' "$BATS_TEST_TMPDIR/chain.log"
}

@test "revise does NOT chain when --no-chain is passed" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/chain.log" ]
}

@test "monotonic counter — two revisions advances 1->2->3" {
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  cp "$FIX_ISSUE_DIR/revisions/r1/comments.md" "$FIX_ISSUE_DIR/revisions/r2/comments.md"
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*3$' "$FIX_STATE_FILE"
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 3 ]
}

@test "revise writes pending_comments_file top-level, not under [parked] (#97)" {
  # Append a [parked] table. The old EOF-append writer lands a not-found key INSIDE it
  # → pending_comments_file becomes parked.pending_comments_file (a bogus parked issue
  # to status/where/resume). The canonical state_set must place it top-level.
  cat >>"$FIX_STATE_FILE" <<'PARKED'

[parked]
Issue-999 = "2026-06-01T00:00:00Z"
PARKED
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  # pending_comments_file is a TOP-LEVEL key: it appears BEFORE the [parked] header.
  pcf=$(grep -n '^pending_comments_file' "$FIX_STATE_FILE" | head -1 | cut -d: -f1)
  parked=$(grep -n '^\[parked\]' "$FIX_STATE_FILE" | head -1 | cut -d: -f1)
  [ -n "$pcf" ]
  [ -n "$parked" ]
  [ "$pcf" -lt "$parked" ]
  # the real parked entry survives; nothing masquerades inside [parked].
  grep -q '^Issue-999 = ' "$FIX_STATE_FILE"
}

@test "revision block resolves via a devdoc override (#120)" {
  local devdoc="${FIX_ISSUE_DIR%/*}"
  mkdir -p "$devdoc/templates"
  printf '## Revision {{N}} REVISED-OVERRIDE-#120\n\n- [ ]  2. draft\n' \
    > "$devdoc/templates/revision_block.md"
  run_revise volk
  [ "$status" -eq 0 ]
  grep -q 'REVISED-OVERRIDE-#120' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise resets last_step so doctor stays truthful (#414)" {
    # Fixture seeds a shipped rev-1: checklist all-[x] through ship, state
    # last_step=15/last_step_name=ship. Appending Revision 2 (all [ ]) must reset
    # the step pointer, else doctor's #329 step-coherence check false-FAILs.
    run_revise volk Issue-676 --no-chain
    [ "$status" -eq 0 ]
    # State pointer no longer names the prior revision's ship step.
    grep -qE '^last_step_name[[:space:]]*=[[:space:]]*""$' "$FIX_STATE_FILE"
    grep -qE '^last_step[[:space:]]*=[[:space:]]*0$' "$FIX_STATE_FILE"
    # doctor no longer false-FAILs step coherence on the freshly-revised issue.
    # #585: shim `claude` so this test does not take a live dependency on the
    # developer's plugin state. STUBBIN is not seeded by helpers/fixtures.
    STUBBIN="${BATS_TEST_TMPDIR}/stubbin"; mkdir -p "$STUBBIN"
    stub_claude_cli enabled
    run "$DEVAGENT_ROOT/scripts/doctor.sh" volk
    [[ "$output" != *"last_step_name=ship"* ]]
}

# --- #537: --retier escalation valve -----------------------------------------

retier_fixture() {
  # Reshape the standard fixture into a oneshot-scaffolded issue mid-flight.
  cat >"$FIX_ISSUE_DIR/checklist.md" <<'EOF'
# Issue — Workflow checklist

State key: [ ] pending  [x] done  [-] skipped  [!] stuck  [~] in-progress  [?] blocked-external  [P] parked

Template: oneshot
Created: 2026-05-19 14:01
Active revision: 1

## Revision 1

- [x]  0. pull
- [~]  9. implement
- [ ]  11. document
- [ ] 22. lessonslearned
- [ ] 23. cleanup

## Log

- 2026-05-19 14:05  pull: fetched example/volk#842, scaffold created
EOF
  cat >"$FIX_STATE_FILE" <<EOF
active_issue   = "$FIX_ISSUE"
issue_dir      = "$FIX_ISSUE_DIR"
branch         = ""
last_step      = 7
last_step_name = "implement"
revision       = 1
updated_at     = "2026-05-19T14:32:00-04:00"
EOF
}

@test "revise --retier standard appends the standard rows minus row 0 and updates Template: (#537)" {
  retier_fixture
  run_revise --retier standard volk Issue-676
  [ "$status" -eq 0 ]
  grep -q '^## Revision 2$' "$FIX_ISSUE_DIR/checklist.md"
  awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -qE '^\- \[ \] +2\. draft'
  [ "$(awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -cE '^\- \[.\] +0\. pull')" -eq 0 ]
  # 20 pending + pre-skipped mergetoall (volk sets no all_prs_branch).
  [ "$(awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -cE '^\- \[ \] +[0-9]+\.')" -eq 20 ]
  awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -qE '^\- \[-\] +19\. mergetoall'
  grep -q '^Template: standard$' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise --retier flips mergetoall to pending when the project sets all_prs_branch" {
  retier_fixture
  # all_prs_branch must live in [project.volk] (an append would land inside the
  # trailing [project.volk.code_source] table); rewrite the config wholesale.
  cat >"$FIX_CONFIG_FILE" <<EOF
[project.volk]
source_dir     = "$BATS_TEST_TMPDIR/src/volk"
devdoc_dir     = "$BATS_TEST_TMPDIR/devdoc/volk"
all_prs_branch = "dev/all-prs"
EOF
  run_revise --retier standard volk Issue-676
  [ "$status" -eq 0 ]
  awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -qE '^\- \[ \] +19\. mergetoall'
}

@test "revise --retier preserves the Log section and prior revision blocks (#537)" {
  retier_fixture
  run_revise --retier standard volk Issue-676
  [ "$status" -eq 0 ]
  grep -q '^## Revision 1$' "$FIX_ISSUE_DIR/checklist.md"
  grep -qE '^\- \[~\] +9\. implement' "$FIX_ISSUE_DIR/checklist.md"
  grep -q 'pull: fetched example/volk#842' "$FIX_ISSUE_DIR/checklist.md"
  grep -q 'retier: oneshot → standard' "$FIX_ISSUE_DIR/checklist.md"
}

@test "revise --retier keeps state and file revision numbers in agreement (#537)" {
  retier_fixture
  run_revise --retier standard volk Issue-676
  [ "$status" -eq 0 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*2$' "$FIX_STATE_FILE"
  grep -q '^last_step[[:space:]]*=[[:space:]]*0$' "$FIX_STATE_FILE"
  grep -q '^last_step_name[[:space:]]*=[[:space:]]*""$' "$FIX_STATE_FILE"
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 2 ]
}

@test "a genuine revise after --retier appends the correct next block number (#537)" {
  retier_fixture
  run_revise --retier standard volk Issue-676
  [ "$status" -eq 0 ]
  mkdir -p "$FIX_ISSUE_DIR/revisions/r2"
  printf '### @bob\nfix it\n' > "$FIX_ISSUE_DIR/revisions/r2/comments.md"
  run_revise volk Issue-676 --no-chain
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## Revision 3$' "$FIX_ISSUE_DIR/checklist.md")" -eq 1 ]
  grep -q '^revision[[:space:]]*=[[:space:]]*3$' "$FIX_STATE_FILE"
}

@test "revise --retier rejects unknown tiers with the legal-names list (#537)" {
  retier_fixture
  run_revise --retier bogus volk Issue-676
  [ "$status" -ne 0 ]
  [[ "$output" == *"legal tiers:"* ]]
  # nothing appended, nothing retitled
  grep -q '^Template: oneshot$' "$FIX_ISSUE_DIR/checklist.md"
  [ "$(grep -c '^## Revision ' "$FIX_ISSUE_DIR/checklist.md")" -eq 1 ]
}

@test "revise --retier without a tier name dies loudly (#537)" {
  retier_fixture
  run_revise --retier
  [ "$status" -ne 0 ]
  [[ "$output" == *"--retier requires a tier name"* ]]
}

@test "revise --retier with an empty tier name dies rather than degrading (#537)" {
  retier_fixture
  run_revise --retier "" volk Issue-676
  [ "$status" -ne 0 ]
  [[ "$output" == *"--retier requires a tier name"* ]]
}

@test "revise --retier excludes the PRE-DRAFT research row like row 0 (#535/#558)" {
  retier_fixture
  run_revise --retier standard volk Issue-676
  [ "$status" -eq 0 ]
  # research is pre-draft: copying it would either re-point next.sh at research or
  # RESET an outstanding flagged row to [-]. It must not appear in the new block —
  # and post-#558 rows 22/23 are lessonslearned/cleanup, which MUST appear.
  [ "$(awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -cE '^\- \[.\] +[0-9]+\. (research|spike)')" -eq 0 ]
  [ "$(awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -cE '^\- \[.\] +22\. lessonslearned')" -eq 1 ]
  [ "$(awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -cE '^\- \[.\] +23\. cleanup')" -eq 1 ]
  # sanity: the block IS non-empty (guards a vacuous zero-count)
  [ "$(awk '/^## Revision 2$/{f=1} f' "$FIX_ISSUE_DIR/checklist.md" | grep -cE '^\- \[')" -ge 20 ]
}

@test "revise's chain continuation carries the resolved project (#578)" {
  # Deliberately NOT run_revise: setup()'s stub_chain_recorder EXPORTS
  # DEVAGENT_CHAIN_CMD at an executable stub, which takes the exec branch and
  # emits no CHAIN: line at all. Scrub it to reach the printf branch.
  run env -u DEVAGENT_CHAIN_CMD \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHAIN: /devagent:next volk"* ]]
}

@test "revise leaves a custom DEVAGENT_CHAIN_CMD unscoped (#578)" {
  # The project is appended only to the /devagent:next default. A custom value is
  # an operator string whose grammar this script does not control, so it is
  # emitted verbatim.
  run env DEVAGENT_CHAIN_CMD="/custom:resume" \
    HOME="$HOME" \
    DEVAGENT_ROOT="$DEVAGENT_ROOT" \
    bash "$DEVAGENT_ROOT/scripts/revise.sh" volk Issue-676
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHAIN: /custom:resume"* ]]
  [[ "$output" != *"CHAIN: /custom:resume volk"* ]]
}
