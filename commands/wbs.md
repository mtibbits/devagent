---
description: WBS authoring and rendering (init | update | show)
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "<init|update|show> [project] [args]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wbs.sh" $ARGUMENTS` with the user's arguments.

Subcommands:
- `init [--force]` — scaffold `<devdoc>/WBS.md` from the resolved `wbs_template.md` (§12 registry: project paths → devdoc → plugin default); `--force` overwrites an existing `WBS.md`
- `update` — append/update WBS entries from active and recently shipped issues
- `show [--depth N] [--milestone X]` — render `<devdoc>/WBS.md` filtered

Positional `[project]` and `[issue-dir]` follow the standard devAgent
invocation grammar (§6.1). This command consumes **no note**: tokens left
after the subcommand and its flags are warned about and ignored
(`wbs-update.sh` / `wbs-show.sh`), not captured as `$NOTE`.
