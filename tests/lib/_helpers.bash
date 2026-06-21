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

  # #238: make config resolution hermetic. config_path() resolves to
  # $(devagent_home)/config.toml = $DA_HOME/config.toml, so pointing DA_HOME at the
  # per-test tmp keeps EVERY config read off the operator's real
  # ~/.claude/devagent/config.toml — not just the devdoc_dir lookup that
  # DEVAGENT_TEST_DEVDOC short-circuits. Replaces the vestigial
  # DEVAGENT_CONFIG_OVERRIDE export, which no script ever read. source_dir is a
  # non-devdoc field so a test can prove general (not devdoc-only) hermeticity.
  export DA_HOME="${TEST_TMP}"
  cat > "${TEST_TMP}/config.toml" <<EOF
[project.testproj]
devdoc_dir = "${TEST_TMP}/devdoc"
source_dir = "${TEST_TMP}/src"
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
