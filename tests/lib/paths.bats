#!/usr/bin/env bats

load '../helpers'

setup() {
  setup_tmp_devdoc
  source "${REPO_ROOT}/scripts/capture/lib/paths.sh"
  export DEVAGENT_DEVDOC_DIR="${TMP_DEVDOC}"
}

teardown() { teardown_tmp_devdoc; }

@test "paths: captures_root returns <devdoc>/Captures" {
  run devagent_captures_root
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/Captures" ]
}

@test "paths: capture_dir returns <devdoc>/Captures/<slug>" {
  run devagent_capture_dir "2026-05-19-foo"
  [ "$status" -eq 0 ]
  [ "$output" = "${TMP_DEVDOC}/Captures/2026-05-19-foo" ]
}

@test "paths: ensure_capture_dir creates dir and returns path" {
  run devagent_ensure_capture_dir "2026-05-19-foo"
  [ "$status" -eq 0 ]
  [ -d "${TMP_DEVDOC}/Captures/2026-05-19-foo" ]
}

@test "paths: ensure_capture_dir is idempotent" {
  devagent_ensure_capture_dir "2026-05-19-foo"
  run devagent_ensure_capture_dir "2026-05-19-foo"
  [ "$status" -eq 0 ]
}

@test "paths: missing DEVAGENT_DEVDOC_DIR is an error" {
  unset DEVAGENT_DEVDOC_DIR
  run devagent_captures_root
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEVAGENT_DEVDOC_DIR"* ]]
}

@test "paths: rejects slug with slash" {
  run devagent_capture_dir "foo/bar"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid slug"* ]]
}

@test "paths: rejects slug starting with dot" {
  run devagent_capture_dir ".hidden"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid slug"* ]]
}
