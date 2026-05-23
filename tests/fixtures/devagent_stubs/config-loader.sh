#!/usr/bin/env bash
# Stub for scripts/lib/config-loader.sh (Plan 1). Real impl reads
# ~/.claude/devagent/config.toml; stub reads env vars set by the test.

devagent_load_config() {
  : "${DEVAGENT_PROJECT:?DEVAGENT_PROJECT must be set in tests}"
  : "${DEVAGENT_DEVDOC_DIR:?DEVAGENT_DEVDOC_DIR must be set}"
  : "${DEVAGENT_PERM_COMMIT_DEVDOC:=false}"
  : "${DEVAGENT_STATE_DIR:=$HOME/.claude/devagent/state}"
  export DEVAGENT_PROJECT DEVAGENT_DEVDOC_DIR DEVAGENT_PERM_COMMIT_DEVDOC DEVAGENT_STATE_DIR
}
export -f devagent_load_config
