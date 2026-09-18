<!-- derived-from: README.md scripts/ .github/workflows/ -->
# Install

## Prerequisites & supported platforms

devAgent is developed and tested on **Linux** (including WSL on Windows), inside
[Claude Code](https://claude.com/claude-code). macOS is currently untested:
the workflow scripts assume GNU coreutils (`stat -c`, GNU `sed -i`,
`readlink -f`) and bash ≥ 4.4 (the resolver libs use namerefs), and CI runs Linux only. You need:

- **Claude Code** — developed and verified against **2.1.223**; earlier
  versions are untested.
- **`bash` ≥ 4.4**, **`python3` ≥ 3.11** (or 3.8-3.10 plus `tomli`, e.g.
  `apt install python3-tomli` — the TOML parser moved into the stdlib as
  `tomllib` in 3.11), **`jq`**, and **`git`** — the workflow
  scripts' toolchain.
- A forge CLI for your backend: **`gh`** (GitHub), **`glab`** or `curl`
  (GitLab), `curl` (JIRA).
- Contributors additionally need **`bats`** and **`shellcheck >= 0.9.0`**
  (the test suite and the CI lint gate).

Contributors running the test suite have three further requirements — a POSIX
filesystem where `chmod` actually changes the mode, a UTF-8 locale, and, for a tree
with `tests/test_*.py`, an interpreter that can run pytest. On Windows that means a
WSL clone on ext4. `scripts/run-suite.sh` enforces the first two by refusing to write
an artifact at all. The third it RECORDS: it prefers `<tree>/.venv/bin/python` over
ambient `python3`, and if no candidate can run pytest the artifact reads
`pytest: (error)` and `scripts/preship-evidence.sh` refuses it. Set
`DEVAGENT_PYTEST_PYTHON` to point at an interpreter for any other layout (#466). See
[Running the test suite](../README.md#running-the-test-suite).

## Install the plugin

devAgent is a Claude Code plugin. Add its marketplace, then install the
plugin:

```sh
# 1. Add the marketplace (the devagent repo)
claude plugin marketplace add mtibbits/devagent

# 2. Install the plugin
claude plugin install devagent@devagent
```

The install reports two `userConfig` options not yet set (`devdoc_root`,
`default_project`); they only seed the `/devagent:init` interview and can be
left unset.

## Recommended: superpowers

When the [`superpowers`](https://github.com/anthropics/claude-plugins-official)
plugin is installed, devAgent's implement and review steps — and draft on its
inline (non-dispatched) path — use its skills. When it is absent, those steps
fall back to compact built-in paths and print a one-line install nudge;
devAgent itself always loads either way, and `/devagent:doctor` warns when the
plugin is missing or disabled. It is recommended, never hard-required
([#541](https://github.com/mtibbits/devagent/issues/541)):

```sh
# Not configured on a fresh install (measured on 2.1.260; not version-specific)
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install superpowers@claude-plugins-official
```

## Updates

Releases are tagged semver versions (`.claude-plugin/plugin.json` carries the
`version`), so updating picks up the next release without an uninstall +
reinstall. Merges to `master` between releases do not reach an installed
plugin; a release does:

```sh
claude plugin update devagent@devagent
```

Installs from before [#541](https://github.com/mtibbits/devagent/issues/541):
run the update once — the old manifest declared superpowers as a hard
dependency, and a cached copy of it keeps devAgent disabled until updated.

## Permissions

Workflow-script calls auto-approve: as of 2.1.223,
`${CLAUDE_PLUGIN_ROOT}` substitutes inside `allowed-tools`, and devAgent ships the
probe-verified quoted grant form
`Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)`
that matches the quoted script invocations the command bodies emit (#548 decision doc).
On older Claude Code (measured at 2.1.211 in #533, where the substitution does not fire;
older versions are untested but assumed the same, and the exact landing version between
2.1.211 and 2.1.223 is unmeasured, so intermediate versions may or may not prompt)
every workflow script call prompts; approve-and-remember there, or upgrade. The model can
occasionally retype a command in a form that misses the literal prefix match (e.g. a
different drive-letter case) — that falls back to a one-off prompt, never to a wider
grant. Never widen to bare `Bash`.

[← devAgent onboarding](./index.md)
