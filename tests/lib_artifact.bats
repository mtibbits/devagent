#!/usr/bin/env bats
# #336 — direct unit coverage for the §12 three-tier artifact resolver (#120).
load 'helpers/common'

setup() {
    devagent_test_setup
    R="$DEVAGENT_ROOT"
    . "$R/scripts/lib/paths.sh"; . "$R/scripts/lib/io.sh"
    . "$R/scripts/lib/config.sh"; . "$R/scripts/lib/artifact.sh"
}
teardown() { devagent_test_teardown; }

@test "artifact_resolve: missing project or key → rc 2" {
    run artifact_resolve "$TEST_PROJECT"    # missing key
    [ "$status" -eq 2 ]
    run artifact_resolve "" mr_template     # missing project (#336 improve, Bug 1)
    [ "$status" -eq 2 ]
}

@test "artifact_resolve: L3 plugin default when no override/devdoc template" {
    run artifact_resolve "$TEST_PROJECT" mr_template
    [ "$status" -eq 0 ]
    [ "$output" = "$DEVAGENT_ROOT/templates/mr_template.md" ]
}

@test "artifact_resolve: L2 devdoc template shadows L3" {
    mkdir -p "$DEVDOC_DIR/templates"
    echo x > "$DEVDOC_DIR/templates/mr_template.md"
    run artifact_resolve "$TEST_PROJECT" mr_template
    [ "$status" -eq 0 ]
    [ "$output" = "$DEVDOC_DIR/templates/mr_template.md" ]
}

@test "artifact_resolve: L1 absolute override shadows all" {
    local abs="$DEVAGENT_TMP/custom.md"; echo x > "$abs"
    devagent_config_set "$HOME/.claude/devagent/config.toml" \
        "project.$TEST_PROJECT.paths.mr_template" "$abs"
    run artifact_resolve "$TEST_PROJECT" mr_template
    [ "$status" -eq 0 ]
    [ "$output" = "$abs" ]
}

@test "artifact_resolve: L1 devdoc-relative override resolves under devdoc_dir" {
    mkdir -p "$DEVDOC_DIR/custom"; echo x > "$DEVDOC_DIR/custom/mr.md"
    devagent_config_set "$HOME/.claude/devagent/config.toml" \
        "project.$TEST_PROJECT.paths.mr_template" "custom/mr.md"
    run artifact_resolve "$TEST_PROJECT" mr_template
    [ "$status" -eq 0 ]
    [ "$output" = "$DEVDOC_DIR/custom/mr.md" ]
}

@test "artifact_resolve: L1 ABSOLUTE override at a missing file falls through to L3" {
    devagent_config_set "$HOME/.claude/devagent/config.toml" \
        "project.$TEST_PROJECT.paths.mr_template" "/nonexistent/x.md"
    run artifact_resolve "$TEST_PROJECT" mr_template
    [ "$status" -eq 0 ]
    [ "$output" = "$DEVAGENT_ROOT/templates/mr_template.md" ]
}

@test "artifact_resolve: L1 RELATIVE override at a missing file falls through to L3 (#336 improve, Bug 2)" {
    # devdoc-relative override whose target does not exist under devdoc_dir —
    # exercises the relative-branch fall-through, distinct from the absolute one.
    devagent_config_set "$HOME/.claude/devagent/config.toml" \
        "project.$TEST_PROJECT.paths.mr_template" "custom/missing.md"
    run artifact_resolve "$TEST_PROJECT" mr_template
    [ "$status" -eq 0 ]
    [ "$output" = "$DEVAGENT_ROOT/templates/mr_template.md" ]
}

@test "artifact_resolve: rc 1 when the key matches nothing at any tier" {
    run artifact_resolve "$TEST_PROJECT" no_such_template_key_xyz
    [ "$status" -eq 1 ]
}

@test "artifact_resolve_or: empty project → L3 default, rc 0" {
    run artifact_resolve_or "" mr_template
    [ "$status" -eq 0 ]
    [ "$output" = "$DEVAGENT_ROOT/templates/mr_template.md" ]
}

@test "artifact_resolve_or: a miss still returns the L3 default at rc 0" {
    run artifact_resolve_or "$TEST_PROJECT" no_such_template_key_xyz
    [ "$status" -eq 0 ]
    [ "$output" = "$DEVAGENT_ROOT/templates/no_such_template_key_xyz.md" ]
}
