---
description: Validate config, state, paths, and template resolution.
allowed-tools: Bash
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" [project]`. With no argument, doctor runs against
every project in `~/.claude/devagent/config.toml` and reports each one.
With a project argument, only that project is checked.

doctor checks structural concerns (config parses; required project fields
present; source_dir/devdoc_dir exist; state file mode 600; secrets dir mode
700; checklist template resolves) and, via the auth doctor hook, auth-secret
presence and reachability.

Forward arguments verbatim.
