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
