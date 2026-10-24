#!/usr/bin/env bats
# tests/transition-docs.bats — #710's documentation AC, pinned. Every transition
# is gated by permissions.transition_issue (on_ship included), the backends take
# --project, and the in-progress signal is the on_draft_start label: each home
# that states the contract must say so, and the retired wording must not return.

load 'lib/bats-helpers'

SPEC="$PLUGIN_ROOT/docs/specs/2026-05-19-devagent-plugin-design.md"

@test "spec §8 gate table lists on_ship under transition_issue (#710)" {
  grep -E '^\| `transition_issue` \|' "$SPEC" | grep -qF '`on_ship` (`ship.sh`, #710)'
  run grep -F '**Not** `on_ship`' "$SPEC"
  [ "$status" -eq 1 ]
}

@test "spec §11 says on_ship is gated and §9.1 names the on_* stages (#710)" {
  grep -E '^\| End of `ship`' "$SPEC" | grep -qF 'gated by `permissions.transition_issue`'
  grep -qF '`on_draft_start`, `on_ship` or `on_merge` (#710)' "$SPEC"
  run grep -F '(e.g., `in_progress`)' "$SPEC"
  [ "$status" -eq 1 ]
}

@test "skills/ship fork_first row names transition_issue (#710)" {
  grep -E '^\| `fork_first = true`' "$PLUGIN_ROOT/skills/ship/SKILL.md" \
    | grep -qF 'only with `permissions.transition_issue = true`'
}

@test "README transition row carries --project (#710)" {
  grep -E '^\| `transition` ' "$PLUGIN_ROOT/README.md" | grep -qF -- '--project <name>'
  grep -qE '^\| `state-exists` ' "$PLUGIN_ROOT/README.md"
}

@test "configuration.md names the on_draft_start label as the in-progress signal (#710)" {
  grep -qF 'the in-progress signal is the label `issue_workflow.on_draft_start`' "$PLUGIN_ROOT/docs-site/configuration.md"
  run grep -F 'github_labels.in_progress' "$PLUGIN_ROOT/docs-site/configuration.md"
  [ "$status" -eq 1 ]
  grep -qF 'every tracker transition (draft, ship, sync) writes only when true' "$PLUGIN_ROOT/docs-site/configuration.md"
}

@test "the config skeleton's transition_issue comment covers every transition (#710)" {
  grep -E '^transition_issue ' "$PLUGIN_ROOT/templates/config.toml.skel" \
    | grep -qF 'every tracker transition (draft, ship, sync) writes only when true'
  run grep -F 'in_progress = "..."' "$PLUGIN_ROOT/templates/config.toml.skel"
  [ "$status" -eq 1 ]
}

@test "CHANGELOG carries the #710 Not breaking line (#710)" {
  grep -qxF '  - Not breaking: the stage names and DEVAGENT_* override names are unchanged.' "$PLUGIN_ROOT/CHANGELOG.md"
  grep -qxF '    Two behaviors stop: a per-stage override with transition_issue = false writing at' "$PLUGIN_ROOT/CHANGELOG.md"
  grep -qxF '    `--project`, whose transitions fail with a warning until it accepts the argument.' "$PLUGIN_ROOT/CHANGELOG.md"
  grep -qF '  - Changed: on_ship is gated by permissions.transition_issue (was ungated, #219/#344).' "$PLUGIN_ROOT/CHANGELOG.md"
}

@test "README and CHANGELOG tell a custom backend it must accept the trailing --project (#710 review)" {
  grep -E '^\| `transition` ' "$PLUGIN_ROOT/README.md" | grep -qF -- '[--project <name>]'
  grep -E '^\| `transition` ' "$PLUGIN_ROOT/README.md" | grep -qF 'a custom backend must accept it and may ignore it'
  grep -qF 'A custom backend must now accept the trailing `--project <name>`' "$PLUGIN_ROOT/CHANGELOG.md"
}
