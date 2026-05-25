---
description: Step 10: commit staged changes with DCO sign-off using commit_template.
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:commit

Invokes `scripts/commit.sh` with the parsed arguments per spec §6.1.

The script honors all permission gates from `[project.<name>.permissions]`.
With `--auto`, the chaining layer suppresses the inter-step prompt but does
**not** suppress permission gates (spec §7.2).

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" $ARGUMENTS`
