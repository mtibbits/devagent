<!-- derived-from: README.md scripts/ -->
# Install

## Prerequisites & supported platforms

devAgent runs on **Linux and macOS**, inside
[Claude Code](https://claude.com/claude-code). You need:

- **Claude Code** — developed and verified against **2.1.211**; earlier
  versions are untested.
- **`bash`**, **`python3`**, and **`jq`** — the workflow scripts' toolchain.
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
plugin is missing or disabled. It is recommended, never hard-required:

```sh
claude plugin install superpowers@claude-plugins-official
```

Installs from before #541: run `claude plugin update devagent@devagent` once —
the old manifest declared superpowers as a hard dependency, and a cached copy
of it keeps devAgent disabled until updated.

## Updates

The plugin is versioned by git commit SHA (no pinned `version`), so updating
picks up new commits without an uninstall + reinstall:

```sh
claude plugin update devagent@devagent
```

## Permissions caveat

As of Claude Code 2.1.211, `${CLAUDE_PLUGIN_ROOT}` is not substituted inside
`allowed-tools`, so devAgent's scoped workflow-script grants don't auto-match
and you'll be prompted to approve each workflow script call. Approve-and-
remember when prompted, or pre-approve by adding a `permissions.allow` entry
in `~/.claude/settings.json` that covers the plugin's installed version
directory under `~/.claude/plugins/cache/devagent/…` (absolute path, `:*`
covering the version segment). Never widen to bare `Bash`.

## While the repo is private

`claude plugin marketplace add` clones over your configured git access — you
need read access to `mtibbits/devagent` (an SSH key, or `gh auth` with `repo`
scope). Once the repo is public this note no longer applies.

[← devAgent onboarding](./index.md)
