# Shared bats helpers for Phase 9 tooling tests.

setup_phase9_env() {
  PHASE9_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/phase9"
  if [ ! -d "${PHASE9_FIXTURE}" ]; then
    PHASE9_FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/phase9"
  fi
  export PHASE9_FIXTURE

  TEST_TMP="$(mktemp -d)"
  cp -a "${PHASE9_FIXTURE}/devdoc"           "${TEST_TMP}/devdoc"
  cp -a "${PHASE9_FIXTURE}/plugin_templates" "${TEST_TMP}/plugin_templates"
  cp -a "${PHASE9_FIXTURE}/state_dir"        "${TEST_TMP}/state"

  export DEVAGENT_STATE_DIR="${TEST_TMP}/state"
  export DEVAGENT_PLUGIN_TEMPLATES="${TEST_TMP}/plugin_templates"
  export DEVAGENT_TEST_DEVDOC="${TEST_TMP}/devdoc"
  export DEVAGENT_TEST_PROJECT="testproj"

  export DEVAGENT_CONFIG_OVERRIDE="${TEST_TMP}/config.toml"
  cat > "${DEVAGENT_CONFIG_OVERRIDE}" <<EOF
[project.testproj]
devdoc_dir = "${TEST_TMP}/devdoc"
EOF

  DEVAGENT_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  if [ ! -d "${DEVAGENT_REPO_ROOT}/scripts" ]; then
    DEVAGENT_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  fi
  export DEVAGENT_REPO_ROOT
  export DEVAGENT_LIB="${DEVAGENT_REPO_ROOT}/scripts/lib"
}

teardown_phase9_env() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "${TEST_TMP}" ]; then
    rm -rf "${TEST_TMP}"
  fi
}
