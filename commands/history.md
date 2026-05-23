---
description: Show chronological log across a project or single issue.
allowed-tools: [Bash]
---

# /devagent:history

Concatenated, chronologically-merged log view drawn from the `## Log`
section of each issue's `checklist.md`.

## Usage

```
/devagent:history [project] [Issue-NNN]
```

Without an issue, prints every project log entry ascending. With an
issue, restricts to that issue only.

## Invocation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/history.sh" $ARGUMENTS
```
