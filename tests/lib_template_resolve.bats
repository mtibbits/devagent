#!/usr/bin/env bats
bats_require_minimum_version 1.5.0   # #341: run --separate-stderr

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "template_resolve: devdoc override wins over plugin default" {
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "devdoc/templates/coding_standards.md"
  echo "$output" | grep -q "layer=devdoc"
}

@test "template_resolve: falls back to plugin templates when no devdoc override" {
  rm "${DEVAGENT_TEST_DEVDOC}/templates/coding_standards.md"
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "plugin_templates/coding_standards.md"
  echo "$output" | grep -q "layer=plugin"
}

@test "template_resolve: project paths override wins over devdoc" {
  override="${TEST_TMP}/my_custom_standards.md"
  printf '# project override\n' > "${override}"
  source "${DEVAGENT_LIB}/template_resolve.sh"
  export TEMPLATE_PATHS_OVERRIDE_coding_standards="${override}"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "my_custom_standards.md"
  echo "$output" | grep -q "layer=project"
}

@test "template_resolve: missing template returns 1" {
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "no_such_template"
  [ "$status" -eq 1 ]
}

@test "template_resolve: dead L1 override warns and falls through (#341)" {
  # Configured override whose file is missing must warn (naming the dead path)
  # while still resolving to a lower layer — not silently skip.
  source "${DEVAGENT_LIB}/template_resolve.sh"
  export TEMPLATE_PATHS_OVERRIDE_coding_standards="${TEST_TMP}/nonexistent-typo.md"
  run --separate-stderr template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  # devdoc has coding_standards.md in this fixture → fall-through lands at devdoc.
  echo "$output" | grep -q "layer=devdoc"
  [[ "$stderr" == *"nonexistent-typo.md"* ]]
  [[ "$stderr" == *"coding_standards"* ]]
}

@test "template_resolve: valid L1 override emits no warn (#341 no-spam)" {
  local override="${TEST_TMP}/present_standards.md"
  printf '# present\n' > "${override}"
  source "${DEVAGENT_LIB}/template_resolve.sh"
  export TEMPLATE_PATHS_OVERRIDE_coding_standards="${override}"
  run --separate-stderr template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=project"
  [ -z "$stderr" ]
}

@test "template_list enumerates known artifact keys" {
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_list "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coding_standards"
  echo "$output" | grep -q "mr_template"
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "layer=plugin"
}

# --- #81: layers must work without the test-only env injection ---

@test "template_resolve: plugin layer resolves via plugin_root with no env (#81)" {
  # Real-world conditions: neither the plugin-templates nor repo-root env is set.
  unset DEVAGENT_PLUGIN_TEMPLATES DEVAGENT_REPO_ROOT DEVAGENT_TEST_DEVDOC
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "mr_template"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=plugin"
  # path points into the real repo templates dir, not a bare /templates
  echo "$output" | grep -qE "/templates/mr_template\.md$"
  echo "$output" | grep -vqE "^path=/templates/"
}

@test "template_resolve: layer 1 honors [project.paths] via config, not just env (#81)" {
  # Real config (config_get_project_field "paths.<key>"), not the env hook.
  local home="${TEST_TMP}/cfghome"
  mkdir -p "${home}"
  local override="${TEST_TMP}/cfg_standards.md"
  printf '# config layer override\n' > "${override}"
  cat > "${home}/config.toml" <<EOF
[project.${DEVAGENT_TEST_PROJECT}.paths]
coding_standards = "${override}"
EOF
  source "${DEVAGENT_LIB}/template_resolve.sh"
  export DA_HOME="${home}"
  run template_resolve "${DEVAGENT_TEST_PROJECT}" "coding_standards"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=project"
  echo "$output" | grep -q "cfg_standards.md"
}
