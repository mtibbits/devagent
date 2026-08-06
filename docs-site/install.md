<!-- derived-from: README.md scripts/ .github/workflows/ -->
# Install

## Prerequisites & supported platforms

devAgent is developed and tested on **Linux**, inside
[Claude Code](https://claude.com/claude-code). macOS is currently untested:
the workflow scripts assume GNU coreutils (`stat -c`, GNU `sed -i`,
`readlink -f`) and bash ≥ 4, and CI runs Linux only. You need:

- **Claude Code** — developed and verified against **2.1.223**; earlier
  versions are untested.
- **`bash` ≥ 4**, **`python3` ≥ 3.11** (or 3.8-3.10 plus `tomli`, e.g.
  `apt install python3-tomli` — the TOML parser moved into the stdlib as
  `tomllib` in 3.11), **`jq`**, and **`git`** — the workflow
  scripts' toolchain.
- A forge CLI for your backend: **`gh`** (GitHub), **`glab`** or `curl`
  (GitLab), `curl` (JIRA).
- Contributors additionally need **`bats`** and **`shellcheck >= 0.9.0`**
  (the test suite and the CI lint gate).

## Install the plugin

devAgent is a Claude Code plugin. Add its marketplace, then install the
plugin:

```sh
# 1. Add the marketplace (the devagent repo)
claude plugin marketplace add mtibbits/devagent

# 2. Install the plugin
claude plugin install devagent@devagent
```

## Recommended: superpowers

When the [`superpowers`](https://github.com/anthropics/claude-plugins-official)
plugin is installed, devAgent's implement and review steps — and draft on its
inline (non-dispatched) path — use its skills. When it is absent, those steps
fall back to compact built-in paths and print a one-line install nudge;
devAgent itself always loads either way, and `/devagent:doctor` warns when the
plugin is missing or disabled. It is recommended, never hard-required
([#541](https://github.com/mtibbits/devagent/issues/541)):

```sh
claude plugin install superpowers@claude-plugins-official
```

## Updates

The plugin is versioned by git commit SHA (no pinned `version`), so updating
picks up new commits without an uninstall + reinstall:

```sh
claude plugin update devagent@devagent
```

Installs from before [#541](https://github.com/mtibbits/devagent/issues/541):
run the update once — the old manifest declared superpowers as a hard
dependency, and a cached copy of it keeps devAgent disabled until updated.

## Permissions

As of Claude Code **2.1.223**, `${CLAUDE_PLUGIN_ROOT}` IS substituted inside
`allowed-tools`, and devAgent ships the probe-verified quoted grant form, so
workflow-script calls auto-approve without prompting (#548 decision doc: the
match is a literal prefix match, which is why the grants carry the same quoted
form the command bodies emit). On earlier Claude Code (≤ 2.1.211, measured in
#533) the substitution never fires and every workflow script call prompts —
approve-and-remember when prompted, or upgrade Claude Code. The model can
occasionally retype a command in a form that misses the prefix match (e.g.
drive-letter case); that falls back to a one-off prompt, never to a wider
grant. Never widen to bare `Bash`.

## While the repo is private

`claude plugin marketplace add` clones over your configured git access — you
need read access to `mtibbits/devagent` (an SSH key, or `gh auth` with `repo`
scope). Once the repo is public this note no longer applies.

[← devAgent onboarding](./index.md)
