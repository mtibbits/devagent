---
description: Execute the next actionable step on the active issue
---

# /devagent:next

**Usage:** `/devagent:next [project] [--auto] [--through <step>] [-- <note>]`

Executes the next actionable step (spec §6.5). `--auto` chains to
`cleanup`; `--through <step>` chains up to and including the named
step (spec §7.1).

`--auto` cannot bypass permission gates and cannot continue past `[!]`
or a non-zero step exit (spec §7.2).

## Run the script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/next.sh" "$@"
```

Where `"$@"` is the verbatim CLI tail forwarded by the harness.
