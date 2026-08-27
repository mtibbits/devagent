#!/usr/bin/env bats
# #586: the register-promotion mechanism — staging (--add), drain (--apply),
# and the claim-vs-register check (--check).
load 'helpers/common'

setup() {
    devagent_test_setup
    # The register MUST resolve to a fixture: an unset override would resolve to
    # the plugin default and the suite would mutate the repo's real
    # templates/potholes.md. The script's own source_dir/devdoc_dir rail is the
    # backstop. Seed citations are NEVER the issue under test (Issue-1).
    mkdir -p "$DEVDOC_DIR/templates"
    REG="$DEVDOC_DIR/templates/potholes.md"
    printf '%s\n' '# Pothole register' '' \
        '## Bash exit-status & control flow' '- an existing line (Issue-7).' '' \
        '## Docs / edit-neighborhood hygiene' '- another existing line (Issue-8).' > "$REG"
    export TEMPLATE_PATHS_OVERRIDE_potholes="$REG"
    PP="$DEVAGENT_ROOT/scripts/promote-potholes.sh"
    ID="$DEVDOC_DIR/Issue-1"
    LL='- 2026-08-01 10:00  lessonslearned: lessonsLearned.md written: 6 entries (1 actionable, 1 reference, 1 norm, 3 pattern);'
}
teardown() { devagent_test_teardown; }

# Move the register into the SOURCE repo (committed) so --apply owns the commit.
use_source_register() {
    use_source_register
}

# --- floor -------------------------------------------------------------------

@test "the script exists and is executable (anti-vacuous floor, #572)" {
    [ -f "$PP" ]
    run bash "$PP"
    [ "$status" -eq 2 ]                 # usage, not 127
}

# --- --check -------------------------------------------------------------------

@test "--check FAILS when the log claims a promotion the register lacks (#571 shape)" {
    printf '%s\n' "$LL 2 patterns promoted to potholes register (cd-empty-substitution, squash-ancestry)" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"Issue-1"* ]]
    [[ "$output" == *"$REG"* ]]
}

@test "--check FAILS on the #572 wording (a claim qualified by 'uncommitted' is still a claim)" {
    printf '%s\n' "$LL 3 patterns promoted to potholes register (uncommitted alongside operator's pending entries)" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check PASSES when the claimed citation is in the register" {
    printf '%s\n' "$LL 2 patterns promoted to the potholes register" >> "$ID/checklist.md"
    printf '%s\n' '- a promoted line (Issue-1).' >> "$REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

@test "--check does not read an honest deferral / skip as a claim" {
    printf '%s\n' "$LL register promotion deferred — register dirty with another session's edit" \
        "$LL pothole promotion SKIPPED per project convention -- 2 pattern candidates recorded" \
        "$LL Four pattern lessons prepared for the register but NOT committed — see pending file" \
        >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

@test "--check ignores non-lessonslearned log lines that merely contain 'promot' (U2 corpus)" {
    printf '%s\n' \
        '- 2026-08-01 10:00  implement: Task 5 — scripts/promote-potholes.sh written; register untouched' \
        '- 2026-08-01 10:01  commit: abc1234: promote-potholes.sh + tests' \
        '- 2026-08-01 10:02  draft: imPlan: state_resume_promote_restore (one set-many)' \
        '- 2026-08-01 10:03  quality: 1 test-helper promotion (YAGNI)' \
        '- 2026-08-01 10:04  prune: 1 out-of-scope bullet promoted INTO scope' \
        >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

@test "--check treats this issue's PENDING staging file as honouring the claim (an IOU is not a lie)" {
    printf '%s\n' "$LL 1 pattern promoted to the register" >> "$ID/checklist.md"
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: pending' '' \
        '## Docs / edit-neighborhood hygiene' '- a line (Issue-1).' > "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *PENDING* ]]
}

@test "--check ignores the free-form note: tail (a note cannot make or unmake a claim)" {
    printf '%s\n' "$LL 3 patterns promoted to the potholes register; note: deferred the flaky candidate to reap" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check reads the machine field: 'register: N staged' with no staging file is a claim; 'none staged' is not" {
    printf '%s\n' "$LL register: 3 staged pending cleanup; note: (none)" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
    sed -i 's/register: 3 staged pending cleanup/register: none staged/' "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

@test "--check FAILS when the staging file says applied but the register lacks the line" {
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: applied deadbee' '' \
        '## Docs / edit-neighborhood hygiene' '- a line (Issue-1).' > "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check citation match is exact — Issue-1) does not match Issue-10) or Issue-Fork-1)" {
    printf '%s\n' '- decoy (Issue-10).' '- decoy (Issue-Fork-1).' >> "$REG"
    printf '%s\n' "$LL 1 pattern promoted to the potholes register" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check cross-project citation must name THIS project ((testproj Issue-1) yes, (lawFirm Issue-1) no)" {
    printf '%s\n' "$LL 1 pattern promoted to the potholes register" >> "$ID/checklist.md"
    printf '%s\n' '- a foreign line (lawFirm Issue-1).' >> "$REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
    printf '%s\n' '- our line (TestProj Issue-1).' >> "$REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

# --- --add ---------------------------------------------------------------------

@test "--add refuses a section heading absent from the register" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "No Such Section" "- x (Issue-1)."
    [ "$status" -eq 1 ]
    [[ "$output" == *"No Such Section"* ]]
}

@test "--add refuses a line whose citation does not name this issue" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- x (Issue-999)."
    [ "$status" -eq 1 ]
}

@test "--add refuses a multi-line value" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "$(printf -- '- a (Issue-1).\n- b (Issue-1).')"
    [ "$status" -eq 1 ]
}

@test "--add refuses a line naming the project in its BODY (weak neutrality rail)" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a $TEST_PROJECT-specific thing (Issue-1)."
    [ "$status" -eq 1 ]
}

@test "--add ACCEPTS the project name inside the citation token itself" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line ($TEST_PROJECT Issue-1)."
    [ "$status" -eq 0 ]
}

