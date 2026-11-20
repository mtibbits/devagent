<!-- derived-from: README.md scripts/ -->
# Install

## Prerequisites

**Supported platforms.** Linux, or Windows with Git Bash.
WSL is for contributors to devAgent itself.
macOS is untested.

- [Claude Code](https://claude.com/claude-code) **2.1.223** (earlier versions are untested).
- `git` ≥ 2.29.
- `bash` ≥ 4.4.
- `python3` ≥ 3.11.
- `jq`.
- Coreutils `timeout`.
- Your tracker's command-line tool: `gh` for GitHub.
- `shellcheck` 0.9.0 or newer, for a project with `analyze = "shellcheck"` (step 13 needs it).

GitLab, JIRA, or Python older than 3.11? See [README's Install section (Prerequisites)](../README.md#install).
Working on devAgent itself? See [CONTRIBUTING.md](../CONTRIBUTING.md).

## Install the plugin

```sh
# 1. Add the marketplace (the devagent repo)
claude plugin marketplace add mtibbits/devagent

# 2. Install the plugin
claude plugin install devagent@devagent
```

The install reports two `userConfig` options not yet set (`devdoc_root`, `default_project`); they
only seed the `/devagent:init` interview and can be left unset.

Recommended, not required: the superpowers plugin, whose skills the implement and review steps use.

```sh
# Not configured on a fresh install (measured on 2.1.260; not version-specific)
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install superpowers@claude-plugins-official
```

Workflow scripts usually run without a prompt on [README's Claude Code version](../README.md#install).

## First run

1. Open your project's directory in Claude Code.
2. Set the project up by following the [Quickstart](./quickstart.md).
3. Check it: `/devagent:doctor <project>`. It passes when it reports no errors.

## Updates

Run this to pick up a new release; a merge to `master` alone does not reach you. An
install whose old manifest required superpowers stays disabled until it runs once:

```sh
claude plugin update devagent@devagent
```

[← devAgent onboarding](./index.html)
