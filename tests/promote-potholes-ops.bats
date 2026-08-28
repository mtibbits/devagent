#!/usr/bin/env bats
# #612: register OPS — multi-token citation grammar, --retire / --amend / --drop,
# keyed op: staging blocks, validate-all-then-write --apply, Retired section,
# warn-cap. Staging + drain basics live in tests/promote-potholes.bats.
load 'helpers/common'
load 'helpers/potholes-fixture'
setup()    { potholes_fixture_setup; }
teardown() { devagent_test_teardown; }

# A committed project layer holding a line with every shell-special character
# an exact-line op must survive.
SPECIAL='- a line with (parens) [brackets] *stars* $dollar and \back (Issue-9).'
seed_special_layer() {
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '# Pothole register (project)' '' \
        '## Docs / edit-neighborhood hygiene' "$SPECIAL" '- plain (Issue-11).' '' \
        '## Project-only heading' '- p (Issue-10).' > "$PROJ_REG"
    ( cd "$DEVDOC_REPO" && git add -A && git commit -q -m proj )
}

# --- floor -------------------------------------------------------------------

@test "ops: --retire / --amend / --drop are recognised modes (anti-vacuous floor, #572)" {
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire
    [ "$status" -ne 127 ]
    [[ "$output" == *"--retire"* ]]                 # the usage text names the new mode
}

# --- grammar (lib) --------------------------------------------------------------
_lib() { . "$DEVAGENT_ROOT/scripts/lib/template_resolve.sh"; }

@test "grammar: potholes_cite_tokens splits a multi-token tail; rejects a bad tail" {
    _lib
    run potholes_cite_tokens '- x (devagent Issue-541; lawFirm Issue-9).'
    [ "$status" -eq 0 ]
    [ "$output" = $'devagent Issue-541\nlawFirm Issue-9' ]
    run potholes_cite_tokens '- x (devagent Issue-541; lawFirm Issue-9)'      # no trailing dot
    [ "$status" -eq 1 ]
    run potholes_cite_tokens '- x (Issue-541;lawFirm Issue-9).'               # missing space after ;
    [ "$status" -eq 1 ]
}

@test "grammar: potholes_line_cite_ok — every token in the layer's form AND the own token present" {
    _lib
    run potholes_line_cite_ok testproj Issue-1 workflow '- x (lawFirm Issue-9; testproj Issue-1).'
    [ "$status" -eq 0 ]                                                        # own token not first: fine
    run potholes_line_cite_ok testproj Issue-1 workflow '- x (Issue-9; testproj Issue-1).'
    [ "$status" -eq 1 ]; [[ "$output" == *"Issue-9"* ]]                        # bare token refused in the workflow layer
    run potholes_line_cite_ok testproj Issue-1 workflow '- x (lawFirm Issue-1; other Issue-2).'
    [ "$status" -eq 1 ]; [[ "$output" == *"testproj Issue-1"* ]]               # own token absent
    run potholes_line_cite_ok testproj Issue-1 project '- x (Issue-9; Issue-1).'
    [ "$status" -eq 0 ]
    run potholes_line_cite_ok testproj Issue-1 project '- x (testproj Issue-9; Issue-1).'
    [ "$status" -eq 1 ]                                                        # project-qualified token refused in the project layer
    run potholes_line_cite_ok testproj Issue-1 project '- x (Issue-10).'
    [ "$status" -eq 1 ]                                                        # Issue-1 is not a prefix match of Issue-10
}

@test "grammar: potholes_cite_re matches the own token anywhere in a multi-token list, never as a prefix" {
    _lib
    re="$(potholes_cite_re testproj Issue-1 workflow)"
    printf '%s\n' '- x (lawFirm Issue-9; testproj Issue-1).' | grep -qE -- "$re"
    printf '%s\n' '- x (testproj Issue-1; lawFirm Issue-9).' | grep -qE -- "$re"
    run grep -qE -- "$re" <(printf '%s\n' '- x (testproj Issue-10; lawFirm Issue-9).'); [ "$status" -eq 1 ]
    run grep -qE -- "$re" <(printf '%s\n' '- x (Issue-1; lawFirm Issue-9).');           [ "$status" -eq 1 ]
    re="$(potholes_cite_re testproj Issue-1 project)"
    printf '%s\n' '- x (Issue-9; Issue-1).' | grep -qE -- "$re"
}

