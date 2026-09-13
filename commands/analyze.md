---
description: "Step 13: run the project's analyzer family against changed-line scope."
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project] [issue-dir]"
---

# /devagent:analyze

Invokes `scripts/analyze.sh` with the parsed arguments per spec §6.1.

The project's `analyze` config key picks the family (#55): `cmake` (default —
static analysis then sanitizers), `shellcheck` (diff-scoped shellcheck for bash
projects; new-findings-on-changed-lines gate; artifact under
`<issue-dir>/analysis/`), or `none` (the step marks itself `[-]` with a logged
reason). An unknown value fails loud naming the legal three.

Both the `cmake` and `shellcheck` families also scope UNTRACKED, non-ignored source
files as whole files (#591): `git diff` cannot see a file that was never
`git add`-ed, so without this a brand-new file passed the gate silently while every
linter skipped it. The enumeration is read-only (nothing is staged), honours
`.gitignore`, and the artifact names every file it pulled in (the `cmake` family
also names each listed candidate it could not read). The `cmake` family skips the
analyzer's own build dirs (`build_dir`, its `-asan`/`-ubsan`/`-tsan` siblings, any
root-level `build-*` dir); the `shellcheck` family has no build-dir rule. On a
checkout shared with other sessions, another session's uncommitted new script is
in scope too — a dogfood run snapshots `git status --porcelain` in the same
command as the analyzer so the artifact says whose files it saw. Only the per-file
tools act on the whole-file range; the compile-database tools and
`git clang-format` see an untracked file once the build / index knows it.

Under the `cmake` family the step **fails loud** (#117): if any sanitizer leg
(ASan/UBSan/TSan) fails at configure, build, or ctest, all three legs still run
(aggregate evidence) and then step 13 exits nonzero — the checklist step stays
unmarked and an `--auto` chain halts — with the error naming each failing leg,
its failing phase, and its artifact file. A source tree with no `CMakeLists.txt`
loud-skips the sanitizer legs (warns and exits clean; set `analyze = "none"`
or `"shellcheck"` for a non-CMake project).

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze.sh" $ARGUMENTS`
