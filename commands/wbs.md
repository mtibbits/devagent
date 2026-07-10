---
description: WBS authoring and rendering (init | update | show)
allowed-tools: Bash
---

Run `scripts/wbs.sh $ARGUMENTS` with the user's arguments.

Subcommands:
- `init` — scaffold `<devdoc>/WBS.md` from the resolved `wbs_template.md` (§12 registry: project paths → devdoc → plugin default)
- `update` — append/update WBS entries from active and recently shipped issues
- `show [--depth N] [--milestone X]` — render `<devdoc>/WBS.md` filtered

Positional arguments follow the standard devAgent invocation grammar
(§6.1): `[project] [issue-dir] [free-form note]`. Unrecognized tokens
between subcommand and flags are treated as `$NOTE`.
