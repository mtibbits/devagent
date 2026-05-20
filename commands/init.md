---
name: devagent:init
description: Interactive bootstrap of a new project under ~/.claude/devagent/.
---

Run `scripts/init.sh <project>`. The script prompts interactively for
source_dir, devdoc_dir, issue/code backends and repos. Forward the user's
single positional argument verbatim.

On success the script prints the paths it created and suggests
`/devagent:doctor <project>` as the next step.
