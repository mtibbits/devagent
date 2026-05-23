---
description: WBS authoring and rendering (init | update | show)
allowed-tools: Bash
---

Run `scripts/wbs.sh "$@"` with the user's arguments.

Subcommands:
- `init` — scaffold `<devdoc>/WBS.md` from `templates/wbs_template.md`
- `update` — append/update WBS entries from active and recently shipped issues
- `show [--depth N] [--milestone X]` — render `<devdoc>/WBS.md` filtered

Positional arguments follow the standard devAgent invocation grammar
(§6.1): `[project] [issue-dir] [free-form note]`. Unrecognized tokens
between subcommand and flags are treated as `$NOTE`.
