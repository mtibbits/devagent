---
description: Multi-project dashboard of active issues, STUCK, and parked
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*"), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/*" *)
argument-hint: "[project|--all]"
---

# /devagent:status

**Usage:** `/devagent:status [project|--all]`

Per spec §6.5. With no args, prints every configured project. With a
project name, prints that one. With `--all`, same as no args.

After the project blocks it prints one line for each devDoc repository that has
commits not on origin (#1148), from local refs only:
`devDoc <repo>: <N> commits not on origin/<branch>, oldest <author date>`, or
`devDoc <repo>: branch <branch> is not on origin` (also: the count could not be
read; HEAD is detached). Only repositories that at least one project with
`commit_devdoc = true` uses are shown, each once. That key is read from the
config, not from a trust policy, so under a trust policy the shown set can differ
from the repositories cleanup syncs. A step-21 merge commit (`wbs update`'s sync,
#1149) shows here until the next cleanup pushes it. See `commands/cleanup.md`,
"The devDoc sync".

For WBS structure, estimates and progress across every project, see
`/devagent:portfolio`, which writes one JSON document over all of them; its
`--ready` lists the leaves ready to start in every project.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" $ARGUMENTS
```
