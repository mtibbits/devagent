#!/usr/bin/env bats
# #586/#611: the register-promotion mechanism — staging (--add --layer), the
# per-layer drain (--apply), and the claim-vs-union check (--check).
load 'helpers/common'
load 'helpers/potholes-fixture'
setup()    { potholes_fixture_setup; }
teardown() { devagent_test_teardown; }

# --- floor -------------------------------------------------------------------

@test "the script exists and is executable (anti-vacuous floor, #572)" {
    [ -f "$PP" ]
    [ -x "$PP" ]
    run bash "$PP"
    [ "$status" -eq 2 ]                 # usage, not 127
}

# --- --check -------------------------------------------------------------------

@test "--check FAILS when the log claims a promotion the register lacks (#571 shape)" {
    printf '%s\n' "$LL 2 patterns promoted to potholes register (cd-empty-substitution, squash-ancestry)" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"Issue-1"* ]]
    [[ "$output" == *"$SEED"* ]]
}

@test "--check FAILS on the #572 wording (a claim qualified by 'uncommitted' is still a claim)" {
    printf '%s\n' "$LL 3 patterns promoted to potholes register (uncommitted alongside operator's pending entries)" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check PASSES when the claimed citation is in the project layer" {
    seed_project_layer
    printf '%s\n' "$LL 2 patterns promoted to the potholes register" >> "$ID/checklist.md"
    printf '%s\n' '- a promoted line (Issue-1).' >> "$PROJ_REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

@test "--check PASSES on a citation present ONLY in the workflow layer (the cleanup re-run case)" {
    use_workflow
    seed_workflow_layer "- our line ($TEST_PROJECT Issue-1)."
    printf '%s\n' "$LL 1 pattern promoted to the potholes register" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

@test "--check: a SEED citation counts only in the project's own form — bare (Issue-N) satisfies the plugin-owning project alone (red-team #611)" {
    printf '%s\n' "$LL 1 pattern promoted to the potholes register" >> "$ID/checklist.md"
    printf '%s\n' '' '## Retired' '- an old bare line (Issue-1).' >> "$SEED"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]                                        # testproj does not own the plugin: the seed's bare form is someone else's Issue-1
    printf '%s\n' "- a pre-split line ($TEST_PROJECT Issue-1)." >> "$SEED"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]                                        # the project-token form in the seed does count (Retired sections included)
    sed -i '$d' "$SEED"
    # Ownership is PROVENANCE: the seed's tree and the project's source_dir carry
    # the same .claude-plugin/plugin.json name (the harness never forces it —
    # SOURCE_DIR is a plain scratch repo, DEVAGENT_PLUGIN_TEMPLATES a scratch dir).
    mkdir -p "$DEVAGENT_TMP/.claude-plugin" "$SOURCE_DIR/.claude-plugin"
    printf '{ "name": "zzqplugin" }\n' > "$DEVAGENT_TMP/.claude-plugin/plugin.json"
    printf '{ "name": "other-plugin" }\n' > "$SOURCE_DIR/.claude-plugin/plugin.json"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]                                        # a DIFFERENT plugin's project: still refused
    printf '{ "name": "zzqplugin" }\n' > "$SOURCE_DIR/.claude-plugin/plugin.json"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]                                        # now testproj develops the plugin whose seed this is
}

@test "--check names every layer file it searched when it FAILS" {
    use_workflow; seed_project_layer
    mkdir -p "$(dirname "$WF")"; printf '%s\n' '# WF' > "$WF"
    printf '%s\n' "$LL 1 pattern promoted to the potholes register" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"$SEED"* ]] && [[ "$output" == *"$WF"* ]] && [[ "$output" == *"$PROJ_REG"* ]]
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
        '## Docs / edit-neighborhood hygiene' 'layer: project' '- a line (Issue-1).' > "$ID/potholes-promotion.md"
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
    sed -i 's/register: none staged/register: 0 staged pending cleanup/' "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]                       # the skill's literal arithmetic; not a claim
}

@test "--check: the machine field is a claim even when free text carries a deny-list word" {
    printf '%s\n' "$LL register: 3 staged pending cleanup; 1 candidate skipped as already covered" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check FAILS when the staging file says applied but no layer carries the line" {
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: applied deadbee' '' \
        '## Docs / edit-neighborhood hygiene' 'layer: project' '- a line (Issue-1).' > "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check citation match is exact — Issue-1) does not match Issue-10) or Issue-Fork-1)" {
    seed_project_layer
    printf '%s\n' '- decoy (Issue-10).' '- decoy (Issue-Fork-1).' >> "$PROJ_REG"
    printf '%s\n' "$LL 1 pattern promoted to the potholes register" >> "$ID/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
}

