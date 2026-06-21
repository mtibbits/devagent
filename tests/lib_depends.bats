#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "depends_add writes a single edge to state file" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  [ "$status" -eq 0 ]

  state_file="${DEVAGENT_STATE_DIR}/${DEVAGENT_TEST_PROJECT}.depends.toml"
  [ -f "${state_file}" ]
  grep -q '\[Issue-100\]' "${state_file}"
  grep -q 'depends_on = \["Issue-101"\]' "${state_file}"
}

@test "depends_add is idempotent for repeated edges" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  count="$(depends_list "${DEVAGENT_TEST_PROJECT}" "Issue-100" | wc -w)"
  [ "${count}" -eq 1 ]
}

@test "depends_add refuses self-dependency" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-100"
  [ "$status" -eq 3 ]
}

@test "depends_add appends a second distinct edge" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-102"
  deps="$(depends_list "${DEVAGENT_TEST_PROJECT}" "Issue-100")"
  echo "${deps}" | grep -q "Issue-101"
  echo "${deps}" | grep -q "Issue-102"
}

@test "depends_add rejects A->B when B->A already exists" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-100"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "cycle"
}

@test "depends_add rejects transitive cycle A->B->C->A" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-102"
  run depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-102" "Issue-100"
  [ "$status" -eq 4 ]
}

@test "depends_graph renders ascii tree" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-102"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-101" "Issue-102"
  run depends_graph "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "└── Issue-102"
}

@test "depends_graph on empty project prints '(no dependencies)'" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_graph "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no dependencies"
}

@test "depends_ship_preflight: no deps -> exit 0, silent" {
  source "${DEVAGENT_LIB}/depends.sh"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "0"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "depends_ship_preflight: open dep, non-strict -> warn, exit 0" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "WARNING"
  echo "$output" | grep -q "Issue-101"
}

@test "depends_ship_preflight: open dep, strict -> block, exit 1" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "blocking"
}

@test "depends_ship_preflight: merged dep -> silent, exit 0" {
  source "${DEVAGENT_LIB}/depends.sh"
  depends_add "${DEVAGENT_TEST_PROJECT}" "Issue-100" "Issue-101"
  mkdir -p "${DEVAGENT_TEST_DEVDOC}/Issue-101"
  touch "${DEVAGENT_TEST_DEVDOC}/Issue-101/.merged"
  run depends_ship_preflight "${DEVAGENT_TEST_PROJECT}" "Issue-100" "1"
  [ "$status" -eq 0 ]
}

# --- #78: fail-loud devdoc resolution (no silent $HOME/devdoc fallback) ---
# Each runs project_devdoc_dir in a fresh `bash -c` with its own hermetic tmp
# DA_HOME so config resolves against that dir's config.toml (overriding the
# suite-wide DA_HOME the helper now sets, #238). DEVAGENT_TEST_DEVDOC is stripped
# for the required/config legs so the real resolution path is exercised.

@test "#78/#246: project_devdoc_dir (resolver moved to config.sh) dies loudly when devdoc_dir cannot be resolved" {
  local tmp_home; tmp_home="$(mktemp -d)"
  printf '[project.otherproj]\ndevdoc_dir = "%s/x"\n' "${tmp_home}" > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" \
    bash -c "source '${DEVAGENT_LIB}/depends.sh'; project_devdoc_dir missingproj"
  rm -rf "${tmp_home}"
  [ "$status" -ne 0 ]
  # match the missing-field leg specifically (distinct from the empty-field leg)
  [[ "$output" == *"cannot resolve devdoc_dir"* ]]
}

@test "#78/#246: project_devdoc_dir (resolver moved to config.sh) dies loudly when devdoc_dir resolves empty" {
  local tmp_home; tmp_home="$(mktemp -d)"
  # field present but empty string: config_get_project_field returns rc 0 + empty,
  # so this exercises the second die leg, not the missing-field leg above.
  printf '[project.emptyproj]\ndevdoc_dir = ""\n' > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" \
    bash -c "source '${DEVAGENT_LIB}/depends.sh'; project_devdoc_dir emptyproj"
  rm -rf "${tmp_home}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolved empty"* ]]
}

