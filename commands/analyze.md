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

Each family's artifacts name the tools that produced them, because versions can
disagree on the same file (#657). The `shellcheck` artifact's header carries
`analyzer: shellcheck <version>`. Under the `cmake` family (#676),
`<date>-static.txt` carries one `analyzer: <row> <version>` line per table row
whose tool ran, in a block just above `## Static Analysis Summary`, and line 2 of
each sanitizer artifact is `analyzer: <tag> <compiler identity>`, probed from the
compiler the build dir recorded. An unreadable version is `(version unknown)`. No
version is enforced by either family; the policy is in the headers of
`scripts/analyze-shellcheck.sh`, `static_analysis_diff.py` and
`scripts/analyze-sanitizers.sh`. devAgent is tested against `shellcheck` 0.9.0 or
newer, and the `analyzer:` line is where an older version, or `(version unknown)`,
shows; such a run's `NEW findings` count is unattested. An artifact written before
these stamps has no `analyzer:` line. Step 14 copies the stamps whole into the MR
body's `## Evidence` block, and preship checks them there (#677).

Under the `cmake` family the step **fails loud** (#117): if any sanitizer leg
(ASan/UBSan/TSan) fails at configure, build, or ctest, all three legs still run
(aggregate evidence) and then step 13 exits nonzero — the checklist step stays
unmarked and an `--auto` chain halts — with the error naming each failing leg,
its failing phase, and its artifact file. A source tree with no `CMakeLists.txt`
loud-skips the sanitizer legs (warns and exits clean; set `analyze = "none"`
or `"shellcheck"` for a non-CMake project).

The `shellcheck` family needs `shellcheck` on PATH: without it the step stops
(`shellcheck not found on PATH`) before writing an artifact and stays unmarked.
Under the `shellcheck` family the step **fails loud** (#675) when shellcheck itself
fails. Every scan records its status in the artifact as
`shellcheck: exit=<rc>`. Any status other than 0 (clean) or 1 (findings), or a
failed `cd` into `source_dir` (recorded as
`shellcheck: not run (cd into source_dir failed)`), writes shellcheck's output and
stderr verbatim with no finding counts; step 13 then exits nonzero, naming the
status and the artifact, and stays unmarked. New findings never fail the step
(report-not-fail). On a shared checkout a vanished or unreadable file is routinely
another session's uncommitted script: re-run once it settles. `analyze = "none"`
skips the analyzer for a project.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze.sh" $ARGUMENTS`