@test "--check cross-project citation must name THIS project ((testproj Issue-1) yes, (lawFirm Issue-1) no)" {
    seed_project_layer
    printf '%s\n' "$LL 1 pattern promoted to the potholes register" >> "$ID/checklist.md"
    printf '%s\n' '- a foreign line (lawFirm Issue-1).' >> "$PROJ_REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 1 ]
    printf '%s\n' '- our line (TestProj Issue-1).' >> "$PROJ_REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --check
    [ "$status" -eq 0 ]
}

# --- --add ---------------------------------------------------------------------

@test "--add REFUSES a line without --layer (mandatory, no default)" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add "Docs / edit-neighborhood hygiene" "- x (Issue-1)."
    [ "$status" -eq 1 ]
    [[ "$output" == *"--layer"* ]]
    [ ! -e "$ID/potholes-promotion.md" ]
}

@test "--add REFUSES an unknown layer" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer seed "Docs / edit-neighborhood hygiene" "- x (Issue-1)."
    [ "$status" -eq 1 ]
}

@test "--add project layer: citation must be exactly (Issue-N)" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- x ($TEST_PROJECT Issue-1)."
    [ "$status" -eq 1 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- x (Issue-999)."
    [ "$status" -eq 1 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a $TEST_PROJECT-specific thing (Issue-1)."
    [ "$status" -eq 0 ]            # domain nouns are LEGAL in the private project layer
}

@test "--add workflow layer: refused when no workflow key is configured (loud at step 22, never a silent DEFER)" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- x ($TEST_PROJECT Issue-1)."
    [ "$status" -eq 1 ]
    [[ "$output" == *"potholes_workflow"* ]]
    [ ! -e "$ID/potholes-promotion.md" ]
}