@test "grammar: the union dedupe stripper strips the WHOLE multi-token suffix (seed line + its merged workflow copy dedupe)" {
    use_workflow
    mkdir -p "$(dirname "$WF")"
    printf '%s\n' '# WF' '' '## Bash exit-status & control flow' \
        "- a seed line ($TEST_PROJECT Issue-7; lawFirm Issue-2)." > "$WF"
    run bash "$DEVAGENT_ROOT/scripts/template.sh" --project "$TEST_PROJECT" show potholes
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'a seed line')" -eq 1 ]
}

@test "grammar: POTHOLES_SECTION_CAP is defined once in the lib; neither the script nor the skill retypes the number" {
    _lib
    [ "$POTHOLES_SECTION_CAP" -eq 25 ]
    [ "$(grep -c '^POTHOLES_SECTION_CAP=' "$DEVAGENT_ROOT/scripts/lib/potholes.sh")" -eq 1 ]
    run grep -nE '(^|[^0-9])25([^0-9]|$)' "$DEVAGENT_ROOT/scripts/promote-potholes.sh"
    [ "$status" -eq 1 ]                                                        # NO literal 25 anywhere in the script — it reads the lib constant
    run grep -nE '(^|[^0-9])25([^0-9]|$)' "$DEVAGENT_ROOT/skills/core-lessons-learned/SKILL.md"
    [ "$status" -eq 1 ]                                                        # nor in the skill prose (Task 9): the warning carries the number
}

@test "show potholes: the READ union omits every layer's Retired section; the CHECK union still sees it" {
    seed_project_layer
    printf '%s\n' '' '## Retired (mechanised)' \
        '- [Docs / edit-neighborhood hygiene] a retired line — mechanised by foo (Issue-9; Issue-1).' >> "$PROJ_REG"
    devdoc_commit retired
    run bash "$DEVAGENT_ROOT/scripts/template.sh" --project "$TEST_PROJECT" show potholes
    [ "$status" -eq 0 ]
    [[ "$output" != *"a retired line"* ]]
    [[ "$output" != *"## Retired (mechanised)"* ]]
    [[ "$output" == *"- a project line (Issue-9)."* ]]                         # active lines still shown
    _lib
    run potholes_union_headings "$TEST_PROJECT"
    [[ "$output" != *"Retired"* ]]
    potholes_cited_union "$TEST_PROJECT" Issue-1                               # the CHECK union reads the FILE
}

# --- --add on the shared grammar --------------------------------------------------

