---
description: Alias for `/devagent:wbs update` (workflow step 17)
allowed-tools: Bash
---

Run `scripts/wbs.sh update "$@"` with the user's arguments.

This is the workflow step-17 entrypoint. Identical behavior to
`/devagent:wbs update`; exists as a separate command so the 21-step
workflow chaining (`--auto`, `--through`) and skill mapping can
reference a single verb.
