# Security policy

devAgent is a Claude Code plugin made of shell scripts, hooks, command bodies
and templates. Everything it does runs on your machine, under your user, with
whatever `gh`, `glab`, `curl` and git credentials that user already holds. That
is the surface this policy covers.

## Supported versions

Only `master` is supported. The plugin is installed and updated by commit SHA
(`claude plugin update devagent@devagent`), there are no release branches, and
fixes are not backported. A report against an older commit is welcome, but the
fix lands on `master` and the remedy is to update.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**. The report is visible
only to the maintainer until a fix is published, and GitHub notifies the
maintainer directly.

Please do not open a public issue for anything exploitable, and do not include
real credentials, tokens or private repository content in a report. A
description of the path (which script, which input, which credential it would
reach) is enough; a minimal reproduction using synthetic values is ideal.

There is no security email address. If the Security tab's report button is not
available to you, open an issue that says only "security report, please enable
private reporting" and the maintainer will make contact through GitHub.

## What is in scope

- `scripts/` and `hooks/`: anything that lets an issue body, a tracker
  response, a template, a config value or a file in the working tree cause a
  command to run, a file to be written outside the intended tree, or a
  credential to be read or exposed.
- The auth subsystem's secret store under `~/.claude/devagent/secrets/`: the
  0700/0600 mode invariants pinned by `tests/auth_security.bats`, and any path
  by which a stored PAT could leak into a log, an artifact or a commit.
- The `allowed-tools` grants carried by command and skill bodies: a change that
  widens a grant beyond the quoted `${CLAUDE_PLUGIN_ROOT}/scripts/*` form, or
  that lets model-typed text reach an unquoted shell.
- Anything that would make a devAgent step push, publish, close or change
  visibility on a repository without the operator asking for it.

## What is out of scope

- Claude Code itself, the Claude model, and the plugin marketplace mechanism.
  Report those to Anthropic through their own security channel.
- GitHub, GitLab and JIRA.
- Choices the operator makes in their own `config.toml`, such as pointing the
  devdoc tree at a shared location.
- The content of the model's output when the scripts have behaved correctly.

## What to expect

devAgent has a single maintainer. A report is acknowledged within seven days.
After that the fix is best effort, prioritised by whether the issue can reach a
credential or leave the machine. You will be told when a fix is on `master`
and, if you want, credited in the commit that carries it.

## Good-faith research

Testing against your own installation, your own repositories and synthetic
credentials is welcome and will not be treated as a violation. Please do not
test against other people's repositories or trackers.
