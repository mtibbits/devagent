#!/usr/bin/env bats

load '../helpers'

setup() {
  setup_tmp_devdoc
  source "${REPO_ROOT}/scripts/capture/lib/template.sh"
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  export DEVAGENT_PLUGIN_DIR="${REPO_ROOT}"
  mkdir -p "${REPO_ROOT}/templates"
  if [[ ! -f "${REPO_ROOT}/templates/issue_template-bug.md" ]]; then
    SEEDED_PLUGIN_TEMPLATE=1
    printf '# Bug template (plugin fallback)\n' \
      >"${REPO_ROOT}/templates/issue_template-bug.md"
  fi
}

teardown() {
  if [[ "${SEEDED_PLUGIN_TEMPLATE:-0}" -eq 1 ]]; then
    rm -f "${REPO_ROOT}/templates/issue_template-bug.md"
  fi
  teardown_tmp_devdoc
}

@test "template: falls through to plugin templates dir when nothing else exists" {
  run devagent_resolve_template issue_template-bug
  [ "$status" -eq 0 ]
  [ "$output" = "${REPO_ROOT}/templates/issue_template-bug.md" ]
}

@test "template: devdoc templates dir wins over plugin" {
  printf '# devdoc override\n' \
    >"${TMP_DEVDOC}/templates/issue_template-bug.md"
  run devagent_resolve_template issue_template-bug
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/templates/issue_template-bug.md" ]
}

@test "template: project-explicit path wins over devdoc and plugin" {
  printf '# devdoc\n' >"${TMP_DEVDOC}/templates/issue_template-bug.md"
  mkdir -p "${TMP_DEVDOC}/custom"
  printf '# project-explicit\n' \
    >"${TMP_DEVDOC}/custom/bug.md"
  export DEVAGENT_TEMPLATE_OVERRIDE_issue_template_bug="${TMP_DEVDOC}/custom/bug.md"
  run devagent_resolve_template issue_template-bug
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/custom/bug.md" ]
}

@test "template: unknown name returns error" {
  run devagent_resolve_template no_such_template
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such template"* ]]
}
