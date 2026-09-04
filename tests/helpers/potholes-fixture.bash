# tests/helpers/potholes-fixture.bash — shared by tests/promote-potholes.bats
# shellcheck disable=SC2034  # SEED/PROJ_REG/WF/PP/ID/LL are read by the bats files that load this helper
# (#586/#611 staging + drain + check) and tests/promote-potholes-ops.bats (#612
# retire/amend/drop/cap/grammar). Three layers, all FIXTURES: a plugin-seed COPY
# under DEVAGENT_PLUGIN_TEMPLATES with only potholes.md replaced (so the plugin
# rung still resolves every other key), the project layer at the devdoc default
# path, and an optional workflow file at the devdoc REPO root — the production
# shape (devDoc repo root, every project's devdoc_dir inside).
# #338: every loaded setup layer sources the hermetic-env guard (pins / git config / TZ / locale).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/hermetic-env.bash"

potholes_fixture_setup() {
    devagent_test_setup
    export DEVAGENT_PLUGIN_TEMPLATES="$DEVAGENT_TMP/plugin_templates"
    cp -r "$DEVAGENT_ROOT/templates" "$DEVAGENT_PLUGIN_TEMPLATES"
    SEED="$DEVAGENT_PLUGIN_TEMPLATES/potholes.md"
    printf '%s\n' '# Pothole register' '' \
        '## Bash exit-status & control flow' '- a seed line (Issue-7).' '' \
        '## Docs / edit-neighborhood hygiene' '- another seed line (Issue-8).' > "$SEED"
    DEVDOC_REPO="$DEVAGENT_TMP/devdoc"
    ( cd "$DEVDOC_REPO" && git -c init.defaultBranch=main init -q \
      && git config user.email t@example.com && git config user.name Tester \
      && git add -A && git commit -q -m seed )
    PROJ_REG="$DEVDOC_DIR/templates/potholes.md"      # absent until bootstrapped
    WF="$DEVDOC_REPO/templates/potholes.md"            # configured by use_workflow only
    PP="$DEVAGENT_ROOT/scripts/promote-potholes.sh"
    ID="$DEVDOC_DIR/Issue-1"
    LL='- 2026-08-01 10:00  lessonslearned: lessonsLearned.md written: 6 entries (1 actionable, 1 reference, 1 norm, 3 pattern);'
}   # plain shell variables, exactly as the original setup() — no export

use_workflow()   { export TEMPLATE_PATHS_OVERRIDE_potholes_workflow="$WF"; }
potholes_lib()   { . "$DEVAGENT_ROOT/scripts/lib/template_resolve.sh"; }   # the lib under test, in the test shell
# A committed project layer with two sections (one absent from the seed);
# extra arguments are additional bullets under the first section.
seed_project_layer() {
    mkdir -p "$DEVDOC_DIR/templates"
    printf '%s\n' '# Pothole register (project)' '' \
        '## Docs / edit-neighborhood hygiene' '- a project line (Issue-9).' "$@" '' \
        '## Project-only heading' '- p (Issue-10).' > "$PROJ_REG"
    ( cd "$DEVDOC_REPO" && git add -A && git commit -q -m proj )
}
# Append a committed Retired section holding one retired line to the project layer.
RETIRED_LINE='- [x] r — mechanised by y (Issue-9; Issue-2).'
seed_retired_line() {
    printf '%s\n' '' '## Retired (mechanised)' "$RETIRED_LINE" >> "$PROJ_REG"
    ( cd "$DEVDOC_REPO" && git add -A && git commit -q -m retired )
}
# The workflow layer under the shared Docs heading, holding the given bullets
# (uncommitted — devdoc_commit when the test needs it tracked).
seed_workflow_layer() {
    mkdir -p "$(dirname "$WF")"
    printf '%s\n' '# WF' '' '## Docs / edit-neighborhood hygiene' "$@" > "$WF"
}
devdoc_commit() { ( cd "$DEVDOC_REPO" && git add -A && git commit -q -m "$1" ); }
