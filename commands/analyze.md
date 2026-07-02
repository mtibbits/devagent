---
description: "Step 11: run the project's analyzer family against changed-line scope."
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:analyze

Invokes `scripts/analyze.sh` with the parsed arguments per spec §6.1.

The project's `analyze` config key picks the family (#55): `cmake` (default —
static analysis then sanitizers), `shellcheck` (diff-scoped shellcheck for bash
projects; new-findings-on-changed-lines gate; artifact under
`<issue-dir>/analysis/`), or `none` (the step marks itself `[-]` with a logged
reason). An unknown value fails loud naming the legal three.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze.sh" $ARGUMENTS`
