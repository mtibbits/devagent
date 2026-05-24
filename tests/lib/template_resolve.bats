#!/usr/bin/env bats

load _helpers

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

@test "template_list enumerates known artifact keys" {
  source "${DEVAGENT_LIB}/template_resolve.sh"
  run template_list "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coding_standards"
  echo "$output" | grep -q "mr_template"
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "layer=plugin"
}