@test "--add workflow layer: citation must be (<project> Issue-N); case-insensitive, staged with the config spelling" {
    use_workflow
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- x (Issue-1)."
    [ "$status" -eq 1 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- x (lawFirm Issue-1)."
    [ "$status" -eq 1 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- x (TestProj Issue-1)."
    [ "$status" -eq 0 ]
    grep -qxF -- "- x ($TEST_PROJECT Issue-1)." "$ID/potholes-promotion.md"
}

@test "--add workflow layer: refuses the project name in the BODY (citation token excluded)" {
    use_workflow
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- a $TEST_PROJECT-specific thing ($TEST_PROJECT Issue-1)."
    [ "$status" -eq 1 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- a neutral line ($TEST_PROJECT Issue-1)."
    [ "$status" -eq 0 ]
}

@test "--add workflow layer: paths.potholes_domain_nouns refuses a word-bounded, case-insensitive match; a substring of another word passes" {
    use_workflow
    printf '\n[project.%s.paths]\npotholes_domain_nouns = ["matter", "law"]\n' "$TEST_PROJECT" >> "$HOME/.claude/devagent/config.toml"   # a REAL array (the set helper stores strings)
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- the Matter id is (${TEST_PROJECT} Issue-1)."
    [ "$status" -eq 1 ]
    [[ "$output" == *"potholes_domain_nouns"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- a lawful flawless line (${TEST_PROJECT} Issue-1)."
    [ "$status" -eq 0 ]
    _devagent_toml set "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.paths.potholes_domain_nouns" '"not-a-list"'
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- another line (${TEST_PROJECT} Issue-1)."
    [ "$status" -eq 1 ]            # malformed config dies, never silently disarms the rail
}

@test "--add validates the section against the UNION's headings and writes nothing outside the staging file" {
    seed_project_layer
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "No Such Section" "- x (Issue-1)."
    [ "$status" -eq 1 ]
    [[ "$output" == *"No Such Section"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Project-only heading" "- x (Issue-1)."    # only in the project layer
    [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Bash exit-status & control flow" "- y (Issue-1)."   # only in the seed
    [ "$status" -eq 0 ]
    run bash -c "cd '$DEVDOC_REPO' && git status --porcelain"
    [[ "$output" == "?? testproj/Issue-1/"* ]]          # the staging file is the ONLY new path
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    run grep -q ' x (Issue-1)' "$PROJ_REG" "$SEED"
    [ "$status" -ne 0 ]
}

@test "--add stages a pending file with a layer per block and is idempotent" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    [ "$status" -eq 0 ]
    [ "$(grep -c -- '- a neutral line (Issue-1).' "$ID/potholes-promotion.md")" -eq 1 ]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
    grep -q '^layer: project$' "$ID/potholes-promotion.md"
    [ ! -e "$PROJ_REG" ]                                   # bootstrap happens at --apply, never at --add
}

@test "--add refuses a multi-line value" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "$(printf -- '- a (Issue-1).\n- b (Issue-1).')"
    [ "$status" -eq 1 ]
}

@test "--add WARNS now about what --apply will DEFER later (commit_devdoc false; workflow file outside the devdoc repo)" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    [ "$status" -eq 0 ]
    [[ "$output" == *"commit_devdoc"*"DEFER"* ]]
    mkdir -p "$DEVAGENT_TMP/other" && ( cd "$DEVAGENT_TMP/other" && git init -q )
    export TEMPLATE_PATHS_OVERRIDE_potholes_workflow="$DEVAGENT_TMP/other/wf.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- a neutral line ($TEST_PROJECT Issue-1)."
    [ "$status" -eq 0 ]
    [[ "$output" == *"containment"*"DEFER"* ]]
}

# --- --apply -------------------------------------------------------------------

@test "--apply bootstraps an ABSENT project layer, appends at the END of its section, adds + commits it path-scoped in the devdoc repo" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    echo foreign > "$DEVDOC_REPO/other.txt"; ( cd "$DEVDOC_REPO" && git add other.txt )   # concurrent staged file
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    [ -f "$PROJ_REG" ]
    grep -qxF -- '- a neutral line (Issue-1).' "$PROJ_REG"
    grep -q '^## Docs / edit-neighborhood hygiene$' "$PROJ_REG"
    run awk 'prev ~ /^- / && /^## / {c++} {prev=$0} END{print c+0}' "$PROJ_REG"
    [ "$output" = "0" ]
    run bash -c "cd '$DEVDOC_REPO' && git show --stat --format= HEAD"
    [[ "$output" == *"testproj/templates/potholes.md"* ]]
    [[ "$output" != *other.txt* ]]
    run bash -c "cd '$DEVDOC_REPO' && git status --porcelain"
    [[ "$output" == *"A  other.txt"* ]]
    [[ "$output" != *"potholes.md"* ]]                       # committed, not left dirty
    run bash -c "cd '$DEVDOC_REPO' && git log -1 --format=%s"
    [ "$output" = "chore: promote pothole-register entries from #1" ]
    run bash -c "cd '$DEVDOC_REPO' && git log -1 --format=%b"
    [[ "$output" == *"layer: project"*"branch: main"* ]]
    run bash -c "cd '$DEVDOC_REPO' && git log -1 --format=%ae"
    [ "$output" = "t@example.com" ]                          # the operator's identity, never devagent@local
    sha="$(cd "$DEVDOC_REPO" && git rev-parse --short HEAD)"
    grep -qx "status: applied $sha" "$ID/potholes-promotion.md"
    [ ! -e "$PROJ_REG.lock" ]
}

@test "--apply drains BOTH layers: two path-scoped commits, two shas in the stamp, workflow file at the devdoc REPO ROOT is in-bounds" {
    use_workflow
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project  "Docs / edit-neighborhood hygiene" "- p line (Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- w line ($TEST_PROJECT Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    grep -qxF -- '- p line (Issue-1).' "$PROJ_REG"
    grep -qxF -- "- w line ($TEST_PROJECT Issue-1)." "$WF"
    run grep -q 'w line' "$PROJ_REG"; [ "$status" -ne 0 ]
    run grep -q 'p line' "$WF";       [ "$status" -ne 0 ]
    run bash -c "cd '$DEVDOC_REPO' && git log -2 --format=%s"
    [ "${lines[0]}" = "chore: promote pothole-register entries from #1" ]
    [ "${lines[1]}" = "chore: promote pothole-register entries from #1" ]
    run bash -c "cd '$DEVDOC_REPO' && git show --stat --format= HEAD~1"
    [[ "$output" == *"templates/potholes.md"* ]] && [[ "$output" != *"testproj/templates"* ]]   # workflow first
    s1="$(cd "$DEVDOC_REPO" && git rev-parse --short HEAD~1)"; s2="$(cd "$DEVDOC_REPO" && git rev-parse --short HEAD)"
    grep -qx "status: applied $s1,$s2" "$ID/potholes-promotion.md"
    run grep -q 'a neutral line\|p line\|w line' "$SEED"; [ "$status" -ne 0 ]     # the seed is never written
}

@test "--apply adds a union-valid heading the layer file lacks, and appends an existing layer at section END preserving the blank run" {
    seed_project_layer
    printf '\n## Tail section\n- t (Issue-8).\n' >> "$PROJ_REG"; devdoc_commit tail
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Bash exit-status & control flow" "- from a seed-only heading (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    run awk '/^## Docs/{f=1;next} f&&/^## /{exit} f&&NF{last=$0} END{print last}' "$PROJ_REG"
    [ "$output" = "- a neutral line (Issue-1)." ]
    grep -q '^## Bash exit-status & control flow$' "$PROJ_REG"
    grep -qxF -- '- from a seed-only heading (Issue-1).' "$PROJ_REG"
    run awk 'prev ~ /^- / && /^## / {c++} {prev=$0} END{print c+0}' "$PROJ_REG"
    [ "$output" = "0" ]
}

@test "--apply lands a backslash-bearing line byte-exact (no awk -v escape processing)" {
    line='- a regex like \( or \[ must survive \\ verbatim (Issue-1).'
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "$line"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    grep -qxF -- "$line" "$PROJ_REG"
}

@test "--apply preserves STAGING order within a section (plain append, no LIFO)" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- first (Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- second (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    run awk '/^## Docs/{f=1;next} f&&/^## /{exit} f&&/Issue-1/' "$PROJ_REG"
    [ "${lines[0]}" = "- first (Issue-1)." ]
    [ "${lines[1]}" = "- second (Issue-1)." ]
}

@test "--apply is a no-op (rc 0) with no staging file; with every line already present it stamps applied <devdoc HEAD> and commits nothing" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    seed_project_layer
    printf '%s\n' '- a neutral line (Issue-1).' >> "$PROJ_REG"; devdoc_commit present
    before="$(cd "$DEVDOC_REPO" && git rev-parse --short HEAD)"
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]
    grep -qx "status: applied $before" "$ID/potholes-promotion.md"
    [ "$(cd "$DEVDOC_REPO" && git rev-parse --short HEAD)" = "$before" ]
    [ "$(grep -c -- '- a neutral line (Issue-1).' "$PROJ_REG")" -eq 1 ]
}

@test "--apply DEFERS (rc 3) when commit_devdoc is false — BEFORE any gate, so DA_YES=1 cannot override the operator's flag; nothing written" {
    devagent_config_set_bool "$HOME/.claude/devagent/config.toml" "project.$TEST_PROJECT.permissions.commit_devdoc" false
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    DA_YES=1 run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"commit_devdoc"* ]]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
    [ ! -e "$PROJ_REG" ]
    run bash -c "cd '$DEVDOC_REPO' && git status --porcelain"
    [[ "$output" == "?? testproj/Issue-1/"* ]]           # only the staging file
}

@test "--apply DEFERS (rc 3) when the target is dirty or untracked, leaving the foreign edit untouched" {
    seed_project_layer
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    printf '%s\n' '- a FOREIGN session line (Issue-3).' >> "$PROJ_REG"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *dirty* ]]
    grep -q FOREIGN "$PROJ_REG"
    run grep -q 'a neutral line' "$PROJ_REG"; [ "$status" -ne 0 ]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
    # untracked skeleton left by something else → same DEFER
    ( cd "$DEVDOC_REPO" && git checkout -q -- testproj/templates/potholes.md )
    use_workflow; mkdir -p "$(dirname "$WF")"; printf '# stray\n' > "$WF"
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- w ($TEST_PROJECT Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *untracked* ]]
}