@test "--add writes a pending staging file and is idempotent; the register is untouched" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    [ "$status" -eq 0 ]
    [ "$(grep -c -- '- a neutral line (Issue-1).' "$ID/potholes-promotion.md")" -eq 1 ]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
    # AC2: no edit in the tree at --add time
    run grep -q 'a neutral line' "$REG"
    [ "$status" -ne 0 ]
}

# --- --apply -------------------------------------------------------------------

@test "--apply lands the line at the END of its section, preserving the blank run" {
    printf '\n## Tail section\n- t (Issue-8).\n' >> "$REG"
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    run awk '/^## Docs/{f=1;next} f&&/^## /{exit} f&&NF{last=$0} END{print last}' "$REG"
    [ "$output" = "- a neutral line (Issue-1)." ]
    run awk 'prev ~ /^- / && /^## / {c++} {prev=$0} END{print c+0}' "$REG"
    [ "$output" = "0" ]
    grep -q '^status: applied' "$ID/potholes-promotion.md"
}

@test "--apply lands a backslash-bearing line byte-exact (no awk -v escape processing)" {
    line='- a regex like \( or \[ must survive \\ verbatim (Issue-1).'
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "$line"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    grep -qxF -- "$line" "$REG"
}

@test "--apply on a devdoc-resident register DEFERS (rc 3) when commit_devdoc is not true (nobody would commit it)" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
    run grep -q 'a neutral line' "$REG"
    [ "$status" -ne 0 ]
}

@test "--apply on a devdoc-resident register stamps 'applied devdoc' (cleanup's devdoc commit carries it)" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    grep -q '^status: applied devdoc$' "$ID/potholes-promotion.md"
}

@test "--apply preserves STAGING order within a section (plain append, no LIFO)" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- first (Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- second (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    run awk '/^## Docs/{f=1;next} f&&/^## /{exit} f&&/Issue-1/' "$REG"
    [ "${lines[0]}" = "- first (Issue-1)." ]
    [ "${lines[1]}" = "- second (Issue-1)." ]
}

@test "--apply is a no-op (rc 0) when there is no staging file" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
}

@test "--apply with every line already present flips the status and exits 0 (never a nothing-to-commit die)" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    printf '%s\n' '- a neutral line (Issue-1).' >> "$REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    grep -q '^status: applied' "$ID/potholes-promotion.md"
    [ "$(grep -c -- '- a neutral line (Issue-1).' "$REG")" -eq 1 ]
}

@test "--apply REFUSES (rc 3) and stays pending when the register is dirty in git" {
    use_source_register
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    printf '%s\n' '- a FOREIGN session line (Issue-3).' >> "$SOURCE_DIR/templates/potholes.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
    grep -q 'FOREIGN' "$SOURCE_DIR/templates/potholes.md"      # foreign edit untouched
    run grep -q 'a neutral line' "$SOURCE_DIR/templates/potholes.md"
    [ "$status" -ne 0 ]                                        # nothing applied
}

@test "--apply REFUSES (rc 3) when the source repo is not on the base branch (a stranded commit is the defect)" {
    use_source_register
    ( cd "$SOURCE_DIR" && git checkout -q -b feat/1-x )
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
}

@test "--apply commits ONLY the register path, leaving a concurrent staged file alone (U1)" {
    use_source_register
    echo foreign > "$SOURCE_DIR/other.txt"
    ( cd "$SOURCE_DIR" && git add other.txt )
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    run bash -c "cd '$SOURCE_DIR' && git show --stat --format= HEAD"
    [[ "$output" == *potholes.md* ]]
    [[ "$output" != *other.txt* ]]
    run bash -c "cd '$SOURCE_DIR' && git status --porcelain other.txt"
    [[ "$output" == A* ]]
    run bash -c "cd '$SOURCE_DIR' && git log -1 --format=%s"
    [[ "$output" == "chore: promote pothole-register entries from #1" ]]
    grep -q '^status: applied' "$ID/potholes-promotion.md"
}

@test "--apply REFUSES (rc 3) when the register is outside source_dir and devdoc_dir" {
    cp "$REG" "$DEVAGENT_TMP/elsewhere.md"
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    export TEMPLATE_PATHS_OVERRIDE_potholes="$DEVAGENT_TMP/elsewhere.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    run grep -q 'a neutral line' "$DEVAGENT_TMP/elsewhere.md"
    [ "$status" -ne 0 ]
}

# --- --list-pending ------------------------------------------------------------

@test "--list-pending names every undrained staging file" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" --list-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *Issue-1* ]]
}
