#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "template.sh list shows all keys with their layer" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coding_standards"
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "mr_template"
  echo "$output" | grep -q "layer=plugin"
}

@test "template.sh show prints layer banner and content" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show coding_standards
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=devdoc"
  echo "$output" | grep -q "devdoc override"
}

@test "template.sh show on missing template exits non-zero" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show no_such_thing
  [ "$status" -ne 0 ]
}

@test "template.sh: project override wins over devdoc, shown in banner" {
  override="${TEST_TMP}/proj_standards.md"
  printf '# project layer override\n' > "${override}"
  export TEMPLATE_PATHS_OVERRIDE_coding_standards="${override}"
  run bash "${DEVAGENT_REPO_ROOT}/scripts/template.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" show coding_standards
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "layer=project"
  echo "$output" | grep -q "project layer override"
}
