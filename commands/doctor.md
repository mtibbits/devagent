---
description: Validate config, state, paths, and template resolution.
---

Run `scripts/doctor.sh [project]`. With no argument, doctor runs against
every project in `~/.claude/devagent/config.toml` and reports each one.
With a project argument, only that project is checked.

Plan 1's doctor checks structural concerns only (config parses; required
project fields present; source_dir/devdoc_dir exist; state file mode 600;
secrets dir mode 700; checklist template resolves). Auth and reachability
checks are added in Plan 8.

Forward arguments verbatim.
