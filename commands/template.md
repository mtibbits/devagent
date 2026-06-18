---
description: Inspect resolved artifact templates (list or show).
allowed-tools: Bash
---

# /devagent:template

Inspect which template file the plugin will use for a given artifact
key, using the three-layer resolution order from spec §12:

1. `[project.<name>.paths].<key>` in `~/.claude/devagent/config.toml`
2. `<devdoc>/templates/<key>.md`
3. `<plugin>/templates/<key>.md` (shipped default)

## Usage

```
/devagent:template [project] list
/devagent:template [project] show <key>
```

`list` prints a table of every known artifact key, the winning
layer, and the path it resolved to.

`show <key>` prints the resolved content of one template, prefixed
by a banner indicating which layer it came from.

## Invocation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/template.sh" $ARGUMENTS
```
