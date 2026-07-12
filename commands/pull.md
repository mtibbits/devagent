---
description: Fetch an issue from origin or fork and scaffold its workflow directory
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "<project> origin|fork <issue-num>"
---

# /devagent:pull

**Usage:** `/devagent:pull <project> origin|fork <issue-num>`

Runs `scripts/pull.sh` to fetch issue `<num>` from the configured
backend, write `<devdoc>/<dir_prefix><num>/issue.md`, initialise
`checklist.md`, mark step 0 done, and promote the issue to active.

Implements workflow step 0 per spec §6.3.

## Behavior

- `origin` reads `[project.<name>.issue_source]` from config.toml
- `fork`   reads `[project.<name>.issue_source_fork]`
- Existing `checklist.md` is preserved; `issue.md` is overwritten on refetch

## Run the script

Execute, substituting positional args. Pass through `$NOTE` only as
documentation — `pull` does not consume notes.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pull.sh" <project> <origin|fork> <num>
```
