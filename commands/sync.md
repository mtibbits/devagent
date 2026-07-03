---
description: Async merge detection: fires on_merge for shipped issues that merged outside this session.
allowed-tools: Bash
argument-hint: "--all | <project>"
---

# /devagent:sync

Invokes `scripts/sync.sh` with the parsed arguments per spec §6.1. Two
forms: `--all` (sync every configured project) or `<project>` (one project);
there is no positional issue/note argument.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" $ARGUMENTS`