@test "--apply DEFERS (rc 3) when the devdoc repo is mid-merge" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    ( cd "$DEVDOC_REPO" && git rev-parse HEAD > .git/MERGE_HEAD )
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"mid-merge"* ]]
    [ ! -e "$PROJ_REG" ]
}

@test "--apply DEFERS (rc 3) when the workflow path is outside the repo holding devdoc_dir (containment bound)" {
    mkdir -p "$DEVAGENT_TMP/other" && ( cd "$DEVAGENT_TMP/other" && git init -q )
    export TEMPLATE_PATHS_OVERRIDE_potholes_workflow="$DEVAGENT_TMP/other/wf.md"
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- w ($TEST_PROJECT Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"not inside the git repo holding devdoc_dir"* ]]
    [ ! -e "$DEVAGENT_TMP/other/wf.md" ]
}

@test "--apply DEFERS (rc 3) on a PROJECT override pointing into the source repo (not a workflow-path DEFER in disguise)" {
    export TEMPLATE_PATHS_OVERRIDE_potholes="$SOURCE_DIR/templates/potholes.md"
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- p (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"project register"*"not inside the git repo holding devdoc_dir"* ]]
    [ ! -e "$SOURCE_DIR/templates/potholes.md" ]
}

@test "--apply DEFERS (rc 3) on a SYMLINKED layer path (never writes through the containment bound)" {
    mkdir -p "$DEVAGENT_TMP/elsewhere" "$DEVDOC_DIR/templates"
    printf '# outside\n' > "$DEVAGENT_TMP/elsewhere/reg.md"
    ln -s "$DEVAGENT_TMP/elsewhere/reg.md" "$PROJ_REG"
    devdoc_commit link
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *symlink* ]]
    run grep -q 'a neutral line' "$DEVAGENT_TMP/elsewhere/reg.md"; [ "$status" -ne 0 ]
}

