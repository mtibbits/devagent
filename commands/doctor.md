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

Per project, `potholes_workflow register: <path|not configured|absent>` names the shared workflow register the project resolves (FAIL on a relative path or unreadable config). One global #611 row, WARN only: `seed carries no private project name` runs the
private-project-name predicate over the shipped `templates/potholes.md` for
every non-public project key in the LIVE config (the suite canary skips until
the seed is curated; doctor is ungated; an unreadable seed, or a missing seed/fixture, is a FAIL — the check never silently skips). A key
absent from the suite fixture `tests/fixtures/private-project-names.txt` is
reported as INFO only — that fixture must never be the first disclosure of a
private name into the public repo, so new projects are checked live, not added.
