---
description: "Step 12: commit staged changes with DCO sign-off using commit_template."
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[project] [issue-dir]"
---

# /devagent:commit

Invokes `scripts/commit.sh` with the parsed arguments per spec §6.1.

Per-task commits during implement are the norm (#116): a clean tree with
commits ahead of baseline is a no-op success (step marked `[x]`), a dirty
tree with nothing staged dies loud (#25), a clean tree whose commits-ahead
state cannot be classified (missing/stale `baseline_sha`) dies loud rather
than guessing, and the branch-identity guard (#69) precedes every path.

## born-red gate (#362/#409)

For projects with `born_red = true`, step 12 checks the issue's born-red
artifact before committing:

- The latest artifact reports **FLAGGED** (a new test is green at baseline) →
  die; make the test fail without the change, or allowlist it with a reason.
- **No** artifact exists → die (#409): `born_red=true` means the implement-phase
  born-red run is mandatory, so an absent artifact is a skipped run, not a pass.
  Re-run `scripts/born-red.sh`; a change with no new tests still writes a
  NO-NEW-TESTS artifact that satisfies the gate.
- The artifact **pins the `tests/` delta** it judged (a `tests-fingerprint:`
  hash over every changed/added path under `tests/`). If a test — or a shared
  helper/fixture under `tests/` that could flip a judged test's result — was
  added/edited/removed since the run, the recorded verdict is stale → die (#410);
  re-run `scripts/born-red.sh` to re-judge. The fingerprint is invariant to a
  file's tracked/untracked status, so merely `git add`-ing an already-judged test
  does not trip it. The check inspects `source_dir` (matching born-red), so a
  change made only inside a separate worktree is not seen — the same boundary
  born-red itself has. Older artifacts without the line are grandfathered.

With `born_red` unset/false (the default — e.g. non-bats projects) the gate is
inert.

## Opt-in scoped auto-staging (#251)

By default, if the working tree has in-scope edits but nothing is staged, step 12
dies loud and asks you to `git add` your files (the #25 safeguard against shipping
an empty PR). Setting `commit_autostage = true` (project or default config) makes
the step stage the issue's declared in-scope files itself instead:

- List the in-scope **files**, one repo-relative *file* path per line, in
  `<issue-dir>/.devagent-scope`. **Directories are not allowed** — list each file
  explicitly (a directory entry would recursively capture untracked siblings).
- Only those exact files are staged (`git add -- <paths>`); there is **no**
  `git add -A`/`.`/glob — an out-of-scope dirty/untracked file is never staged and
  is provably absent from the commit.
- A missing/empty `.devagent-scope`, an invalid entry (`.`, `..`, a leading `-`,
  a `:` pathspec-magic prefix, an absolute path, a glob char, or a directory), or
  paths that aren't actually dirty all fall back to the die-loud guard —
  auto-staging never guesses.

With `commit_autostage` unset/false the behavior is unchanged.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" $ARGUMENTS`
