# Changelog

All notable changes to devAgent are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

devAgent is released as tagged semver versions. `.claude-plugin/plugin.json`
carries the release `version` (the marketplace entry carries none — Claude
Code uses the plugin.json value when both are set, so a second copy can only
go stale). Each release is an annotated `devagent--v<version>` git tag created
with `claude plugin tag --push`, a dated section below, and a GitHub release
whose notes are that section. A marketplace install is pinned to the version
string and picks up the next release on `claude plugin update`. Until 1.0.0
the plugin was versioned by git commit SHA with no release cadence (#532,
ratified 2026-07-20 while the repository was private, re-taken at go-public);
the README's "Versioning & releases" section has the release procedure.

## [Unreleased]

- **Fixed: clang-format, iwyu, scan-build-18 and compiler rows no longer read clean or pass when the tool fails (#683).**
  - Each of the four rows now reads its tool's exit status. clang-format fails on any
    nonzero exit with no diff, or on exit 2 or higher. iwyu fails on a nonzero exit that
    left a requested file without a verdict, and names the files (`not analyzed: ...`).
    scan-build-18 fails on any nonzero exit, which without `--status-bugs` is the build's.
    compiler fails on any nonzero build exit, even when the build printed diagnostics.
  - A failed row reads `error: <tool> exit=<rc>: <reason>`. A Status cell starts with
    `error:` exactly when the row's tool or leg did not complete, and each `--json` row
    gains `failed`, computed from that same cell.
  - A completed scan-build run's bug count now reads `FAIL: <n> bug(s) found ...`, not
    `error:`.
  - A failed compiler build without findings changes from `| - | - | error: build failed`
    to `| 0 | 0 | error: compiler exit=<rc>: build failed`.
  - An absent git-clang-format wrapper or formatter binary now reads `skipped`, instead of
    `clean`.
  - cppcheck with nothing to analyze now reads `skipped (no compilable files in diff)`.
  - A skipped pool row's progress line now prints `<tool>: skipped (<reason>)`, not
    `done (0 total, 0 novel)`.
  - The new reasons are table-safe: control characters become spaces, the text is capped
    at 200 characters, and `|` is escaped.
  - Not breaking: step 13's outcome and the python's exit status do not change.

- **Docs: the user homes name the shellcheck prerequisite (#678).** A project that sets
  `analyze = "shellcheck"` now learns before step 13 what that family needs.
  - README's Prerequisites, the install page's "You need:" list and the `analyze` comment
    in `templates/config.toml.skel` say that step 13 stops without `shellcheck` on PATH,
    and that devAgent is tested against `shellcheck` 0.9.0 or newer with nothing checking
    the version at run time. The `analyze` line of the configuration page names the
    PATH need and the tested version, and points to `commands/analyze.md`.
  - `commands/analyze.md` is the home of the detail: the missing-binary message, and
    the `analyzer:` line as the place an older or unknown version shows.
  - A new `tests/docs-site.bats` sweep pins every shellcheck version token in those homes
    and in the contributor homes to the one CONTRIBUTING.md names.
  - Not breaking (docs and one test).

- **Added: the MR body's Evidence block carries the analyzer stamps (#677).** A finding
  count in the MR can now be attributed to the toolchain that produced it.
  - Step 14 copies every counted `analyzer:` line of the newest step-13 artifacts
    (`analysis/<date>-<shellcheck|static|asan|ubsan|tsan>.txt`, matched by exact basename,
    the newest per name) into the `## Evidence` block whole, after `platform:`. Counted:
    each column-0 `analyzer:` line of the shellcheck and static artifacts, and line 2 of a
    sanitizer artifact if it starts `analyzer:`. The Testing section keeps finding counts
    only.
  - `scripts/preship-evidence.sh` FAILS an Evidence `analyzer:` line that no counted line
    backs, and one that stands twice. It WARNS, naming the line, about each counted line
    the block omits; the exit status and the PASS line are unchanged.
  - The warning reaches only the operator (preship.md is private), so an MR reader cannot
    tell an omitted stamp from no stamped artifact.
  - Not breaking: the fail arms fire only on a body carrying an `analyzer:` line; omission
    only warns.

- **Added: cmake-family artifacts name the tools that produced them (#676).**
  Versions can disagree on the same file, so a finding count is now attributable to a
  toolchain, as #657 did for shellcheck.
  - `<date>-static.txt` carries one `analyzer: <row> <version>` line per table row whose
    tool ran, in a block just above `## Static Analysis Summary` (on stderr under `--json`,
    so stdout stays pure JSON). A skipped or absent tool gets no line; a row that timed out
    or errored keeps its line.
  - Line 2 of each `<date>-{asan,ubsan,tsan}.txt` is `analyzer: <tag> <compiler identity>`.
  - Compiler stamps (`compiler`, `asan+ubsan`, `tsan`, and the sanitizer line 2) probe the
    compiler path plus `CMAKE_<LANG>_COMPILER_ARG1` that the build dir's CMake recorded, so a
    launcher like ccache stamps the real compiler; CMake's cached compiler version is never
    read.
  - An unreadable version is `(version unknown)`; every probe is time-bounded and never fails
    a row or a leg. A sanitizer artifact whose line 2 cannot be written is kept as written,
    with a warning.
  - The clang-format, iwyu and scan-build-18 stamps mirror how each wrapper picks its binary,
    and PATH-tool stamps on Windows follow Python's lookup, so those are inferred.
  - Policy: stamp, do not change what runs. No floor, no gate, no analysis command line,
    exit status, table status or existing message changes. Not breaking.
  - Artifacts written before this release carry no `analyzer:` line.

- **Fixed: step 13 stops when shellcheck itself fails, and option-shaped file names are scanned (#675).**
  `scripts/analyze-shellcheck.sh` used to discard the scan's exit status, so a scan that
  never ran read as 0 findings and step 13 was marked done.
  - The new failure: a scan whose shellcheck exits anything but 0 (clean) or 1 (findings),
    or whose `cd` into `source_dir` fails, now stops step 13. The artifact carries
    `shellcheck: exit=<rc>` (or `shellcheck: not run (cd into source_dir failed)`),
    shellcheck's output and its stderr, and no finding counts; the step stays unmarked and
    an `--auto` chain halts. Every completed scan records `shellcheck: exit=0` or
    `shellcheck: exit=1` under the header.
  - The remedy: fix what that stderr names (a bad `SHELLCHECK_OPTS`, an unreadable or
    vanished file, a missing binary) and re-run `/devagent:analyze`.
  - File names are passed after `--`, so a name like `-x.sh` or `--rcfile=rc.sh` is now
    scanned instead of being read as an option.

- **Added: the shellcheck analyzer's artifact names the shellcheck that produced it (#657).**
  `scripts/analyze-shellcheck.sh` writes one header line, `analyzer: shellcheck <version>`,
  between `baseline:` and `scope:`. The version is the token `shellcheck --version` prints
  after `version:`, with a Windows build's carriage return dropped. When no version can be
  read the line says `analyzer: shellcheck (version unknown)`; the run never stops over it.
  - Why: two shellcheck versions that both clear the project's floor disagree on
    pre-existing findings (#550), so a `NEW findings` count is now attributable to the
    binary that counted it.
  - Policy, recorded in the script header: the analyzer runs under the same floor as the
    test suite and the CI lint gate (CONTRIBUTING.md "What you need"). It is a floor, not a
    pin, and nothing enforces it at runtime: a mismatch is visible only in that line.

## [2.0.0] — 2026-10-02

A major release because two changes make an evidence run that passed on 1.0.0
refuse: `run-suite.sh` must now be told which issue it measures (#659), and it
refuses a measured tree that is detached or behind its origin (#660). Both are
marked `Changed (breaking)` below, with the remedy each refusal prints.

- **Changed: an `--auto`/`--through` chain now stops at phase breaks, so each phase starts
  in a fresh session.** Measured from this project's transcripts, one session per issue
  re-reads its whole history on every call: Issue-660's main context grew from 49K to 845K
  tokens over 386 calls, and waiting for the merge expired the cache, so the whole 749K was
  written again. Replaying the same calls with fresh sessions at implement, quality and
  updatewbs cuts that session's cost ~56%.
  - `scripts/next.sh` marks every `CHAIN:` line `--chained`. A continued chain stops before
    each step in `phase_breaks` and prints `PHASE BREAK` with a Resume command. The
    operator runs `/clear`, then the Resume command, which runs the boundary step and
    chains on. The default is `"implement quality updatewbs"`; set it per project or in
    `[defaults]`, `""` disables it, and `--no-breaks` skips it for one chain. A plain
    `/devagent:next` never breaks.
  - Behavior change for unattended runs: an `--auto` chain now also stops before implement
    and before quality. The stop before updatewbs falls at the merge wait, where the chain
    already paused. Set `phase_breaks = ""` to keep the old behavior.
  - `session_rehydrate` (#456, opt-in) pairs with this; `templates/config.toml.skel` now
    documents both keys.
- **Changed: the plan has a budget.** Every step from scope to preship re-reads
  `imPlan.md`. Issue-660's ran 160 KB, 100 KB of it task code, for a 1,379-line diff, and
  its `## Potholes considered` ran 22 KB. `/devagent:draft`'s Plan budget overrides
  writing-plans' complete-code rule: tasks name files, interfaces, tests and invariants,
  and carry code only where the exact text is the decision. Potholes considered lists
  matching triggers one line each and N/A ones as a single line of ids. next.sh warns when
  it reaches scope with a plan over 40 KB. core-scope reads the plan by its outline,
  core-tighten checks cited ranges instead of reading whole files, and `/devagent:quality`
  asks simplify's reviewers for one-line findings.
- **Added: `scripts/cost-report.sh` reports token cost per issue and per step** from the
  current directory's Claude Code transcripts, in input-token equivalents (cache read
  0.1, cache write 1.25 for 5-minute and 2 for 1-hour, output 5). Each call is charged to
  the step next.sh last dispatched, and each subagent to the step that launched it.
  `--summary` gives one line per issue, and the impact step (21) records that line in
  `impact.md`. Measured: #588 cost 6.9M; #660 cost 37.7M.
- **Added: every suite-count artifact records the platform it was produced on, and the
  operator who runs preship can declare which platforms count (#654).** `scripts/run-suite.sh`
  appends `platform: os=<uname -s> kernel=<uname -r> fs=<filesystem type of the measured
  tree> modes=posix|no-op`. The filesystem type is what tells the WSL clone (`ext4`) from a
  WSL `/mnt/c` checkout (`9p`); a kernel string cannot. `scripts/preship-evidence.sh` echoes
  the line at the end of its PASS line as `[platform=…]`.
  - The optional `[project.<name>] evidence_platforms = ["os=Linux fs=ext4 modes=posix"]`,
    in the config of whoever RUNS preship, makes an artifact from any other platform fail
    `PLATFORM UNATTESTED`, and one with no `platform:` line fail. The example pins
    `modes=posix`, because an entry ignores the keys it does not name; `modes=posix`
    means the chmod probe found no no-op, not proof that modes work. To accept one such
    artifact, the operator re-runs the check with the
    `--attest-platform 'head=<sha> platform=<line>'` the failure prints; the PASS line
    records it, and the preship verifier never passes it. A malformed declaration stops
    the check.
  - The MR body carries the platform. The `## Evidence` block of
    `templates/mr_template.md` gains a `platform:` line, which `/devagent:draftmr`
    copies from the artifact, and preship-evidence compares the two byte for byte (a
    mismatch names the exact line; exactly one such line may stand). With a
    declaration, an Evidence block without the line fails, acknowledged or not, and so
    does an `mr.md` with no Evidence block.
  - Not breaking: without a declaration, an existing `mr.md` and artifact see only the
    new artifact line and the PASS-line suffix (`[platform=undeclared: …]`, or
    `[platform=unstamped]` for an older artifact). An Evidence `platform:` line is
    checked only when one is present, which includes a new `mr.md`'s template
    placeholder (next bullet).
  - Migration, for every project whether it declares or not: an `mr.md` drafted from
    the new template must carry the artifact's `platform:` line, or drop the template's
    line. An unfilled placeholder fails preship, and so does a `platform:` line with no
    artifact line to match (for example, an artifact from a WSL clone still running
    pre-#654 scripts, which writes none). `/devagent:draftmr` from this release fills
    it.
  - The line is a claim the artifact makes: a hand-written artifact can carry any
    well-formed `platform:` line.
  - `scripts/lib/_toml.py get-list` refuses an array element holding a line break (rc 3);
    it used to print it as two elements. `potholes_domain_nouns` is read the same way.

- **Changed (breaking): run-suite refuses a stale or detached measured tree, and every
  suite-count artifact says which branch it measured (#660).** A second clone that had
  not been fetched could produce green evidence for an old commit. In #570 the WSL clone
  was parked on another issue's branch, nine days behind, and nothing refused.
  `scripts/run-suite.sh` now refuses before any suite runs, and writes nothing, in two
  cases:
  - the measured tree's HEAD is detached (`DETACHED HEAD`, naming the SHA);
  - after asking `origin` under a per-call bound of `DEVAGENT_FETCH_TIMEOUT` seconds (default 30),
    the HEAD does not contain `origin/<branch>` (`BEHIND ORIGIN`, naming both SHAs and
    the branch).

  This applies in every tree, including one that is its own config's `source_dir`. The
  artifact gains `branch:` and `upstream:` lines. `upstream:` is one of:
  - origin's tip;
  - `(no-origin)`, for a tree with no origin (not a degradation);
  - `(unreachable)`, when origin did not answer (failed or timed out);
  - `(unpushed)`, when origin has no such branch.

  `scripts/preship-evidence.sh` now fails when the artifact's `branch:` is not the
  issue's recorded branch. It reads `upstream:` as a second provenance rung, and its PASS
  line ends `[tree=…] [upstream=checked|no-origin|unpushed|attested: …]`.
  - A `(unpushed)` artifact produced in the very tree being shipped passes as
    `[upstream=unpushed]`. That is the normal first-round state, because the branch is
    first pushed at the ship step, after preship.
  - `(unreachable)`, and a `(unpushed)` artifact from another environment (the WSL
    clone seen from Windows), fail `UPSTREAM UNATTESTED` unless the caller passes a
    per-run `--attest-upstream 'head=<sha> upstream=<sha>|(unpushed)'`. The preship
    verifier now does that, after running `git ls-remote` where the artifact was
    produced. With origin persistently unreachable preship cannot pass, and neither
    can ship.
  - run-suite asks origin with one bounded `git ls-remote`, and fetches only when HEAD
    lacks origin's tip. That fetch writes exactly one ref, the measured tree's
    `refs/remotes/origin/<branch>`. It prunes nothing and writes no `FETCH_HEAD`, and a
    tree that is already fresh gets no write at all. It needs git 2.29 or later
    (`--no-write-fetch-head`).
  - A diverged measured tree refuses `BEHIND ORIGIN` too. Its printed remedy integrates
    origin's commits (`git merge --no-edit origin/<branch>`) and never discards this
    tree's own.

  **Migration:**
  - Run run-suite in the WSL clone with the issue's branch checked out:
    `git fetch origin && git checkout <branch>`, then `git merge --ff-only origin/<branch>`
    on later runs. A detached checkout now refuses.
  - Every suite-count artifact written before this change fails preship-evidence (no
    `branch:` line): re-run run-suite.
  - `timeout(1)` must be on PATH wherever run-suite measures a tree that has an origin.
  - Restart Claude Code sessions after updating: agent prompts load at session start.
  - Limitation: the check asks `origin`. A project that ships to a `source_remote` other
    than `origin` (fork-first) is warned by run-suite, and does not get the single-tree
    `(unpushed)` pass without an attestation.

  Like #659, this changes a documented contract, and the next release is already a MAJOR
  bump.

- **Changed (breaking): run-suite must be told which issue it is measuring
  (#659).** `scripts/run-suite.sh` took no issue argument (a second one was
  silently ignored). Unless `DEVAGENT_ACTIVE_ISSUE` was pinned, it chose the issue
  directory it writes into, and the tree it measures, from the project's SHARED
  state slots, which another session's pull moves. An evidence run meant for one
  issue could therefore land in another issue's `analysis/`, measured on that
  issue's tree, with no warning; #550's remediation run did exactly that. The issue
  now comes from the second positional argument (`run-suite.sh <project> <Issue-N>`)
  or the session's `DEVAGENT_ACTIVE_ISSUE` pin, and the argument wins when both are
  set. With neither, run-suite refuses with `ISSUE UNSTATED` before any suite runs
  and writes nothing. The refusal names the directory the shared slot would have
  chosen and prints the corrected command. The one resolved issue picks both the
  artifact's directory and the measured tree. An invalid issue id, or one with no
  issue directory, is refused before any suite runs. **Migration:** replace
  `run-suite.sh <project>` with `run-suite.sh <project> <Issue-N>`; a session that
  pins `DEVAGENT_ACTIVE_ISSUE` needs no change. This changes a documented command
  contract, so the next release must be a MAJOR version bump (README, "Cutting a
  release"). `.claude-plugin/plugin.json` is deliberately not bumped here: the bump
  happens when the release is cut. Every documented caller now passes the issue:
  the core-draft-mr skill, README, CONTRIBUTING, and the MR and PR templates. The
  preship verifier now passes the issue to `preship-evidence.sh` too, so the ship
  gate cannot check another issue's evidence.
  `scripts/preship-evidence.sh` keeps its arity. Its header now states its issue
  precedence (argument, then pin, then the shared `issue_dir` slot), and its
  missing-artifact message prints the run-suite command with the issue. Restart
  Claude Code sessions after updating: a live session keeps the old core-draft-mr
  text, whose command now meets `ISSUE UNSTATED`, and the refusal prints the command
  to run instead. `tests/run-suite.bats` gains 19 tests and rewrites "#571 AC5" to
  run the skill's command verbatim.

- **Changed: preship-evidence no longer passes an artifact whose checkout it
  cannot see (#655).** When the suite-count artifact's `tree:` names a path that
  does not exist where the check runs, `scripts/preship-evidence.sh` used to warn
  and pass on the `head:` comparison alone, so its tree check never ran there.
  That is the normal shape of the sanctioned two-environment flow: an artifact
  produced in a WSL clone and checked from Windows. It now fails with
  `TREE UNATTESTED` unless the caller passes a per-run
  `--attest-tree 'head=<sha> dirty=no path=<tree>'` stating what
  `git -C <tree> rev-parse HEAD` and `git -C <tree> status --porcelain` printed
  in the producing environment. The attestation must match the artifact's `head:`
  and `tree:` exactly, so a pasted value fails at the next commit. It is an
  argument rather than an environment variable, so there is nothing exported to
  leave set. The script checks only that the attestation is well-formed and bound
  to the artifact; that the caller really looked rests on the caller.
  `DEVAGENT_TREE_GUARD_OVERRIDE` does not silence the failure. A missing or empty
  value, a repeated `--attest-tree` or an unknown option is a usage error. The
  PASS line now ends with the tree check's verdict: `[tree=checked]`,
  `[tree=attested: …]` (the attestation, verbatim) or `[tree=unstamped]` (an
  artifact with no `tree:` line, which still skips the check). For the sanctioned
  flow, a WSL-produced artifact checked from Windows, the day-one path is the
  preship verifier: it runs the two git commands in WSL and passes the
  attestation. Any other pair of environments needs the same two commands run
  where the artifact was produced. Spec §7.5 and the README's WSL section describe
  the flow. Restart Claude Code sessions after updating: agent prompts load at
  session start, so a live session keeps the old verifier instructions and
  records FAIL on these checks. An `mr.md` without an `## Evidence` block still
  warns and exits 0. `tests/suite-tree-guard.bats` replaces the old
  warn-and-pass pin and gains thirteen tests.

- **Fixed: preship-evidence's no-Evidence `(error)` refusal no longer depends on
  whitespace (#601).** The refusal that runs above the #149 back-compat exit matched
  `pytest: (error)` exactly. An artifact that padded the line (`pytest:   (error)`)
  next to an mr.md with no `## Evidence` block therefore exited 0 with a warning,
  while the same artifact with an Evidence block was refused. The refusal now reads
  the pytest body with the main path's whitespace-tolerant parse. An unreadable
  artifact on that path now aborts with the read error instead of warning and exiting
  0, which fails closed as the main path already did. `run-suite.sh`
  always writes the exact form, so artifacts it produced were never affected. A
  trailing blank (`(error) `) remains an unparseable line, which the no-Evidence path
  deliberately lets through: a declared blind spot. #601's headline report, that a
  pytest-only project could not satisfy the Evidence check, was already fixed by #466
  (#605), which reconstructs the suite line per framework. `tests/preship-evidence.bats`
  gains five tests: padded `(none)` bodies and padded counts reconcile for each
  framework, a trailing blank after `(none)` fails loudly as unparseable (one per
  framework), and a padded `(error)` is refused with no Evidence block. Each is proven
  able to fail by a recorded mutation matrix.
- **`/devagent:comments` now captures code-review feedback on GitHub
  (#592).** `code/github.sh mr-comments` used to fetch only conversation
  comments, so a PR reviewed only with inline comments wrote
  `## Comments (0)`. It now adds review summaries (`### @user · date ·
  review: STATE`, skipping the empty `COMMENTED` containers GitHub creates
  for inline batches and `PENDING` drafts) and inline comments
  (`### @user · date · path:line`, via `gh api …/pulls/N/comments`) after
  the conversation comments. They sit under one `## Comments (N)` header
  that now counts every entry. The shape is recorded in spec §9.3.
  Conversation-only output is byte-identical (pinned by a golden generated
  from the old filter). A failed forge call now fails the fetch instead of
  writing a partial file. `DEVAGENT_MR_COMMENTS_SKIP_INLINE=1` fetches
  without inline comments and marks the gap in the output. An `mr_url`
  that is not a `…/pull/<n>` URL is now refused (exit 2). The gitlab and
  custom backends are unchanged, because the suffixes are optional for
  conformance.

- **The review step now tells its reviewer the report contract the lint
  enforces (#598).** `commands/review.md` gains a Report contract block that
  the main session appends to the dispatched reviewer's prompt on both paths
  (the `superpowers:requesting-code-review` path and the superpowers-absent
  fallback) and on step 5a's re-dispatch: the two artifact header lines,
  which the main session writes, and the verdict signals
  `dispatch-lint.sh --class review` accepts. An upstream reviewer that was
  never told the contract wrote to its own house style and failed the lint
  with "no verdict signal", costing a re-dispatch. Two tests in
  `tests/dispatch-lint.bats` derive the lint's signal set and pin that the
  block names exactly that set, once, and that all three dispatch sites
  route it into the prompt. Prompt and test only; `dispatch-lint.sh` is
  unchanged.
- **run-suite's chmod guard no longer blocks suites that never touch a file mode
  (#600).** Where `chmod` is a no-op (Windows noacl), `run-suite.sh` refused for any
  project whose tree carried a suite, so a pure-pytest project could never produce
  evidence on native Windows. It now scans the suite source (`tests/` plus a root
  `conftest.py`) for word-bounded file-mode tokens and refuses only on a hit (naming
  it) or when the scan cannot run; otherwise it proceeds, and a new trailing artifact
  line records `file_modes: posix`, `file_modes: no-op; no test file references a file
  mode (…)`, or `file_modes: (none)`. The scan is a proxy and the artifact says so; a
  mode dependency living only in the code under test, or in test-support code loaded
  from outside the scanned paths, is not seen. devAgent's own suite still refuses
  there, and a tree whose only pytest files are nested (`tests/unit/test_*.py`), which
  the old non-recursive trigger never gated, is now scanned too. On native Windows a `.venv/Scripts/` interpreter still needs
  `DEVAGENT_PYTEST_PYTHON` (#466).
- **The six auto-exec commands are now pinned, not merely described (#596).**
  `tests/skills-no-bang-exec.bats` gains a positive counterpart to #550's negative
  canary: the set of `commands/*.md` carrying a bang-exec line is asserted to be
  exactly {analyze, branch, cleanup, commit, mergetoall, sync}, one line each, at
  column 0, with a fixture self-test for the scan. Dropping one of those lines,
  and adding one to a seventh top-level command, now both redden. Still unpinned,
  as the test header states: the bang-exec grammar itself, fenced or indented
  lines, and commands in subdirectories of `commands/`. Test-only; each leg is
  proven able to fail by a recorded mutation matrix.
- **The onboarding site is live at https://mtibbits.github.io/devagent/ (#465).**
  Pages was enabled and `DOCS_SITE_DEPLOY` set on 2026-09-18; every docs push
  to `master` now deploys. `docs/pages-deployment.md` is corrected from the
  real transcript, README and the repository homepage carry the URL, and the
  install page gained the official-marketplace step and the `userConfig` note
  that a clean-machine install walkthrough (attached to #465) found missing.
- **`/devagent:cleanup` (step 23) now refuses a `lessonsLearned.md` that does
  not lint clean (#594).** Behavior change: before any side effect, cleanup
  runs the lessons lint over the issue's own file and stops with the offenders
  and a fix-first remedy. A file that is present is linted whatever the
  `lessonslearned` glyph says; `lessonslearned` `[x]` with no file is refused;
  marking the step `[-]` with no file written is the skip. New
  `scripts/lessons-lint-corpus.sh <root-dir | file>...` runs the lint over a set
  of files (exit 0 clean / 1 offenders / 2 could not answer — an empty subject
  set is never a pass).
- **`scripts/lessons-lint.sh` closes two false positives (#594).** A bracket
  that leads a heading (`### [tag] <claim>`) is read as that entry's tag
  (tolerated, not recommended — `/devagent:reap` does not read a heading
  bracket), and a `- [[wikilink]]` bullet is a link, never a tag. Its interface
  and exit codes are unchanged.
- **`scripts/capture/capture.sh` gains `--body-file` and `--on-collision
  suffix` (#597).** `--body-file <path>` writes that file's bytes as
  `draft.md` instead of rendering the template and exits **5** when the
  body's H1 is not `<title>` (`Epic: <title>` for `--type epic`), which is
  the invariant `file.sh` depends on. `--on-collision suffix` resolves an
  existing-slug collision with the #252 content-derived suffix (first six
  hex of the body's content hash) in one retry and prints the final slug.
  A content-identical (whitespace/case-insensitive) re-run is a no-op,
  announced by a `note:` line on stderr. It requires `--body-file` and
  cannot be combined with `--slug-suffix` or `--force`. Both flags are
  optional: without them, behavior is unchanged, including the exit-3
  collision signal and `--force`. The H1 extraction is now one
  shared helper (`scripts/capture/lib/draft.sh`) that `file.sh` also
  calls. `commands/crrf.md`'s promote loop is now a single invocation.
- **Changed: the evidence scripts now refuse when one checkout is a clone made
  from the other by path (#656).** `run-suite.sh` and `preship-evidence.sh`
  die with `TREE MISMATCH` and write no artifact when the current directory
  is in one checkout and `source_dir` is a clone made from it, or the
  reverse: for example a WSL session whose cwd is `/mnt/c/…` while
  `source_dir = ~/devagent-wsl`. Before, that pair passed silently, because
  the clone's `origin` is a path and the original's is a forge URL (or
  absent), so the URL comparison could not decide. The origin is now also
  read as a local path (plain, relative, or POSIX `file://`) and compared to
  the other checkout by identity. This applies only when no `worktree_path`
  is recorded for the issue; a recorded worktree is used as-is. The remedies
  are the ones the message already prints: re-run from the measured tree,
  record `worktree_path`, or set `DEVAGENT_TREE_GUARD_OVERRIDE=1` for one
  call. Other clone shapes still pass, among them ssh vs https, a clone of a
  clone, and a linked worktree of the original against the original's clone.
  Two separately configured projects now refuse each other when one repo's
  origin is the other's tree by path; the override covers that pair.

## [1.0.0] — 2026-09-18

First tagged release, cut at go-public (#463, #464). Everything in this section
had already shipped SHA-by-SHA to `master` before the tag existed.

- **The plugin carries a version: `plugin.json` `version: 1.0.0` (#532
  re-take).** Behavior change for every install from the GitHub marketplace,
  stated here because #532 required it never be claimed as "no change": until
  now `claude plugin update devagent@devagent` followed `master` commit by
  commit; from this release it resolves to the version string and only sees an
  update when that string changes, so a merge to `master` reaches installed
  users at the next release rather than immediately. A marketplace added from
  a local checkout loads it in place and is not pinned. Measured on Claude Code
  2.1.223: `claude plugin validate --strict` now passes (it was
  documented-red on the missing version), and `claude plugin tag --dry-run`
  resolves `devagent--v1.0.0`. `tests/test_plugin_versioning.py` inverts from
  "no version anywhere" to "semver in plugin.json, none in the marketplace
  entry, matching CHANGELOG section", and `tests/plugin-validate.bats` wires
  the strict gate plus the tag dry-run. README, the docs-site install page and
  SECURITY.md describe the release policy instead of SHA-tracking.

- **The onboarding site can be built and published (#465).**
  `scripts/build-docs-site.sh` renders the `docs-site/` pages to a static
  site with pandoc, straight from the tracked markdown — no rendered copy is
  committed. It rewrites page-to-page links, sends links that leave
  `docs-site/` to the forge, and fails the build on a link it cannot classify
  or that resolves to nothing, and refuses a pandoc older than 3.x. A new
  `publish docs site` workflow runs the builder's tests, builds, and can deploy
  to GitHub Pages by keyless OIDC. **Deploy is off** until the repository
  variable `DOCS_SITE_DEPLOY` is set to `true`, because GitHub Pages is not
  enabled on the repository yet and a deploy against a Pages-disabled repo
  fails; `docs/pages-deployment.md` has the switch-on steps. New optional test
  prerequisite: pandoc 3.x, for `tests/build-docs-site.bats` only.

- **The oneshot tier's no-repo-diff boundary is enforced mechanically (#595).**
  "An operational action, not a repo change" lived in prose in three documents
  and nothing caught a one-shot that quietly produced commits. The oneshot tier
  has no branch step, so no `baseline_sha` exists and `zero_diff_classify`
  answered `indeterminate` forever. What a branchless tier measures is now
  defined as **whether the source tree carries unpublished change** — on the
  base branch, no commits beyond `default_baseline`, no uncommitted paths —
  rather than whether the issue itself produced a diff, which a shared source
  tree cannot attribute. A new `scripts/oneshot-zerodiff.sh` owns the
  predicate: it calls the shared `zero_diff_classify` unchanged for the commits
  half, adds a `git status --porcelain` probe for the dirty half (a dirty-only
  tree classifies as `empty`), compares the checked-out branch to the base, and
  mints one exit code per verdict. `cleanup.sh` reads the tier itself and
  refuses before any side effect on `violated` or `indeterminate`, directing
  the operator to `revise.sh --retier standard`; every other tier pays one
  header read and never spawns the checker. A shared tree left on a sibling
  issue's branch is the routine `indeterminate`, with a one-line remedy; a
  recorded linked worktree is `indeterminate` with a remedy that names the
  tier. The refusal never asserts authorship.
  `echo "<reason>" > <issue-dir>/.devagent-oneshot-ack` is an auditable escape
  seam for trees git cannot measure.
  `commands/document.md`'s straggler instruction — which told a oneshot to
  commit and promised a step 12 that tier does not have — is carved out, and
  `commands/implement.md`'s "must produce no repo diff" is reframed to the
  decidable form; both key on the tier name, since the research tier omits
  step 12 too.

- **Untracked new source files enter the analyzer's changed-line scope (#591).**
  `static_analysis_diff.py` scoped from `git diff` alone, which lists TRACKED
  changes only — a brand-new file that had never been `git add`-ed produced no
  hunks, so every per-file tool skipped it and step 13 passed vacuously for exactly
  the file with the least review history. A new `get_untracked_ranges()` enumerates
  untracked, non-ignored candidates with
  `git ls-files --others --exclude-standard --full-name -z` (read-only — no
  `git add`, no `git add -N`, no temp commit) and gives each a whole-file
  `LineRange(1, <line count>)`, so cpplint, codespell, ruff, flake8, bandit, mypy
  and cmake-lint run on it and `filter_novel` counts every line as changed; markdown
  runs print one artifact-visible progress line,
  `Untracked files (whole-file scope): …` (stderr under `--json`, #119), and the
  summary labels now say "changed lines or untracked files". The compile-database
  tools (cppcheck, clang-tidy, iwyu, compiler warnings) and `git clang-format`
  cannot reach a file the build / index does not know and still report it clean —
  a documented limit. Candidates are limited to the suffixes the `run_*` filters
  already select on (`.cc .c .h .py .cmake CMakeLists.txt`) and exclude the
  analyzer's own `build_dir` / `-asan` / `-ubsan` / `-tsan` dirs and any root-level
  `build-*` dir — where `analyze-sanitizers.sh` builds regardless of the configured
  `build_dir` (#324/#351) — which a target project's `.gitignore` may not cover.
  Names are decoded as UTF-8 (never the locale's encoding), and a listed candidate
  that cannot be read is named on the same artifact-visible stream instead of
  vanishing. `scripts/analyze-shellcheck.sh` gets the same treatment for
  `*.sh` / `*.bats` / `*.bash` (both its `git diff` and its `git ls-files` run with
  `core.quotePath=false`, so a non-ASCII name — tracked or untracked — is not
  silently dropped), keyed on untrackedness so a tracked file
  whose only hunks are pure deletions keeps its empty range, with an
  `untracked (whole-file scope):` header line in its artifact. A `--files` run
  never widens beyond its pathspecs, `.gitignore`d files stay out, and a
  tracked-only tree's output is byte-identical to before.

- **run-suite.sh runs bats test files in parallel for a project that opts in
  (#593).** New `[project.<name>]` key `suite_jobs` (integer ≥ 1, default 1 =
  serial) passes `--jobs N --no-parallelize-within-files` to bats; tests inside
  one file still run in order, matching the file-granularity safety audit in
  Issue-593's analysis dir. `DEVAGENT_SUITE_JOBS` overrides it for one run and
  is scrubbed from both suite children (and unset per test by
  `tests/lib/hermetic-env.bash`), so a test that invokes the runner cannot
  inherit it. Scrubbed alongside it: `BATS_NUMBER_OF_PARALLEL_JOBS` and
  `BATS_NO_PARALLELIZE_ACROSS_FILES`, which bats reads from the environment, so
  an inherited value would make the new `bats_jobs:` line false in either
  direction; and `BATS_PARALLEL_BINARY_NAME`, which would otherwise let bats
  reach for a binary the probe below never checked. The value is validated
  before either suite runs; N > 1 first checks for GNU parallel by banner (bats
  1.10.0's own probe is miswired — an absent binary surfaced inside the TAP
  stream as a "truncated" suite) and dies naming the package and the
  `suite_jobs = 1` seam. The artifact gains a
  trailing `bats_jobs: <N> | (none)` line. Carriers: README "Running the test
  suite", `tests/README.md` "Parallel execution", the config skeleton,
  `docs-site/configuration.md`, the spec's run-suite section, and the
  core-draft-mr skill's artifact-read note.

- **The rederive prober compares the checkout to its baseline and resolves bare
  basenames (#590).** `scripts/rederive.sh` now opens its artifact with a
  `## Checkout vs baseline` line — `behind N, ahead M` against `default_baseline`
  after a best-effort fetch whose outcome (`ok` / `skipped` / `FAILED` / `n/a`)
  is stamped on the line. Pre-branch, `behind > 0` is a `✗ … STALE CHECKOUT`
  falsified premise whose remedy names the `merge --ff-only` to run (Issue-570
  ran draft through improve three commits behind its base with every file probe
  ✓); on the recorded issue branch (every revision re-runs draft) the same
  numbers print as an `ℹ` row — expected drift, not a premise. An unconfigured
  or unresolvable base prints an explicit `? behind-count undetermined` line,
  never a silent 0; a faulting `rev-parse`/`rev-list`/`ls-tree` dies loud. A
  `.devagent-baseline` marker is acknowledged by existence in the heading and
  never parsed (only `branch.sh` reads it). A backticked bare basename or path
  suffix (`SKILL.md`, `capture/capture.sh`) is matched against the HEAD tree by
  exact suffix at a `/` boundary: one hit → `✓ tok → path (resolved …)` and the
  resolved path feeds the since-log and the `file:line` drift check; several →
  a `~ … ambiguous` advisory row; none → the same `✗` as before (Issue-570's
  artifact carried six ✗ rows, zero real). Plumbing: `upstream_fetch` sets
  `UPSTREAM_FETCH_STATUS` (skipped|ok|failed) and runs its fetch with
  `GIT_TERMINAL_PROMPT=0`, so git's own credential prompt fails instead of
  hanging an unattended step (ship and mergetoall inherit that; an ssh prompt or
  a black-holed remote is not covered — a fetch timeout is a recorded
  follow-up). The prober measures the issue's recorded worktree when
  `use_worktree` put the branch there (#571's `active_tree_resolve`), else
  `source_dir`. Carriers:
  `commands/draft.md`, the imPlan template's Preconditions note, `core-scope`
  question 7, and the `commands/branch.md` override rules describe the new rows.
- **The checklist writers fail closed (#589).** `checklist_mark` refuses a
  name-less mark of a step number that is absent from the ACTIVE `## Revision`
  block but present in an older one — the write used to fall through the
  resolver's file-wide return and silently flip the older revision's row. The
  refusal names both remedies: pass the calling step's own name as the 4th
  argument, or mark by name with `checklist-mark.sh --by-name`. A number absent
  from every block still dies `not found`. `checklist_mark_by_name` now reads
  its row back after the write and dies, file byte-identical, when no row
  carries the requested glyph — it used to return 0 silently, so `sync.sh`'s
  closeout unblock had no signal when a flip never landed. Readers,
  name-passing callers, and legacy no-heading checklists are unchanged; the
  one operator-visible change is that `checklist-mark.sh <issue-dir> N <glyph>`
  after a `/devagent:revise` now exits 1 instead of flipping the old row.

- **The plugin seed `templates/potholes.md` is a curated public excerpt (#613).**
  The 340-bullet register moved into the private devDoc layers once, every line
  routed by its citation and recorded in `<devDoc>/templates/potholes-migration-ledger.tsv`
  (`kept | merged-into F<n> | retired <mechanism>`); the seed keeps ≤ 100
  bullets (≤ 25 per section), bare `(Issue-N)` devagent citations only, every
  section heading, and a line-1 `<!-- curated: ledger <sha> -->` marker that
  turns the gated rows of `tests/potholes-seed-canary.bats` live (private
  names, section cap, total cap, privacy sweep, file contract, headings). The
  register FILE contract is one lib predicate, `potholes_file_check`, which
  `promote-potholes.sh --apply` runs over the whole temp copy (a pre-existing
  violation in a layer file DEFERs the drain naming `<file>:<line>`), beside
  `potholes_line_sha1` and `potholes_seed_sweep`; `POTHOLES_ISSUE_RE` is
  tightened to `Issue-(Fork-)?[0-9]+`. `--retire`/`--amend` still refuse a seed
  line, now naming the devdoc body-twin the union read dedupes away (a register
  distributed from this seed has one per seed line — that twin is the op
  target) or, when no layer carries the lesson, the seed-curation PR path.
  `doctor` runs `potholes_file_check` over each present layer file (WARN naming
  `<file>:<line>`) so a pre-existing violation is a diagnostic, not a closeout
  DEFER. The canary's operator-handle sweep takes its words from the fork
  owners the live config declares, never from commit metadata. Public record
  of what the caps held out: 16 seed-eligible devagent lessons — by source line
  in `templates/potholes.md` at `2438f4d`: L23 (Issue-72), L41 (Issue-94), L44 (Issue-32), L65 (Issue-85), L101 (Issue-4), L105 (Issue-5), L106 (Issue-5), L107 (Issue-5), L151 (Issue-33), L78 (Issue-106), L197 (Issue-4), L198 (Issue-5), L199 (Issue-5), L200 (Issue-5), L266 (Issue-21), L309 (Issue-5) — remain in this
  repo's history and are candidates for the next seed-curation PR. The
  `Issue-(Fork-)?N` grammar means a tracker's `dir_prefix` must be `Issue-` or
  `Issue-Fork-` (stated in the config skeleton and spec §12).

- **unstuck/resume flip the row that carries `[!]`/`[P]`, wherever it sits
  (#587).** `scripts/unstuck.sh` and `scripts/resume.sh` scanned the checklist
  file-wide, carried out only the step NUMBER, and handed it to `checklist_mark`,
  which re-scopes a reused closeout number into the ACTIVE revision block — so a
  `[!]`/`[P]` left in an older block flipped the active block's twin (or
  regressed its `[x]` row to `[ ]`) while the real mark survived and STUCK was
  deleted anyway. The find-the-line / mark-that-line shape `checklist-unstuck.sh`
  gained in #558 now lives in `scripts/lib/checklist.sh`
  (`checklist_find_glyph_line`, `checklist_step_name_at_line`,
  `checklist_mark_line`) and all three entry points — `/devagent:unstuck`,
  `/devagent:resume`, `/devagent:checklist-unstuck` — ride it. `checklist_mark_line`
  is fail-closed (post-write verify), so STUCK is never removed over a row that
  did not flip. Both unstuck entry points stay; `next.sh`'s hint keeps naming
  `/devagent:unstuck`, now fixed.

- **Core-skill script calls no longer prompt mid-chain (#584).** The #548
  composite grant now sits on the 10 `core-*` skills whose bodies make a
  plugin-script call (census at `fea468e`: 13 calls; the four judgment-only
  core skills make none and stay grant-less), taking the Bash-grant carrier
  count from 57 to 67. Two body corrections rode along, both behavior-
  preserving: the seven `checklist-log.sh` invocations are emitted in the
  `bash "..."` form the literal-prefix matcher can match (the bare form never
  matched and also relied on an exec bit Git Bash cannot set), and the three
  fork skills' fallback `scripts/state.sh` instruction - a path that never
  existed - now names `scripts/where.sh`. The live ladder also showed the
  permission matcher refuses a backslash-continued (multi-line) command even
  when its first line prefix-matches, so every continuation-form script
  snippet in the tree (7 core skills, 8 step wrappers, 2 `capture.sh` sites)
  is now a single line. A hermetic probe ladder measured
  `allowed-tools` on a SKILL.md as additive (a per-skill auto-approve list, not
  a ceiling) and confirmed the grant reaches a `context: fork` skill's
  dispatched agent, so the bare pair ships with no per-file tool lists. The
  drift guard gains a body-call => grant implication canary with the subject
  set pinned by name and a mutation control that enters through the guard.

- **Draft's rc-2 (`inherit`) path is decided — stay inline, final, and pinned
  (#583).** `docs/draft-dispatch-contract.md` and `commands/draft.md` shipped
  the stay-inline choice as an open question (#561 review F1) and named
  dispatch-with-`model: inherit` as the alternative; no test pinned either
  reading. Ratified: `inherit` is the operator's escape from a project pin back
  to the class's default shape, and the thinking class's default is inline at
  the session model (the checking class dispatches on rc 2 only because its
  default shape is a fresh-context fork). No behavior changes; the one wording
  CORRECTION is §7.5, which said dispatch keys on a *non-empty* thinking tier — a
  config-table `inherit` is non-empty yet resolves rc 2 and never dispatched.
  `tests/dispatch-contract.bats` now executes the contract's own resolution
  snippet against fixtures for every exit code — the rc-0 case drives a KEYED
  `.devagent-step-models` marker through the wrapper idiom, the first mechanical
  consumption of the keyed form (#561 DoD-8) — and pins the draft snippet
  byte-equal to the checking-class one. The #561 class-map sweep guard
  (`tests/generic-templates.bats`) now checks per-class ASSIGNMENT rather than
  the union: a home whose numbers sit under the wrong key — within three lines
  of an `implementation-model` / class-name anchor — fails, where the old union
  check passed a swap; a restatement farther from any anchor is still
  unattributed (the test states that limit; `UNATTR` reporting is the follow-up).

- **The `## Workflow flags` scanner is fence-aware, and its silent losses now
  warn on every pull (#582).** A fenced code block in an issue body — the
  natural way to DOCUMENT the grammar — parsed as live config: a fenced
  `## Workflow flags` heading opened a block whose keys steered the pull, and a
  fence opened inside a live block was scanned as more keys. Both awk machines
  (`flags_get`, `flags_validate`) now toggle fence state on a line whose first
  non-blank characters are three backticks, close any open block there, and
  skip fenced lines before the heading, block-close and key rules see them; the
  pair sits below the HTML-comment pair so a fence marker inside an `<!-- -->`
  span never toggles.
  Three losses that were silent are now named by `flags_validate`, non-fatally
  (warn-and-ignore, forward-compat): the #553 close — a mis-cased or indented
  first key still ends the block, but the closing line is named, which
  supersedes that entry's warn-less trade-off; an inline `<!--` on a key line
  warns naming the dropped key (the key is still dropped: the bare-value
  grammar is unchanged); and the fix's own two new close shapes warn too — a
  fence opened inside a live block (before or after its first key), and an
  unbalanced fence that swallowed a flags heading (a bare closing fence inside a
  comment span opened within a fence, an opening fence whose info string holds a
  comment, or an opening fence hidden by a comment begun mid-line on prose — each
  divergence is latched, so a later balanced example cannot disarm the warn, and
  a block parsed after it is flagged as possibly a documented example) — so the
  fence rule cannot itself introduce a silent loss. The one diagnostic that
  echoes a body line (the Rule C close) prints it quoted, printable ASCII only
  and bounded, since it is remote content. `flags_get` stays silent by
  design: `pull.sh` calls it five times per pull. `pull.sh` now runs
  `flags_validate` on EVERY pull, immediately after the fetched body lands,
  instead of only at first scaffold, so a key edited onto the body after
  scaffold is validated on the next re-pull (it stays inert — scaffold-only
  keys are scaffold-only by design). **No corpus body changes meaning:** over
  the 477 issue bodies in the local devdoc, old and new `flags_get` agree on
  every one of the five keys, and the new `flags_validate` emits zero warnings;
  by design, a body whose keys sat inside a fence, or after a fence inside a
  live block, now loses them — with a warning. Three documented residuals: the
  rule toggles on any line starting with three backticks (a four-backtick
  inline span, a code span at line start, an indented code-block line), and a
  live block below such a line is reported by the END warn rather than lost
  silently (a documented example below it is scanned live, with no diagnostic);
  the `^## Comments (` exit rule stays fence-blind; a literal `<!--` on a fenced
  line still opens a comment span. See spec §6.3.

- **Chain hops carry their scope; the dispatch output names it (#578).**
  `next.sh` resolved the project once but emitted both of its model-facing
  commands without it, so every hop of an `--auto`/`--through` chain
  re-resolved global state at FIRE time — a concurrent session that moved the
  pointer (or a pointer left stale) silently redirected the rest of the chain
  to another project. Both emissions now carry the resolved project
  (`→ Run /devagent:<name> <project>` and
  `CHAIN: /devagent:next <project> --auto`). `scripts/revise.sh` — which starts a
  chain of its own — carries the same fix, narrowed to the `/devagent:next`
  default so a custom `DEVAGENT_CHAIN_CMD` is still emitted verbatim. The dispatch
  line names
  `<project>/<issue>` so a misresolution is visible in the transcript instead
  of surfacing later as a confusing prerequisite failure. This restores on the
  skill-backed path an invariant the script-backed path already held (it has
  always passed `"$project"`).

  Two deliberate behavior changes come with it, neither a side effect:

  1. **Chain hops no longer refresh the global pointer.** Hops now resolve from
     `arg`, and per #282 only pointer/fallback-resolved runs refresh it. A
     *fresh* bare `/devagent:next` is unchanged and still resolves from — and
     refreshes — the pointer.
  2. **Chain hops are no longer covered by the #572 wrong-scope guard.**
     `active_guard_scope` returns immediately when the scope came from `arg`,
     treating an explicit scope as a per-invocation assertion, so hops are now
     exempt. Note this also removes coverage from env-pinned hops, which the
     guard deliberately does NOT exempt today ("an inherited pin is
     contamination, not an assertion"); and a chain whose FIRST resolution came
     from `pointer` or `env` re-emits that value as an `arg` on every later hop,
     laundering a non-asserted source into an asserted one for the chain's
     remainder. The bound on that laundering is CONDITIONAL, not absolute: hop 1 is
     still guard-checked, but `active_guard_scope` is tri-state — it dies on a
     genuine `SCOPE MISMATCH` only when `$PWD` is decidable, and when `$PWD` is
     under no configured `source_dir` it allows with a single warning. In that
     undecidable case hop 1 clears nothing, and the chain launders an unverified
     value into a guard-exempt `arg` for every remaining hop. This is not
     hypothetical: `Issue-578/analysis/2026-08-12-bornred.txt` captured exactly that
     branch firing. `scripts/revise.sh`'s twin emitter — the entry point to a
     whole revision pass, and the remaining pointer-first way into this path — is
     fixed in the same change, so no shipped emitter now hands the model a
     scope-free continuation. Accepted because a chain's scope is correct by
     construction and
     the new dispatch identification keeps it visible; restoring guard coverage
     via a distinct `chain` resolution source is recorded as a follow-up.

- **The suite environment is documented and enforced (#565).**
  `scripts/run-suite.sh` refuses to write an evidence artifact from a filesystem
  where `chmod` is a no-op, and pins a UTF-8 locale for its bats run. Without
  one, bats walks `@test` names byte-wise when encoding them into function
  names; on Git Bash/MSYS that silently skips every name containing a non-ASCII
  character (124 such names across 48 files at this commit) while still
  printing a full `1..N` plan. On glibc the byte is hex-escaped and the test
  still registers, so the skip is an MSYS property — the pin removes the
  dependence on that difference either way. CI pins the same locale,
  `tests/locale-registration.bats` makes a bare locale-empty `bats tests/` fail
  loudly and asserts both platform branches, and README gains
  "Running the test suite".

### Fixed — 2026-08-07
- **Evidence runs now measure the checkout the issue's work lives in, or
  refuse (#571).** `run-suite.sh` used to `cd` into the configured
  `source_dir` regardless of where it was invoked, so a suite run from a git
  worktree or second clone silently produced a green artifact about the wrong
  tree (observed in Issue-553) — a failure #572's scope guard cannot see,
  because it fires even when the project resolves correctly. Both evidence
  scripts now resolve `state.worktree_path`-else-`source_dir`
  (`active_tree_resolve`) and refuse with `TREE MISMATCH` when invoked from
  another checkout of the *same* project (a linked worktree, else an
  equal-`origin` clone; remote-less and differing-origin shapes fail open by
  documented decision — note this fires even for an explicitly-scoped
  invocation, unlike the scope guard). A mid-run HEAD move also refuses, and
  the suite-count artifact carries a canonical `tree:` stamp that
  `preship-evidence.sh` cross-checks (a stamp naming a tree absent in the
  checking environment warns and falls back to the head comparison —
  cross-environment evidence stays shippable). Per-call escape:
  `DEVAGENT_TREE_GUARD_OVERRIDE=1` (truth-valued). Spec §7.5.
- **Unscoped scripts no longer silently act on the global pointer's project
  (#572).** The 14 write-, verify- or transition-capable resolving scripts
  (triage: `docs/resolver-scope-triage.md`, sweep-tested) now refuse a bare
  invocation when `$PWD` demonstrably belongs to a DIFFERENT configured
  project than the one the pointer/env resolved — dying with a message naming
  both projects, both active issues, and the resolution source. An explicit
  scope (positional or `--project`) is never questioned; an undecidable cwd
  allows with a warning naming the resolved project and source; the per-call
  escape is `DEVAGENT_SCOPE_GUARD_OVERRIDE=1` (truth-valued). `next.sh` guards
  before its pointer refresh, so a mismatched bare chain neither dispatches
  nor moves the pointer. `checklist-init.sh` gains `--project`; the four
  workflow docs that invoked these scripts bare now pass the scope. Spec §7.5.

### Fixed — 2026-08-06
- **Workflow-script calls now auto-approve on Claude Code ≥ 2.1.223 (#548).**
  All 57 `allowed-tools` grants (54 commands + 3 skills) moved to the
  probe-verified quoted two-token form
  `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)`.
  Two measured facts drove the form: (1) `${CLAUDE_PLUGIN_ROOT}` now substitutes
  inside `allowed-tools` (#533's 2.1.211 negative flipped — measured, not
  documented upstream); (2) matching is a literal prefix match, so the grant
  must carry the same QUOTED shape the command bodies emit — the old unquoted
  form never matched, and the issue's proposed `${CLAUDE_SKILL_DIR}` target
  never substitutes for command files at all (it would have broken all 54).
  Live-verified end-to-end against the real plugin (stream-json, hermetic
  settings); re-asked on every CC upgrade by the new filled
  `plugin-root-grant-automatch` smoke rung. Both permission-caveat docs homes
  rewritten to the positive; verified-against re-stamped to 2.1.223. Evidence:
  Issue-548 `decision-skill-dir-probe.md`.

### Fixed — 2026-08-04
- **An EMPTY `## Workflow flags` heading no longer leaves the block open
  (#553).** The block ended at the next `#` heading, or at a blank line once at
  least one key had been seen. That `seen` gate exists because terminating on
  the FIRST blank silently dropped every flag in the markdown-conventional
  heading/blank/keys form (#535 redmr). The residual: with an EMPTY heading no
  key has been seen at the blank either, so the block stayed open across prose
  and a later col-1 `key: value` prose line parsed as a live flag. Since #561's
  `implementation-model`/`checking-model` keys are die-class, that had stopped
  being a spurious warning and become a hard `pull.sh` failure — reproduced by
  this issue's own body, whose fenced EXAMPLE made a real scaffold warn. The
  block now also ends, while no key has been seen, at the first non-blank line
  that is not a col-1 key. **No currently-valid body changes meaning:** the rule
  fires only inside the no-key-yet window, so any block whose first in-block
  non-blank line is a key parses bit-for-bit as before. The one trade-off, and
  it is warn-LESS: a block that opens with a MALFORMED key line — mis-cased
  (`Tier:`), indented, or a list item — now closes there and silently drops the
  legitimate keys below it, where before those keys were read. No fixture
  carries that shape; a warn-on-close follow-up is recorded on the issue. See
  spec §6.3. Both rules the issue
  proposed were falsified by execution first — one never fires on the
  reproducer, the other reintroduces the #535 regression — because the two
  shapes share their first three lines and no rule keyed on a blank can
  separate them. One line per state machine, in `flags_get` and
  `flags_validate` alike, with an anti-drift guard asserting it lands in both.

### Fixed — 2026-08-01
- **The mandatory/optional step-split claim is reconciled and now guarded
  (#566).** The "Current capabilities" line still carried the pre-#562 split —
  a mandatory count one higher than today's, naming only two optional steps —
  and now matches spec §6.3, the README, and `docs-site/workflow.md`. The #558
  entry below drops its incidental step-split count, and the docs site drops a
  redundant word-form count — two places where the number carried no weight for
  a reader. The remaining homes keep the number, because a reader of the README
  or the site wants it in front of them; they stay correct by being swept rather
  than by being removed. `tests/checklist-numbering.bats` now sweeps every prose
  home of the claim across the tracked tree — subject set
  derived from the predicate, expected value derived from
  `templates/checklist-standard.md` — so the next optionality change reddens
  instead of drifting silently.

### Added — 2026-07-31
- **`/devagent:crrf` — autonomous capture → red-team → revise → file (#559).**
  An orchestration alias over the existing verbs: invoking it IS the
  operator's bounded autonomy grant (topic declared first; the capture
  skill's multi-epic confirmation answered in advance; scaffolded children
  promoted to their own captures; at most two revise cycles per draft;
  premise-level red-team findings halt before filing; the `push_mr` gate
  delegated to `file.sh` exit 4, never `--yes`; every run ends with a
  kept/discarded manifest). Pinned by `tests/crrf.bats`; the behavioral half
  is baselined by three `crrf-*` eval cases.

### Added — 2026-07-29
- **Per-issue model steering for both step classes, plus a `tier:` compat
  shim (#561).** Two new `## Workflow flags` keys, orthogonal to `tier:`
  (which remains the checklist-template selector):

  | Key | Class | Steps |
  |---|---|---|
  | `implementation-model: <token>` | *thinking* | 2 draft · 9 implement · 10 quality · 11 document · 14 draftmr |
  | `checking-model: <token>` | *checking* | 5 improve · 15 review · 16 redmr · 17 preship |

  Legal tokens: `sonnet opus haiku fable inherit`, validated fail-closed before
  any file write. Both resolve into the per-issue `.devagent-step-models`
  marker at first scaffold, whose format now accepts keyed
  `checking:` / `thinking:` lines in addition to the legacy bare token.

  **Enforcement differs by step and the key names under-promise it:**
  `checking-model` is fully enforced (all four checking steps dispatch and
  consume the tier as their Agent-tool `model:` override), while
  `implementation-model` is enforced for **draft only** and **advisory** for
  9/10/11/14 — those run inline and a session cannot swap its own model, so
  the tier appears only as the `next`/`catchup` hint.

- **`tier: <model>-checking` no longer breaks `pull`.** That form is a model
  annotation from a convention predating #537's claim on the `tier:` key
  (koopman-gnn), and #537 made those bodies die pre-path — blocking the pull
  of already-drafted issues (observed: koopman-gnn#106). `pull.sh` now warns,
  leaves the template on the project default chain, and reads it as
  `checking-model: <model>`. The shim is **permanent grammar and warns
  always** — the warning is the migration nudge, and a removal date would
  orphan capture drafts that are not yet filed. Any other unknown `tier:`
  value still dies listing the legal tier names.

- **Forge labels now steer models (#561).** Both backends already fetched the
  label set and rendered it into `issue.md`'s `- Labels:` line; nothing
  consumed it, so a label-only project got no steering at all (observed:
  factorAI#85 ran every checking step at the config floor despite a
  `tier:check-fable` label). Recognized at first scaffold:
  `tier:impl-<model>` (thinking), `tier:check-<model>` and
  `tier:<model>-checking` (checking). Read once from the `- Labels:` HEADER
  line, so a `- Labels:` line in the body or a tracker comment never steers.

  Per-class precedence: body key > body `tier:` shim > label > the
  `step_models` config chain. Fail-closed: an illegal model token dies, and
  two labels steering one class to different models die naming both — even
  when a body key would have won that class. Never-die: an unrecognized
  `tier:*` label warns and is ignored, a non-`tier:` label is silent.

  **Upgrading:** nothing to do. A body with no new keys and no recognized
  steering labels resolves byte-identically to before (verified by a
  two-checkout capture-diff over all 24 steps × 3 marker states), and legacy
  bare-token markers keep their exact semantics. If your project stamps
  `tier:*` labels, note they now take effect at first pull; later label edits
  never retro-edit an existing marker, and hand-editing the marker remains
  the post-scaffold path.

### Fixed — 2026-07-29
- **Draft dispatch no longer treats a bad per-issue marker as "stay inline"
  (#561).** The step-2 tier was resolved with `$(… || true)`, mapping rc 1
  (bad/unreadable marker) to the same empty string as rc 3 (nothing
  configured). Since #561 makes the marker's structural faults apply to the
  thinking class, rc 1 became reachable at step 2 — so a broken keyed marker
  would have silently disabled dispatch at the one place
  `implementation-model` is enforced. `docs/draft-dispatch-contract.md` and
  `commands/draft.md` now read the exit code, and **rc 1 stops**.

### Changed — 2026-07-29
- **Step 19 (`mergetoall`) is now optional and off by default.** Checklist
  templates (standard, perf, docs-only) and revision blocks scaffold the row
  pre-marked `[-]` (skipped); configuring the per-project `all_prs_branch`
  flips it back to `[ ]` pending at scaffold time (pull, revise, and
  `--retier` all apply the same filter). The workflow is now counted as
  21 mandatory + 3 optional steps.

  **Upgrading:** if you rely on step 19 without `all_prs_branch` set (e.g.
  invoking `/devagent:mergetoall` manually), set `all_prs_branch` in
  `[project.<name>]` — otherwise new checklists and revision blocks ship the
  row skipped and `/devagent:next --auto` sails past it. Checklists
  scaffolded before this release are untouched: a pending row 19 stays
  pending, and `mergetoall.sh`'s runtime auto-skip still covers the
  unconfigured and zero-diff cases at dispatch. A manual per-issue opt-in
  (`checklist-mark.sh --by-name mergetoall` back to pending) does NOT survive
  `/devagent:revise` — the new revision block re-applies the config-derived
  glyph, matching research/spike semantics.

### Changed — 2026-07-26 (#558)
- **Workflow steps are renumbered to execution order.** Checklist numbers are
  now POSITIONS, not permanent IDs: the standard template reads `0 pull` …
  `23 cleanup` top-to-bottom. Old `21 preship` is now `17`, optional old
  `22 research` is now `1`, and old `23 spike` is now `3`. The workflow is
  described as **24-step** throughout (24 numbered step commands). Execution
  order is unchanged — dispatch is by step NAME and file order was always the
  authority.

  **Upgrading with work in flight — run the migrator first.** A checklist
  scaffolded before this release carries the old numbers. The seven script
  **self-marks** now **hard-stop** on it rather than marking the wrong row
  (`checklist_mark` refuses when the number's row name does not match the
  calling step), and command-doc handoffs mark by NAME, which is
  scheme-proof. Callers outside those two classes (e.g. `unstuck.sh`'s
  file-wide `[!]` scan) are NOT guarded (fixed in #587, which marks the
  located row by line); migration is still recommended before resuming:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-checklist-numbering.sh" --dry-run --all
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/migrate-checklist-numbering.sh" --all
  ```

  It is keyed by step NAME (correct on old, a no-op on current, safe on a
  mixed file), idempotent, and reversible with `--reverse` if you roll #558
  back. `--all` covers projects present in `config.toml`; pass any other issue
  directory explicitly. Completed checklists are skipped by design.
  `/devagent:revise` remains an alternative — it opens a fresh, correctly
  numbered revision block — but the migrator is the direct remedy the
  hard-stop message names.

  Without migrating, the older symptom also applies: `[project.<name>.step_models]` tier
  resolution is keyed to the step NUMBER read from the checklist, so an
  old-numbered checklist resolves the WRONG model class: old `3 improve`,
  `13 review` and `21 preship` fall back to the default tier, and old
  `14 redmr` resolves as *thinking*. Run `/devagent:revise` to regenerate the
  checklist's revision block with current numbering before relying on a tier
  override. Steps that can be invoked outside a revision block (`research`,
  `spike`) now read and mark by NAME (`checklist-mark.sh --by-name`), so a
  checklist holding both schemes cannot be mis-marked.

  Numeric per-step keys in `[project.<name>.step_models]` (e.g.
  `"13" = "opus"`) must be remapped by hand; the class keys (`thinking` /
  `checking` / `default`) are unaffected.

### Added — 2026-07-25 (#461)
- `docs-site/`: six audience-facing onboarding pages (what is devAgent,
  install, quickstart, workflow reference, configuration, multi-project &
  concurrency) plus a content-drift policy, guarded by `tests/docs-site.bats`
  (line-1 derive headers, both-sides token pins with README, a step table
  derived from `templates/checklist-standard.md`, command-arity pins).
  Static markdown only — Pages deployment is the #404 sibling child.

### Changed — 2026-07-25 (#541)
- superpowers demoted from declared dependency to recommended plugin: the
  manifest carries no `dependencies` key (measured at CC 2.1.211: dependencies
  never auto-install and an unresolved one silently disables the whole plugin);
  draft / implement / review gain built-in fallbacks + a one-line install
  nudge, and `/devagent:doctor` WARNs when the plugin is absent or disabled.
  Pre-#541 installs sit at `✘ failed to load` under the old cached manifest:
  run `claude plugin update devagent@devagent` once to heal (measured —
  the update alone flips the plugin to `✔ enabled`, superpowers still absent).

Current capabilities as of this release:

### Core
- **58 slash commands** driving a fixed **24-step issue workflow** (21 mandatory,
  plus the optional research step 1, spike step 3, and mergetoall step 19),
  with all state preserved on disk so you can switch issues — or hand one to a
  fresh session — without losing context.
- `next`/`capture`/`ship` converted from commands to user-invocable skills with
  `references/`; `next` thinned 5,764 → 2,209 chars whole-file (operative body
  5,565 → 1,916, pinned under 2,000 by #439's size canary).
- Backends: **GitHub and GitLab** (issue tracker + code forge) and **JIRA** (issue tracker only).
- Subsystems: capture + issue red-team, revision, WBS, status reports, and an
  auth subsystem (PAT / SSH-key lifecycle).

### Plugin conformance & distribution readiness
- `.claude-plugin/plugin.json` manifest with no hard dependencies — `superpowers`
  is recommended, not declared (#541; the pre-#541 manifest declared it).
- SHA-versioned marketplace entry (no pinned `version`) so `/plugin update`
  works without uninstall + reinstall.
- Every command routes its scripts through `${CLAUDE_PLUGIN_ROOT}` (works from a
  marketplace install), enforced by a CI canary.
- `allowed-tools` scoped past a blanket `Bash` grant, on commands and skills
  alike.
- Invocation control: the 14 internal `core-*` skills are hidden from the `/`
  menu (`user-invocable: false`), and `auth`/`init`/`use` are operator-timed
  (`disable-model-invocation: true`).
- `argument-hint` autocomplete grammar on every command.
- Packaging: LICENSE (MIT), this CHANGELOG, and a README install section.
