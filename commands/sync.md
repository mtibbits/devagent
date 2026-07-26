---
description: "Async merge detection: fires on_merge for shipped issues that merged outside this session."
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)
argument-hint: "--all | <project>"
---

# /devagent:sync

Invokes `scripts/sync.sh` with the parsed arguments per spec §6.1. Two
forms: `--all` (sync every configured project) or `<project>` (one project);
there is no positional issue/note argument.

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" $ARGUMENTS`

## Closeout handoff (#363)

<!-- Sync is a standalone command with no checklist step of its own, so there is
     no per-step checklist-mark to make here (this is not a workflow-step handoff). -->
Sync executes NO closeout steps — on a detected merge it makes the checklist
truthful (unblocks any `[?]` closeout step to `[ ]`) and, while closeout is
pending, prints a derived nudge line:

```
CLOSEOUT: <project>/<issue> merged — pending: <steps> — run /devagent:next <project> --auto
```

If the output above contains a `CLOSEOUT:` line, **ask the operator ONE
question** offering to run that `/devagent:next <project> --auto` (which chains
steps 19→23 on existing machinery). Never auto-invoke it — the closeout steps
include gated, tree-mutating work that needs an operator in the loop. If there is
no `CLOSEOUT:` line, nothing is pending; stop.

**Unattended (cron `--all`, no model):** identical script behavior; no prompt can
fire and nothing is executed or deleted — the queue simply survives as checklist
state (the `[?]`→`[ ]` flip), and the next interactive surface routes to
`/devagent:next`.
