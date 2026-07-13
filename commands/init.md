---
description: Interactive bootstrap of a new project under ~/.claude/devagent/.
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
disable-model-invocation: true
argument-hint: "<project>"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" <project>`. The script prompts interactively for
source_dir, devdoc_dir, issue/code backends and repos. Forward the user's
single positional argument verbatim.

On success the script prints the paths it created and suggests
`/devagent:doctor <project>` as the next step.

## userConfig seed vs. config.toml (precedence) — #459

`.claude-plugin/plugin.json` declares a `userConfig` block (`devdoc_root`,
`default_project`). Claude prompts for these at plugin-enable time and exports the
answers to `init.sh` as `CLAUDE_PLUGIN_OPTION_DEVDOC_ROOT` /
`CLAUDE_PLUGIN_OPTION_DEFAULT_PROJECT`. They are **seeds only**:

- `devdoc_root` supplies the *default* for the `devdoc dir` prompt (an explicit answer
  or the `DA_INIT_DEVDOC_DIR` env short-circuit still wins).
- `default_project` is used as the project name **only** when `init.sh` is run with no
  positional argument (no-arg + no seed → usage, unchanged).

`config.toml` is the single source of truth and **wins**: `init.sh` dies if
`[project.<name>]` already exists, so re-running enable never overwrites a configured
project. Once config.toml exists, the userConfig values are ignored beyond that first
seed — there are never two live sources for the devdoc root.

(`${CLAUDE_PLUGIN_DATA}` — the update-surviving plugin data dir — was evaluated and
**rejected** for devAgent state (spec §3.7). devAgent state already lives at the fixed,
update-surviving `~/.claude/devagent/`.)
