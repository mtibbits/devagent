---
description: "Step 10: commit staged changes with DCO sign-off using commit_template."
allowed-tools: Bash
argument-hint: "[project] [issue-dir] [free-form note words ...]"
---

# /devagent:commit

Invokes `scripts/commit.sh` with the parsed arguments per spec §6.1.

## Opt-in scoped auto-staging (#251)

By default, if the working tree has in-scope edits but nothing is staged, step 10
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
