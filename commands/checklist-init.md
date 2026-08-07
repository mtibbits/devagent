---
description: "Initialize the per-issue checklist.md (default template: standard)."
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[--template <name>] <issue-dir>"
---

Run the shell script `bash "${CLAUDE_PLUGIN_ROOT}/scripts/checklist-init.sh"` with the user's arguments. The
expected positional form is `[--template <name>] [--project <p>] <issue-dir>`.

Forward all arguments verbatim, and pass `--project <p>` when the project is
known in context (#572 — an explicit scope is never guard-questioned).
Surface stderr to the user.
