---
description: Multi-project dashboard of active issues, STUCK, and parked
---

# /devagent:status

**Usage:** `/devagent:status [project|--all]`

Per spec §6.5. With no args, prints every configured project. With a
project name, prints that one. With `--all`, same as no args.

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" "$@"
```
