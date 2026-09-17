# Contributing to devAgent

Thank you for looking under the hood. devAgent is a Claude Code plugin written
almost entirely in bash, with a bats test suite and a small pytest suite. This
page covers what you need installed, how the suite runs, and the conventions
every change is held to. The README's "Running the test suite" section is the
authority on the suite's environmental requirements; this page points at it
rather than repeating it.

## What you need

- `bash` 4.4 or newer (the resolver libraries use namerefs), `git`, `jq`,
  `python3`.
- For the test suite: `bats` 1.10 or newer, GNU `parallel` (bats `--jobs`),
  `pytest`, and `shellcheck` (CI runs it over `scripts/` and `hooks/`).
- Optional, only for the auth subsystem's live paths: `gh`, `glab`, `curl`.
  The tests stub all three; you do not need accounts to run the suite.
- Claude Code, if you want to exercise a change through the slash commands
  rather than by calling the scripts directly. The README states the version
  the plugin is verified against.

## Platforms

Linux and WSL are where the suite is green, and where CI runs
(`ubuntu-24.04`). The suite needs a filesystem where `chmod` really changes a
mode and a UTF-8 locale; native Git Bash on Windows provides neither by
default, so it can run the plugin and individual scripts but is not a
supported environment for the suite. On Windows, develop in a WSL clone on a
native Linux filesystem, not under `/mnt/c`. The README section named above
explains the mechanism behind both requirements.

## Running the suite

The canonical runner is `scripts/run-suite.sh`, which pins the hermetic
environment and refuses to write a result it cannot stand behind:

```sh
bash scripts/run-suite.sh <project>
```

For a single file while you work, pin the locale yourself:

```sh
LC_ALL=C.UTF-8 bats tests/some-file.bats
python3 -m pytest tests/ -v
```

CI runs bats as four shards with `--jobs 2` across files and tests within a
file serially; a new `tests/*.bats` file joins a shard by its sorted position,
so there is no list to maintain.

## Conventions every change follows

- **Sign off every commit.** The project uses the Developer Certificate of
  Origin: `git commit -s`. A PR with an unsigned commit is not merged.
- **Commit subject:** `<type>: <title>`, where `<type>` is the branch prefix
  (`fix`, `chore`, `perf`, and so on) and the title is imperative and under
  72 characters. Put issue references in the body (`Closes #N`, `Related: #N`),
  not the subject. The `Co-Authored-By:` trailer is accepted for AI-assisted
  work. `docs/commit-conventions.md` has the full rules, a template and
  examples.
- **Tests are born red.** A behaviour change ships with a bats or pytest test
  that fails on the old code and passes on the new. If a test cannot be made
  to fail first, say so in the PR and explain what it is guarding instead.
- **shellcheck clean.** `shellcheck -x -s bash` over anything you touch under
  `scripts/` and `hooks/`; CI enforces it. Silence a finding with a targeted
  `# shellcheck disable=` and a reason, never a file-wide one.
- **One change per PR.** Unrelated fixes go in their own PR, even when small.
- **Docs travel with the change.** The README, `docs-site/`, and the
  `commands/*.md` bodies are the user-facing homes; `docs/specs/` is the
  design record. If a change alters what a command does, its body and the
  README's command table change in the same PR. Some documented totals are
  guarded by tests (`tests/cmd_wrappers.bats`) and will tell you.
- **Never widen a tool grant.** Command and skill bodies grant
  `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*")` in the quoted form and
  nothing broader. A change that needs more should be discussed in an issue
  first.

## Filing a bug

Use the bug report form. It asks for the things that make a report actionable:
your Claude Code version, OS and shell, the devAgent commit you have installed
(`claude plugin list`), the exact command, and the output of
`/devagent:doctor`. Please strip real tokens, private repository names and
personal paths before pasting.

For a security problem, do not file a bug: see `SECURITY.md`.

## Proposing something larger

Open an issue before writing code for anything beyond a fix. devAgent's
workflow is deliberately fixed (24 numbered steps, on-disk state), and changes
to the step contract, the config schema, or the artifact formats have
downstream effects on every project that uses the plugin. An issue lets that
be worked out before the diff exists.

## How the maintainer works

The maintainer runs devAgent on devAgent: every issue goes through the plugin's
own 24-step workflow, and the per-issue artifacts (plans, reviews, red-team
reports) live in a separate private devdoc repository. You do not need to use
that workflow to contribute. A plain branch and PR with the conventions above
is exactly what the workflow produces anyway.

There is deliberately no `CODEOWNERS` file: with a single maintainer GitHub
already routes every PR to them, and a one-line CODEOWNERS would only add a
required-review gate that blocks the maintainer's own PRs. This will be
revisited when there is a second maintainer.

## License

By contributing you agree that your contribution is licensed under the MIT
License that covers the repository, and your `Signed-off-by` line certifies
the Developer Certificate of Origin (https://developercertificate.org/).
