#!/usr/bin/env bats

load 'helpers'

setup() {
  setup_tmp_devdoc
  source "${REPO_ROOT}/scripts/capture/lib/template.sh"
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
  # #107/F8: seed the plugin fallback in a TMP dir, never the real checkout's
  # templates/ (the old REPO_ROOT path raced under bats --jobs and leaked on SIGKILL).
  export DEVAGENT_PLUGIN_DIR="${TMP_DEVDOC}/plugin"
  mkdir -p "${DEVAGENT_PLUGIN_DIR}/templates"
  printf '# Bug template (plugin fallback)\n' \
    >"${DEVAGENT_PLUGIN_DIR}/templates/issue_template-bug.md"
}

teardown() { teardown_tmp_devdoc; }

@test "template: falls through to plugin templates dir when nothing else exists" {
  run devagent_resolve_template issue_template-bug
  [ "$status" -eq 0 ]
  [ "$output" = "${DEVAGENT_PLUGIN_DIR}/templates/issue_template-bug.md" ]
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
