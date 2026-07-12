---
description: "Step 11: run the project's analyzer family against changed-line scope."
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[project] [issue-dir]"
---

# /devagent:analyze

Invokes `scripts/analyze.sh` with the parsed arguments per spec §6.1.

The project's `analyze` config key picks the family (#55): `cmake` (default —
static analysis then sanitizers), `shellcheck` (diff-scoped shellcheck for bash
projects; new-findings-on-changed-lines gate; artifact under
`<issue-dir>/analysis/`), or `none` (the step marks itself `[-]` with a logged
reason). An unknown value fails loud naming the legal three.

Under the `cmake` family the step **fails loud** (#117): if any sanitizer leg
(ASan/UBSan/TSan) fails at configure, build, or ctest, all three legs still run
(aggregate evidence) and then step 11 exits nonzero — the checklist step stays
unmarked and an `--auto` chain halts — with the error naming each failing leg,
its failing phase, and its artifact file. A source tree with no `CMakeLists.txt`
loud-skips the sanitizer legs (warns and exits clean; set `analyze = "none"`
or `"shellcheck"` for a non-CMake project).

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze.sh" $ARGUMENTS`
