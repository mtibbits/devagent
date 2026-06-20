#!/usr/bin/env bats

load lib/_helpers

setup() { setup_phase9_env; }
teardown() { teardown_phase9_env; }

@test "history.sh whole project prints all entries sorted" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  echo "$output" | grep -q "Issue-101"
  echo "$output" | grep -q "Issue-102"
}

@test "history.sh issue scoped prints one issue only" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Issue-100"
  run grep -q "Issue-101" <<<"$output"
  [ "$status" -ne 0 ]
}

@test "history.sh output format is human-readable" {
  run bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" \
    --project "${DEVAGENT_TEST_PROJECT}" Issue-100
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^2026-05-10 09:00 +Issue-100 +pull: +fetched'
}

# --- #79: history.sh devdoc resolution comes from config, end-to-end (locks #78) ---
# Strip DEVAGENT_TEST_DEVDOC; point a hermetic DA_HOME config at the SAME phase9
# devdoc the override uses, so resolution must come from config. On pre-#78 code
# history.sh would resolve $HOME/devdoc and print nothing.

@test "#79: history.sh resolves devdoc via config, not \$HOME/devdoc" {
  local th; th="$(mktemp -d)"
  printf '[project.p79]\ndevdoc_dir = "%s"\n' "${DEVAGENT_TEST_DEVDOC}" > "${th}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${th}" \
    bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" --project p79
  rm -rf "${th}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Issue-100"* ]]
}

@test "#79: history.sh fails loud on unresolvable project (no silent \$HOME/devdoc)" {
  local th; th="$(mktemp -d)"
  printf '[project.other]\ndevdoc_dir = "%s/x"\n' "${th}" > "${th}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${th}" \
    bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" --project missing79
  rm -rf "${th}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve devdoc_dir"* ]]
}

@test "#239: history.sh prints ONE error line (no redundant empty 'devdoc dir not found') on unresolvable project" {
  # die in the $(...) capture exits only the subshell; the parent used to fall
  # through to '[ ! -d "" ]' and print a 2nd, empty-path line. '|| exit 2' must
  # collapse it to a single message with rc 2.
  local th; th="$(mktemp -d)"
  printf '[project.other]\ndevdoc_dir = "%s/x"\n' "${th}" > "${th}/config.toml"
  run env -u DEVAGENT_TEST_DEVDOC DA_HOME="${th}" \
    bash "${DEVAGENT_REPO_ROOT}/scripts/history.sh" --project missing239
  rm -rf "${th}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot resolve devdoc_dir"* ]]
  [[ "$output" != *"devdoc dir not found"* ]]   # no redundant second line
}
