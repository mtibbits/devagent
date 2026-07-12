---
description: Inspect resolved artifact templates (list or show).
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "[--project P] list|show <key>"
---

# /devagent:template

Inspect which template file the plugin will use for a given artifact
key, using the three-layer resolution order from spec §12:

1. `[project.<name>.paths].<key>` in `~/.claude/devagent/config.toml`
2. `<devdoc>/templates/<key>.md`
3. `<plugin>/templates/<key>.md` (shipped default)

## Usage

```
/devagent:template [--project P] list
/devagent:template [--project P] show <key>
```

`list` prints a table of every known artifact key, the winning
layer, and the path it resolved to.

`show <key>` prints the resolved content of one template, prefixed
by a banner indicating which layer it came from.

## Invocation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/template.sh" $ARGUMENTS
```

## Custom workflow templates (#120)

Checklist templates (`checklist-<name>`) and `revision_block` resolve via
the §12 registry, so a project may override its workflow. Authoring rules:
gates resolve step NAMES with absent ⇒ no gate — keep
`updatewbs`/`impact`/`lessonslearned`/`preship` named for the gates you
want; `cleanup` (20) is required (hardcoded self-mark). Dispatch is
checklist FILE ORDER; numbers are permanent IDs. A custom step name needs
its own `/devagent:<name>` command (operator-provided). An override path
that does not exist falls through silently to the plugin default.
