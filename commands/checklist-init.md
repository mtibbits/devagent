---
description: "Initialize the per-issue checklist.md (default template: standard)."
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[--template <name>] <issue-dir>"
---

Run the shell script `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-init.sh"` with the user's arguments. The
expected positional form is `[--template <name>] <issue-dir>`.

Forward all arguments verbatim. Surface stderr to the user.
