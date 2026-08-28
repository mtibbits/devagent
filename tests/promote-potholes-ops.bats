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
