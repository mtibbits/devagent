---
description: Validate config, state, paths, and template resolution.
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" [project]`. With no argument, doctor runs against
every project in `~/.claude/devagent/config.toml` and reports each one.
With a project argument, only that project is checked.

doctor checks structural concerns (config parses; required project fields
present; source_dir/devdoc_dir exist; state file mode 600; secrets dir mode
700; checklist template resolves; and — #541, global phase — whether the
recommended `superpowers` plugin is installed and enabled, WARN + install
hint when it is absent or disabled — deliberately silent when the CLI is
missing or errors, an undetermined state, not an absence claim) and, via
the auth doctor hook, auth-secret presence and reachability.

Forward arguments verbatim.

Two #611 rows, WARN only: `seed carries no private project name` runs the
private-project-name predicate over the shipped `templates/potholes.md` for
every non-public project key in the live config (the suite canary skips until
the seed is curated; doctor is ungated), and `private-project fixture list
covers config` reports any non-public config project key missing from
`tests/fixtures/private-project-names.txt`.