@test "--apply DEFERS (rc 3) naming the lock when a second writer holds it; a stale lock is never swept by a devdoc commit" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    mkdir -p "$PROJ_REG.lock"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"$PROJ_REG.lock"* ]]
    [ ! -e "$PROJ_REG" ]
    run bash -c "cd '$DEVDOC_REPO' && git add -A && git status --porcelain"
    [[ "$output" != *".lock"* ]]                            # an empty dir is invisible to git
    rmdir "$PROJ_REG.lock"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply             # re-runs cleanly once released
    [ "$status" -eq 0 ]
}

@test "--apply on a bootstrapped file whose commit FAILS leaves no file, no index entry, no dir; stays pending" {
    ( cd "$DEVDOC_REPO" && git config user.email "" && git config user.name "" )
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run env GIT_AUTHOR_NAME='' GIT_AUTHOR_EMAIL='' GIT_COMMITTER_NAME='' GIT_COMMITTER_EMAIL='' EMAIL='' \
        bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"restored"* ]]
    [ ! -e "$PROJ_REG" ]; [ ! -d "$DEVDOC_DIR/templates" ]
    run bash -c "cd '$DEVDOC_REPO' && git status --porcelain"
    [[ "$output" == "?? testproj/Issue-1/"* ]]
    grep -q '^status: pending' "$ID/potholes-promotion.md"
    [ ! -e "$PROJ_REG.lock" ]
}

@test "--apply on an EXISTING file whose commit fails restores the original bytes" {
    seed_project_layer
    ( cd "$DEVDOC_REPO" && git config user.email "" && git config user.name "" )
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run env GIT_AUTHOR_NAME='' GIT_AUTHOR_EMAIL='' GIT_COMMITTER_NAME='' GIT_COMMITTER_EMAIL='' EMAIL='' \
        bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 1 ]
    run bash -c "cd '$DEVDOC_REPO' && git status --porcelain -- testproj/templates/potholes.md"
    [ -z "$output" ]
}

@test "--apply chore commit cites a fork issue as #Fork-N, not #N" {
    mkdir -p "$DEVDOC_DIR/Issue-Fork-7"; cp "$ID/checklist.md" "$DEVDOC_DIR/Issue-Fork-7/checklist.md"
    bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-Fork-7" --add --layer project "Docs / edit-neighborhood hygiene" "- a fork line (Issue-Fork-7)."
    run bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-Fork-7" --apply
    [ "$status" -eq 0 ]
    run bash -c "cd '$DEVDOC_REPO' && git log -1 --format=%s"
    [ "$output" = "chore: promote pothole-register entries from #Fork-7" ]
}

@test "--apply DIES on a pre-existing staged block with no layer line (none exist in the wild)" {
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: pending' '' '## Docs / edit-neighborhood hygiene' '- a line (Issue-1).' > "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"layer"* ]]
    [ ! -e "$PROJ_REG" ]
}

@test "two issues closing out in sequence both land on the shared workflow file (second sees an advanced, clean HEAD)" {
    use_workflow
    mkdir -p "$DEVDOC_DIR/Issue-2"; cp "$ID/checklist.md" "$DEVDOC_DIR/Issue-2/checklist.md"
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- one ($TEST_PROJECT Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-2" --add --layer workflow "Docs / edit-neighborhood hygiene" "- two ($TEST_PROJECT Issue-2)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply;                   [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-2" --apply;   [ "$status" -eq 0 ]
    grep -qxF -- "- one ($TEST_PROJECT Issue-1)." "$WF"; grep -qxF -- "- two ($TEST_PROJECT Issue-2)." "$WF"
    [ "$(cd "$DEVDOC_REPO" && git log --format=%s | grep -c 'promote pothole-register')" -eq 2 ]
}

# --- --list-pending ------------------------------------------------------------

@test "--list-pending names every undrained staging file" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- a neutral line (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" --list-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *Issue-1* ]]
}