@test "#78/#246: project_devdoc_dir (resolver moved to config.sh) resolves devdoc_dir from config (self-sourced, no command -v)" {
  local tmp_home; tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/devdoc-target"
  printf '[project.cfgproj]\ndevdoc_dir = "%s/devdoc-target"\n' "${tmp_home}" > "${tmp_home}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${tmp_home}" \
    bash -c "source '${DEVAGENT_LIB}/depends.sh'; project_devdoc_dir cfgproj"
  local expected="${tmp_home}/devdoc-target"
  rm -rf "${tmp_home}"
  [ "$status" -eq 0 ]
  [ "$output" = "${expected}" ]
}

@test "#78/#246: project_devdoc_dir (resolver moved to config.sh) honors DEVAGENT_TEST_DEVDOC override (tolerant leg)" {
  run env DEVAGENT_TEST_DEVDOC=/tmp/devdoc-override-xyz \
    bash -c "source '${DEVAGENT_LIB}/depends.sh'; project_devdoc_dir anyproj"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/devdoc-override-xyz" ]
}

# --- #80: DEVAGENT_STATE_DIR defaults in the lib (no caller export needed) ---
# Only ship.sh exported it; the /devagent:depends entry (set -u) hit an unbound
# variable. The lib now defaults it to <devagent_home>/state, honoring DA_HOME.

@test "#80: depends.sh defaults DEVAGENT_STATE_DIR to <devagent_home>/state (honors DA_HOME)" {
  run env -u DEVAGENT_STATE_DIR DA_HOME=/tmp/da80home \
    bash -c "source '${DEVAGENT_LIB}/depends.sh'; printf '%s\n' \"\${DEVAGENT_STATE_DIR:-UNSET}\""
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/da80home/state" ]
}

@test "#80: depends.sh list works with DEVAGENT_STATE_DIR unset (no unbound error)" {
  local th; th="$(mktemp -d)"
  mkdir -p "${th}/state"
  printf '[Issue-100]\ndepends_on = ["Issue-101"]\n' > "${th}/state/p80.depends.toml"
  run env -u DEVAGENT_STATE_DIR DA_HOME="${th}" DEVAGENT_ACTIVE_PROJECT=p80 \
    bash "${DEVAGENT_REPO_ROOT}/scripts/depends.sh" list
  rm -rf "${th}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"Issue-100"* ]]
  [[ "$output" == *"Issue-101"* ]]
}

@test "#80: depends_add works with DEVAGENT_STATE_DIR unset (creates default dir)" {
  local th; th="$(mktemp -d)"
  run env -u DEVAGENT_STATE_DIR DA_HOME="${th}" \
    bash -c "source '${DEVAGENT_LIB}/depends.sh'; depends_add p80b Issue-200 Issue-201 && cat \"\$(depends_state_file p80b)\""
  rm -rf "${th}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-201"* ]]
}

@test "#238: the test harness resolves config hermetically, never the operator's real ~/.claude/devagent" {
  # The helper used to export a vestigial DEVAGENT_CONFIG_OVERRIDE (read by no
  # script) and never set DA_HOME, so config_path() fell through to the operator's
  # real ~/.claude/devagent/config.toml. DEVAGENT_TEST_DEVDOC only short-circuits
  # the devdoc_dir lookup, NOT arbitrary config reads. Assert hermeticity on a
  # non-devdoc field. Strip DEVAGENT_TEST_DEVDOC to prove the config path itself
  # (not the short-circuit) is what's isolated.
  source "${DEVAGENT_LIB}/paths.sh"
  source "${DEVAGENT_LIB}/config.sh"
  run env -u DEVAGENT_TEST_DEVDOC bash -c \
    "source '${DEVAGENT_LIB}/paths.sh'; config_path"
  [ "$status" -eq 0 ]
  [ "$output" = "${TEST_TMP}/config.toml" ]
  [ "$output" != "${HOME}/.claude/devagent/config.toml" ]
  # A non-devdoc field reads from the temp config, not the operator's real one.
  run env -u DEVAGENT_TEST_DEVDOC bash -c \
    "source '${DEVAGENT_LIB}/paths.sh'; source '${DEVAGENT_LIB}/config.sh'; config_get_project_field ${DEVAGENT_TEST_PROJECT} source_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "${TEST_TMP}/src" ]
}
