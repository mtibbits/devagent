#!/usr/bin/env bats

load 'lib/bats-helpers'

setup() {
  setup_tmp_devagent_home
  install_fixture_config config-twoproject.toml
  source "$PLUGIN_ROOT/scripts/lib/paths.sh"
  source "$PLUGIN_ROOT/scripts/lib/io.sh"
  source "$PLUGIN_ROOT/scripts/lib/config.sh"
}

teardown() { teardown_tmp_devagent_home; }

@test "config_load passes on a good file" {
  run config_load
  [ "$status" -eq 0 ]
}

@test "config_load dies on a missing file" {
  rm "$DA_HOME/config.toml"
  run config_load
  [ "$status" -ne 0 ]
}

@test "config_get reads a default" {
  run config_get defaults.checklist_template
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "config_get_project_field reads a nested field" {
  run config_get_project_field volk issue_source.repo
  [ "$status" -eq 0 ]
  [ "$output" = "gnuradio/volk" ]
}

@test "config_list_projects lists both" {
  run config_list_projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"volk"* ]]
  [[ "$output" == *"toy"*  ]]
}

@test "config_is_project true/false" {
  run config_is_project volk
  [ "$status" -eq 0 ]
  run config_is_project nope
  [ "$status" -ne 0 ]
}

@test "config_active_project dies on multi-project file" {
  run config_active_project
  [ "$status" -ne 0 ]
}

@test "config_active_project echoes the one project on single-project file" {
  install_fixture_config config-onproject.toml
  run config_active_project
  [ "$status" -eq 0 ]
  [ "$output" = "volk" ]
}

@test "config_require_project lists projects and suggests init on unknown" {
  run config_require_project nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in config.toml"* ]]
  [[ "$output" == *"configured projects:"* ]]
  [[ "$output" == *"/devagent:init nonexistent"* ]]
}

@test "config_require_project says 'did you mean' with one configured project" {
  install_fixture_config config-onproject.toml
  run config_require_project typo
  [ "$status" -eq 1 ]
  [[ "$output" == *"did you mean 'volk'"* ]]
}

@test "config_require_project returns 0 for a known project" {
  run config_require_project volk
  [ "$status" -eq 0 ]
}

# --- #82: tilde expansion ---------------------------------------------------

@test "expand_tilde: ~/x -> \$HOME/x [#82]" {
  run expand_tilde '~/x'
  [ "$output" = "$HOME/x" ]
}
@test "expand_tilde: bare ~ -> \$HOME [#82]" {
  run expand_tilde '~'
  [ "$output" = "$HOME" ]
}
@test "expand_tilde: ~root/x -> root's passwd home + /x (not \${HOME}root) [#82]" {
  local rh; rh="$(getent passwd root | cut -d: -f6)"
  run expand_tilde '~root/x'
  [ "$output" = "${rh}/x" ]
}
@test "expand_tilde: unknown user left untouched, never mangled [#82]" {
  run expand_tilde '~no_such_user_zzq/x'
  [ "$output" = '~no_such_user_zzq/x' ]
}
@test "expand_tilde: absolute path untouched [#82]" {
  run expand_tilde '/a/b'
  [ "$output" = '/a/b' ]
}
@test "expand_tilde: mid-string tilde untouched (only leading) [#82]" {
  run expand_tilde '/a/~b'
  [ "$output" = '/a/~b' ]
}

@test "config_get_project_field expands ~ in a path field (devdoc_dir) [#82]" {
  run config_get_project_field volk devdoc_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/src/devDoc/volk" ]   # fixture has '~/src/devDoc/volk'
}
@test "config_get_project_field expands ~ in source_dir too [#82]" {
  run config_get_project_field volk source_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/src/volk" ]
}
@test "config_get_project_field does NOT expand a non-path field [#82]" {
  run config_get_project_field volk default_baseline
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]             # git ref, untouched
}

# --- #246: public project_devdoc_dir resolver (moved here from depends.sh) ---
# Sourcing ONLY the config trio (paths/io/config, per setup) proves the resolver
# genuinely lives in config.sh — not depends.sh. Preserves the #78 fail-loud +
# DEVAGENT_TEST_DEVDOC behavior. Hermetic bash -c with its own DA_HOME.

@test "project_devdoc_dir resolves from config via config.sh alone [#246]" {
  local tmp_home; tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/devdoc-target"
  printf '[project.cfgproj]\ndevdoc_dir = "%s/devdoc-target"\n' "${tmp_home}" > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir cfgproj"
  local expected="${tmp_home}/devdoc-target"
  rm -rf "${tmp_home}"
  [ "$status" -eq 0 ]
  [ "$output" = "${expected}" ]
}

@test "project_devdoc_dir honors DEVAGENT_TEST_DEVDOC override [#246]" {
  run env DEVAGENT_TEST_DEVDOC=/tmp/devdoc-override-xyz bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir anyproj"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/devdoc-override-xyz" ]
}

@test "project_devdoc_dir dies loudly when devdoc_dir cannot be resolved [#246/#78]" {
  local tmp_home; tmp_home="$(mktemp -d)"
  printf '[project.otherproj]\ndevdoc_dir = "%s/x"\n' "${tmp_home}" > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir missingproj"
  rm -rf "${tmp_home}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve devdoc_dir"* ]]
}

@test "project_devdoc_dir dies loudly when devdoc_dir resolves empty [#246/#78]" {
  local tmp_home; tmp_home="$(mktemp -d)"
  printf '[project.emptyproj]\ndevdoc_dir = ""\n' > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" bash -c \
    "source '$PLUGIN_ROOT/scripts/lib/paths.sh'; source '$PLUGIN_ROOT/scripts/lib/io.sh'; source '$PLUGIN_ROOT/scripts/lib/config.sh'; project_devdoc_dir emptyproj"
  rm -rf "${tmp_home}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolved empty"* ]]
}