@test "--add: a merged multi-token line is legal; every token must take the layer's form; the own token must be present" {
    use_workflow
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- merged (lawFirm Issue-9; $TEST_PROJECT Issue-1)."
    [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- merged (Issue-9; $TEST_PROJECT Issue-1)."
    [ "$status" -eq 1 ]; [[ "$output" == *"Issue-9"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- merged (lawFirm Issue-9; lawFirm Issue-1)."
    [ "$status" -eq 1 ]; [[ "$output" == *"$TEST_PROJECT Issue-1"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- merged (Issue-9; Issue-1)."
    [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- merged ($TEST_PROJECT Issue-9; Issue-1)."
    [ "$status" -eq 1 ]
}

@test "--add: the body-strip strips the WHOLE multi-token suffix — a devagent-authored merged workflow line passes the project-name rail" {
    use_workflow
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- neutral body ($TEST_PROJECT Issue-3; $TEST_PROJECT Issue-1)."
    [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- the $TEST_PROJECT body (lawFirm Issue-3; $TEST_PROJECT Issue-1)."
    [ "$status" -eq 1 ]; [[ "$output" == *"names the project"* ]]
}

@test "--add: own token normalised to the config spelling inside a multi-token list" {
    use_workflow
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer workflow "Docs / edit-neighborhood hygiene" "- merged (lawFirm Issue-9; TESTPROJ Issue-1)."
    [ "$status" -eq 0 ]
    grep -qxF -- "- merged (lawFirm Issue-9; $TEST_PROJECT Issue-1)." "$ID/potholes-promotion.md"
}

@test "--add refuses the Retired section as a target" {
    seed_project_layer
    printf '%s\n' '' '## Retired (mechanised)' '- [x] r — mechanised by y (Issue-9; Issue-2).' >> "$PROJ_REG"; devdoc_commit r
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Retired (mechanised)" "- x (Issue-1)."
    [ "$status" -eq 1 ]; [[ "$output" == *"Retired"* ]]
    [ ! -e "$ID/potholes-promotion.md" ]
}

@test "--add writes an 'op: add' keyed block; --list-pending counts blocks" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- one (Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- two (Issue-1)."
    [ "$(grep -c '^op: add$' "$ID/potholes-promotion.md")" -eq 2 ]
    run bash "$PP" "$TEST_PROJECT" --list-pending
    [[ "$output" == *"(2 ops)"* ]]
}

@test "--add WARNS (never refuses) at >= POTHOLES_SECTION_CAP bullets in the target section of the target LAYER FILE, naming section, count and cap; the union is not counted" {
    mkdir -p "$DEVDOC_DIR/templates"
    { printf '%s\n' '# P' '' '## Docs / edit-neighborhood hygiene'
      for i in $(seq 1 25); do printf -- '- filler %s (Issue-%s).\n' "$i" "$i"; done
      printf '%s\n' '' '## Bash exit-status & control flow' '- one (Issue-3).'; } > "$PROJ_REG"
    devdoc_commit full
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- x (Issue-1)."
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docs / edit-neighborhood hygiene"*"25"*"25"* ]]
    grep -qxF -- '- x (Issue-1).' "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Bash exit-status & control flow" "- y (Issue-1)."
    [ "$status" -eq 0 ]
    [[ "$output" != *"cap"* ]]                        # 1 bullet in the file's section; the seed's 1 is not added to it
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply      # a full section never blocks the drain
    [ "$status" -eq 0 ]
}

# --- staging blocks / --drop ------------------------------------------------------

@test "--apply: a block without op: is an add (legacy); an unknown op: dies (rc 1) writing nothing" {
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: pending' '' \
        '## Docs / edit-neighborhood hygiene' 'layer: project' '- legacy (Issue-1).' > "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 0 ]; grep -qxF -- '- legacy (Issue-1).' "$PROJ_REG"
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: pending' '' \
        '## Docs / edit-neighborhood hygiene' 'layer: project' 'op: frobnicate' '- x (Issue-1).' > "$ID/potholes-promotion.md"
    before="$(cd "$DEVDOC_REPO" && git rev-parse HEAD)"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 1 ]; [[ "$output" == *"frobnicate"* ]]
    [ "$(cd "$DEVDOC_REPO" && git rev-parse HEAD)" = "$before" ]
    run grep -q 'x (Issue-1)' "$PROJ_REG"; [ "$status" -ne 0 ]
}

@test "--apply: a retire/amend block with a stray bare '- ' line dies (never read as a second add)" {
    seed_project_layer
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: pending' '' \
        '## Docs / edit-neighborhood hygiene' 'layer: project' 'op: retire' 'old: - a project line (Issue-9).' 'mechanism: foo' '- stray (Issue-1).' > "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 1 ]; [[ "$output" == *"stray"* ]]
    run grep -q 'stray' "$PROJ_REG"; [ "$status" -ne 0 ]
}

@test "--apply: an add block with TWO bare bullets dies (one op per block) — nothing written" {
    printf '%s\n' '# Pothole promotion — Issue-1' 'status: pending' '' \
        '## Docs / edit-neighborhood hygiene' 'layer: project' '- a (Issue-1).' '- b (Issue-1).' > "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply
    [ "$status" -eq 1 ]; [[ "$output" == *"one op per block"* ]]
    [ ! -e "$PROJ_REG" ]
}

@test "--drop refuses on a non-pending file; dropping the last op flips status to dropped, which --apply ignores and --check reads as no promise" {
    seed_project_layer
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- one (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --apply; [ "$status" -eq 0 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --drop 1; [ "$status" -eq 1 ]; [[ "$output" == *"not pending"* ]]
    grep -q '^## Docs' "$ID/potholes-promotion.md"                              # record intact
    mkdir -p "$DEVDOC_DIR/Issue-2"; cp "$ID/checklist.md" "$DEVDOC_DIR/Issue-2/checklist.md"
    bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-2" --add --layer project "Docs / edit-neighborhood hygiene" "- two (Issue-2)."
    run bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-2" --drop 1; [ "$status" -eq 0 ]
    grep -qx 'status: dropped (all ops)' "$DEVDOC_DIR/Issue-2/potholes-promotion.md"
    before="$(cd "$DEVDOC_REPO" && git rev-parse HEAD)"
    run bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-2" --apply; [ "$status" -eq 0 ]
    [ "$(cd "$DEVDOC_REPO" && git rev-parse HEAD)" = "$before" ]
    run bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-2" --check; [ "$status" -eq 0 ]                      # no log claim, no promise: clean
    printf '%s\n' "$LL register: 1 staged; retired: 0, amended: 0" >> "$DEVDOC_DIR/Issue-2/checklist.md"
    run bash "$PP" "$TEST_PROJECT" "$DEVDOC_DIR/Issue-2" --check; [ "$status" -eq 1 ]                      # the stale log claim is honestly refused, with the fix named
    [[ "$output" == *"correct the log line"* ]]
}

@test "--drop <n> removes the nth block; out of range refuses; --list-pending count follows" {
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- one (Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- two (Issue-1)."
    bash "$PP" "$TEST_PROJECT" "$ID" --add --layer project "Docs / edit-neighborhood hygiene" "- three (Issue-1)."
    run bash "$PP" "$TEST_PROJECT" "$ID" --drop 4;  [ "$status" -eq 1 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --drop 0;  [ "$status" -eq 2 ]
    run bash "$PP" "$TEST_PROJECT" "$ID" --drop 2;  [ "$status" -eq 0 ]
    run grep -c '^## ' "$ID/potholes-promotion.md"; [ "$output" = "2" ]
    run grep -q 'two (Issue-1)' "$ID/potholes-promotion.md"; [ "$status" -ne 0 ]
    grep -q '^- one (Issue-1)\.$' "$ID/potholes-promotion.md"; grep -q '^- three (Issue-1)\.$' "$ID/potholes-promotion.md"
    grep -q '^status: pending$' "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" --list-pending; [[ "$output" == *"(2 ops)"* ]]
}

# --- --retire / --amend staging -----------------------------------------------------

@test "--retire stages a keyed block; the result line carries [section], the mechanism, old tokens + own token" {
    seed_special_layer
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "$SPECIAL" "the --foo guard in bar.sh"
    [ "$status" -eq 0 ]
    grep -qxF -- 'op: retire' "$ID/potholes-promotion.md"
    grep -qxF -- "old: $SPECIAL" "$ID/potholes-promotion.md"
    grep -qxF -- 'mechanism: the --foo guard in bar.sh' "$ID/potholes-promotion.md"
    grep -qxF -- '## Docs / edit-neighborhood hygiene' "$ID/potholes-promotion.md"
    [ "$(grep -c '^- ' "$ID/potholes-promotion.md")" -eq 0 ]                   # no bare bullet in an op block
    [ ! -e "$PROJ_REG.lock" ]; run bash -c "cd '$DEVDOC_REPO' && git status --porcelain -- testproj/templates"; [ -z "$output" ]
}

@test "--retire refuses: --layer missing; heading target; multi-hit; mechanism with ')' or 'Issue-'; multi-line args" {
    seed_project_layer
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire "- a project line (Issue-9)." m;                    [ "$status" -eq 1 ]; [[ "$output" == *"--layer"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "## Project-only heading" m;         [ "$status" -eq 1 ]; [[ "$output" == *"bullet"* ]]
    printf '%s\n' '- a project line (Issue-9).' >> "$PROJ_REG"; devdoc_commit dup
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "- a project line (Issue-9)." m;      [ "$status" -eq 1 ]; [[ "$output" == *"2 times"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "- p (Issue-10)." "a (paren) mech";   [ "$status" -eq 1 ]; [[ "$output" == *")"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "- p (Issue-10)." "see Issue-4";      [ "$status" -eq 1 ]; [[ "$output" == *"Issue-"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "- p (Issue-10)." "$(printf 'a\nb')"; [ "$status" -eq 1 ]
    [ ! -e "$ID/potholes-promotion.md" ]
}

@test "--retire refuses a seed-only line with the distribute-issue message; a line absent everywhere says not found" {
    seed_project_layer
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "- a seed line (Issue-7)." m
    [ "$status" -eq 1 ]; [[ "$output" == *"seed line"*"distribute"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "- nowhere (Issue-7)." m
    [ "$status" -eq 1 ]; [[ "$output" == *"not found"* ]]
}

@test "--retire / --amend refuse a bullet that sits ABOVE the first heading (no section — never an empty '## ' block)" {
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '# Pothole register (project)' '- orphan (Issue-9).' '' '## Project-only heading' '- p (Issue-10).' > "$PROJ_REG"; devdoc_commit orphan
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project "- orphan (Issue-9)." m
    [ "$status" -eq 1 ]; [[ "$output" == *"not found"* ]]
    run bash "$PP" "$TEST_PROJECT" "$ID" --amend --layer project "- orphan (Issue-9)." "- orphan2 (Issue-9; Issue-1)."
    [ "$status" -eq 1 ]
    [ ! -e "$ID/potholes-promotion.md" ]
}

@test "--retire refuses a target that lives only in the Retired section (cannot retire twice)" {
    seed_project_layer
    printf '%s\n' '' '## Retired (mechanised)' '- [x] r — mechanised by y (Issue-9; Issue-2).' >> "$PROJ_REG"; devdoc_commit r
    run bash "$PP" "$TEST_PROJECT" "$ID" --retire --layer project '- [x] r — mechanised by y (Issue-9; Issue-2).' m
    [ "$status" -eq 1 ]; [[ "$output" == *"not found"* ]]
}

@test "--amend stages a keyed block; the new line must keep every old token and add the own token; per-layer form enforced" {
    seed_project_layer
    run bash "$PP" "$TEST_PROJECT" "$ID" --amend --layer project "- a project line (Issue-9)." "- a project line, sharper (Issue-9; Issue-1)."
    [ "$status" -eq 0 ]
    grep -qxF -- 'op: amend' "$ID/potholes-promotion.md"
    grep -qxF -- 'old: - a project line (Issue-9).' "$ID/potholes-promotion.md"
    grep -qxF -- 'new: - a project line, sharper (Issue-9; Issue-1).' "$ID/potholes-promotion.md"
    run bash "$PP" "$TEST_PROJECT" "$ID" --amend --layer project "- p (Issue-10)." "- p, sharper (Issue-1)."
    [ "$status" -eq 1 ]; [[ "$output" == *"Issue-10"* ]]                        # dropped the old token
    run bash "$PP" "$TEST_PROJECT" "$ID" --amend --layer project "- p (Issue-10)." "- p, sharper (Issue-10)."
    [ "$status" -eq 1 ]                                                          # own token missing
    run bash "$PP" "$TEST_PROJECT" "$ID" --amend --layer project "- p (Issue-10)." "- p, sharper ($TEST_PROJECT Issue-10; Issue-1)."
    [ "$status" -eq 1 ]                                                          # qualified token in the project layer
}

@test "--amend cannot rewrite a Retired line back into an active shape" {
    seed_project_layer
    printf '%s\n' '' '## Retired (mechanised)' '- [x] r — mechanised by y (Issue-9; Issue-2).' >> "$PROJ_REG"; devdoc_commit r
    run bash "$PP" "$TEST_PROJECT" "$ID" --amend --layer project '- [x] r — mechanised by y (Issue-9; Issue-2).' '- r again (Issue-9; Issue-2; Issue-1).'
    [ "$status" -eq 1 ]; [[ "$output" == *"not found"* ]]
}

@test "--amend workflow layer: the replacement passes the project-name rail on a multi-token tail" {
    use_workflow
    mkdir -p "$(dirname "$WF")"; printf '%s\n' '# WF' '' '## Docs / edit-neighborhood hygiene' "- w (lawFirm Issue-2)." > "$WF"; devdoc_commit wf
    run bash "$PP" "$TEST_PROJECT" "$ID" --amend --layer workflow "- w (lawFirm Issue-2)." "- w, merged (lawFirm Issue-2; $TEST_PROJECT Issue-1)."
    [ "$status" -eq 0 ]
}
